with daily as (

    select
        station_id,
        min(calendar_date)                         as first_observation_date,
        max(calendar_date)                         as last_observation_date,
        count_if(is_observed)                      as observed_days,
        count(*)                                   as calendar_days
    from {{ ref('int_station_daily_series') }}
    group by station_id

)

select
    s.station_id,
    s.station_label,
    s.climate_region,
    st.station_name,
    st.wmo_id,
    st.country_code,
    st.latitude,
    st.longitude,
    st.elevation_m,
    t.hemisphere,
    d.first_observation_date,
    d.last_observation_date,
    d.observed_days,
    d.observed_days / nullif(d.calendar_days, 0) as observed_day_coverage,
    t.lower_threshold_c,
    t.upper_threshold_c,
    t.annual_range_c,
    t.has_thermal_seasons
from {{ ref('stations_of_interest') }} as s
left join {{ ref('stg_lcd__stations') }} as st
    on s.station_id = st.station_id
left join daily as d
    on s.station_id = d.station_id
left join {{ ref('int_station_thresholds') }} as t
    on s.station_id = t.station_id
