-- Accuracy of rebuilding a day's average temperature from hourly readings
-- (docs/methodology.md section 6). On days that have BOTH an official daily average
-- and enough hourly readings, compare the official value with:
--   (a) the method used:   (hourly max + hourly min) / 2
--   (b) the alternative:   plain average of the hourly readings
-- One row per station plus an 'ALL' row. The dbt test assert_hourly_derivation_accuracy
-- re-checks (a) on every build.
with hourly_avg as (

    select station_id, observation_date, avg(temp_c) as hourly_avg_c
    from {{ ref('stg_lcd__hourly_temperatures') }}
    where temp_c is not null and not is_temp_suspect and not is_temp_erroneous
    group by station_id, observation_date

),

paired as (

    select
        d.station_id,
        d.derived_mean_c - o.temp_mean_c   as diff_method_c,
        h.hourly_avg_c - o.temp_mean_c     as diff_hourly_avg_c
    from {{ ref('int_daily_temps_from_hourly') }} as d
    inner join {{ ref('stg_lcd__daily_observations') }} as o
        on d.station_id = o.station_id and d.observation_date = o.observation_date
    inner join hourly_avg as h
        on d.station_id = h.station_id and d.observation_date = h.observation_date
    where d.meets_coverage
      and o.temp_mean_c is not null
      and not o.is_temp_suspect
      and not o.is_temp_erroneous

)

select
    iff(grouping(station_id) = 1, 'ALL', station_id)                     as station,
    count(*)                                                             as paired_days,
    round(avg(diff_method_c), 2)                                         as bias_method_c,
    round(avg(abs(diff_method_c)), 2)                                    as mae_method_c,
    round(count_if(abs(diff_method_c) <= 1.0) / count(*), 3)             as share_within_1c_method,
    round(avg(diff_hourly_avg_c), 2)                                     as bias_hourly_avg_c,
    round(avg(abs(diff_hourly_avg_c)), 2)                                as mae_hourly_avg_c
from paired
group by rollup (station_id)
order by station = 'ALL', station
