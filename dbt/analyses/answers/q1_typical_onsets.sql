-- Q1: typical start date per station and season (median, middle 50% of years).
-- Source of the Q1 table in docs/answers.md. Run in dbt Cloud (Compile/Preview) or Snowsight.
select station_label, season, n_years,
       typical_onset, typical_range_from, typical_range_to, iqr_days
from {{ ref('mart_season_onset_trends') }}
order by season_order, station_label
