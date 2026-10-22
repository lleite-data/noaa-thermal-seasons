{#
  Station-relative season thresholds from a FIXED baseline period, so that
  loading new years never changes the thresholds (or past onsets).
  - lower / upper threshold: percentiles of the station's daily mean temperature
  - annual range: warmest minus coldest average month; stations below
    min_annual_range_c (tropics) have no meaningful thermal seasons.
#}
with baseline as (

    select *
    from {{ ref('int_station_daily_series') }}
    where calendar_year between {{ var('baseline_start_year') }} and {{ var('baseline_end_year') }}
      and temp_mean_clean_c is not null

),

percentiles as (

    select
        station_id,
        any_value(hemisphere)                                                    as hemisphere,
        count(*)                                                                 as baseline_days,
        min(calendar_year)                                                       as baseline_first_year,
        max(calendar_year)                                                       as baseline_last_year,
        percentile_cont({{ var('lower_threshold_pct') }}) within group (order by temp_mean_clean_c) as lower_threshold_c,
        percentile_cont({{ var('upper_threshold_pct') }}) within group (order by temp_mean_clean_c) as upper_threshold_c
    from baseline
    group by station_id

),

monthly as (

    select
        station_id,
        month(calendar_date)     as month_of_year,
        avg(temp_mean_clean_c)   as month_mean_c
    from baseline
    group by station_id, month_of_year

),

annual_range as (

    select
        station_id,
        max(month_mean_c) - min(month_mean_c) as annual_range_c
    from monthly
    group by station_id

)

select
    p.station_id,
    p.hemisphere,
    p.baseline_days,
    p.baseline_first_year,
    p.baseline_last_year,
    p.lower_threshold_c,
    p.upper_threshold_c,
    a.annual_range_c,
    a.annual_range_c >= {{ var('min_annual_range_c') }} as has_thermal_seasons
from percentiles as p
inner join annual_range as a
    on p.station_id = a.station_id
