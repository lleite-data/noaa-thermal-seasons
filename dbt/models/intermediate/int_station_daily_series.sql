{#
  One row per station per CALENDAR day (gap-aware), from the station's first to
  last observation. Missing days exist as rows with NULL temperatures, so window
  functions count days, not rows:
    - a 7-day rolling mean really covers 7 calendar days
    - a 5-day persistence check really covers 5 consecutive days
  The rolling mean is only computed when at least min_rolling_obs of the window's
  days were observed; otherwise it is NULL (and breaks any streak).
  Southern Hemisphere stations get a season_calendar_date shifted by 182 days so
  that the same season windows apply in both hemispheres.
#}
with observations as (

    select
        o.station_id,
        o.observation_date,
        o.latitude,
        o.temp_mean_c,
        o.temp_max_c,
        o.temp_min_c,
        o.is_temp_suspect,
        o.is_temp_erroneous
    from {{ ref('stg_lcd__daily_observations') }} as o
    inner join {{ ref('stations_of_interest') }} as s
        on o.station_id = s.station_id

),

station_ranges as (

    select
        station_id,
        min(observation_date) as first_date,
        max(observation_date) as last_date,
        avg(latitude)         as latitude
    from observations
    group by station_id

),

spine as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="'" ~ var('analysis_start_date') ~ "'::date",
        end_date="dateadd(day, 1, current_date())"
    ) }}

),

calendar as (

    select
        r.station_id,
        r.latitude,
        sp.date_day::date as calendar_date
    from station_ranges as r
    inner join spine as sp
        on sp.date_day between r.first_date and r.last_date

),

joined as (

    select
        c.station_id,
        c.calendar_date,
        c.latitude,
        o.observation_date is not null                            as is_observed,
        o.temp_mean_c,
        o.temp_max_c,
        o.temp_min_c,
        coalesce(o.is_temp_suspect, false)                        as is_temp_suspect,
        coalesce(o.is_temp_erroneous, false)                      as is_temp_erroneous,
        -- analysis value: flagged values are excluded from season/outlier logic
        iff(coalesce(o.is_temp_suspect, false) or coalesce(o.is_temp_erroneous, false),
            null, o.temp_mean_c)                                  as temp_mean_clean_c
    from calendar as c
    left join observations as o
        on c.station_id = o.station_id
       and c.calendar_date = o.observation_date

),

windowed as (

    select
        *,
        count(temp_mean_clean_c) over (
            partition by station_id order by calendar_date
            rows between {{ var('rolling_window_days') - 1 }} preceding and current row
        ) as rolling_obs_count,
        avg(temp_mean_clean_c) over (
            partition by station_id order by calendar_date
            rows between {{ var('rolling_window_days') - 1 }} preceding and current row
        ) as rolling_avg_raw
    from joined

)

select
    station_id,
    calendar_date,
    year(calendar_date)                                           as calendar_year,
    dayofyear(calendar_date)                                      as day_of_year,
    latitude,
    iff(latitude < 0, 'southern', 'northern')                     as hemisphere,
    iff(latitude < 0, dateadd(day, 182, calendar_date), calendar_date)
                                                                  as season_calendar_date,
    is_observed,
    temp_mean_c,
    temp_max_c,
    temp_min_c,
    temp_mean_clean_c,
    is_temp_suspect,
    is_temp_erroneous,
    rolling_obs_count,
    iff(rolling_obs_count >= {{ var('min_rolling_obs') }}, rolling_avg_raw, null)
                                                                  as temp_rolling_mean_c
from windowed
