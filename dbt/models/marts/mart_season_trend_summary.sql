{#
  Cross-station view per season: is there a consistent direction across climates?
  Individual stations are noisy; agreement across many stations is the stronger signal.
#}
select
    season,
    any_value(season_order)                                  as season_order,
    count(*)                                                 as stations,
    count_if(shift_days_per_decade < 0)                      as stations_trending_earlier,
    count_if(shift_days_per_decade > 0)                      as stations_trending_later,
    count_if(is_significant and shift_days_per_decade < 0)   as stations_significantly_earlier,
    count_if(is_significant and shift_days_per_decade > 0)   as stations_significantly_later,
    median(shift_days_per_decade)                            as median_shift_days_per_decade,
    min(shift_days_per_decade)                               as min_shift_days_per_decade,
    max(shift_days_per_decade)                               as max_shift_days_per_decade
from {{ ref('mart_season_onset_trends') }}
where n_years >= {{ var('min_years_for_trend') }}
group by season
