"""Offline smoke test: the dashboard renders every tab without errors.

Snowflake is replaced by a fake session that answers each query with a small,
realistic DataFrame (same column names as the marts). Catches broken code, wrong
column names in the app and chart errors before a deploy. It does not check numbers:
those are tested in dbt.
"""

import sys
import types
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
from streamlit.testing.v1 import AppTest

APP = Path(__file__).resolve().parents[1] / "streamlit_app.py"
LABELS = ["Boston", "Denver", "Miami"]
IDS = ["S1", "S2", "S3"]
SEASONS = ["spring", "summer", "autumn", "winter"]
CLIMATE = ["CLIMATE_ANOMALY_HIGH", "CLIMATE_ANOMALY_LOW"]


def _onsets(rng: np.random.Generator, station: str | None = None) -> pd.DataFrame:
    rows = []
    for sid, label in zip(IDS, LABELS, strict=True):
        if station and sid != station:
            continue
        for year in range(2006, 2027):
            start = pd.Timestamp(f"{year}-03-01") + pd.Timedelta(days=int(rng.integers(0, 40)))
            rows.append(
                {
                    "STATION_LABEL": label,
                    "SEASON_YEAR": year,
                    "ONSET_DATE": start.date(),
                    "ONSET_CALENDAR": start.replace(year=2001).date(),
                }
            )
    return pd.DataFrame(rows)


def _respond(sql: str, rng: np.random.Generator) -> pd.DataFrame:  # noqa: C901 - one branch per query
    s = " ".join(sql.split()).lower()
    now = pd.Timestamp.now(tz="UTC")
    if "information_schema.tables" in s:
        return pd.DataFrame({"LAST_BUILD": [now - pd.Timedelta(hours=6)]})
    if "dim_station order by 2" in s:
        return pd.DataFrame({"STATION_ID": IDS, "STATION_LABEL": LABELS, "CLIMATE_REGION": ["NE", "SW", "SE"]})
    if "typical_onset ||" in s:
        return pd.DataFrame(
            [
                {"STATION_LABEL": lab, "CLIMATE_REGION": "X", "SEASON": se, "SEASON_ORDER": i, "ONSET": "Mar 05"}
                for lab in LABELS
                for i, se in enumerate(SEASONS)
            ]
        )
    if "warm_season_days" in s and "datediff" in s:
        return pd.DataFrame({"SEASON_YEAR": range(2006, 2027), "WARM_SEASON_DAYS": rng.integers(80, 110, 21)})
    if "fct_season_onset" in s and "station_id = 's1'" in s:
        return _onsets(rng, "S1")[["SEASON_YEAR", "ONSET_DATE", "ONSET_CALENDAR"]]
    if "fct_season_onset" in s:
        return _onsets(rng)
    if "mart_season_trend_summary" in s:
        return pd.DataFrame(
            [
                {
                    "SEASON": se, "SEASON_ORDER": i, "STATIONS": 12, "EARLIER": e, "LATER": 12 - e,
                    "SIGNIF_EARLIER": 1, "SIGNIF_LATER": 0, "MEDIAN_DAYS_PER_DECADE": -4.3,
                    "MIN_DAYS_PER_DECADE": -9.0, "MAX_DAYS_PER_DECADE": 2.0,
                }
                for i, (se, e) in enumerate(zip(SEASONS, [9, 10, 0, 6], strict=True))
            ]
        )  # fmt: skip
    if "mart_season_onset_trends" in s:
        return pd.DataFrame(
            {
                "STATION_LABEL": LABELS, "DAYS_PER_DECADE": [-4.0, 2.1, -1.0],
                "IS_SIGNIFICANT": [True, False, False], "N_YEARS": [21] * 3, "EXPLAINED_PCT": [30, 10, 0],
                "TREND_DIRECTION": ["earlier", "no_clear_trend", "too_few_years"],
            }
        )  # fmt: skip
    if "mart_warm_season_length" in s:
        return pd.DataFrame(
            {
                "STATION_LABEL": LABELS, "MEDIAN_DAYS": [95, 90, 120], "CHANGE_DAYS_PER_DECADE": [8.0, 5.0, 1.0],
                "IS_SIGNIFICANT": [True, False, False], "N_YEARS": [21] * 3,
            }
        )  # fmt: skip
    if "fct_weather_outliers" in s and "station_label" in s and "record_high" not in s:
        return pd.DataFrame({"STATION_LABEL": LABELS * 2, "OUTLIER_TYPE": CLIMATE * 3, "DAYS": [5, 6, 7, 8, 9, 1]})
    if "year(observation_date)" in s:
        return pd.DataFrame({"YEAR": [2008, 2009], "OUTLIER_TYPE": CLIMATE, "DAYS": [10, 4]})
    if "record_high" in s:
        return pd.DataFrame(
            {
                "STATION_LABEL": LABELS, "OUTLIER_TYPE": ["RECORD_HIGH", "RECORD_LOW", "RECORD_HIGH"],
                "OBSERVATION_DATE": [pd.Timestamp("2012-07-01").date()] * 3, "VALUE_C": [40.0, -30.0, 36.0],
            }
        )  # fmt: skip
    if "order by abs(z_score)" in s:
        return pd.DataFrame(
            {
                "OBSERVATION_DATE": [pd.Timestamp("2008-12-14").date()], "OUTLIER_TYPE": ["CLIMATE_ANOMALY_LOW"],
                "MEAN_TEMP_C": [-22.0], "Z_SCORE": [-4.1],
            }
        )  # fmt: skip
    if "data_quality" in s:
        return pd.DataFrame({"OUTLIER_TYPE": ["SUSPICIOUS_JUMP", "STUCK_SENSOR"], "DAYS": [3, 1]})
    if "derived_temp_days" in s:
        return pd.DataFrame(
            {"STATION_LABEL": LABELS, "DERIVED_TEMP_DAYS": [0, 274, 0], "OBSERVED_DAYS": [7600] * 3,
             "COVERAGE_PCT": [99.9] * 3}
        )  # fmt: skip
    if "mart_ingest_runs" in s:
        return pd.DataFrame(
            {
                "FINISHED_AT": [now - pd.Timedelta(hours=h) for h in (2, 8)], "STATUS": ["success", "failed"],
                "TRIGGERED_BY": ["workflow_dispatch", "schedule"], "FILES_CHECKED": [24] * 2,
                "FILES_NEW": [0] * 2, "FILES_CHANGED": [0] * 2, "FILES_LOADED": [0] * 2, "ROWS_LOADED": [0] * 2,
                "DURATION_SECONDS": [20] * 2, "MESSAGE": ["ok", "x"],
            }
        )  # fmt: skip
    if "warehouse_metering_history" in s:
        return pd.DataFrame(
            {"WAREHOUSE_NAME": ["LOAD_WH", "TRANSFORM_WH"], "DAY": [pd.Timestamp("2026-10-26").date()] * 2,
             "CREDITS": [0.01, 0.05]}
        )  # fmt: skip
    raise AssertionError(f"Smoke test has no fake answer for this query: {s[:200]}")


@pytest.fixture
def app(monkeypatch) -> AppTest:
    rng = np.random.default_rng(0)

    class Result:
        def __init__(self, sql: str):
            self.sql = sql

        def to_pandas(self) -> pd.DataFrame:
            return _respond(self.sql, rng)

    class Session:
        def sql(self, sql: str) -> Result:
            return Result(sql)

    context = types.ModuleType("snowflake.snowpark.context")
    context.get_active_session = Session
    for name in ("snowflake", "snowflake.snowpark"):
        monkeypatch.setitem(sys.modules, name, types.ModuleType(name))
    monkeypatch.setitem(sys.modules, "snowflake.snowpark.context", context)
    return AppTest.from_file(str(APP), default_timeout=60)


def test_renders_all_tabs_without_errors(app: AppTest) -> None:
    app.run()
    assert not app.exception, [e.value for e in app.exception]
    assert len(app.tabs) == 4
    assert len(app.metric) == 4


@pytest.mark.parametrize("season", SEASONS)
def test_every_season_and_station_renders(app: AppTest, season: str) -> None:
    app.run()
    app.selectbox[0].set_value(season)
    app.selectbox[1].set_value("Boston")
    app.run()
    assert not app.exception, [e.value for e in app.exception]
