"""Thermal seasons dashboard (Streamlit in Snowflake).

Answers the three brief questions from the dbt marts, plus pipeline health and cost.
Deployed as CLIMATE_ANALYTICS.APPS.CLIMATE_SEASONS_DASHBOARD (snowflake/05_dashboard.sql).
Runs with the owner's rights (CLIMATE_DASHBOARD_ROLE): read-only on MARTS, nothing else
in the analytics database, and no access to raw.

Every number comes from the dbt marts. This file only presents them: plain-language
labels, one trend line drawn on a chart, and short summary sentences. If a number on
screen looks wrong, the fix belongs in the dbt model, not in this file.
"""

from math import comb

import altair as alt
import numpy as np
import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

MARTS = "CLIMATE_ANALYTICS.MARTS"
SEASONS = ["spring", "summer", "autumn", "winter"]

# Plain-language labels for the technical values stored in the marts
OUTLIER_LABELS = {
    "CLIMATE_ANOMALY_HIGH": "Unusually warm day",
    "CLIMATE_ANOMALY_LOW": "Unusually cold day",
    "RECORD_HIGH": "Hot peak",
    "RECORD_LOW": "Cold peak",
    "SENSOR_FLAG_SUSPECT": "Flagged by NOAA as suspect",
    "SENSOR_FLAG_ERRONEOUS": "Flagged by NOAA as wrong",
    "PHYSICAL_INCONSISTENT": "Values contradict each other (e.g. max below min)",
    "PHYSICAL_OUT_OF_RANGE": "Physically impossible value",
    "STUCK_SENSOR": "Same reading 5 days in a row (flagged for review)",
    "SUSPICIOUS_JUMP": "Sudden change vs the day before (flagged for review)",
}
TREND_LABELS = {
    "earlier": "Starting earlier",
    "later": "Starting later",
    "no_clear_trend": "No clear trend",
    "too_few_years": "Not enough years",
}
WAREHOUSE_LABELS = {
    "LOAD_WH": "Data loading",
    "TRANSFORM_WH": "Analysis (dbt)",
    "REPORTING_WH": "Dashboard",
    "CLIMATE_WH": "Setup and alerts",
}
WARM, COLD, GREY = "#c0392b", "#2e86c1", "#95a5a6"

st.set_page_config(page_title="Thermal seasons", layout="wide")
session = get_active_session()


@st.cache_data(ttl=600)
def query(sql: str) -> pd.DataFrame:
    df = session.sql(sql).to_pandas()
    df.columns = [c.lower() for c in df.columns]
    return df


def table(df: pd.DataFrame, columns: dict) -> None:
    """Show only the listed columns, renamed to plain language."""
    st.dataframe(df[list(columns)].rename(columns=columns), use_container_width=True, hide_index=True)


def to_f(celsius: pd.Series) -> pd.Series:
    return (celsius * 9 / 5 + 32).round(1)


def sign_test_p(agreeing: int, n: int) -> float:
    """Two-sided sign test: chance that at least `agreeing` of `n` stations move the same
    way if each were a coin flip (stations with no change are left out of n)."""
    if n == 0:
        return 1.0
    tail = sum(comb(n, i) for i in range(agreeing, n + 1)) / 2**n
    return min(1.0, 2 * tail)


def evidence_label(p_value: float) -> str:
    """Same grading as docs/answers.md: under 1% strong, under 5% moderate, under 10% weak."""
    if p_value < 0.01:
        return "strong evidence"
    if p_value < 0.05:
        return "moderate evidence"
    if p_value < 0.10:
        return "weak evidence"
    return ""


# Start dates on one reference calendar so different years can share an axis:
# non-winter seasons -> 2001, winter Sep-Dec -> 2000 and Jan-Mar -> 2001 (winter crosses New Year).
ONSET_CALENDAR = """
    dateadd(year,
            iff(season = 'winter' and month(onset_date) >= 9, 2000, 2001) - year(onset_date),
            onset_date)
"""

# ---------------------------------------------------------------- header + filters
st.title("Climate Dashboard: Season Trends")
st.caption("NOAA Local Climatological Data v2 · 12 US stations · 2006-Current · Live from the dbt marts.")

with st.expander("How to read this dashboard (start here)"):
    st.markdown(
        """
**What it answers**
1. **Season start**: when does each season usually begin at each weather station?
2. **Shift Trends**: is that date moving over the years, earlier or later?
3. **Outliers**: which days were truly unusual, and can we trust the measurements?

**What "season start" means here**
Seasons are defined by temperature, not by the calendar. Each station is compared with
*its own* normal temperatures (2006–2020), so Miami and Minneapolis are each judged by
their own climate.
- **Spring** starts when the 7-day average temperature rises above the station's usual
  *cool* level and stays there for 5 days.
- **Summer** starts when it rises above the usual *warm* level and stays there.
- **Autumn** starts when it falls back below the *warm* level.
- **Winter** starts when it falls below the *cool* level. A winter is counted in the year
  it ends (winter 2025/26 = 2026).

**Words used**
- **Typical date**: the middle value across all years (half the years were earlier, half later).
- **Usual range**: the dates covering the middle half of the years. Wider = less predictable.
- **Days every 10 years**: how far the start date moves per decade. Negative = earlier.
- **Clear trend**: the shift is large compared with normal year-to-year swings, so it is
  unlikely to be chance. Otherwise it is shown as *could be chance*.
- **Agreement across stations** is the strongest evidence: one station can be noisy, but
  many stations moving the same way is hard to explain by luck.
        """
    )

stations = query(f"select station_id, station_label, climate_region from {MARTS}.dim_station order by 2")
c1, c2 = st.columns(2)
season = c1.selectbox("Season", SEASONS, index=0, format_func=str.capitalize)
station_label = c2.selectbox("Station (for the single-station charts)", stations["station_label"].tolist())
station_id = stations.loc[stations["station_label"] == station_label, "station_id"].iloc[0]
season_name = season.capitalize()

tab_q1, tab_q2, tab_q3, tab_ops = st.tabs(
    ["Season start", "Shift Trends", "Outliers", "Pipeline health & cost"]
)

# ---------------------------------------------------------------- Q1
with tab_q1:
    st.subheader("Season Start")
    st.write("Typical start date at each station (usual range in brackets)")
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
    table(
        pivot,
        {
            "station_label": "Station",
            "climate_region": "Region",
            "spring": "Spring",
            "summer": "Summer",
            "autumn": "Autumn",
            "winter": "Winter",
        },
    )
    st.caption(
        "Example: 'Mar 01 (Feb 20 – Mar 12)' = spring usually starts around 1 March; "
        "in half of the years it started between 20 February and 12 March."
    )

    st.subheader(f"{season_name}: Start date range per year")
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
            y=alt.Y("onset_calendar:T", title="Start date", axis=alt.Axis(format="%b %d")),
            tooltip=[
                alt.Tooltip("station_label:N", title="Station"),
                alt.Tooltip("season_year:Q", title="Year"),
                alt.Tooltip("onset_date:T", title="Started on", format="%d %b %Y"),
            ],
        )
    )
    medians = (
        alt.Chart(onsets)
        .mark_tick(thickness=3, size=30, color="black")
        .encode(x="station_label:N", y="median(onset_calendar):T")
    )
    st.altair_chart((points + medians).properties(height=380), use_container_width=True)
    st.caption(
        "Each dot is one year. The black line is the typical date. "
        "Dots spread over a tall column = this season's start is hard to predict at that station."
    )

# ---------------------------------------------------------------- Q2
with tab_q2:
    st.subheader("Season Start: Shift Trends Summary")
    summary = query(f"""
        select season, season_order, stations,
               stations_trending_earlier as earlier, stations_trending_later as later,
               stations_significantly_earlier as signif_earlier,
               stations_significantly_later as signif_later,
               round(median_shift_days_per_decade, 1) as median_days_per_decade,
               round(min_shift_days_per_decade, 1) as min_days_per_decade,
               round(max_shift_days_per_decade, 1) as max_days_per_decade
        from {MARTS}.mart_season_trend_summary
        order by season_order
    """)

    # One plain sentence per season, written from the numbers, with the strength of the
    # evidence graded by the same sign test as docs/answers.md
    for row in summary.itertuples():
        majority = max(row.earlier, row.later)
        p_value = sign_test_p(majority, row.earlier + row.later)
        evidence = evidence_label(p_value)
        if evidence:
            direction = "later" if row.later > row.earlier else "earlier"
            st.markdown(
                f"- **{row.season.capitalize()}** is starting **{direction}** at **{majority} of "
                f"{row.stations}** stations (typical shift: {row.median_days_per_decade:+.1f} days every "
                f"10 years; **{evidence}**)."
            )
        else:
            st.markdown(
                f"- **{row.season.capitalize()}**: **no consistent direction** "
                f"({row.earlier} stations earlier, {row.later} later)."
            )
    st.caption(
        "Evidence = how likely it is that this many stations agree if each were a coin flip (sign test): "
        "under 1% strong, under 5% moderate, under 10% weak. Nearby stations share weather, so treat it as "
        "indicative. The direction was re-checked with different settings (smoothing, persistence, thresholds)."
    )

    table(
        summary,
        {
            "season": "Season",
            "stations": "Stations",
            "earlier": "Starting earlier",
            "later": "Starting later",
            "signif_earlier": "Clearly earlier",
            "signif_later": "Clearly later",
            "median_days_per_decade": "Typical shift (days / 10 yrs)",
            "min_days_per_decade": "Smallest shift",
            "max_days_per_decade": "Largest shift",
        },
    )

    st.subheader(f"{season_name}: shift at each station (days every 10 years)")
    trends = query(f"""
        select station_label, round(shift_days_per_decade, 1) as days_per_decade,
               is_significant, n_years, round(r_squared * 100) as explained_pct, trend_direction
        from {MARTS}.mart_season_onset_trends
        where season = '{season}'
    """)
    trends["evidence"] = np.where(trends["is_significant"], "Clear trend", "Could be chance")
    trends["direction"] = trends["trend_direction"].map(TREND_LABELS)
    bars = (
        alt.Chart(trends)
        .mark_bar()
        .encode(
            x=alt.X("days_per_decade:Q", title="Days every 10 years (left = earlier, right = later)"),
            y=alt.Y("station_label:N", title=None, sort="x"),
            color=alt.Color(
                "evidence:N",
                title=None,
                scale=alt.Scale(domain=["Clear trend", "Could be chance"], range=[WARM, GREY]),
            ),
            tooltip=[
                alt.Tooltip("station_label:N", title="Station"),
                alt.Tooltip("days_per_decade:Q", title="Days every 10 years"),
                alt.Tooltip("evidence:N", title="Evidence"),
                alt.Tooltip("n_years:Q", title="Years measured"),
                alt.Tooltip("explained_pct:Q", title="Share of yearly swings explained by the trend (%)"),
            ],
        )
    )
    st.altair_chart(bars.properties(height=360), use_container_width=True)
    st.caption(
        "Red = clear trend; grey = the shift is small compared with normal year-to-year swings and could be chance. "
        "Hover a bar for details."
    )

    left, right = st.columns(2)
    with left:
        st.subheader(f"{station_label}: {season} start, year by year")
        series = query(f"""
            select season_year, onset_date, {ONSET_CALENDAR} as onset_calendar
            from {MARTS}.fct_season_onset
            where station_id = '{station_id}' and season = '{season}' and onset_status = 'detected'
        """)
        # Straight-line trend computed on day numbers (the chart library needs numbers, not dates)
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
            y=alt.Y("onset_calendar:T", title="Start date", axis=alt.Axis(format="%b %d")),
            tooltip=[
                alt.Tooltip("season_year:Q", title="Year"),
                alt.Tooltip("onset_date:T", title="Started on", format="%d %b %Y"),
            ],
        )
        trend = base.mark_line(strokeDash=[6, 4], color=WARM).encode(y="trend:T")
        st.altair_chart((line + trend).properties(height=320), use_container_width=True)
        st.caption("Dots = actual start date each year. Dashed line = overall direction (straight-line trend).")

    with right:
        st.subheader(f"{station_label}: length of the warm season")
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
            y=alt.Y("warm_season_days:Q", title="Days from summer start to autumn start", scale=alt.Scale(zero=False)),
        )
        st.altair_chart(
            (
                base.mark_line(point=True).encode(
                    tooltip=[
                        alt.Tooltip("season_year:Q", title="Year"),
                        alt.Tooltip("warm_season_days:Q", title="Warm-season days"),
                    ]
                )
                + base.transform_regression("season_year", "warm_season_days").mark_line(strokeDash=[6, 4], color=WARM)
            ).properties(height=320),
            use_container_width=True,
        )
        st.caption("Warm season = the days between the start of summer and the start of autumn.")

    st.subheader("Warm season trend (all stations)")
    warm = query(f"""
        select station_label, median_warm_season_days as median_days,
               round(change_days_per_decade, 1) as change_days_per_decade, is_significant, n_years
        from {MARTS}.mart_warm_season_length order by change_days_per_decade desc
    """)
    warm["evidence"] = np.where(warm["is_significant"], "Clear trend", "Could be chance")
    table(
        warm,
        {
            "station_label": "Station",
            "median_days": "Typical length (days)",
            "change_days_per_decade": "Change (days every 10 years)",
            "evidence": "Evidence",
            "n_years": "Years measured",
        },
    )
    st.caption("Positive change = the warm season is getting longer.")

# ---------------------------------------------------------------- Q3
with tab_q3:
    st.subheader("Outliers Tracker")
    st.write(
        "A day counts as **unusual** when its average temperature is far outside the normal range for "
        "that station and that time of year (3 or more standard deviations). By chance alone this "
        "happens about once a year per station."
    )
    counts = query(f"""
        select s.station_label, o.outlier_type, count(*) as days
        from {MARTS}.fct_weather_outliers o
        join {MARTS}.dim_station s using (station_id)
        where o.outlier_type in ('CLIMATE_ANOMALY_HIGH', 'CLIMATE_ANOMALY_LOW')
        group by 1, 2
    """)
    counts["kind"] = counts["outlier_type"].map(OUTLIER_LABELS)
    kind_scale = alt.Scale(domain=["Unusually warm day", "Unusually cold day"], range=[WARM, COLD])
    st.altair_chart(
        alt.Chart(counts)
        .mark_bar()
        .encode(
            x=alt.X("days:Q", title="Number of unusual days since 2006"),
            y=alt.Y("station_label:N", title=None, sort="-x"),
            color=alt.Color("kind:N", title=None, scale=kind_scale),
            tooltip=[
                alt.Tooltip("station_label:N", title="Station"),
                alt.Tooltip("kind:N", title="Type"),
                alt.Tooltip("days:Q", title="Days"),
            ],
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
    per_year["kind"] = per_year["outlier_type"].map(OUTLIER_LABELS)
    st.markdown("**Unusual days per year (all stations)**")
    st.altair_chart(
        alt.Chart(per_year)
        .mark_bar()
        .encode(
            x=alt.X("year:O", title=None),
            y=alt.Y("days:Q", title="Days"),
            color=alt.Color("kind:N", title=None, scale=kind_scale),
            tooltip=[
                alt.Tooltip("year:O", title="Year"),
                alt.Tooltip("kind:N", title="Type"),
                alt.Tooltip("days:Q", title="Days"),
            ],
        )
        .properties(height=240),
        use_container_width=True,
    )

    st.subheader("Highest and lowest historical peaks")
    records = query(f"""
        select s.station_label, o.outlier_type, o.observation_date, round(o.value_c, 1) as value_c
        from {MARTS}.fct_weather_outliers o
        join {MARTS}.dim_station s using (station_id)
        where o.outlier_type in ('RECORD_HIGH', 'RECORD_LOW')
        order by s.station_label, o.outlier_type, o.observation_date
    """)
    records["kind"] = records["outlier_type"].map(OUTLIER_LABELS)
    records["value_f"] = to_f(records["value_c"])
    table(
        records,
        {
            "station_label": "Station",
            "kind": "Record",
            "observation_date": "Date",
            "value_c": "Temperature (°C)",
            "value_f": "Temperature (°F)",
        },
    )
    st.caption("Records use NOAA's official daily values only (since 2006, the period loaded here).")

    st.subheader(f"Most unusual days at {station_label}")
    extremes = query(f"""
        select observation_date, outlier_type, round(value_c, 1) as mean_temp_c, round(z_score, 1) as z_score
        from {MARTS}.fct_weather_outliers
        where station_id = '{station_id}' and outlier_type in ('CLIMATE_ANOMALY_HIGH', 'CLIMATE_ANOMALY_LOW')
        order by abs(z_score) desc
        limit 15
    """)
    extremes["kind"] = extremes["outlier_type"].map(OUTLIER_LABELS)
    extremes["mean_temp_f"] = to_f(extremes["mean_temp_c"])
    table(
        extremes,
        {
            "observation_date": "Date",
            "kind": "Type",
            "mean_temp_c": "Average temp (°C)",
            "mean_temp_f": "Average temp (°F)",
            "z_score": "How unusual (std. deviations from normal)",
        },
    )
    st.caption("'How unusual': 0 = a normal day for that date; 3 or more (or -3 or less) = very rare.")

    st.subheader("Measurement Reliability Checks")
    q1, q2 = st.columns(2)
    quality = query(f"""
        select outlier_type, count(*) as days
        from {MARTS}.fct_weather_outliers
        where outlier_family = 'DATA_QUALITY'
        group by 1 order by 2 desc
    """)
    quality["check"] = quality["outlier_type"].map(OUTLIER_LABELS)
    with q1:
        st.markdown("**Automatic checks on every day of data**")
        table(quality, {"check": "Check", "days": "Days found"})
        st.caption(
            "Doubtful or impossible values are left out of the analysis. The last two checks only flag days "
            "for review: each one was compared with the hourly readings and turned out to be real weather."
        )
    derived = query(f"""
        select station_label, derived_temp_days, observed_days,
               round(observed_day_coverage * 100, 1) as coverage_pct
        from {MARTS}.dim_station order by derived_temp_days desc, station_label
    """)
    with q2:
        st.markdown("**Gaps filled from hourly readings**")
        table(
            derived,
            {
                "station_label": "Station",
                "derived_temp_days": "Days filled in",
                "observed_days": "Days with data",
                "coverage_pct": "Coverage (%)",
            },
        )
        st.caption(
            "Some days had no official daily summary from NOAA (Denver, 2013: 274 days), but the hourly "
            "readings existed. We rebuilt those days from the hourly data and checked the method on 90,509 "
            "days that had both: on average it was off by only 0.24 °C, and within 1 °C 99.2% of the time."
        )

# ---------------------------------------------------------------- pipeline health & cost
with tab_ops:
    st.subheader("Freshness")
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
        "Last successful data check",
        hours_ago(ok_runs["finished_at"].max() if len(ok_runs) else None),
        help="We check NOAA for new data every 6 hours. An email alert is sent if no check succeeds for 12 hours.",
    )
    m2.metric("Result Status", runs["status"].iloc[0].capitalize() if len(runs) else "n/a")
    m3.metric(
        "Last refresh of the analysis",
        hours_ago(last_build["last_build"].iloc[0]),
        help="The analysis is rebuilt daily at 11:30 UTC. An email alert is sent if it is older than 26 hours.",
    )
    m4.metric("Failed checks (last 20)", int((runs["status"] == "failed").sum()))
    st.caption(
        "NOAA does not publish new data every day, so many checks find nothing new; that is expected. "
        "Only changed files are downloaded and loaded."
    )
    runs["started_by"] = (
        runs["triggered_by"]
        .map({"workflow_dispatch": "Scheduler or manual", "schedule": "Backup scheduler"})
        .fillna(runs["triggered_by"])
    )
    table(
        runs,
        {
            "finished_at": "Finished at",
            "status": "Result",
            "started_by": "Started by",
            "files_checked": "Files checked",
            "files_new": "New files",
            "files_changed": "Updated files",
            "rows_loaded": "Rows loaded",
            "duration_seconds": "Duration (s)",
        },
    )

    st.subheader("What does it cost? (Snowflake credits, last 14 days)")
    try:
        cost = query("""
            select warehouse_name, to_date(start_time) as day, sum(credits_used) as credits
            from SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
            where start_time >= dateadd(day, -14, current_date())
            group by 1, 2
        """)
        cost["workload"] = cost["warehouse_name"].map(WAREHOUSE_LABELS).fillna(cost["warehouse_name"])
        st.altair_chart(
            alt.Chart(cost)
            .mark_bar()
            .encode(
                x=alt.X("day:T", title=None, axis=alt.Axis(format="%b %d")),
                y=alt.Y("credits:Q", title="Credits"),
                color=alt.Color("workload:N", title="Used by"),
                tooltip=[
                    alt.Tooltip("workload:N", title="Used by"),
                    alt.Tooltip("day:T", title="Day", format="%d %b"),
                    alt.Tooltip("credits:Q", title="Credits", format=".3f"),
                ],
            )
            .properties(height=300),
            use_container_width=True,
        )
        totals = cost.groupby("workload", as_index=False)["credits"].sum().round(3)
        table(totals, {"workload": "Used by", "credits": "Credits (14 days)"})
        st.caption(
            "Each job has its own compute, so the cost of each part is visible on its own. "
            "A monthly cap of 20 credits stops all compute if it is ever reached. Figures can lag about 3 hours."
        )
    except Exception as exc:  # usage views not granted to the app role
        st.warning(f"Cost view unavailable for this role: {exc}")
