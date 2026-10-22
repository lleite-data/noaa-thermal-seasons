{#
  Two families of outliers, kept apart on purpose:

  DATA QUALITY (the measurement is doubtful)
    SENSOR_FLAG_SUSPECT    NOAA flagged a temperature "s"
    SENSOR_FLAG_ERRONEOUS  NOAA flagged a temperature "*"
    PHYSICAL_INCONSISTENT  max < min, or mean outside [min, max] (0.5 C tolerance)
    PHYSICAL_OUT_OF_RANGE  outside -70 .. 60 C

  CLIMATE (the measurement is fine, the weather was extreme)
    CLIMATE_ANOMALY_HIGH/LOW  |z| >= z_score_threshold vs the day-of-year normal
    RECORD_HIGH / RECORD_LOW  highest max / lowest min in the station's record
  Climate outliers use only values without quality problems.
#}
with daily as (

    select * from {{ ref('fct_daily_weather') }}

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
    where temp_max_c < temp_min_c
       or temp_mean_c not between temp_min_c - 0.5 and temp_max_c + 0.5

    union all
    select station_id, observation_date, 'DATA_QUALITY', 'PHYSICAL_OUT_OF_RANGE', temp_mean_c, null
    from daily
    where temp_mean_c not between -70 and 60
       or temp_max_c  not between -70 and 60
       or temp_min_c  not between -70 and 60

),

bad_days as (

    select distinct station_id, observation_date from quality

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
        qualify rank() over (partition by station_id order by temp_max_c desc nulls last) = 1
    )

    union all
    select * from (
        select station_id, observation_date, 'CLIMATE', 'RECORD_LOW', temp_min_c, temp_anomaly_z
        from clean
        qualify rank() over (partition by station_id order by temp_min_c asc nulls last) = 1
    )

)

select * from quality
union all
select * from climate
