{#
  Two families of outliers, kept apart on purpose:

  DATA QUALITY (the measurement is doubtful)
    SENSOR_FLAG_SUSPECT    NOAA flagged a temperature "s"
    SENSOR_FLAG_ERRONEOUS  NOAA flagged a temperature "*"
    PHYSICAL_INCONSISTENT  max < min, or mean outside [min, max] (0.5 C tolerance)
    PHYSICAL_OUT_OF_RANGE  outside -70 .. 60 C
  (both rules live in macros/quality_rules.sql and also keep such values out of the
   analysis: int_station_daily_series.temp_mean_clean_c)
    STUCK_SENSOR           daily mean, max AND min all unchanged for stuck_sensor_days
                           consecutive days. Mean alone is not enough: LCD values derive
                           from whole degrees F, so in stable weather the same mean can
                           repeat for days while max/min still move (seen in Miami, Dallas)
    SUSPICIOUS_JUMP        daily mean changes more than max_daily_jump_c vs the day before
  STUCK_SENSOR and SUSPICIOUS_JUMP are review candidates, not proof of error
  (verify against the hourly observations kept in raw).

  CLIMATE (the measurement is fine, the weather was extreme)
    CLIMATE_ANOMALY_HIGH/LOW  |z| >= z_score_threshold vs the day-of-year normal
    RECORD_HIGH / RECORD_LOW  highest max / lowest min in the station's record
  Climate outliers use only values without quality problems.
#}
with daily as (

    select * from {{ ref('fct_daily_weather') }}

),

sequenced as (

    -- previous days' values, only when the days are truly consecutive
    select
        *,
        lag(observation_date, {{ var('stuck_sensor_days') - 1 }})
            over (partition by station_id order by observation_date)        as run_start_date,
        -- identical over the run <=> min = max (COUNT DISTINCT is not allowed with a window frame)
        min(temp_mean_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        )                                                                     as run_min_c,
        max(temp_mean_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        )                                                                     as run_max_c,
        count(temp_mean_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        )                                                                     as run_values,
        -- max and min must be frozen too for a real stuck sensor
        max(temp_max_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        ) - min(temp_max_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        )                                                                     as run_max_spread_c,
        max(temp_min_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        ) - min(temp_min_c) over (
            partition by station_id order by observation_date
            rows between {{ var('stuck_sensor_days') - 1 }} preceding and current row
        )                                                                     as run_min_spread_c,
        lag(temp_mean_c) over (partition by station_id order by observation_date)
                                                                              as prev_temp_mean_c,
        lag(observation_date) over (partition by station_id order by observation_date)
                                                                              as prev_date
    from daily

),

quality as (

    select station_id, observation_date, 'DATA_QUALITY' as outlier_family,
           'SENSOR_FLAG_SUSPECT' as outlier_type, temp_mean_c as value_c, null::float as z_score
    from daily where is_temp_suspect

    union all
    select station_id, observation_date, 'DATA_QUALITY', 'SENSOR_FLAG_ERRONEOUS', temp_mean_c, null
    from daily where is_temp_erroneous

    union all
    select station_id, observation_date, 'DATA_QUALITY', 'PHYSICAL_INCONSISTENT', temp_mean_c, null
    from daily
    where {{ is_physically_inconsistent('temp_mean_c', 'temp_max_c', 'temp_min_c') }}

    union all
    select station_id, observation_date, 'DATA_QUALITY', 'PHYSICAL_OUT_OF_RANGE', temp_mean_c, null
    from daily
    where {{ is_physically_out_of_range('temp_mean_c', 'temp_max_c', 'temp_min_c') }}

    union all
    select station_id, observation_date, 'DATA_QUALITY', 'STUCK_SENSOR', temp_mean_c, null
    from sequenced
    where run_values = {{ var('stuck_sensor_days') }}
      and run_min_c = run_max_c
      and run_max_spread_c = 0
      and run_min_spread_c = 0
      and datediff(day, run_start_date, observation_date) = {{ var('stuck_sensor_days') - 1 }}

    union all
    select station_id, observation_date, 'DATA_QUALITY', 'SUSPICIOUS_JUMP', temp_mean_c, null
    from sequenced
    where datediff(day, prev_date, observation_date) = 1
      and abs(temp_mean_c - prev_temp_mean_c) > {{ var('max_daily_jump_c') }}

),

bad_days as (

    -- days excluded from climate outliers: definite quality problems only
    -- (NOAA flags, physically impossible values). STUCK_SENSOR and SUSPICIOUS_JUMP
    -- are review candidates: on this dataset every one was checked against the
    -- hourly observations and turned out to be real weather (stable Miami spring,
    -- a Denver cold front, the Bismarck rebound after a record low), so they stay in the climate analysis.
    select distinct station_id, observation_date
    from quality
    where outlier_type not in ('STUCK_SENSOR', 'SUSPICIOUS_JUMP')

),

clean as (

    select d.*
    from daily as d
    left join bad_days as b
        on d.station_id = b.station_id and d.observation_date = b.observation_date
    where b.station_id is null

),

climate as (

    select station_id, observation_date, 'CLIMATE' as outlier_family,
           iff(temp_anomaly_z > 0, 'CLIMATE_ANOMALY_HIGH', 'CLIMATE_ANOMALY_LOW') as outlier_type,
           temp_mean_c as value_c, temp_anomaly_z as z_score
    from clean
    where abs(temp_anomaly_z) >= {{ var('z_score_threshold') }}

    union all
    select * from (
        select station_id, observation_date, 'CLIMATE', 'RECORD_HIGH', temp_max_c, temp_anomaly_z
        from clean
        where temp_source = 'daily_summary'   -- hourly-derived max reads low: never a record
        qualify rank() over (partition by station_id order by temp_max_c desc nulls last) = 1
    )

    union all
    select * from (
        select station_id, observation_date, 'CLIMATE', 'RECORD_LOW', temp_min_c, temp_anomaly_z
        from clean
        where temp_source = 'daily_summary'   -- hourly-derived min reads high: never a record
        qualify rank() over (partition by station_id order by temp_min_c asc nulls last) = 1
    )

)

select * from quality
union all
select * from climate
