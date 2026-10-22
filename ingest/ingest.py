"""
NOAA LCD v2 ingest: detect changes at the source, download, and load into Snowflake.

    python ingest.py --start-year 2006 --end-year 2026          # initial backfill
    python ingest.py --start-year 2025 --end-year 2026          # scheduled run: recent years only
    python ingest.py --check-only --start-year 2006             # report what changed, load nothing
    python ingest.py --stations USW00094846 --start-year 2024 --end-year 2024
    python ingest.py --load-station-list                        # (re)load NOAA station metadata

Change detection (is there anything new at NOAA?)
  For every station-year we send a cheap HTTP HEAD request and compare the
  server's Content-Length / Last-Modified with what we recorded last time in
  CLIMATE_RAW.LCD.INGEST_MANIFEST:
    new        -> not in the manifest yet          -> download + load
    changed    -> size or Last-Modified differs    -> download, compare MD5:
                    content really differs         -> load (NOAA revised or appended data)
                    same MD5                       -> metadata-only change, skip
    unchanged  -> same size and Last-Modified      -> skip (no download)
    missing    -> 404, station-year not published  -> log, skip
  The current year changes daily; older years change only when NOAA revises
  data. A scheduled run therefore scans the last 1-2 years, and a periodic full
  scan (e.g. monthly) catches historical revisions.
  At national scale (thousands of stations) the same logic reads NOAA's yearly
  inventory bundle (one JSON per file with size, end date and column list)
  instead of one HEAD request per file.

Schema drift (did NOAA change the columns?)
  1. Detect: each new or changed file's header is compared with the raw table's
     columns; differences are written to SCHEMA_DRIFT_LOG and logged as warnings.
  2. Absorb: the raw table has ENABLE_SCHEMA_EVOLUTION = TRUE and COPY matches
     columns by name, so a new column is added to the table automatically and a
     dropped column simply loads as NULL. The load never breaks.
  3. Contain: dbt staging selects an explicit column list, so new raw columns
     never leak downstream; tests on the columns we depend on fail loudly if one
     disappears or is renamed.

Idempotent: reruns re-check, but only new/changed content is downloaded and loaded.
A reloaded file adds new row versions; dbt staging keeps the latest (_LOADED_AT).

Connection (environment variables):
    SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, and one of:
      SNOWFLAKE_PRIVATE_KEY_PATH   (key-pair auth: service user, used by GitHub Actions)
      SNOWFLAKE_AUTHENTICATOR=externalbrowser   (local, interactive)
      SNOWFLAKE_PASSWORD
    Optional: SNOWFLAKE_ROLE (LOADER_ROLE), SNOWFLAKE_WAREHOUSE (CLIMATE_WH),
              SNOWFLAKE_DATABASE (CLIMATE_RAW), SNOWFLAKE_SCHEMA (LCD)
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import hashlib
import json
import logging
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path

import requests

BASE_URL = os.getenv(
    "LCD_BASE_URL",
    "https://www.ncei.noaa.gov/oa/local-climatological-data/v2/access",
)
REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SEED = REPO_ROOT / "dbt" / "seeds" / "stations_of_interest.csv"
DEFAULT_DATA_DIR = REPO_ROOT / "data" / "lcd_v2"
STATION_LIST_URL = os.getenv(
    "LCD_STATION_LIST_URL",
    "https://www.ncei.noaa.gov/oa/local-climatological-data/v2/doc/lcdv2-station-list.txt",
)
STAGE = "@LCD_STAGE"
METADATA_COLUMNS = {"_SOURCE_FILE", "_FILE_ROW_NUMBER", "_LOADED_AT"}
EXPECTED_HEADER_PREFIX = b'"STATION","DATE"'

log = logging.getLogger("ingest")


@dataclass
class FileState:
    station: str
    year: int
    status: str = ""                 # new | changed | unchanged | missing | error
    remote_size: int | None = None
    remote_last_modified: str | None = None
    md5: str | None = None
    path: Path | None = None

    @property
    def name(self) -> str:
        return f"LCD_{self.station}_{self.year}.csv"

    @property
    def url(self) -> str:
        return f"{BASE_URL}/{self.year}/{self.name}"


# ------------------------------------------------------------ change detection
def head(fs: FileState, session: requests.Session) -> FileState:
    try:
        r = session.head(fs.url, timeout=60, allow_redirects=True)
        if r.status_code == 404:
            fs.status = "missing"
            return fs
        r.raise_for_status()
        size = r.headers.get("Content-Length")
        fs.remote_size = int(size) if size else None
        fs.remote_last_modified = r.headers.get("Last-Modified")
    except requests.RequestException as exc:
        log.error("HEAD failed %s: %s", fs.name, exc)
        fs.status = "error"
    return fs


def classify(fs: FileState, manifest: dict[str, dict]) -> FileState:
    if fs.status in ("missing", "error"):
        return fs
    prev = manifest.get(fs.name)
    if prev is None:
        fs.status = "new"
    elif (prev["remote_size"] == fs.remote_size
          and prev["remote_last_modified"] == fs.remote_last_modified
          and fs.remote_last_modified is not None):
        fs.status = "unchanged"
    else:
        fs.status = "changed"  # confirmed (or not) by MD5 after download
    return fs


def download(fs: FileState, data_dir: Path, session: requests.Session,
             manifest: dict[str, dict]) -> FileState:
    target = data_dir / str(fs.year) / fs.name
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".part")
    md5 = hashlib.md5()
    try:
        with session.get(fs.url, stream=True, timeout=300) as r:
            r.raise_for_status()
            with open(tmp, "wb") as fh:
                for chunk in r.iter_content(chunk_size=1 << 20):
                    fh.write(chunk)
                    md5.update(chunk)
    except requests.RequestException as exc:
        log.error("download failed %s: %s", fs.name, exc)
        fs.status = "error"
        return fs
    # Guard: NOAA redirects some requests to an HTML explorer page. Only accept
    # files that really are LCD CSVs, so garbage never reaches Snowflake.
    with open(tmp, "rb") as fh:
        head_bytes = fh.read(len(EXPECTED_HEADER_PREFIX))
    if head_bytes != EXPECTED_HEADER_PREFIX:
        log.error("not an LCD CSV, rejected: %s (starts with %r)", fs.name, head_bytes[:40])
        tmp.unlink(missing_ok=True)
        fs.status = "error"
        return fs
    tmp.replace(target)  # atomic: never leave a half-written CSV behind
    fs.md5, fs.path = md5.hexdigest(), target
    prev = manifest.get(fs.name)
    if fs.status == "changed" and prev and prev.get("content_md5") == fs.md5:
        fs.status = "unchanged"  # server metadata moved, content identical
    return fs


# ------------------------------------------------------------- schema drift
def raw_columns(cur) -> set[str]:
    cur.execute(
        "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS "
        "WHERE TABLE_SCHEMA = CURRENT_SCHEMA() AND TABLE_NAME = 'RAW_LCD_OBSERVATIONS'"
    )
    return {r[0].upper() for r in cur.fetchall()} - METADATA_COLUMNS


def check_drift(cur, files: list[FileState]) -> None:
    expected = raw_columns(cur)
    for fs in files:
        with open(fs.path, newline="", encoding="utf-8") as fh:
            header = {h.strip().upper() for h in next(csv.reader(fh))}
        added, removed = sorted(header - expected), sorted(expected - header)
        if added or removed:
            log.warning("schema drift in %s: added=%s removed=%s", fs.name, added, removed)
            cur.execute(
                "INSERT INTO SCHEMA_DRIFT_LOG (FILE_NAME, ADDED_COLUMNS, REMOVED_COLUMNS) "
                "SELECT %s, PARSE_JSON(%s), PARSE_JSON(%s)",
                (fs.name, json.dumps(added), json.dumps(removed)),
            )


# ---------------------------------------------------------------- snowflake
def connect():
    import snowflake.connector  # lazy: --check-only without Snowflake is not supported

    params = dict(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        role=os.getenv("SNOWFLAKE_ROLE", "LOADER_ROLE"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "CLIMATE_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "CLIMATE_RAW"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "LCD"),
    )
    if os.getenv("SNOWFLAKE_PRIVATE_KEY_PATH"):          # service user, key-pair (CI / scheduled)
        params["authenticator"] = "SNOWFLAKE_JWT"
        params["private_key_file"] = os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]
    elif os.getenv("SNOWFLAKE_AUTHENTICATOR"):           # e.g. externalbrowser (local dev)
        params["authenticator"] = os.environ["SNOWFLAKE_AUTHENTICATOR"]
    else:
        params["password"] = os.environ["SNOWFLAKE_PASSWORD"]
    return snowflake.connector.connect(**params)


def read_manifest(cur) -> dict[str, dict]:
    cur.execute("SELECT FILE_NAME, REMOTE_SIZE, REMOTE_LAST_MODIFIED, CONTENT_MD5 FROM INGEST_MANIFEST")
    return {r[0]: {"remote_size": r[1], "remote_last_modified": r[2], "content_md5": r[3]}
            for r in cur.fetchall()}


def write_manifest(cur, files: list[FileState], loaded: set[str]) -> None:
    rows = [(f.name, f.station, f.year, f.status, f.remote_size, f.remote_last_modified, f.md5,
             f.name in loaded) for f in files if f.status not in ("error",)]
    if not rows:
        return
    cur.execute("CREATE OR REPLACE TEMPORARY TABLE _MANIFEST_BATCH LIKE INGEST_MANIFEST")
    cur.executemany(
        "INSERT INTO _MANIFEST_BATCH (FILE_NAME, STATION_ID, YEAR, LAST_STATUS, REMOTE_SIZE, "
        "REMOTE_LAST_MODIFIED, CONTENT_MD5, LAST_LOADED_AT) "
        "VALUES (%s, %s, %s, %s, %s, %s, %s, IFF(%s, CURRENT_TIMESTAMP(), NULL))",
        rows,
    )
    cur.execute(
        """
        MERGE INTO INGEST_MANIFEST m USING _MANIFEST_BATCH b ON m.FILE_NAME = b.FILE_NAME
        WHEN MATCHED THEN UPDATE SET
            LAST_STATUS = b.LAST_STATUS,
            REMOTE_SIZE = COALESCE(b.REMOTE_SIZE, m.REMOTE_SIZE),
            REMOTE_LAST_MODIFIED = COALESCE(b.REMOTE_LAST_MODIFIED, m.REMOTE_LAST_MODIFIED),
            CONTENT_MD5 = COALESCE(b.CONTENT_MD5, m.CONTENT_MD5),
            LAST_CHECKED_AT = CURRENT_TIMESTAMP(),
            LAST_LOADED_AT = COALESCE(b.LAST_LOADED_AT, m.LAST_LOADED_AT)
        WHEN NOT MATCHED THEN INSERT
            (FILE_NAME, STATION_ID, YEAR, LAST_STATUS, REMOTE_SIZE, REMOTE_LAST_MODIFIED,
             CONTENT_MD5, LAST_CHECKED_AT, LAST_LOADED_AT)
        VALUES (b.FILE_NAME, b.STATION_ID, b.YEAR, b.LAST_STATUS, b.REMOTE_SIZE,
                b.REMOTE_LAST_MODIFIED, b.CONTENT_MD5, CURRENT_TIMESTAMP(), b.LAST_LOADED_AT)
        """
    )


def put_files(cur, files: list[FileState]) -> None:
    for fs in files:
        local = fs.path.resolve().as_posix()  # forward slashes; quotes handle spaces in paths
        cur.execute(f"PUT 'file://{local}' {STAGE}/v2/{fs.year}/ AUTO_COMPRESS = TRUE OVERWRITE = TRUE")
        log.info("PUT %-32s %s", fs.name, cur.fetchone()[6])


def copy_observations(cur) -> set[str]:
    cur.execute(
        f"""
        COPY INTO RAW_LCD_OBSERVATIONS
        FROM {STAGE}/v2/
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
        INCLUDE_METADATA = (
            _SOURCE_FILE     = METADATA$FILENAME,
            _FILE_ROW_NUMBER = METADATA$FILE_ROW_NUMBER,
            _LOADED_AT       = METADATA$START_SCAN_TIME
        )
        ON_ERROR = ABORT_STATEMENT
        """
    )
    rows = cur.fetchall()
    if len(rows) == 1 and len(rows[0]) == 1:  # "Copy executed with 0 files processed."
        log.info("COPY: nothing new to load")
        return set()
    loaded = {Path(r[0]).name.removesuffix(".gz") for r in rows if r[1] == "LOADED"}
    log.info("COPY: %d files loaded, %d rows", len(loaded), sum(r[3] or 0 for r in rows if r[1] == "LOADED"))
    for r in rows:
        if r[1] != "LOADED":
            log.warning("COPY result: %s", r)
    return loaded


def load_station_list(cur, data_dir: Path, session: requests.Session) -> None:
    """Download NOAA's fixed-width station list, convert to CSV, fully replace RAW_LCD_STATIONS."""
    r = session.get(STATION_LIST_URL, timeout=120)
    r.raise_for_status()
    text = r.content.decode("utf-8")
    if not text[:11].strip().isalnum():  # guard: first token must be a station id, not HTML
        raise RuntimeError(f"unexpected station list content: {text[:60]!r}")
    # Offsets verified against the file: id 0-11, lat 12-20, lon 21-30, elev 31-37, name 41-71, wmo 80-85
    out = data_dir / "stations" / "lcdv2_stations.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with open(out, "w", newline="") as dst:
        w = csv.writer(dst)
        w.writerow(["STATION_ID", "LATITUDE", "LONGITUDE", "ELEVATION_M", "STATION_NAME", "WMO_ID"])
        for line in text.splitlines():
            if not line.strip():
                continue
            w.writerow([line[0:11].strip(), line[12:20].strip(), line[21:30].strip(),
                        line[31:37].strip(), line[41:71].strip(), line[80:85].strip()])
            n += 1
    cur.execute(f"PUT 'file://{out.resolve().as_posix()}' {STAGE}/stations/ AUTO_COMPRESS = TRUE OVERWRITE = TRUE")
    cur.execute("TRUNCATE TABLE RAW_LCD_STATIONS")
    cur.execute(
        f"""
        COPY INTO RAW_LCD_STATIONS
        FROM {STAGE}/stations/
        MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
        INCLUDE_METADATA = (_LOADED_AT = METADATA$START_SCAN_TIME)
        FORCE = TRUE
        """
    )
    log.info("station list: %d stations loaded", n)


# ---------------------------------------------------------------------- cli
def read_seed(seed: Path) -> list[str]:
    with open(seed, newline="") as fh:
        return [row["station_id"].strip() for row in csv.DictReader(fh) if row["station_id"].strip()]


def main(argv: list[str] | None = None) -> int:
    this_year = dt.date.today().year
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--stations", nargs="*", help="GHCN station IDs (default: dbt seed)")
    p.add_argument("--seed", type=Path, default=DEFAULT_SEED)
    p.add_argument("--start-year", type=int, default=this_year - 1)
    p.add_argument("--end-year", type=int, default=this_year)
    p.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    p.add_argument("--workers", type=int, default=6)
    p.add_argument("--check-only", action="store_true", help="report new/changed files, load nothing")
    p.add_argument("--load-station-list", action="store_true",
                   help="(re)load NOAA's station list into RAW_LCD_STATIONS")
    a = p.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")
    stations = a.stations or read_seed(a.seed)
    years = list(range(a.start_year, a.end_year + 1))
    log.info("stations=%d years=%s-%s source=%s", len(stations), years[0], years[-1], BASE_URL)

    with connect() as conn, conn.cursor() as cur:
        session = requests.Session()
        if a.load_station_list:
            load_station_list(cur, a.data_dir, session)

        manifest = read_manifest(cur)
        files = [FileState(s, y) for s in stations for y in years]
        with ThreadPoolExecutor(max_workers=a.workers) as pool:
            files = list(pool.map(lambda f: classify(head(f, session), manifest), files))

        to_fetch = [f for f in files if f.status in ("new", "changed")]
        summary = {s: sum(f.status == s for f in files) for s in ("new", "changed", "unchanged", "missing", "error")}
        log.info("source check: %s", summary)
        for f in files:
            if f.status == "missing":
                log.warning("not published: %s", f.name)
        if a.check_only:
            for f in to_fetch:
                log.info("would load: %s (%s)", f.name, f.status)
            return 0

        with ThreadPoolExecutor(max_workers=a.workers) as pool:
            list(pool.map(lambda f: download(f, a.data_dir, session, manifest), to_fetch))
        to_load = [f for f in to_fetch if f.status in ("new", "changed")]
        log.info("content changed: %d files to load", len(to_load))

        loaded: set[str] = set()
        if to_load:
            check_drift(cur, to_load)
            put_files(cur, to_load)
            loaded = copy_observations(cur)
        write_manifest(cur, files, loaded)
    return 0


if __name__ == "__main__":
    sys.exit(main())
