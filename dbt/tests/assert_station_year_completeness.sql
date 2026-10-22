-- Each analysed station should report (almost) every day of every complete year.
-- Skips the station's first year (may start mid-year) and the current year.
-- Warn, not error: gaps are handled downstream, but they should be visible.
{{ config(severity='warn') }}

with per_year as (

    select o.station_id, year(o.observation_date) as obs_year, count(*) as days_reported
    from {{ ref('stg_lcd__daily_observations') }} as o
    inner join {{ ref('stations_of_interest') }} as s on o.station_id = s.station_id
    group by 1, 2

),

first_year as (

    select station_id, min(obs_year) as first_obs_year
    from per_year
    group by 1

)

select p.station_id, p.obs_year, p.days_reported
from per_year as p
inner join first_year as f on p.station_id = f.station_id
where p.obs_year > f.first_obs_year
  and p.obs_year < year(current_date())
  and p.days_reported < {{ var('min_days_per_year', 360) }}
