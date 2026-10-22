{#
  Daily weather per station with anomaly vs the station's normal for that day of year.
  Full refresh by design: the z-score depends on station-wide statistics, so an
  incremental merge could leave stale values. At ~90k rows a rebuild is seconds.
  Incremental processing happens upstream, in staging, where it is correct.
#}
select
    d.station_id,
    d.calendar_date                                         as observation_date,
    d.calendar_year                                         as observation_year,
    d.day_of_year,
    d.temp_mean_c,
    d.temp_max_c,
    d.temp_min_c,
    d.temp_rolling_mean_c,
    o.precip_mm,
    o.snowfall_mm,
    o.is_precip_trace,
    o.noaa_departure_from_normal_c,
    c.normal_mean_c,
    c.normal_stddev_c,
    d.temp_mean_clean_c - c.normal_mean_c                   as temp_anomaly_c,
    (d.temp_mean_clean_c - c.normal_mean_c) / nullif(c.normal_stddev_c, 0)
                                                            as temp_anomaly_z,
    d.is_temp_suspect,
    d.is_temp_erroneous
from {{ ref('int_station_daily_series') }} as d
inner join {{ ref('stg_lcd__daily_observations') }} as o
    on d.station_id = o.station_id
   and d.calendar_date = o.observation_date
left join {{ ref('int_station_day_climatology') }} as c
    on d.station_id = c.station_id
   and d.day_of_year = c.day_of_year
