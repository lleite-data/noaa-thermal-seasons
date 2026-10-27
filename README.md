# NOAA Thermal Seasons

When does each season start, is that changing, and what outliers were recorded?
A data pipeline that loads NOAA weather data into **Snowflake**, transforms it with
**dbt**, and serves the answers in a **Streamlit** app inside Snowflake.

![Architecture overview](docs/architecture_overview.png)

## The answers in brief

Twelve US weather stations, 2006 to today. Seasons are **thermal**: defined by each
station's own temperatures, not the calendar.

1. **When seasons start.** Summer is the most regular (early June everywhere). Autumn
   starts early to mid September, winter in the second half of November. Spring is the
   least regular: mid February to early March, with frequent cold relapses.
2. **Change and trend.** **Autumn starts later at all 12 stations** (about +7 days per
   decade) and **summer earlier at 10 of 12** (about −2.6), so the warm season is getting
   longer. Spring is also earlier (direction robust, size uncertain). Winter shows no
   reliable trend. The conclusions hold under four different method settings.
3. **Outliers.** About 200 unusually warm or cold days (cold ones twice as common), and
   each station's record high and low. No doubtful or impossible measurements; one real
   data gap (Denver, 2013) was rebuilt from hourly readings and validated.

Full results: [docs/answers.md](docs/answers.md).

## Documents

| Document | Contents |
|---|---|
| [Answers](docs/answers.md) | results for Q1–Q3, with tables, evidence and caveats |
| [Methodology](docs/methodology.md) | definitions, choices and alternatives, trend and outlier methods, limitations, glossary |
| [Architecture](docs/architecture.md) | components, data flow, design decisions, reliability, security, cost, scaling |
| [Overview diagram](docs/architecture_overview.png) · [detailed diagram](docs/architecture_detailed.png) | editable `.drawio` sources next to them |

## How the brief is covered

| Requirement | Where |
|---|---|
| Load at least the last 5 years | about 21 years (2006 → today), any range by parameter |
| Pattern of season starts (Q1) | `mart_season_onset_trends`, dashboard tab *Season start* |
| Change and trend (Q2) | `mart_season_onset_trends`, `mart_season_trend_summary`, `mart_warm_season_length`, tab *Shift trends* |
| Outliers (Q3) | `fct_weather_outliers`, tab *Outliers* |
| Snowflake | raw and analytics databases, alert, dashboard |
| dbt | all transformations, tests and documentation |
| Scalable to more history and future data | change detection, incremental loads, fixed baseline; national-scale design in [architecture](docs/architecture.md#scaling-up) |
| Architecture diagram, methodology, answers | [`docs/`](docs/) |

## Repository layout

| Path | Contents |
|---|---|
| `ingest/` | Python ingest (`ingest.py`): change detection, download, load, run log; offline tests |
| `.github/workflows/` | `ingest.yml` scheduled load · `ci.yml` lint and tests · `dashboard.yml` test and deploy |
| `snowflake/` | setup SQL, run once in order (`01` to `05`) |
| `dbt/` | dbt project: `models/` (staging, intermediate, marts), `tests/`, `seeds/`, `macros/`, `analyses/` |
| `dashboard/` | Streamlit app, Snowflake CLI deploy definition, smoke tests |
| `docs/` | documents and diagrams |

## Running it

**1. Snowflake** (as `ACCOUNTADMIN`, once, in order):

| Script | Creates |
|---|---|
| `snowflake/01_setup.sql` | warehouse, databases, roles, stage, file format, raw tables |
| `snowflake/02_service_user.sql` | `INGEST_SVC` (key pair) for the ingest |
| `snowflake/03_governance.sql` | `DBT_SVC`, read-only `REPORTER_ROLE`, one warehouse per workload, credit cap |
| `snowflake/04_alerts.sql` | email integration and the hourly staleness alert |
| `snowflake/05_dashboard.sql` | `APPS` schema, dashboard role, `DASHBOARD_DEPLOY_SVC` |

Each script says which key pair to generate and where its public part goes.

**2. GitHub secrets:** `SNOWFLAKE_ACCOUNT`, `SNOWFLAKE_USER` (`INGEST_SVC`),
`SNOWFLAKE_PRIVATE_KEY`, `SNOWFLAKE_DEPLOY_PRIVATE_KEY`.

**3. Load data.** Run the *ingest* workflow manually with `start_year = 2006` and
`load_station_list = true`, or locally:

```bash
pip install -r ingest/requirements.txt
export SNOWFLAKE_ACCOUNT=... SNOWFLAKE_USER=INGEST_SVC SNOWFLAKE_PRIVATE_KEY_PATH=...
python ingest/ingest.py --start-year 2006 --load-station-list
```

Scheduling: an external scheduler (cron-job.org) calls the workflow's `workflow_dispatch`
API every 6 hours; the workflow's own schedule is the backup (see the header of
`.github/workflows/ingest.yml`).

**4. dbt.** dbt Cloud project with subdirectory `dbt`; Production environment connected
as `DBT_SVC` (role `DBT_ROLE`, warehouse `TRANSFORM_WH`); one job:
`dbt source freshness` then `dbt build`, daily at 11:30 UTC. Locally: `dbt deps && dbt build`.

**5. Dashboard.** Deployed automatically by `dashboard.yml` on every push to `main` that
changes `dashboard/`. Open it in Snowsight: *Projects → Streamlit →
CLIMATE_SEASONS_DASHBOARD*.

## Tests

| Where | What |
|---|---|
| `ingest/tests` (pytest, CI) | change detection, header guard, station-list parser, run outcome |
| `dashboard/tests` (pytest, CI) | every dashboard tab renders for every season, with Snowflake mocked |
| dbt (every build) | source freshness, keys, raw → staging reconciliation, completeness, hourly-rebuild accuracy, data-quality rules, unit tests for the season-start rule |
| CI | ruff, actionlint, dbt parse |
