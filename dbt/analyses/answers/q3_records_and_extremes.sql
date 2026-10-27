-- Q3: record high / low per station (official daily values, period loaded) and the
-- most unusual days overall (largest |z| vs the day-of-year normal).
select 'record' as kind, s.station_label, o.outlier_type, o.observation_date,
       round(o.value_c, 1) as value_c, round(o.z_score, 1) as z_score
from {{ ref('fct_weather_outliers') }} as o
join {{ ref('dim_station') }} as s using (station_id)
where o.outlier_type in ('RECORD_HIGH', 'RECORD_LOW')
union all
select * from (
    select 'extreme', s.station_label, o.outlier_type, o.observation_date,
           round(o.value_c, 1), round(o.z_score, 1)
    from {{ ref('fct_weather_outliers') }} as o
    join {{ ref('dim_station') }} as s using (station_id)
    where o.outlier_family = 'CLIMATE' and o.z_score is not null
    order by abs(o.z_score) desc
    limit 15
)
order by kind desc, station_label, outlier_type
