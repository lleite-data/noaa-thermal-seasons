{#
  Hourly (and sub-hourly) temperature readings: one row per raw observation row.
  Used to rebuild daily temperatures where NOAA's daily summary is blank or missing
  (e.g. Denver 2013: daily summaries blank Apr-Dec and absent in October, while the
  hourly sensor kept reporting).
  - Hourly rows are every row that is NOT a daily (SOD) or monthly (SOM) summary:
    their REPORT_TYPE changed over time (FM-15/FM-16/FM-12/SY-MT in 2006, blank in 2026).
  - Blank fields arrive as '' (NOAA quotes every field), handled by lcd_number.
  - File reloads: only rows from the latest load of each source file are kept.
#}
with source as (

    select *
    from {{ source('lcd', 'raw_lcd_observations') }}
    where coalesce(report_type, '') not in ('SOD', 'SOM')
      and try_to_date(left(date, 10)) >= '{{ var("analysis_start_date") }}'::date
      and nullif(trim(hourlydrybulbtemperature), '') is not null

),

latest_file_version as (

    select *
    from source
    qualify _loaded_at = max(_loaded_at) over (partition by _source_file)

)

select
    station                                                   as station_id,
    try_to_timestamp_ntz(date)                                as observed_at_lst,
    try_to_date(left(date, 10))                               as observation_date,
    try_to_number(substr(date, 12, 2))                        as observation_hour,
    coalesce(report_type, '')                                 as report_type,
    {{ lcd_number('hourlydrybulbtemperature') }}              as temp_c,
    {{ lcd_is_suspect('hourlydrybulbtemperature') }}          as is_temp_suspect,
    {{ lcd_is_erroneous('hourlydrybulbtemperature') }}        as is_temp_erroneous,
    _source_file,
    _loaded_at
from latest_file_version
