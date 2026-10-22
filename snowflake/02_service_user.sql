-- =====================================================================
-- Service user for scheduled ingest (GitHub Actions).
-- TYPE = SERVICE: no password, no MFA prompts, key-pair auth only.
-- Snowflake is phasing out password-only logins, and CI cannot answer MFA.
-- =====================================================================
-- 1) Generate a key pair locally (Git Bash / WSL / macOS):
--      openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out snowflake_key.p8 -nocrypt
--      openssl rsa -in snowflake_key.p8 -pubout -out snowflake_key.pub
--    Paste the public key body (without the BEGIN/END lines) below.
-- 2) Add GitHub repo secrets:
--      SNOWFLAKE_ACCOUNT     = your account identifier
--      SNOWFLAKE_USER        = INGEST_SVC
--      SNOWFLAKE_PRIVATE_KEY = full contents of snowflake_key.p8
--    Never commit the .p8 file.
USE ROLE ACCOUNTADMIN;

CREATE USER IF NOT EXISTS INGEST_SVC
    TYPE = SERVICE
    DEFAULT_ROLE = LOADER_ROLE
    DEFAULT_WAREHOUSE = CLIMATE_WH
    DEFAULT_NAMESPACE = CLIMATE_RAW.LCD
    COMMENT = 'GitHub Actions: scheduled NOAA LCD ingest';

ALTER USER INGEST_SVC SET RSA_PUBLIC_KEY = '<paste public key body here>';

GRANT ROLE LOADER_ROLE TO USER INGEST_SVC;

-- Check: DESC USER INGEST_SVC;  (RSA_PUBLIC_KEY_FP should be populated)
