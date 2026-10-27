-- Q2: agreement across stations per season (headline table in docs/answers.md).
-- Warm-season length is in q2_warm_season_length.sql.
select season, stations, stations_trending_earlier, stations_trending_later,
       stations_significantly_earlier, stations_significantly_later,
       round(median_shift_days_per_decade, 1) as median_shift_days_per_decade,
       round(min_shift_days_per_decade, 1)    as min_shift_days_per_decade,
       round(max_shift_days_per_decade, 1)    as max_shift_days_per_decade
from {{ ref('mart_season_trend_summary') }}
order by season_order
