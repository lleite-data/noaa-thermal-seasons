{#
  Ingest run history for consumers (dashboard pipeline-health panel).
  A view on purpose: it must show the latest run live, not as of the last dbt build.
  Consumers (REPORTER_ROLE) read MARTS only, so this exposes the run log without
  granting access to the raw database.
#}
{{ config(materialized='view') }}

select
    run_id,
    started_at,
    finished_at,
    datediff(second, started_at, finished_at)   as duration_seconds,
    triggered_by,
    start_year,
    end_year,
    stations,
    files_checked,
    files_new,
    files_changed,
    files_unchanged,
    files_missing,
    files_error,
    files_loaded,
    rows_loaded,
    copy_problems,
    status,
    message
from {{ source('lcd', 'ingest_run_log') }}
