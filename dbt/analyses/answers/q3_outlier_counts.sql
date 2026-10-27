-- Q3: outlier counts by family and type, overall and per station.
select o.outlier_family, o.outlier_type, s.station_label, count(*) as days
from {{ ref('fct_weather_outliers') }} as o
join {{ ref('dim_station') }} as s using (station_id)
group by grouping sets ((o.outlier_family, o.outlier_type), (o.outlier_family, o.outlier_type, s.station_label))
order by o.outlier_family, o.outlier_type, s.station_label nulls first
