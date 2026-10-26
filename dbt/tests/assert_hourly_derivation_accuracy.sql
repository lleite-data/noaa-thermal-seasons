-- The hourly fallback is only trustworthy while it matches NOAA's own daily values.
-- On every build, compare rebuilt vs official means on days that have both, and
-- fail if the bias or the mean absolute error drifts above the agreed limits
-- (validated at bias -0.07 C, MAE 0.24 C on ~90k days).
with paired as (

    select d.derived_mean_c - o.temp_mean_c as diff_c
    from {{ ref('int_daily_temps_from_hourly') }} as d
    inner join {{ ref('stg_lcd__daily_observations') }} as o
        on d.station_id = o.station_id
       and d.observation_date = o.observation_date
    where d.meets_coverage
      and o.temp_mean_c is not null
      and not o.is_temp_suspect
      and not o.is_temp_erroneous

),

stats as (

    select count(*) as paired_days, avg(diff_c) as bias_c, avg(abs(diff_c)) as mae_c
    from paired

)

select *
from stats
where abs(bias_c) > {{ var('max_derivation_bias_c') }}
   or mae_c > {{ var('max_derivation_mae_c') }}
   or paired_days = 0
