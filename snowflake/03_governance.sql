-- =====================================================================
-- Governance hardening (run once as ACCOUNTADMIN)
--   1. DBT_SVC: dedicated service user for the dbt Cloud Production profile
--      (production never runs as a person)
--   2. REPORTER_ROLE: read-only access to the published marts (dashboards, analysts)
--   3. Separate warehouses per workload + a resource monitor (cost guardrail)
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- ---------- 1. dbt production service user ----------
-- Generate a key pair locally (Git Bash):
--   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out dbt_svc_key.p8 -nocrypt
--   openssl rsa -in dbt_svc_key.p8 -pubout -out dbt_svc_key.pub
CREATE USER IF NOT EXISTS DBT_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = DBT_ROLE
    DEFAULT_WAREHOUSE = TRANSFORM_WH
    COMMENT = 'dbt Cloud Production environment';
ALTER USER DBT_SVC SET RSA_PUBLIC_KEY = '<body of dbt_svc_key.pub, without BEGIN/END lines>';
GRANT ROLE DBT_ROLE TO USER DBT_SVC;
-- Then in dbt Cloud: Production profile -> Username DBT_SVC (its login name),
-- Private key = full content of dbt_svc_key.p8, Warehouse TRANSFORM_WH.

-- ---------- 2. read-only role for consumers ----------
CREATE ROLE IF NOT EXISTS REPORTER_ROLE COMMENT = 'Read-only on published marts';
GRANT ROLE REPORTER_ROLE TO ROLE SYSADMIN;
GRANT USAGE ON DATABASE CLIMATE_ANALYTICS                    TO ROLE REPORTER_ROLE;
GRANT USAGE ON SCHEMA   CLIMATE_ANALYTICS.MARTS              TO ROLE REPORTER_ROLE;
GRANT SELECT ON ALL    TABLES IN SCHEMA CLIMATE_ANALYTICS.MARTS TO ROLE REPORTER_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CLIMATE_ANALYTICS.MARTS TO ROLE REPORTER_ROLE;
GRANT SELECT ON ALL    VIEWS  IN SCHEMA CLIMATE_ANALYTICS.MARTS TO ROLE REPORTER_ROLE;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA CLIMATE_ANALYTICS.MARTS TO ROLE REPORTER_ROLE;
-- dbt replaces tables on every build; FUTURE grants make the new tables readable.
-- Note: future grants at schema level only apply if the schema owner (DBT_ROLE)
-- does not override them; if a rebuilt table loses access, add to dbt_project.yml:
--   models: +grants: {select: ['REPORTER_ROLE']}   (marts only)
GRANT ROLE REPORTER_ROLE TO USER "levigle.spam";   -- your user NAME, for the dashboard
-- Testing it: newer users default to DEFAULT_SECONDARY_ROLES = ('ALL'), so your other roles
-- still apply after USE ROLE REPORTER_ROLE. Run USE SECONDARY ROLES NONE first; then raw is
-- denied (verified 26 Oct 2026). Hardened consumer users: ALTER USER ... SET DEFAULT_SECONDARY_ROLES = ().

-- ---------- 3. warehouses per workload + cost guardrail ----------
CREATE WAREHOUSE IF NOT EXISTS LOAD_WH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Ingest (COPY INTO)';
CREATE WAREHOUSE IF NOT EXISTS TRANSFORM_WH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'dbt builds';
CREATE WAREHOUSE IF NOT EXISTS REPORTING_WH
    WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dashboards and ad-hoc queries';

GRANT USAGE ON WAREHOUSE LOAD_WH      TO ROLE LOADER_ROLE;
GRANT USAGE ON WAREHOUSE TRANSFORM_WH TO ROLE DBT_ROLE;
GRANT USAGE ON WAREHOUSE REPORTING_WH TO ROLE REPORTER_ROLE;

CREATE RESOURCE MONITOR IF NOT EXISTS CLIMATE_MONTHLY_QUOTA
    WITH CREDIT_QUOTA = 20
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 75 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;
ALTER WAREHOUSE LOAD_WH      SET RESOURCE_MONITOR = CLIMATE_MONTHLY_QUOTA;
ALTER WAREHOUSE TRANSFORM_WH SET RESOURCE_MONITOR = CLIMATE_MONTHLY_QUOTA;
ALTER WAREHOUSE REPORTING_WH SET RESOURCE_MONITOR = CLIMATE_MONTHLY_QUOTA;
ALTER WAREHOUSE CLIMATE_WH   SET RESOURCE_MONITOR = CLIMATE_MONTHLY_QUOTA;

-- After this: ingest.yml sets env SNOWFLAKE_WAREHOUSE=LOAD_WH (ingest.py reads it),
-- and the dbt Production profile warehouse is TRANSFORM_WH.

-- ---------- cost visibility (run any time) ----------
-- SELECT warehouse_name, DATE(start_time) AS day, SUM(credits_used) AS credits
-- FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
-- WHERE start_time >= DATEADD(day, -14, CURRENT_DATE())
-- GROUP BY 1, 2 ORDER BY 2, 1;
