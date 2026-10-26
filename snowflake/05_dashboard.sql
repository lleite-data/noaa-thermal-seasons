-- =====================================================================
-- 05_dashboard.sql: Streamlit in Snowflake dashboard (dashboard as code)
--
-- The app code lives in dashboard/streamlit_app.py. Streamlit apps run with the
-- OWNER's rights, so the owner role decides what the app can read:
--   CLIMATE_DASHBOARD_ROLE = REPORTER_ROLE (read-only MARTS, REPORTING_WH)
--                            + SNOWFLAKE.USAGE_VIEWER (cost panel only)
-- A dedicated role keeps REPORTER_ROLE itself "marts only" for human analysts.
-- Run as ACCOUNTADMIN.
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- 1) Where apps live (separate from dbt-managed schemas)
CREATE SCHEMA IF NOT EXISTS CLIMATE_ANALYTICS.APPS COMMENT = 'Streamlit apps (not managed by dbt)';

-- 2) App owner role
CREATE ROLE IF NOT EXISTS CLIMATE_DASHBOARD_ROLE COMMENT = 'Owner of the climate dashboard app';
GRANT ROLE REPORTER_ROLE TO ROLE CLIMATE_DASHBOARD_ROLE;            -- marts read + REPORTING_WH
GRANT DATABASE ROLE SNOWFLAKE.USAGE_VIEWER TO ROLE CLIMATE_DASHBOARD_ROLE;  -- WAREHOUSE_METERING_HISTORY
GRANT USAGE ON SCHEMA CLIMATE_ANALYTICS.APPS TO ROLE CLIMATE_DASHBOARD_ROLE;
GRANT CREATE STREAMLIT ON SCHEMA CLIMATE_ANALYTICS.APPS TO ROLE CLIMATE_DASHBOARD_ROLE;
GRANT CREATE STAGE     ON SCHEMA CLIMATE_ANALYTICS.APPS TO ROLE CLIMATE_DASHBOARD_ROLE;
GRANT ROLE CLIMATE_DASHBOARD_ROLE TO ROLE SYSADMIN;
GRANT ROLE CLIMATE_DASHBOARD_ROLE TO USER "levigle.spam";          -- to create/edit the app

-- 3) Deploy (one time, Snowsight UI):
--    switch role to CLIMATE_DASHBOARD_ROLE (the app's owner = the role you create it with)
--    Projects -> Streamlit -> + Streamlit App
--      Name: CLIMATE_SEASONS_DASHBOARD
--      Location: CLIMATE_ANALYTICS.APPS
--      Warehouse: REPORTING_WH
--    Replace the sample code with dashboard/streamlit_app.py -> Run.
--    Packages: default Streamlit/Altair/pandas/numpy are enough (smoke-tested on
--    Streamlit 1.35 + Altair 4.2 and Streamlit 1.66 + Altair 6).
--
--    Production path (CI deploy, no UI): Snowflake CLI from GitHub Actions
--      snow streamlit deploy --replace   (snowflake.yml points at dashboard/streamlit_app.py)
--    so every merge to main redeploys the reviewed code.

-- 4) Verify
-- SHOW STREAMLITS IN SCHEMA CLIMATE_ANALYTICS.APPS;
