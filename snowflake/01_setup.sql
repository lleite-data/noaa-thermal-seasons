-- =====================================================================
-- NOAA LCD v2 thermal seasons: Snowflake setup
-- Run once as ACCOUNTADMIN (or a role with CREATE DATABASE / ROLE rights).
-- Creates: warehouse, RAW + ANALYTICS databases, loader role, stage,
-- file format and raw landing tables. dbt (DBT_ROLE) reads RAW and
-- builds into ANALYTICS.
-- =====================================================================
USE ROLE ACCOUNTADMIN;

-- ---------- compute ----------
CREATE WAREHOUSE IF NOT EXISTS CLIMATE_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'NOAA LCD thermal seasons project';

-- ---------- storage ----------
CREATE DATABASE IF NOT EXISTS CLIMATE_RAW       COMMENT = 'Landing zone: files as delivered by NOAA, all text';
CREATE SCHEMA   IF NOT EXISTS CLIMATE_RAW.LCD;
CREATE DATABASE IF NOT EXISTS CLIMATE_ANALYTICS COMMENT = 'dbt-managed models';

-- ---------- roles ----------
-- LOADER_ROLE: used only by ingest.py (write to RAW).
-- DBT_ROLE:    used by dbt Cloud (read RAW, build ANALYTICS).
CREATE ROLE IF NOT EXISTS LOADER_ROLE;
CREATE ROLE IF NOT EXISTS DBT_ROLE;
GRANT ROLE LOADER_ROLE TO ROLE SYSADMIN;
GRANT ROLE DBT_ROLE    TO ROLE SYSADMIN;      -- admins can see dbt-owned objects
-- Replace <YOUR_USER> with the output of: SELECT CURRENT_USER();
-- Keep the double quotes: they preserve the exact case/characters of the name.
GRANT ROLE LOADER_ROLE TO USER "<YOUR_USER>";
GRANT ROLE DBT_ROLE    TO USER "<YOUR_USER>";

GRANT USAGE ON WAREHOUSE CLIMATE_WH TO ROLE LOADER_ROLE;
GRANT USAGE ON WAREHOUSE CLIMATE_WH TO ROLE DBT_ROLE;

GRANT USAGE, CREATE TABLE, CREATE STAGE, CREATE FILE FORMAT
    ON SCHEMA CLIMATE_RAW.LCD TO ROLE LOADER_ROLE;
GRANT USAGE ON DATABASE CLIMATE_RAW TO ROLE LOADER_ROLE;

GRANT USAGE ON DATABASE CLIMATE_RAW     TO ROLE DBT_ROLE;
GRANT USAGE ON SCHEMA   CLIMATE_RAW.LCD TO ROLE DBT_ROLE;
GRANT SELECT ON ALL    TABLES IN SCHEMA CLIMATE_RAW.LCD TO ROLE DBT_ROLE;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CLIMATE_RAW.LCD TO ROLE DBT_ROLE;
GRANT USAGE, CREATE SCHEMA ON DATABASE CLIMATE_ANALYTICS TO ROLE DBT_ROLE;

-- ---------- objects owned by the loader ----------
USE ROLE LOADER_ROLE;
USE WAREHOUSE CLIMATE_WH;
USE SCHEMA CLIMATE_RAW.LCD;

-- Header-aware CSV format: columns are matched BY NAME, so NOAA reordering
-- or adding columns never shifts data into the wrong column.
CREATE FILE FORMAT IF NOT EXISTS LCD_CSV
    TYPE = CSV
    PARSE_HEADER = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE
    TRIM_SPACE = FALSE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- Internal stage. ingest.py PUTs files to @LCD_STAGE/v2/<year>/LCD_<station>_<year>.csv.gz
CREATE STAGE IF NOT EXISTS LCD_STAGE
    FILE_FORMAT = LCD_CSV
    COMMENT = 'NOAA LCD v2 station-year CSVs';

-- Raw observations: every column as VARCHAR (no casting in the landing zone,
-- flags like "23.4s" must survive). Typing happens in dbt staging.
CREATE TABLE IF NOT EXISTS RAW_LCD_OBSERVATIONS (
    STATION                                            VARCHAR,
    DATE                                               VARCHAR,
    LATITUDE                                           VARCHAR,
    LONGITUDE                                          VARCHAR,
    ELEVATION                                          VARCHAR,
    NAME                                               VARCHAR,
    REPORT_TYPE                                        VARCHAR,
    SOURCE                                             VARCHAR,
    HOURLYALTIMETERSETTING                             VARCHAR,
    HOURLYDEWPOINTTEMPERATURE                          VARCHAR,
    HOURLYDRYBULBTEMPERATURE                           VARCHAR,
    HOURLYPRECIPITATION                                VARCHAR,
    HOURLYPRESENTWEATHERTYPE                           VARCHAR,
    HOURLYPRESSURECHANGE                               VARCHAR,
    HOURLYPRESSURETENDENCY                             VARCHAR,
    HOURLYRELATIVEHUMIDITY                             VARCHAR,
    HOURLYSKYCONDITIONS                                VARCHAR,
    HOURLYSEALEVELPRESSURE                             VARCHAR,
    HOURLYSTATIONPRESSURE                              VARCHAR,
    HOURLYVISIBILITY                                   VARCHAR,
    HOURLYWETBULBTEMPERATURE                           VARCHAR,
    HOURLYWINDDIRECTION                                VARCHAR,
    HOURLYWINDGUSTSPEED                                VARCHAR,
    HOURLYWINDSPEED                                    VARCHAR,
    SUNRISE                                            VARCHAR,
    SUNSET                                             VARCHAR,
    DAILYAVERAGEDEWPOINTTEMPERATURE                    VARCHAR,
    DAILYAVERAGEDRYBULBTEMPERATURE                     VARCHAR,
    DAILYAVERAGERELATIVEHUMIDITY                       VARCHAR,
    DAILYAVERAGESEALEVELPRESSURE                       VARCHAR,
    DAILYAVERAGESTATIONPRESSURE                        VARCHAR,
    DAILYAVERAGEWETBULBTEMPERATURE                     VARCHAR,
    DAILYAVERAGEWINDSPEED                              VARCHAR,
    DAILYCOOLINGDEGREEDAYS                             VARCHAR,
    DAILYDEPARTUREFROMNORMALAVERAGETEMPERATURE         VARCHAR,
    DAILYHEATINGDEGREEDAYS                             VARCHAR,
    DAILYMAXIMUMDRYBULBTEMPERATURE                     VARCHAR,
    DAILYMINIMUMDRYBULBTEMPERATURE                     VARCHAR,
    DAILYPEAKWINDDIRECTION                             VARCHAR,
    DAILYPEAKWINDSPEED                                 VARCHAR,
    DAILYPRECIPITATION                                 VARCHAR,
    DAILYSNOWDEPTH                                     VARCHAR,
    DAILYSNOWFALL                                      VARCHAR,
    DAILYSUSTAINEDWINDDIRECTION                        VARCHAR,
    DAILYSUSTAINEDWINDSPEED                            VARCHAR,
    DAILYWEATHER                                       VARCHAR,
    MONTHLYAVERAGERH                                   VARCHAR,
    MONTHLYDAYSWITHGT001PRECIP                         VARCHAR,
    MONTHLYDAYSWITHGT010PRECIP                         VARCHAR,
    MONTHLYDAYSWITHGT32TEMP                            VARCHAR,
    MONTHLYDAYSWITHGT90TEMP                            VARCHAR,
    MONTHLYDAYSWITHLT0TEMP                             VARCHAR,
    MONTHLYDAYSWITHLT32TEMP                            VARCHAR,
    MONTHLYDEPARTUREFROMNORMALAVERAGETEMPERATURE       VARCHAR,
    MONTHLYDEPARTUREFROMNORMALCOOLINGDEGREEDAYS        VARCHAR,
    MONTHLYDEPARTUREFROMNORMALHEATINGDEGREEDAYS        VARCHAR,
    MONTHLYDEPARTUREFROMNORMALMAXIMUMTEMPERATURE       VARCHAR,
    MONTHLYDEPARTUREFROMNORMALMINIMUMTEMPERATURE       VARCHAR,
    MONTHLYDEPARTUREFROMNORMALPRECIPITATION            VARCHAR,
    MONTHLYDEWPOINTTEMPERATURE                         VARCHAR,
    MONTHLYGREATESTPRECIP                              VARCHAR,
    MONTHLYGREATESTPRECIPDATE                          VARCHAR,
    MONTHLYGREATESTSNOWDEPTH                           VARCHAR,
    MONTHLYGREATESTSNOWDEPTHDATE                       VARCHAR,
    MONTHLYGREATESTSNOWFALL                            VARCHAR,
    MONTHLYGREATESTSNOWFALLDATE                        VARCHAR,
    MONTHLYMAXSEALEVELPRESSUREVALUE                    VARCHAR,
    MONTHLYMAXSEALEVELPRESSUREVALUEDATE                VARCHAR,
    MONTHLYMAXSEALEVELPRESSUREVALUETIME                VARCHAR,
    MONTHLYMAXIMUMTEMPERATURE                          VARCHAR,
    MONTHLYMEANTEMPERATURE                             VARCHAR,
    MONTHLYMINSEALEVELPRESSUREVALUE                    VARCHAR,
    MONTHLYMINSEALEVELPRESSUREVALUEDATE                VARCHAR,
    MONTHLYMINSEALEVELPRESSUREVALUETIME                VARCHAR,
    MONTHLYMINIMUMTEMPERATURE                          VARCHAR,
    MONTHLYSEALEVELPRESSURE                            VARCHAR,
    MONTHLYSTATIONPRESSURE                             VARCHAR,
    MONTHLYTOTALLIQUIDPRECIPITATION                    VARCHAR,
    MONTHLYTOTALSNOWFALL                               VARCHAR,
    MONTHLYWETBULB                                     VARCHAR,
    MONTHLYAVERAGEWINDSPEED                            VARCHAR,
    COOLINGDEGREEDAYSSEASONTODATE                      VARCHAR,
    MONTHLYCOOLINGDEGREEDAYS                           VARCHAR,
    MONTHLYNUMBERDAYSWITHSNOWFALL                      VARCHAR,
    HEATINGDEGREEDAYSSEASONTODATE                      VARCHAR,
    MONTHLYHEATINGDEGREEDAYS                           VARCHAR,
    MONTHLYNUMBERDAYSWITHTHUNDERSTORMS                 VARCHAR,
    MONTHLYNUMBERDAYSWITHHEAVYFOG                      VARCHAR,
    NORMALSCOOLINGDEGREEDAY                            VARCHAR,
    NORMALSHEATINGDEGREEDAY                            VARCHAR,
    SHORTDURATIONENDDATE005                            VARCHAR,
    SHORTDURATIONENDDATE010                            VARCHAR,
    SHORTDURATIONENDDATE015                            VARCHAR,
    SHORTDURATIONENDDATE020                            VARCHAR,
    SHORTDURATIONENDDATE030                            VARCHAR,
    SHORTDURATIONENDDATE045                            VARCHAR,
    SHORTDURATIONENDDATE060                            VARCHAR,
    SHORTDURATIONENDDATE080                            VARCHAR,
    SHORTDURATIONENDDATE100                            VARCHAR,
    SHORTDURATIONENDDATE120                            VARCHAR,
    SHORTDURATIONENDDATE150                            VARCHAR,
    SHORTDURATIONENDDATE180                            VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE005                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE010                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE015                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE020                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE030                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE045                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE060                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE080                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE100                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE120                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE150                 VARCHAR,
    SHORTDURATIONPRECIPITATIONVALUE180                 VARCHAR,
    REM                                                VARCHAR,
    BACKUPDIRECTION                                    VARCHAR,
    BACKUPDISTANCE                                     VARCHAR,
    BACKUPDISTANCEUNIT                                 VARCHAR,
    BACKUPELEMENTS                                     VARCHAR,
    BACKUPELEVATION                                    VARCHAR,
    BACKUPEQUIPMENT                                    VARCHAR,
    BACKUPLATITUDE                                     VARCHAR,
    BACKUPLONGITUDE                                    VARCHAR,
    BACKUPNAME                                         VARCHAR,
    WINDEQUIPMENTCHANGEDATE                            VARCHAR,
    _SOURCE_FILE                                       VARCHAR,
    _FILE_ROW_NUMBER                                   NUMBER,
    _LOADED_AT                                         TIMESTAMP_LTZ
)
COMMENT = 'NOAA LCD v2 station-year CSV rows, as delivered (hourly, SOD and SOM rows mixed)';

-- Station metadata parsed from lcdv2-station-list.txt (fixed width) by ingest.py.
CREATE TABLE IF NOT EXISTS RAW_LCD_STATIONS (
    STATION_ID   VARCHAR,
    LATITUDE     VARCHAR,
    LONGITUDE    VARCHAR,
    ELEVATION_M  VARCHAR,
    STATION_NAME VARCHAR,
    WMO_ID       VARCHAR,
    _LOADED_AT   TIMESTAMP_LTZ
)
COMMENT = 'NOAA LCD v2 station list';


-- Schema drift, layer 2 (absorb): new columns in NOAA files are added to the
-- table automatically by COPY (works with MATCH_BY_COLUMN_NAME + PARSE_HEADER).
-- Dropped columns simply load as NULL. The load never breaks on column changes.
ALTER TABLE RAW_LCD_OBSERVATIONS SET ENABLE_SCHEMA_EVOLUTION = TRUE;

-- Change detection: what we saw at NOAA last time, per station-year file.
CREATE TABLE IF NOT EXISTS INGEST_MANIFEST (
    FILE_NAME            VARCHAR,       -- LCD_<station>_<year>.csv
    STATION_ID           VARCHAR,
    YEAR                 NUMBER,
    LAST_STATUS          VARCHAR,       -- new | changed | unchanged | missing
    REMOTE_SIZE          NUMBER,        -- HTTP Content-Length
    REMOTE_LAST_MODIFIED VARCHAR,       -- HTTP Last-Modified
    CONTENT_MD5          VARCHAR,       -- hash of the last downloaded content
    LAST_CHECKED_AT      TIMESTAMP_LTZ,
    LAST_LOADED_AT       TIMESTAMP_LTZ
)
COMMENT = 'One row per source file: last seen state at NOAA, drives incremental downloads';

-- One row per ingest run (also created by ingest.py if missing). Created here too so the
-- alert (04_alerts.sql) and dbt's freshness check can be set up before the first run.
CREATE TABLE IF NOT EXISTS INGEST_RUN_LOG (
    RUN_ID          VARCHAR,
    STARTED_AT      TIMESTAMP_LTZ,
    FINISHED_AT     TIMESTAMP_LTZ,
    TRIGGERED_BY    VARCHAR,
    START_YEAR      NUMBER,
    END_YEAR        NUMBER,
    STATIONS        NUMBER,
    FILES_CHECKED   NUMBER,
    FILES_NEW       NUMBER,
    FILES_CHANGED   NUMBER,
    FILES_UNCHANGED NUMBER,
    FILES_MISSING   NUMBER,
    FILES_ERROR     NUMBER,
    FILES_LOADED    NUMBER,
    ROWS_LOADED     NUMBER,
    COPY_PROBLEMS   NUMBER,
    STATUS          VARCHAR,
    MESSAGE         VARCHAR
)
COMMENT = 'One row per ingest run: what was checked, loaded and whether it succeeded';

-- Schema drift, layer 1 (detect): every header difference is recorded.
CREATE TABLE IF NOT EXISTS SCHEMA_DRIFT_LOG (
    FILE_NAME       VARCHAR,
    DETECTED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    ADDED_COLUMNS   VARIANT,
    REMOVED_COLUMNS VARIANT
)
COMMENT = 'Column differences between incoming NOAA files and RAW_LCD_OBSERVATIONS';

GRANT SELECT ON ALL TABLES IN SCHEMA CLIMATE_RAW.LCD TO ROLE DBT_ROLE;

-- ---------- reference: the load statement ingest.py runs ----------
-- COPY INTO RAW_LCD_OBSERVATIONS
--   FROM @LCD_STAGE/v2/
--   MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
--   INCLUDE_METADATA = (_SOURCE_FILE = METADATA$FILENAME,
--                       _FILE_ROW_NUMBER = METADATA$FILE_ROW_NUMBER,
--                       _LOADED_AT = METADATA$START_SCAN_TIME)
--   ON_ERROR = ABORT_STATEMENT;
-- Snowflake load metadata skips files already loaded, so reruns are safe.

-- ---------- sanity checks after the first load ----------
-- SELECT REPORT_TYPE, COUNT(*) FROM RAW_LCD_OBSERVATIONS GROUP BY 1;
-- SELECT STATION, LEFT(DATE,4) yr, COUNT_IF(REPORT_TYPE='SOD') days
--   FROM RAW_LCD_OBSERVATIONS GROUP BY 1,2 ORDER BY 1,2;
