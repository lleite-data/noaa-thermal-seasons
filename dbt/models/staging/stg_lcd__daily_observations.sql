{#
  Daily grain: one row per station per day.
  - Keeps only daily summary rows (REPORT_TYPE = 'SOD'). Hourly and monthly rows
    stay in raw. REPORT_TYPE values for hourly rows differ between years
    (FM-15/FM-16/... in 2006, blank in 2026), SOD is stable across all years.
  - Extracts flags before casting (see macros/lcd_parsing.sql).
  - Deduplicates: a reloaded file (NOAA revision) adds new row versions to raw;
    the latest load wins.
  - Incremental: only rows loaded since the last run are processed and merged
    on (station_id, observation_date). Correct here because nothing in this
    model depends on other rows (no windows across days).
#}
{{
    config(
        materialized='incremental',
        unique_key=['station_id', 'observation_date'],
        incremental_strategy='merge',
        on_schema_change='append_new_columns'
    )
}}

with source as (

    select *
    from {{ source('lcd', 'raw_lcd_observations') }}
    where report_type = 'SOD'
    {% if is_incremental() %}
      and _loaded_at > (select coalesce(max(_loaded_at), '1900-01-01'::timestamp_ltz) from {{ this }})
    {% endif %}

),

latest as (

    select *
    from source
    qualify row_number() over (
        partition by station, left(date, 10)
        order by _loaded_at desc, _file_row_number desc
    ) = 1

)

select
    station                                                        as station_id,
    try_to_date(left(date, 10))                                    as observation_date,
    name                                                           as station_name_raw,
    try_to_double(latitude)                                        as latitude,
    try_to_double(longitude)                                       as longitude,
    try_to_double(elevation)                                       as elevation_m,

    -- temperatures (deg C)
    {{ lcd_number('dailyaveragedrybulbtemperature') }}             as temp_mean_c,
    {{ lcd_number('dailymaximumdrybulbtemperature') }}             as temp_max_c,
    {{ lcd_number('dailyminimumdrybulbtemperature') }}             as temp_min_c,
    {{ lcd_number('dailydeparturefromnormalaveragetemperature') }} as noaa_departure_from_normal_c,

    -- precipitation (mm); trace = measurable-but-tiny, stored as 0 with a flag
    iff({{ lcd_is_trace('dailyprecipitation') }}, 0,
        {{ lcd_number('dailyprecipitation') }})                    as precip_mm,
    iff({{ lcd_is_trace('dailysnowfall') }}, 0,
        {{ lcd_number('dailysnowfall') }})                         as snowfall_mm,
    {{ lcd_number('dailyheatingdegreedays') }}                     as heating_degree_days,
    {{ lcd_number('dailycoolingdegreedays') }}                     as cooling_degree_days,

    -- quality flags
    {{ lcd_is_trace('dailyprecipitation') }}                       as is_precip_trace,
    {{ lcd_is_suspect('dailyaveragedrybulbtemperature') }}
      or {{ lcd_is_suspect('dailymaximumdrybulbtemperature') }}
      or {{ lcd_is_suspect('dailyminimumdrybulbtemperature') }}    as is_temp_suspect,
    {{ lcd_is_erroneous('dailyaveragedrybulbtemperature') }}
      or {{ lcd_is_erroneous('dailymaximumdrybulbtemperature') }}
      or {{ lcd_is_erroneous('dailyminimumdrybulbtemperature') }}  as is_temp_erroneous,

    _source_file,
    _loaded_at

from latest
where try_to_date(left(date, 10)) >= '{{ var("analysis_start_date") }}'::date
