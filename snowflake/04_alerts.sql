-- =====================================================================
-- 04_alerts.sql: pipeline staleness alert (email)
--
-- Why: dbt Cloud's free tier has no job notifications. cron-job.org and
-- GitHub Actions email on their own failures, but nothing tells us when a
-- run simply never happens or dbt stops rebuilding. This alert watches
-- both layers from the warehouse side, where the data actually lands.
--
-- Checks (hourly at :15 UTC):
--   1. INGEST STALE: no successful/warning run in INGEST_RUN_LOG for 12 h
--      (triggers every 6 h, so two runs in a row must fail).
--   2. DBT STALE: MARTS.FCT_SEASON_ONSET not rebuilt for 26 h
--      (daily_build runs at 11:30 UTC; +2 h slack for a slow run).
-- INFORMATION_SCHEMA is real time (ACCOUNT_USAGE lags hours).
--
-- Cost: ~24 short X-Small wake-ups/day (60 s minimum billing each).
-- Run as ACCOUNTADMIN. Snowflake only emails verified users of the account.
-- Production path: route the same alert to a team mailbox / webhook
-- (Slack, PagerDuty) via a webhook notification integration.
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- 1) Email integration (only listed, verified recipients)
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS CLIMATE_EMAIL_ALERTS
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('levigle.spam@gmail.com');

-- Smoke test of the email path
-- CALL SYSTEM$SEND_EMAIL('CLIMATE_EMAIL_ALERTS', 'levigle.spam@gmail.com',
--     'Snowflake test: climate pipeline alerts', 'Snowflake can email you.');

-- 2) Condition on its own: must return 0 rows when healthy
-- SELECT 'INGEST STALE' AS problem, MAX(finished_at)::varchar AS last_ok
-- FROM CLIMATE_RAW.LCD.INGEST_RUN_LOG
-- WHERE status IN ('success', 'warning')
-- HAVING MAX(finished_at) IS NULL
--     OR MAX(finished_at) < DATEADD('hour', -12, CURRENT_TIMESTAMP())
-- UNION ALL
-- SELECT 'DBT STALE', last_altered::varchar
-- FROM CLIMATE_ANALYTICS.INFORMATION_SCHEMA.TABLES
-- WHERE table_schema = 'MARTS' AND table_name = 'FCT_SEASON_ONSET'
--   AND last_altered < DATEADD('hour', -26, CURRENT_TIMESTAMP());

-- 3) The alert
CREATE OR REPLACE ALERT CLIMATE_RAW.LCD.PIPELINE_STALENESS_ALERT
  WAREHOUSE = CLIMATE_WH
  SCHEDULE = 'USING CRON 15 * * * * UTC'
  IF (EXISTS (
      SELECT 1
      FROM CLIMATE_RAW.LCD.INGEST_RUN_LOG
      WHERE status IN ('success', 'warning')
      HAVING MAX(finished_at) IS NULL
          OR MAX(finished_at) < DATEADD('hour', -12, CURRENT_TIMESTAMP())
      UNION ALL
      SELECT 1
      FROM CLIMATE_ANALYTICS.INFORMATION_SCHEMA.TABLES
      WHERE table_schema = 'MARTS'
        AND table_name = 'FCT_SEASON_ONSET'
        AND last_altered < DATEADD('hour', -26, CURRENT_TIMESTAMP())
  ))
  THEN
    CALL SYSTEM$SEND_EMAIL(
      'CLIMATE_EMAIL_ALERTS',
      'levigle.spam@gmail.com',
      'ALERT: NOAA climate pipeline is stale',
      'Either no successful ingest in 12 h (check CLIMATE_RAW.LCD.INGEST_RUN_LOG and GitHub Actions) or the dbt marts were not rebuilt in 26 h (check the dbt Cloud daily_build job).'
    );

ALTER ALERT CLIMATE_RAW.LCD.PIPELINE_STALENESS_ALERT RESUME;   -- alerts start suspended
SHOW ALERTS IN SCHEMA CLIMATE_RAW.LCD;

-- 4) Fire drill (done 26 Oct 2026: TRIGGERED, email received).
--    Same logic with thresholds 1 h in the FUTURE so both checks fire;
--    run once by hand, check history, drop.
-- CREATE OR REPLACE ALERT CLIMATE_RAW.LCD.PIPELINE_ALERT_DRILL
--   WAREHOUSE = CLIMATE_WH
--   SCHEDULE = 'USING CRON 0 0 1 1 * UTC'
--   IF (EXISTS (
--       SELECT 1 FROM CLIMATE_RAW.LCD.INGEST_RUN_LOG
--       WHERE status IN ('success', 'warning')
--       HAVING MAX(finished_at) IS NULL
--           OR MAX(finished_at) < DATEADD('hour', 1, CURRENT_TIMESTAMP())
--   ))
--   THEN CALL SYSTEM$SEND_EMAIL('CLIMATE_EMAIL_ALERTS', 'levigle.spam@gmail.com',
--       'DRILL: NOAA climate pipeline alert test', 'Fire drill. No action needed.');
-- EXECUTE ALERT CLIMATE_RAW.LCD.PIPELINE_ALERT_DRILL;
-- SELECT name, state, scheduled_time, completed_time, sql_error_message
-- FROM TABLE(CLIMATE_RAW.INFORMATION_SCHEMA.ALERT_HISTORY(
--        SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP())))
-- ORDER BY scheduled_time DESC;
-- DROP ALERT CLIMATE_RAW.LCD.PIPELINE_ALERT_DRILL;
