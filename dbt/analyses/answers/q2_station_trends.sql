-- Q2: shift per station and season (days per decade, negative = earlier) and evidence.
-- Source of the Q2 per-station table in docs/answers.md.
select station_label, season, n_years,
       round(shift_days_per_decade, 1) as shift_days_per_decade,
       round(r_squared, 2)             as r_squared,
       round(t_statistic, 2)           as t_statistic,
       is_significant, trend_direction
from {{ ref('mart_season_onset_trends') }}
order by season_order, station_label
