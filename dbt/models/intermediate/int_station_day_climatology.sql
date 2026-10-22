{#
  "Normal" temperature for each station and day of year, from the fixed baseline:
  mean and standard deviation of all baseline days within +/- climatology_window_days
  of that day of year (circular, so late December and early January are neighbours).
  Used for anomaly z-scores. A per-month normal would be too coarse: temperatures
  move several degrees within a month, inflating anomalies at month edges.
#}
with baseline as (

    select station_id, day_of_year, temp_mean_clean_c
    from {{ ref('int_station_daily_series') }}
    where calendar_year between {{ var('baseline_start_year') }} and {{ var('baseline_end_year') }}
      and temp_mean_clean_c is not null

),

target_days as (

    select row_number() over (order by seq4()) as day_of_year
    from table(generator(rowcount => 366))

)

select
    b.station_id,
    t.day_of_year,
    count(*)                         as sample_days,
    avg(b.temp_mean_clean_c)         as normal_mean_c,
    stddev_samp(b.temp_mean_clean_c) as normal_stddev_c
from target_days as t
inner join baseline as b
    on least(abs(b.day_of_year - t.day_of_year), 366 - abs(b.day_of_year - t.day_of_year))
       <= {{ var('climatology_window_days') }}
group by b.station_id, t.day_of_year
