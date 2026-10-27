-- Every analysed station must still be publishing. Catches a station NOAA stops
-- updating even when every ingest run succeeds. NOAA publishes with a few days'
-- lag, so the tolerance is max_station_lag_days.
{{ config(severity='warn') }}

select s.station_id, max(o.observation_date) as last_observation_date
from {{ ref('stations_of_interest') }} as s
left join {{ ref('stg_lcd__daily_observations') }} as o on s.station_id = o.station_id
group by s.station_id
having max(o.observation_date) is null
    or max(o.observation_date) < dateadd(day, -{{ var('max_station_lag_days', 14) }}, current_date())
