select
    o.station_id,
    s.station_label,
    s.climate_region,
    o.season,
    o.season_order,
    o.season_year,
    -- human-readable: winter spans two calendar years, e.g. "winter 2026/27"
    iff(o.season = 'winter',
        'winter ' || (o.season_year - 1) || '/' || right(o.season_year::varchar, 2),
        o.season || ' ' || o.season_year)       as season_label,
    o.onset_status,
    o.onset_date,
    o.onset_day_index,
    dayofyear(o.onset_date)                 as onset_day_of_year,
    o.window_start,
    o.window_end,
    o.window_coverage,
    s.has_thermal_seasons
from {{ ref('int_season_onsets') }} as o
inner join {{ ref('dim_station') }} as s
    on o.station_id = s.station_id
