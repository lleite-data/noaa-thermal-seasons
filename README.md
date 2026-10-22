# NOAA Thermal Seasons

Data pipeline that loads NOAA Local Climatological Data (LCD v2) into Snowflake and
uses dbt to answer:

1. What is the pattern for when each season starts?
2. Has the start of each season changed, and is there a trend?
3. What outliers have been recorded?

## Repository layout

| Path | Purpose |
|---|---|
| `snowflake/` | One-time Snowflake setup (warehouse, databases, roles, stage, raw tables) and the ingest service user |
| `ingest/` | Python ingest: change detection against NOAA, download, load to Snowflake |
| `.github/workflows/` | Scheduled ingest on GitHub Actions (daily + monthly full scan) |
| `dbt/` | dbt project: staging, intermediate, marts, tests, docs |

Documentation (architecture, methodology, answers) is added under `docs/`.
