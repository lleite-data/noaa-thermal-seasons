# Architecture

![Architecture overview](architecture_overview.png)

A detailed version (every table, model, role and check) is in
[architecture_detailed.png](architecture_detailed.png). Both diagrams are editable in
draw.io ([overview](architecture_overview.drawio), [detailed](architecture_detailed.drawio)).

## In one paragraph

An **ELT** pipeline. A Python script on **GitHub Actions** checks NOAA every 6 hours,
downloads only new or changed files and loads them, unchanged, into **Snowflake** (raw).
**dbt**, run daily by dbt Cloud, turns raw into tested tables that answer the three
questions (marts). A **Streamlit app inside Snowflake** shows the answers, and analysts can
query the marts directly. Everything is code in one GitHub repository; production runs only
as service accounts.

## Components

| Component | Technology | Role |
|---|---|---|
| Source | NOAA LCD v2 (public HTTPS files) | one CSV per station per year |
| Scheduler | cron-job.org (primary), GitHub cron (backup) | starts the ingest every 6 hours and a full historical scan monthly |
| Ingest | Python on GitHub Actions | change detection, download, upload, load, run log |
| Raw | Snowflake `CLIMATE_RAW.LCD` | data exactly as delivered + load metadata |
| Transform | dbt (dbt Cloud job, SQL runs in Snowflake) | staging → intermediate → marts, with tests |
| Analytics | Snowflake `CLIMATE_ANALYTICS` | `STAGING`, `INTERMEDIATE`, `MARTS`, `REFERENCE` schemas |
| Dashboard | Streamlit in Snowflake (`APPS` schema) | answers Q1–Q3, pipeline health and cost |
| CI/CD | GitHub Actions | lint and tests on every change; deploys the dashboard |
| Monitoring | Snowflake Alert, dbt freshness tests, scheduler emails | email when something fails or goes stale |

## How data flows

1. **Trigger.** cron-job.org calls the GitHub API every 6 hours (04, 10, 16, 22 UTC) to
   start the ingest; on the 1st of each month it starts a full scan from 2006 that also
   reloads the station list. GitHub's own scheduler runs twice a day as a backup.
2. **Detect and download.** For each station-year, a cheap `HEAD` request compares the
   file's size and date with the last load (`INGEST_MANIFEST`). Only new or changed files
   are downloaded, then checked: content hash (to skip metadata-only changes) and header
   (to reject error pages).
3. **Upload (`PUT`).** Files go to a Snowflake internal stage, one parallel upload per year.
4. **Load (`COPY INTO`).** Rows are loaded into `RAW_LCD_OBSERVATIONS`, all columns as text.
   Snowflake's load history means a file is never loaded twice. Versions of a file beyond
   its latest 4 are then deleted (see [Reliability](#reliability)).
5. **Transform (`dbt build`).** Daily at 11:30 UTC: check freshness, then build and test
   every model in dependency order.
6. **Serve.** The dashboard and analysts read the marts, read-only.

## Design decisions

| Decision | Why | Alternative considered |
|---|---|---|
| **ELT, raw kept as delivered** (all text) | Any logic change is a dbt re-run, no re-download; a format change at NOAA cannot break the load | Typed load: fragile, loses the original values |
| **Ingest on GitHub Actions** | The Snowflake trial blocks outbound network access from Snowflake; Actions is free, versioned, has secrets management | Snowflake task with external access (the production option on a paid account) |
| **External scheduler + GitHub backup** | GitHub's scheduler ran 2–5 hours late in testing; cron-job.org fires on time. Duplicate runs are harmless | Cloudflare Workers cron; an orchestrator (Airflow, Azure Data Factory) in production |
| **Change detection** (HEAD + manifest + hash) | Only changed files are downloaded; a monthly full scan catches NOAA's corrections to old years | Re-download everything every run |
| **Internal stage + `PUT` + `COPY INTO`** | Simple, secure, idempotent by Snowflake's load history | External stage + Snowpipe (the scale-up path) |
| **Schema evolution + match by column name** | A new NOAA column is added automatically and logged (`SCHEMA_DRIFT_LOG`); a dropped column loads as NULL | Fixed schema: the load breaks on change |
| **Three dbt layers** | Staging cleans, intermediate holds the method, marts hold the answers; each layer is tested | One large SQL script |
| **Fixed 2006–2020 baseline** | Thresholds never change, so results are reproducible and new data never rewrites history (staging is incremental) | Rolling baseline: every load would recompute everything |
| **Marts as tables** | Computed once a day, read many times by the dashboard | Views: recomputed on every read |
| **Dashboard inside Snowflake, deployed by CI** | Data never leaves Snowflake; access is governed by Snowflake roles; every change is tested before deploy | External BI tool with its own copy of credentials |
| **One warehouse per workload** | Cost per workload is visible, and workloads cannot slow each other | One shared warehouse |

## Reliability

- **Safe to rerun.** One ingest at a time; the same file is never loaded twice; when NOAA
  revises a file, the new version is loaded next to the old one and dbt staging keeps the
  latest version of each row.
- **Recent history kept, but bounded.** Raw keeps each file's current version and the 3
  before it (its last 3 changes), so an earlier version can be compared or restored if a
  NOAA revision looks wrong. After each successful load, older versions of the files just
  loaded are deleted (Time Travel can still recover them for the table's retention
  period, 1 day by default). Without this, the current-year files, which change almost
  daily, would grow without limit.
- **Fails loudly.** The ingest exits with an error (red run, email) on any load error or
  if more than 5% of source requests fail. Every loading run is recorded in
  `INGEST_RUN_LOG`, including runs that crash (status `failed`, with the error message).
- **Two kinds of staleness, two responses.** No successful ingest in 30 hours means the
  pipeline is broken: the dbt job stops. No new NOAA data for 7 days means the source is
  quiet (NOAA publishes in batches): a warning only.
- **Independent alert.** A Snowflake Alert checks every 3 hours and emails if there was no
  successful ingest in 12 hours or the marts were not rebuilt in 26 hours. This catches
  the case nothing else does: a run that silently never happened.
- **Tests on every build:** row reconciliation raw → staging, unique and not-null keys,
  completeness per station-year, accuracy of the hourly rebuild, data-quality rules,
  seasons detected in their natural order, and unit tests for the season-start rule.

## Security

- Production runs only as **service users with key-pair login**: `INGEST_SVC` (ingest),
  `DBT_SVC` (dbt), `DASHBOARD_DEPLOY_SVC` (dashboard deploy). No passwords, no personal
  accounts in production.
- **Least privilege:** `LOADER_ROLE` writes raw; `DBT_ROLE` reads raw and writes analytics;
  `REPORTER_ROLE` reads marts only; the dashboard runs as `CLIMATE_DASHBOARD_ROLE`
  (marts + cost views, nothing else).
- Private keys live only in GitHub secrets and dbt Cloud, never in the repository. The
  GitHub token used by the scheduler is limited to this repository and to the Actions
  permission (start and cancel runs; no access to code or secrets), and expires every
  90 days. Manual-run inputs are validated before use, and the private key is written
  to the runner only after that.
- The data is public weather data with no personal information. With sensitive data, the
  same roles would be combined with masking and row-access policies.

## Cost

- Every warehouse is X-Small and suspends after 60 seconds idle.
- A **resource monitor** caps all warehouses at 20 credits per month (email at 75%,
  suspend at 100%). In normal running they use about 10 a month.
- Change detection keeps ingest cheap: most runs find nothing new and finish in seconds.
- The dashboard runs in a container (Snowflake compute pool), which is billed while the
  app is running (about 3 credits a day, the largest cost in the account) and is **not**
  covered by the warehouse resource monitor. The app shuts down after 1 day without
  viewers, the shortest idle time Snowflake allows for container apps. For occasional use,
  the cheaper option is Snowflake's warehouse runtime: the app then runs on `REPORTING_WH`
  only while someone has it open, and falls under the monitor (see Production path).
- The staleness alert checks every 3 hours. Each check wakes a warehouse, billed for at
  least 60 seconds, so this costs about 4 credits a month (checking hourly would use about
  12, most of the cap).
- The dashboard's *Pipeline health & cost* tab shows credits per warehouse for the last
  14 days.

## Scaling up

The pilot is 12 stations. The design is meant to reach all ~6,100 US stations (or worldwide):

| Concern | Today (12 stations) | At national scale |
|---|---|---|
| Change detection | one `HEAD` request per file | NOAA's inventory: one small JSON per data file (size, dates, columns), downloaded as one bundle per year |
| Download | individual files | yearly archives (`tar.gz`) |
| Storage | files uploaded to an internal stage | files kept in object storage (S3/Azure), read through an external stage |
| Load | `COPY INTO` from GitHub Actions | Snowpipe, loading as files arrive |
| Volume | ~90,000 daily rows | ~44 million daily rows (20 years); over 1 TB of files, 97% of it hourly data, which stays in object storage |
| Raw history | latest 4 versions of each file kept; older ones deleted after each load | same rule in Snowflake; every version also kept as a file in object storage (cheap archive) |
| Backfill | one run | partitioned by year, in parallel, on a temporarily larger warehouse |
| Transform | full rebuild of intermediate and marts | incremental models, clustering by station and date |
| Grouping | NOAA climate regions (US only) | Köppen–Geiger climate zones (worldwide) |

Rollout would start with a pilot of about 100 stations to measure load time and cost
before going national.

## Production path

What would change outside a trial account:

- **Orchestration:** one orchestrator (e.g. Azure Data Factory or Airflow) runs ingest and
  then triggers the dbt job, instead of two independent schedules.
- **dbt jobs as code** (`dbt-jobs-as-code`), reviewed in pull requests like everything else
  (not available on the dbt Cloud free plan used here).
- **Alerts to a team channel** (Slack, PagerDuty) through a webhook integration, not a
  personal email; the alert owned by a dedicated monitoring role instead of `ACCOUNTADMIN`,
  and serverless (no warehouse to wake up).
- **The ingest itself inside Snowflake** (a task with an external network integration),
  which the trial account does not allow.
- **Dashboard on the warehouse runtime** if it is used occasionally: it then runs only
  while open and is capped by the resource monitor, instead of a container billed while
  it runs.
- **Branch protection** on `main` with required reviews; key rotation using Snowflake's
  second key slot (`RSA_PUBLIC_KEY_2`) for zero-downtime changes.

## Where things are in the repo

| Path | Contents |
|---|---|
| `ingest/` | Python ingest + offline unit tests |
| `.github/workflows/` | `ingest.yml` (scheduled load), `ci.yml` (lint + tests), `dashboard.yml` (test + deploy) |
| `snowflake/` | setup SQL in run order: databases and roles, service users, governance, alert, dashboard |
| `dbt/` | models, tests, seeds, macros, analyses (sensitivity check, answer queries) |
| `dashboard/` | Streamlit app, deploy definition, smoke tests |
| `docs/` | these documents and the diagrams |
