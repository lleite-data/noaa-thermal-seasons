-- Alarm (warn): NOAA flagged a value, or a value is physically impossible.
-- Such days are already kept out of the analysis (int_station_daily_series), so the
-- build continues, but it turns yellow so someone looks at the source.
-- Review candidates (STUCK_SENSOR, SUSPICIOUS_JUMP) are deliberately not part of this alarm.
{{ config(severity='warn') }}

select station_id, observation_date, outlier_type, value_c
from {{ ref('fct_weather_outliers') }}
where outlier_type in (
    'SENSOR_FLAG_SUSPECT', 'SENSOR_FLAG_ERRONEOUS',
    'PHYSICAL_INCONSISTENT', 'PHYSICAL_OUT_OF_RANGE'
)
