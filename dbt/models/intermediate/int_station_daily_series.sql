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
  Fallback: when NOAA's daily summary has no temperature (blank or missing row),
  the day is rebuilt from hourly readings if enough hours were covered
  (int_daily_temps_from_hourly). temp_source says which one was used.
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

from_hourly as (

    select *
    from {{ ref('int_daily_temps_from_hourly') }}
    where meets_coverage

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
        -- official daily summary first; hourly rebuild only where it has no temperature
        o.temp_mean_c is null and h.station_id is not null            as use_hourly,
        o.observation_date is not null or use_hourly                  as is_observed,
        case
            when o.temp_mean_c is not null then 'daily_summary'
            when use_hourly                then 'derived_from_hourly'
        end                                                           as temp_source,
        iff(use_hourly, h.derived_mean_c, o.temp_mean_c)              as temp_mean_c,
        iff(use_hourly, h.hourly_max_c,   o.temp_max_c)               as temp_max_c,
        iff(use_hourly, h.hourly_min_c,   o.temp_min_c)               as temp_min_c,
        coalesce(o.is_temp_suspect, false)                            as is_temp_suspect,
        coalesce(o.is_temp_erroneous, false)                          as is_temp_erroneous
    from calendar as c
    left join observations as o
        on c.station_id = o.station_id
       and c.calendar_date = o.observation_date
    left join from_hourly as h
        on c.station_id = h.station_id
       and c.calendar_date = h.observation_date

),

checked as (

    -- separate step so the rules read the final values (official or hourly-rebuilt)
    select
        *,
        {{ is_physically_inconsistent('temp_mean_c', 'temp_max_c', 'temp_min_c') }}
            or {{ is_physically_out_of_range('temp_mean_c', 'temp_max_c', 'temp_min_c') }}
                                                                      as is_physically_invalid,
        -- analysis value: NOAA-flagged and physically impossible values never reach the
        -- season, threshold, climatology or outlier logic (same rules as fct_weather_outliers)
        iff(is_temp_suspect or is_temp_erroneous or is_physically_invalid,
            null,
            temp_mean_c)                                              as temp_mean_clean_c
    from joined

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
    from checked

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
    temp_source,
    temp_mean_c,
    temp_max_c,
    temp_min_c,
    temp_mean_clean_c,
    is_temp_suspect,
    is_temp_erroneous,
    is_physically_invalid,
    rolling_obs_count,
    iff(rolling_obs_count >= {{ var('min_rolling_obs') }}, rolling_avg_raw, null)
                                                                  as temp_rolling_mean_c
from windowed
