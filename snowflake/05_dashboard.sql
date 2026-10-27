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
GRANT ROLE CLIMATE_DASHBOARD_ROLE TO USER "<YOUR_USER>";           -- your user NAME, to open/edit the app

-- 3) Container runtime (newer Snowsight default) needs the compute pool
--    Cost: the container is billed while the app runs and is not covered by the warehouse
--    resource monitor; dashboard/snowflake.yml stops it after 15 min without viewers.
GRANT USAGE ON COMPUTE POOL SYSTEM_COMPUTE_POOL_CPU TO ROLE CLIMATE_DASHBOARD_ROLE;

-- 4) Deploy = CI, not the UI. .github/workflows/dashboard.yml runs on every push to
--    main that touches dashboard/: smoke test (mocked Snowflake), then
--    `snow streamlit deploy --replace` (dashboard/snowflake.yml) as this service user.
--    Key pair (Git Bash, outside the repo):
--      openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out dashboard_deploy_key.p8 -nocrypt
--      openssl rsa -in dashboard_deploy_key.p8 -pubout -out dashboard_deploy_key.pub
--    GitHub secret SNOWFLAKE_DEPLOY_PRIVATE_KEY = full dashboard_deploy_key.p8.
CREATE USER IF NOT EXISTS DASHBOARD_DEPLOY_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = CLIMATE_DASHBOARD_ROLE
    DEFAULT_WAREHOUSE = REPORTING_WH
    COMMENT = 'GitHub Actions: deploys the Streamlit dashboard';
ALTER USER DASHBOARD_DEPLOY_SVC SET RSA_PUBLIC_KEY = '<body of dashboard_deploy_key.pub, without BEGIN/END lines>';
GRANT ROLE CLIMATE_DASHBOARD_ROLE TO USER DASHBOARD_DEPLOY_SVC;
-- Deploying with the owner role keeps ownership and the app's read-only access unchanged.
-- Note: apps created in the Snowsight UI land in the creator's personal database
-- (USER$<name>.PUBLIC), tied to a person; CI always deploys to CLIMATE_ANALYTICS.APPS.

-- 5) Verify
-- SHOW STREAMLITS IN SCHEMA CLIMATE_ANALYTICS.APPS;
