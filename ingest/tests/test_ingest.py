"""Offline tests for ingest.py: no network, no Snowflake."""
import hashlib
import importlib.util
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ingest", ROOT / "ingest.py")
ingest = importlib.util.module_from_spec(spec)
sys.modules["ingest"] = ingest
spec.loader.exec_module(ingest)

CSV_BODY = b'"STATION","DATE","REPORT_TYPE"\n"USW00003017","2006-01-01T00:00:00","SOD"\n'
HTML_BODY = b"<!DOCTYPE html><html><body>explorer</body></html>"


class FakeResponse:
    def __init__(self, status=200, headers=None, body=b""):
        self.status_code, self.headers, self.body = status, headers or {}, body

    def raise_for_status(self):
        pass

    def iter_content(self, chunk_size):
        yield self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeSession:
    def __init__(self, status=200, headers=None, body=b""):
        self.response = FakeResponse(status, headers, body)

    def head(self, *a, **k):
        return self.response

    def get(self, *a, **k):
        return self.response


HEADERS = {"Content-Length": str(len(CSV_BODY)), "Last-Modified": "Tue, 29 Jul 2025 07:04:30 GMT"}
SAME = {"remote_size": len(CSV_BODY), "remote_last_modified": HEADERS["Last-Modified"],
        "content_md5": hashlib.md5(CSV_BODY).hexdigest()}


def check(manifest, session, tmp_path):
    fs = ingest.classify(ingest.head(ingest.FileState("USW00003017", 2006), session), manifest)
    if fs.status in ("new", "changed"):
        ingest.download(fs, tmp_path, session, manifest)
    return fs


# ------------------------------------------------------------ change detection
def test_new_file_is_downloaded(tmp_path):
    fs = check({}, FakeSession(headers=HEADERS, body=CSV_BODY), tmp_path)
    assert fs.status == "new" and fs.path.exists()


def test_unchanged_file_is_not_downloaded(tmp_path):
    fs = check({"LCD_USW00003017_2006.csv": SAME}, FakeSession(headers=HEADERS, body=CSV_BODY), tmp_path)
    assert fs.status == "unchanged" and fs.path is None


def test_metadata_only_change_is_skipped_after_md5(tmp_path):
    stale = {**SAME, "remote_last_modified": "Mon, 01 Jan 2024 00:00:00 GMT"}
    fs = check({"LCD_USW00003017_2006.csv": stale}, FakeSession(headers=HEADERS, body=CSV_BODY), tmp_path)
    assert fs.status == "unchanged"


def test_content_change_is_loaded(tmp_path):
    changed = {**SAME, "remote_size": 1, "content_md5": "different"}
    fs = check({"LCD_USW00003017_2006.csv": changed}, FakeSession(headers=HEADERS, body=CSV_BODY), tmp_path)
    assert fs.status == "changed"


def test_not_published_is_missing(tmp_path):
    fs = check({}, FakeSession(status=404), tmp_path)
    assert fs.status == "missing"


def test_html_instead_of_csv_is_rejected(tmp_path):
    fs = check({}, FakeSession(headers=HEADERS, body=HTML_BODY), tmp_path)
    assert fs.status == "error" and fs.path is None
    assert not list(tmp_path.rglob("*.csv")) and not list(tmp_path.rglob("*.part"))


# -------------------------------------------------------------- station list
def test_station_list_fixed_width_parsing():
    text = ("USW00014739  42.3606  -71.0097    3.4    BOSTON                                 72509\r\n"
            "USW00096409  68.6483 -149.3986  750.1    TOOLIK LAKE 5 ENE                           \r\n")
    assert ingest.parse_station_list(text) == [
        ["USW00014739", "42.3606", "-71.0097", "3.4", "BOSTON", "72509"],
        ["USW00096409", "68.6483", "-149.3986", "750.1", "TOOLIK LAKE 5 ENE", ""],
    ]


def test_station_list_rejects_html():
    with pytest.raises(RuntimeError):
        ingest.parse_station_list("<!DOCTYPE html><html>")


# ------------------------------------------------------------- run outcome
@pytest.mark.parametrize("summary,copy_problems,expected", [
    ({"error": 0, "missing": 3}, 0, "success"),      # 404s are normal
    ({"error": 1}, 0, "warning"),                    # 1/100 below the 5% threshold
    ({"error": 10}, 0, "failed"),                    # 10/100 above it
    ({"error": 0}, 2, "failed"),                     # any COPY problem fails
    ({"error": 100}, 0, "failed"),                   # nothing could be checked
])
def test_run_outcome(summary, copy_problems, expected):
    status, _ = ingest.run_outcome(summary, copy_problems, files_checked=100, max_error_share=0.05)
    assert status == expected


def test_seed_is_readable():
    stations = ingest.read_seed(ingest.DEFAULT_SEED)
    assert len(stations) == 12 and all(s.startswith("USW") and len(s) == 11 for s in stations)


class RecordingCursor:
    """Fake Snowflake cursor: records every statement and its parameters."""

    def __init__(self):
        self.statements = []
        self.rowcount = 0

    def execute(self, sql, params=None):
        self.statements.append((sql, params))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeConnection:
    def __init__(self, cursor):
        self._cursor = cursor

    def cursor(self):
        return self._cursor

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_crashed_run_is_still_logged_as_failed(monkeypatch, tmp_path):
    cur = RecordingCursor()
    monkeypatch.setattr(ingest, "connect", lambda: FakeConnection(cur))

    def boom(_cur):
        raise RuntimeError("COPY failed")

    monkeypatch.setattr(ingest, "read_manifest", boom)
    with pytest.raises(RuntimeError, match="COPY failed"):
        ingest.main(["--stations", "USW00003017", "--start-year", "2025", "--data-dir", str(tmp_path)])

    inserts = [params for sql, params in cur.statements if sql.startswith("INSERT INTO INGEST_RUN_LOG")]
    assert len(inserts) == 1
    assert "failed" in inserts[0]
    assert any("COPY failed" in str(v) for v in inserts[0])


# ------------------------------------------------------------ raw retention
def test_trim_skips_when_nothing_was_loaded():
    cur = RecordingCursor()
    assert ingest.trim_old_versions(cur, set()) == 0
    assert cur.statements == []


def test_trim_checks_only_the_files_just_loaded():
    cur = RecordingCursor()
    cur.rowcount = 5
    loaded = {"LCD_USW00003017_2026.csv", "LCD_USW00094846_2026.csv"}
    assert ingest.trim_old_versions(cur, loaded) == 5
    (sql, params), = cur.statements
    assert sql.lstrip().startswith("DELETE FROM RAW_LCD_OBSERVATIONS")
    assert params == sorted(loaded) and sql.count("%s") == len(loaded)
    assert "MAX(VERSION_NO) OVER (PARTITION BY FILE_NAME) - 4" in sql  # latest + 3 previous kept


def test_successful_load_trims_old_versions(monkeypatch, tmp_path):
    cur = RecordingCursor()
    cur.rowcount = 7
    monkeypatch.setattr(ingest, "connect", lambda: FakeConnection(cur))
    monkeypatch.setattr(ingest, "read_manifest", lambda _cur: {})
    monkeypatch.setattr(ingest, "head", lambda fs, _session: fs)
    monkeypatch.setattr(ingest, "download", lambda fs, *_: fs)
    for step in ("check_drift", "put_files", "write_manifest"):
        monkeypatch.setattr(ingest, step, lambda *_: None)
    monkeypatch.setattr(ingest, "copy_observations",
                        lambda _cur: ({"LCD_USW00003017_2025.csv"}, 10, 0))

    assert ingest.main(["--stations", "USW00003017", "--start-year", "2025", "--end-year", "2025",
                        "--data-dir", str(tmp_path)]) == 0

    deletes = [p for sql, p in cur.statements if sql.lstrip().startswith("DELETE FROM RAW_LCD_OBSERVATIONS")]
    assert deletes == [["LCD_USW00003017_2025.csv"]]
    (log_row,) = [p for sql, p in cur.statements if sql.startswith("INSERT INTO INGEST_RUN_LOG")]
    assert "success" in log_row
    assert any("7 rows of older file versions removed" in str(v) for v in log_row)
