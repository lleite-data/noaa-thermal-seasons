# NOAA project cheat sheet (panel, Mon 9 Nov)

Where everything is, what it does, in one line. Data flows top to bottom.

## 1. Ingest (GitHub Actions + Python)

| File | What it does |
|---|---|
| `.github/workflows/ingest.yml` | The ingest workflow. Started by cron-job.org every 6 h (current + previous year), monthly for all years back to 2006, GitHub's own schedule as backup, or by hand. Validates inputs, writes the key to a temp file, runs the script. |
| `ingest/ingest.py` | The ingest script. Reads the manifest from Snowflake → HEAD request per NOAA file (size, date) → downloads only changed/new files → MD5 check (skip if content identical) → schema drift check → PUT to stage → COPY into raw → updates manifest → trims to latest 4 versions → writes the run log. Fails the run if >5% of files can't be checked. |
| `ingest/tests/test_ingest.py` | Python tests: change detection, HTML-page guard, station list, run outcome, crashed runs still logged, raw retention. |
| `.github/workflows/ci.yml` | On every change: ruff (lint), pytest (ingest + dashboard), actionlint, `dbt parse`. |
| `.github/workflows/dashboard.yml` | On changes to `dashboard/`: smoke test, then deploys the Streamlit app with Snowflake CLI as `DASHBOARD_DEPLOY_SVC`. |

## 2. Snowflake setup scripts (`snowflake/`, run once, in order)

| File | What it creates |
|---|---|
| `01_setup.sql` | Databases `CLIMATE_RAW` (raw, as delivered) and `CLIMATE_ANALYTICS` (dbt). Roles `LOADER_ROLE`, `DBT_ROLE`. Stage, CSV file format (reads header, matches by name). Raw tables with schema evolution on. `INGEST_MANIFEST`, `SCHEMA_DRIFT_LOG`, `INGEST_RUN_LOG`. |
| `02_service_user.sql` | `INGEST_SVC`: service user, key pair, `LOADER_ROLE`. |
| `03_governance.sql` | `DBT_SVC` (dbt's service user), `REPORTER_ROLE` (read-only marts), warehouses per workload (`LOAD_WH`, `TRANSFORM_WH`, `REPORTING_WH`), resource monitor (20 credits/month: warn 75%, suspend 100%). |
| `04_alerts.sql` | Email alert every 3 h: no successful ingest in 12 h, or marts not rebuilt in 26 h. |
| `05_dashboard.sql` | `APPS` schema, `CLIMATE_DASHBOARD_ROLE` (owns the app), compute-pool grant, `DASHBOARD_DEPLOY_SVC`. |
| *(not in repo)* | `REVIEWER_ROLE` + user `ZHIWEI`: read-only on every layer + the app. Your live "onboarding" example. |

## 3. dbt

### Config
| File | What it does |
|---|---|
| `dbt/dbt_project.yml` | Project settings: layer folders → schemas and materializations (staging views, intermediate/marts tables), variables (baseline years, windows, lag days). |
| `dbt/packages.yml` | dbt_utils (extra generic tests, e.g. accepted range, unique combination). |
| `models/staging/_sources.yml` | Declares the raw tables as sources. Freshness: raw warns after 7 days (NOAA can be quiet); the run log errors after 30 h (pipeline broken). |

### Staging: clean the raw text (one row = one thing)
| Model | Materialized | What it does |
|---|---|---|
| `stg_lcd__daily_observations` | **incremental** (merge on station + date) | Daily summary rows (`SOD`) only. Reads NOAA flags out of each field, text → numbers (blank → NULL, never zero), keeps the latest file version per station-day. Only reads rows loaded since the last run (pruning on `_loaded_at`). |
| `stg_lcd__hourly_temperatures` | view | Hourly readings. Only used to rebuild missing days. |
| `stg_lcd__stations` | view | NOAA's station list: names, coordinates. |

### Intermediate: the method's steps (all tables, full rebuild)
| Model | What it does |
|---|---|
| `int_daily_temps_from_hourly` | Rebuilds a day from hourly readings: (max + min) / 2, only with ≥ 18 hours. Filled 274 Denver days in 2013. |
| `int_station_daily_series` | One row per station per **calendar** day (gaps kept as empty rows). Applies quality rules (cleaned temperature), fills from the hourly rebuild, computes the **7-day rolling average** (only if ≥ 5 of 7 days have data). |
| `int_station_thresholds` | Each station's **25th and 75th percentile** of daily averages, 2006–2020. Fixed baseline → never changes when new data arrives. |
| `int_station_day_climatology` | Each date's **normal**: average and spread of baseline days within ±15 days (Dec/Jan wrap around). Used for z-scores. |
| `int_season_onsets` | **The rule.** Per station, season, year: 7-day average crosses the threshold and stays across 5 days, inside the season's window. Gives each season-year a status: `detected`, `not_detected`, `window_incomplete`, etc. |

### Marts: what people read (tables, full rebuild, except one view)
| Model | What it does |
|---|---|
| `fct_daily_weather` | Every station-day with temperature, normal and z-score. |
| `fct_season_onset` | Every detected season start, with station labels. Feeds Q1 and the dashboard. |
| `mart_season_onset_trends` | One row per station × season: typical date (median, middle 50%) for Q1; trend for Q2 (days per decade, R², standard error, t-statistic, significant?). |
| `mart_season_trend_summary` | One row per season across stations: how many earlier/later, median shift. The Q2 headline. |
| `mart_warm_season_length` | Days from summer start to autumn start, per station, and its trend. |
| `fct_weather_outliers` | All outliers, two families: **data quality** (flags, impossible, stuck sensor, jump) and **climate** (unusual days z ≥ 3, records). |
| `dim_station` | One row per station: label, region, coordinates, data coverage. |
| `mart_ingest_runs` | **view** on the run log, so the dashboard shows the latest run live. |
| `_exposures.yml` | Declares the dashboard as a consumer of the marts (shows in lineage). |

### Seeds (small CSVs loaded as tables)
| File | What it holds |
|---|---|
| `seeds/stations_of_interest.csv` | The 12 stations. Adding one = one line + a backfill. |
| `seeds/season_definitions.csv` | Per season: direction (up/down), threshold (25th or 75th), search window. Spring Jan 15–Jun 30, Summer Mar 1–Aug 31, Autumn Jul 1–Nov 30, Winter Sep 1–Mar 31. |

### Macros (reusable SQL)
| File | What it does |
|---|---|
| `macros/lcd_parsing.sql` | Turns NOAA text values into numbers and flags (`s` suspect, `*` erroneous, blank = missing). |
| `macros/quality_rules.sql` | The physical rules, defined once: max < min or mean outside [min, max] (± 0.5 °C), outside −70 to 60 °C. Used by both cleaning and reporting. |
| `macros/generate_schema_name.sql` | Prod writes to clean schema names (`STAGING`, `MARTS`); dev writes to `dbt_<you>_staging` etc. |

### Tests (singular, `dbt/tests/`)
| File | Severity | Checks |
|---|---|---|
| `assert_raw_to_staging_daily_reconciliation` | error | Station-days in raw = rows in staging. Nothing lost, nothing duplicated. |
| `assert_station_year_completeness` | warn | Every complete station-year has (almost) every day. |
| `assert_station_recency` | warn | Every station has data in the last 14 days. |
| `assert_hourly_derivation_accuracy` | error | Rebuilt days still match NOAA's official values (bias and error within limits). |
| `assert_no_definite_quality_problems` | warn | Alarm: NOAA flagged or impossible values exist (already excluded). |
| `assert_quality_problems_excluded_from_analysis` | error | Guard: no reported-bad day has a value in the analysis series. |
| `assert_seasons_in_order` | warn | Spring < summer < autumn in a year; autumn before the next winter. |

Plus **generic tests** in the `_*.yml` files: unique, not null, accepted values, relationships, accepted range, unique combinations.

### Unit test
| File | What it does |
|---|---|
| `models/intermediate/_unit_tests.yml` → `season_onset_rules` | Fake input, known answer, runs before `int_season_onsets` is built. A: 3-day false start ignored → 20 Mar. B: missing day breaks streak → 10 Mar. C: data starts mid-window → `window_incomplete`. D: never warms → `not_detected`. |

**Totals on every build:** 71 items = 16 models + 2 seeds + 52 data tests + 1 unit test (all passed, 27 Oct).

### Analyses (`dbt/analyses/`, run on demand, not built)
| File | What it does |
|---|---|
| `answers/q1_typical_onsets.sql` | Q1 table: typical start date per station and season. |
| `answers/q2_summary.sql` | Q2 headline: stations earlier/later per season. |
| `answers/q2_station_trends.sql` | Q2 per station: days per decade, R², t, significant. |
| `answers/q2_warm_season_length.sql` | Warm-season length and its trend. |
| `answers/q3_outlier_counts.sql` | Q3 counts by type and station. |
| `answers/q3_records_and_extremes.sql` | Records and most unusual days. |
| `onset_sensitivity.sql` | Re-runs the rule with 4 settings (base, 10-day persistence, 14-day smoothing, 20/80 thresholds). |
| `spring_relapses.sql` | How often spring falls back into cold within 30 days. |
| `hourly_rebuild_validation.sql` | Accuracy of the hourly rebuild on ~90k days (error 0.24 °C). |
| `data_profile.sql` | What the raw files contain: rows per year by type. |

## 4. Dashboard (`dashboard/`)
| File | What it does |
|---|---|
| `streamlit_app.py` | The app. Tabs: **Season start** (typical dates, per station), **Shift Trends** (Q2 with evidence grade), **Outliers** (counts, records), **Pipeline health & cost** (runs, credits). |
| `snowflake.yml` | Deploy definition: name, warehouse, container runtime, 1-day idle shutdown. |
| `tests/test_app_smoke.py` | Renders every tab against fake data; checks for errors, not numbers. |

## 5. Docs
| File | What it holds |
|---|---|
| `README.md` | Answers in brief, how the brief is covered, how to run, tests. |
| `docs/answers.md` | Q1–Q3 in detail with tables, screenshots, records checked against news. |
| `docs/methodology.md` | Data profile, season rule, statistics, outlier rules, limitations, glossary. |
| `docs/architecture.md` | Design, reliability, security, cost, scaling, production path. |
| `docs/evidence/` | Build log (71/71), screenshot, query results behind every number. |

---

# Statistics in plain words (with your numbers)

**The setup.** For each station and season you have ~21 points: one start date per year. You draw the best straight line through them.

| Term | Plain meaning | Your example |
|---|---|---|
| **Slope** | How much the start date moves per year along the line. ×10 = **days per decade**. Positive = later, negative = earlier. | Chicago autumn +12.1 days/decade |
| **Noise** | Start dates jump weeks between years because of that year's weather. The trend (days per decade) is small next to that. | Typical year-to-year swing: 2–5 weeks |
| **R²** | Share of the year-to-year variation the line explains (0 to 1). Low = the line explains little; the rest is weather noise. Low R² is normal here. | Chicago autumn 0.14; Miami autumn 0.22 |
| **Standard error** | How uncertain the slope is. More noise or fewer years → bigger. | (computed, not shown) |
| **t-statistic** | Slope ÷ its standard error. "How many uncertainties away from zero is the slope?" **|t| ≥ 2.1** ≈ unlikely to be chance (about 5%). | Miami autumn 2.34 → significant; Chicago 1.73, Bismarck 1.99 → not quite |
| **Significant** | One station's trend clears the 2.1 bar on its own. Most don't, because 21 noisy years is short. | Autumn: only Miami |
| **Sign test** | Ignore sizes; count directions across stations. If each station were a coin flip, how likely is it that this many agree? | Autumn 12/12 later → ~0.05% (1 in 4,000) |
| **Evidence grade** | From the sign test: < 1% strong, < 5% moderate, < 10% weak. | Autumn strong · Summer 10/12 earlier moderate (3.9%) · Spring 9 of 11 weak (6.5%) · Winter 8/12 nothing (39%) |
| **Sign test caveat** | It assumes stations are independent. Neighbours share weather, so the real certainty is lower. Say it yourself: "strong but indicative". | |
| **Sensitivity check** | Re-run with 4 settings. Directions held for autumn and summer; sizes vary (spring −3.6 to −9.8). | |
| **z-score** | How many standard deviations a day is from its normal (±15-day climatology). **≥ 3** = unusual day. | 211 unusual days (144 cold, 67 warm) |

**Why "only Miami is significant" and "12 of 12 later" both hold:** direction vs certainty. All 12 slopes point later; each alone is too noisy to be sure. Twelve weak witnesses all agreeing is strong evidence (by chance: ~1 in 4,000).

**The gap to name:** slope and R² use Snowflake's built-in `REGR_SLOPE` / `REGR_R2`; the standard error and t-statistic are a hand-written formula with no unit test. Fix: a unit test on a known dataset, checked against a stats library.

---

# Key numbers
- 12 stations · 2006 → today · baseline 2006–2020
- Season rule: 7-day average crosses p25/p75, stays across 5 days, inside the window
- Q1: summer early–mid Jun · autumn early–mid Sep (Miami late Aug) · winter 2nd half Nov · spring least regular (early Feb–early Mar)
- Q2: autumn later 12/12 (~+7/decade, strong) · summer earlier 10/12 (−2.6, moderate) · spring probably earlier (weak) · winter no trend · warm season longer at 11/12 (+11.6 median)
- Q3: 211 unusual days, cold ~2× warm · records match news (Seattle 108 °F 2021, Miami 100 °F Aug 2026) · Denver 2013: 274 days rebuilt, error 0.24 °C
- Pipeline: every 6 h ingest · daily dbt build · 71 checks · alert every 3 h · ~10 credits/month (~$30), cap 20 · dashboard container ~3 credits/day when running
