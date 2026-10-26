"""Thermal seasons dashboard (Streamlit in Snowflake).

Answers the three brief questions from the dbt marts, plus pipeline health and cost.
Deployed as CLIMATE_ANALYTICS.APPS.CLIMATE_SEASONS_DASHBOARD (snowflake/05_dashboard.sql).
Runs with the owner's rights (CLIMATE_DASHBOARD_ROLE): read-only on MARTS, nothing else
in the analytics database, and no access to raw.

Every query reads a mart; no business logic lives here. If a number on screen looks
wrong, the fix belongs in the dbt model, not in this file.
"""

import altair as alt
import numpy as np
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

MARTS = "CLIMATE_ANALYTICS.MARTS"
SEASONS = ["spring", "summer", "autumn", "winter"]

st.set_page_config(page_title="Thermal seasons", layout="wide")
session = get_active_session()


@st.cache_data(ttl=600)
def query(sql: str) -> pd.DataFrame:
    df = session.sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df


# Onset dates on one reference calendar so years can share an axis:
# non-winter seasons -> 2001, winter Sep-Dec -> 2000 and Jan-Mar -> 2001 (winter crosses New Year).
ONSET_CALENDAR = """
    dateadd(year,
            iff(season = 'winter' and month(onset_date) >= 9, 2000, 2001) - year(onset_date),
            onset_date)
"""

# ---------------------------------------------------------------- header + filters
st.title("When do the seasons start, and is that changing?")
st.caption(
    "NOAA Local Climatological Data v2 · 12 US stations · 2006 onward · thermal seasons from "
    "each station's own temperature thresholds (fixed 2006–2020 baseline). Live from the dbt marts."
)

stations = query(f"select station_id, station_label, climate_region from {MARTS}.dim_station order by 2")
c1, c2 = st.columns(2)
season = c1.selectbox("Season", SEASONS, index=0)
station_label = c2.selectbox("Station (for the per-year charts)", stations["station_label"].tolist())
station_id = stations.loc[stations["station_label"] == station_label, "station_id"].iloc[0]

tab_q1, tab_q2, tab_q3, tab_ops = st.tabs(
    ["Q1 · When seasons start", "Q2 · Has it changed?", "Q3 · Outliers", "Pipeline health & cost"]
)

# ---------------------------------------------------------------- Q1
with tab_q1:
    st.subheader("Typical onset date (median) per station and season")
    typical = query(f"""
        select station_label, climate_region, season, season_order,
               typical_onset || '  (' || typical_range_from || ' – ' || typical_range_to || ')' as onset
        from {MARTS}.mart_season_onset_trends
    """)
    pivot = (
        typical.pivot_table(
            index=["station_label", "climate_region"], columns="season", values="onset", aggfunc="first"
        )
        .reindex(columns=SEASONS)
        .reset_index()
    )
    st.dataframe(pivot, use_container_width=True, hide_index=True)
    st.caption("Median onset, with the middle 50% of years in brackets (IQR). Winter = the winter ending that year.")

    st.subheader(f"Every detected {season} onset, per station")
    onsets = query(f"""
        select station_label, season_year, onset_date, {ONSET_CALENDAR} as onset_calendar
        from {MARTS}.fct_season_onset
        where season = '{season}' and onset_status = 'detected'
    """)
    points = (
        alt.Chart(onsets)
        .mark_circle(size=60, opacity=0.5)
        .encode(
            x=alt.X("station_label:N", title=None, sort="ascending"),
            y=alt.Y("onset_calendar:T", title="Onset date", axis=alt.Axis(format="%b %d")),
            tooltip=["station_label", "season_year", "onset_date"],
        )
    )
    medians = (
        alt.Chart(onsets)
        .mark_tick(thickness=3, size=30, color="black")
        .encode(
            x="station_label:N",
            y="median(onset_calendar):T",
        )
    )
    st.altair_chart((points + medians).properties(height=380), use_container_width=True)
    st.caption("One dot per year; black tick = median. A tall column of dots = a season whose start varies a lot.")

# ---------------------------------------------------------------- Q2
with tab_q2:
    st.subheader("Direction across stations, per season")
    summary = query(f"""
        select season, stations,
               stations_trending_earlier as earlier, stations_trending_later as later,
               stations_significantly_earlier as signif_earlier,
               stations_significantly_later as signif_later,
               round(median_shift_days_per_decade, 1) as median_days_per_decade,
               round(min_shift_days_per_decade, 1) as min_days_per_decade,
               round(max_shift_days_per_decade, 1) as max_days_per_decade
        from {MARTS}.mart_season_trend_summary
        order by season_order
    """)
    st.dataframe(summary, use_container_width=True, hide_index=True)
    st.info(
        "Sensitivity check (dbt/analyses/onset_sensitivity.sql, 4 parameter scenarios): autumn later at "
        "11–12/12 stations in every scenario (+5.2 to +8.3 days/decade); summer earlier at 9–10/12 "
        "(−1.8 to −2.6); spring earlier but the size depends on the settings (−3.6 to −9.8, report a range); "
        "winter has no robust trend. Agreement across stations is the signal; single-station trends are noisy."
    )

    st.subheader(f"{season.capitalize()} onset shift per station (days per decade)")
    trends = query(f"""
        select station_label, round(shift_days_per_decade, 1) as days_per_decade,
               is_significant, n_years, round(r_squared, 2) as r_squared, trend_direction
        from {MARTS}.mart_season_onset_trends
        where season = '{season}'
    """)
    bars = (
        alt.Chart(trends)
        .mark_bar()
        .encode(
            x=alt.X("days_per_decade:Q", title="Days per decade (negative = starts earlier)"),
            y=alt.Y("station_label:N", title=None, sort="x"),
            color=alt.Color(
                "is_significant:N",
                title="Significant (|t| ≥ 2.1)",
                scale=alt.Scale(domain=[True, False], range=["#c0392b", "#95a5a6"]),
            ),
            tooltip=["station_label", "days_per_decade", "n_years", "r_squared", "trend_direction"],
        )
    )
    st.altair_chart(bars.properties(height=360), use_container_width=True)

    left, right = st.columns(2)
    with left:
        st.subheader(f"{station_label}: {season} onset by year")
        series = query(f"""
            select season_year, onset_date, {ONSET_CALENDAR} as onset_calendar
            from {MARTS}.fct_season_onset
            where station_id = '{station_id}' and season = '{season}' and onset_status = 'detected'
        """)
        # Least-squares trend computed here on day numbers (Vega's regression needs numbers, not dates)
        series["onset_calendar"] = pd.to_datetime(series["onset_calendar"])
        if len(series) >= 2:
            ref = series["onset_calendar"].min()
            days = (series["onset_calendar"] - ref).dt.days
            slope, intercept = np.polyfit(series["season_year"], days, 1)
            series["trend"] = ref + pd.to_timedelta(slope * series["season_year"] + intercept, unit="D")
        else:
            series["trend"] = series["onset_calendar"]
        base = alt.Chart(series).encode(x=alt.X("season_year:Q", title="Year", axis=alt.Axis(format="d")))
        line = base.mark_line(point=True).encode(
            y=alt.Y("onset_calendar:T", title="Onset date", axis=alt.Axis(format="%b %d")),
            tooltip=["season_year", "onset_date"],
        )
        trend = base.mark_line(strokeDash=[6, 4], color="#c0392b").encode(y="trend:T")
        st.altair_chart((line + trend).properties(height=320), use_container_width=True)
        st.caption("Dashed line = least-squares trend (the same method as the mart).")

    with right:
        st.subheader(f"{station_label}: warm-season length by year")
        length = query(f"""
            select season_year,
                   datediff(day,
                            max(iff(season = 'summer', onset_date, null)),
                            max(iff(season = 'autumn', onset_date, null))) as warm_season_days
            from {MARTS}.fct_season_onset
            where station_id = '{station_id}' and season in ('summer', 'autumn')
              and onset_status = 'detected'
            group by season_year
            having warm_season_days is not null
        """)
        base = alt.Chart(length).encode(
            x=alt.X("season_year:Q", title="Year", axis=alt.Axis(format="d")),
            y=alt.Y("warm_season_days:Q", title="Days from summer onset to autumn onset", scale=alt.Scale(zero=False)),
        )
        st.altair_chart(
            (
                base.mark_line(point=True).encode(tooltip=["season_year", "warm_season_days"])
                + base.transform_regression("season_year", "warm_season_days").mark_line(
                    strokeDash=[6, 4], color="#c0392b"
                )
            ).properties(height=320),
            use_container_width=True,
        )

    warm = query(f"""
        select station_label, median_warm_season_days as median_days,
               round(change_days_per_decade, 1) as change_days_per_decade, is_significant, n_years
        from {MARTS}.mart_warm_season_length order by change_days_per_decade desc
    """)
    st.caption("Warm-season length, all stations (positive = longer)")
    st.dataframe(warm, use_container_width=True, hide_index=True)

# ---------------------------------------------------------------- Q3
with tab_q3:
    st.subheader("Climate outliers: real weather, far from the station's normal")
    counts = query(f"""
        select s.station_label, o.outlier_type, count(*) as days
        from {MARTS}.fct_weather_outliers o
        join {MARTS}.dim_station s using (station_id)
        where o.outlier_type in ('CLIMATE_ANOMALY_HIGH', 'CLIMATE_ANOMALY_LOW')
        group by 1, 2
    """)
    st.altair_chart(
        alt.Chart(counts)
        .mark_bar()
        .encode(
            x=alt.X("days:Q", title="Days with |z| ≥ 3 vs the day-of-year normal"),
            y=alt.Y("station_label:N", title=None, sort="-x"),
            color=alt.Color(
                "outlier_type:N",
                title=None,
                scale=alt.Scale(domain=["CLIMATE_ANOMALY_HIGH", "CLIMATE_ANOMALY_LOW"], range=["#c0392b", "#2e86c1"]),
            ),
            tooltip=["station_label", "outlier_type", "days"],
        )
        .properties(height=340),
        use_container_width=True,
    )

    per_year = query(f"""
        select year(observation_date) as year, outlier_type, count(*) as days
        from {MARTS}.fct_weather_outliers
        where outlier_type in ('CLIMATE_ANOMALY_HIGH', 'CLIMATE_ANOMALY_LOW')
        group by 1, 2
    """)
    st.caption("Anomaly days per year, all stations")
    st.altair_chart(
        alt.Chart(per_year)
        .mark_bar()
        .encode(
            x=alt.X("year:O", title=None),
            y=alt.Y("days:Q", title="Days"),
            color=alt.Color(
                "outlier_type:N",
                title=None,
                legend=None,
                scale=alt.Scale(domain=["CLIMATE_ANOMALY_HIGH", "CLIMATE_ANOMALY_LOW"], range=["#c0392b", "#2e86c1"]),
            ),
            tooltip=["year", "outlier_type", "days"],
        )
        .properties(height=240),
        use_container_width=True,
    )

    st.subheader("Station records (official daily summaries only)")
    records = query(f"""
        select s.station_label, o.outlier_type, o.observation_date, round(o.value_c, 1) as value_c
        from {MARTS}.fct_weather_outliers o
        join {MARTS}.dim_station s using (station_id)
        where o.outlier_type in ('RECORD_HIGH', 'RECORD_LOW')
        order by s.station_label, o.outlier_type, o.observation_date
    """)
    st.dataframe(records, use_container_width=True, hide_index=True)

    st.subheader(f"Most extreme days at {station_label}")
    extremes = query(f"""
        select observation_date, outlier_type, round(value_c, 1) as mean_temp_c, round(z_score, 1) as z_score
        from {MARTS}.fct_weather_outliers
        where station_id = '{station_id}' and outlier_family = 'CLIMATE' and z_score is not null
        order by abs(z_score) desc
        limit 15
    """)
    st.dataframe(extremes, use_container_width=True, hide_index=True)

    st.subheader("Data quality: is the measurement itself doubtful?")
    q1, q2 = st.columns(2)
    quality = query(f"""
        select outlier_type, count(*) as days
        from {MARTS}.fct_weather_outliers
        where outlier_family = 'DATA_QUALITY'
        group by 1 order by 2 desc
    """)
    q1.dataframe(quality, use_container_width=True, hide_index=True)
    q1.caption(
        "NOAA flags and physically impossible values are excluded from the climate analysis. "
        "STUCK_SENSOR and SUSPICIOUS_JUMP are review candidates: every one was checked against the "
        "hourly readings and was real weather (e.g. the Denver Dec 2008 and Bismarck Jan 2009 fronts)."
    )
    derived = query(f"""
        select station_label, derived_temp_days, observed_days,
               round(observed_day_coverage * 100, 1) as coverage_pct
        from {MARTS}.dim_station order by derived_temp_days desc, station_label
    """)
    q2.dataframe(derived, use_container_width=True, hide_index=True)
    q2.caption(
        "derived_temp_days: days where NOAA's daily summary was blank and the temperature was rebuilt "
        "from hourly readings ((max + min) / 2, ≥ 18 hours). Denver 2013: 274 days. Validated on 90,509 "
        "days with both: bias −0.07 °C, MAE 0.24 °C, 99.2% within 1 °C."
    )

# ---------------------------------------------------------------- pipeline health & cost
with tab_ops:
    runs = query(f"""
        select finished_at, status, triggered_by, files_checked, files_new, files_changed,
               files_loaded, rows_loaded, duration_seconds, message
        from {MARTS}.mart_ingest_runs
        order by finished_at desc
        limit 20
    """)
    last_build = query("""
        select max(last_altered) as last_build
        from CLIMATE_ANALYTICS.INFORMATION_SCHEMA.TABLES
        where table_schema = 'MARTS' and table_name = 'FCT_SEASON_ONSET'
    """)
    ok_runs = runs[runs["status"].isin(["success", "warning"])]
    now = pd.Timestamp.now(tz="UTC")

    def hours_ago(ts) -> str:
        if ts is None or pd.isna(ts):
            return "never"
        ts = pd.Timestamp(ts)
        ts = ts.tz_localize("UTC") if ts.tzinfo is None else ts.tz_convert("UTC")
        return f"{(now - ts).total_seconds() / 3600:.1f} h ago"

    m1, m2, m3, m4 = st.columns(4)
    m1.metric(
        "Last successful ingest",
        hours_ago(ok_runs["finished_at"].max() if len(ok_runs) else None),
        help="Alert emails if > 12 h",
    )
    m2.metric("Last ingest status", runs["status"].iloc[0] if len(runs) else "n/a")
    m3.metric("Last dbt build (marts)", hours_ago(last_build["last_build"].iloc[0]), help="Alert emails if > 26 h")
    m4.metric("Failed runs (last 20)", int((runs["status"] == "failed").sum()))
    st.caption("Schedulers: cron-job.org every 6 h (primary), GitHub cron (backup). dbt Cloud daily_build 11:30 UTC.")
    st.dataframe(runs, use_container_width=True, hide_index=True)

    st.subheader("Credits per warehouse, last 14 days")
    try:
        cost = query("""
            select warehouse_name, to_date(start_time) as day, sum(credits_used) as credits
            from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
            where start_time >= dateadd(day, -14, current_date())
            group by 1, 2
        """)
        st.altair_chart(
            alt.Chart(cost)
            .mark_bar()
            .encode(
                x=alt.X("day:T", title=None, axis=alt.Axis(format="%b %d")),
                y=alt.Y("credits:Q", title="Credits"),
                color=alt.Color("warehouse_name:N", title="Warehouse"),
                tooltip=["warehouse_name", "day", alt.Tooltip("credits:Q", format=".3f")],
            )
            .properties(height=300),
            use_container_width=True,
        )
        totals = cost.groupby("warehouse_name", as_index=False)["credits"].sum().round(3)
        st.dataframe(totals, use_container_width=True, hide_index=True)
        st.caption(
            "ACCOUNT_USAGE lags up to ~3 h. One warehouse per workload, so cost per workload is direct. "
            "Monthly cap: resource monitor CLIMATE_MONTHLY_QUOTA (20 credits)."
        )
    except Exception as exc:  # usage views not granted to the app role
        st.warning(f"Cost view unavailable for this role: {exc}")
