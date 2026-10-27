{#
  Daily temperatures rebuilt from hourly readings, one row per station per day.
  derived_mean_c = (hourly max + hourly min) / 2, matching NOAA's daily-average
  convention. Validated against ~90k days that have both an official daily summary
  and hourly data: bias -0.07 C, mean absolute error 0.24 C, 99.2% within 1 C
  (the plain average of hourly readings was ~3x worse: MAE 0.66 C).
  Hourly readings miss short peaks, so derived max reads ~0.4 C low and derived min
  ~0.3 C high: fine for season onsets (7-day means), not used for records.
  meets_coverage: enough distinct hours with a reading for the day to be trusted.
  The accuracy is re-checked on every build by tests/assert_hourly_derivation_accuracy.sql.
#}
select
    h.station_id,
    h.observation_date,
    count(distinct h.observation_hour)                             as hours_covered,
    count(*)                                                       as readings,
    max(h.temp_c)                                                  as hourly_max_c,
    min(h.temp_c)                                                  as hourly_min_c,
    (max(h.temp_c) + min(h.temp_c)) / 2                            as derived_mean_c,
    count(distinct h.observation_hour) >= {{ var('min_hourly_coverage_hours') }}
                                                                   as meets_coverage
from {{ ref('stg_lcd__hourly_temperatures') }} as h
inner join {{ ref('stations_of_interest') }} as s
    on h.station_id = s.station_id
where h.temp_c is not null
  and not h.is_temp_suspect
  and not h.is_temp_erroneous
group by h.station_id, h.observation_date
