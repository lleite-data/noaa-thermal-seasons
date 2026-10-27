-- Q3: outlier counts by family and type: one 'All stations' total per type, then per station.
select o.outlier_family, o.outlier_type,
       iff(grouping(s.station_label) = 1, 'All stations', s.station_label) as station,
       count(*) as days
from {{ ref('fct_weather_outliers') }} as o
join {{ ref('dim_station') }} as s using (station_id)
group by grouping sets ((o.outlier_family, o.outlier_type), (o.outlier_family, o.outlier_type, s.station_label))
order by 1, 2, station = 'All stations' desc, station
