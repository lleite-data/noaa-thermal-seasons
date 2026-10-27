-- Guard (error): every day reported as a definite quality problem must have NO value
-- in the analysis series. Fails if the reporting rules and the cleaning rules ever drift
-- apart (both come from macros/quality_rules.sql and the NOAA flags).
select o.station_id, o.observation_date, o.outlier_type, s.temp_mean_clean_c
from {{ ref('fct_weather_outliers') }} as o
inner join {{ ref('int_station_daily_series') }} as s
    on o.station_id = s.station_id
   and o.observation_date = s.calendar_date
where o.outlier_type in (
    'SENSOR_FLAG_SUSPECT', 'SENSOR_FLAG_ERRONEOUS',
    'PHYSICAL_INCONSISTENT', 'PHYSICAL_OUT_OF_RANGE'
)
  and s.temp_mean_clean_c is not null
