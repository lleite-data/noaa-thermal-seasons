-- Q2: warm-season length per station (days from summer start to autumn start) and its trend.
select station_label, n_years, median_warm_season_days,
       round(change_days_per_decade, 1) as change_days_per_decade,
       is_significant
from {{ ref('mart_warm_season_length') }}
order by change_days_per_decade desc
