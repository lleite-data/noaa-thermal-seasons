{#
  One row per station x season: answers Q1 (pattern) and Q2 (change / trend).

  Q1 pattern: median onset and spread (IQR), shown as a typical calendar date.
  Q2 trend:   least-squares slope of onset_day_index on season_year, in days per
              decade (negative = season starts earlier). With ~20 points per
              station, a slope alone is not evidence, so we also report:
                n, R^2, standard error of the slope and the t statistic
              is_significant = |t| >= 2.1 (approx. two-sided p < 0.05 for ~18 df).
  Only detected onsets of stations with real thermal seasons are used.
#}
with onsets as (

    select o.*, sd.window_start_month, sd.window_start_day, sd.window_starts_previous_year
    from {{ ref('fct_season_onset') }} as o
    inner join {{ ref('season_definitions') }} as sd
        on o.season = sd.season
    where o.onset_status = 'detected'
      and o.has_thermal_seasons

),

stats as (

    select
        station_id,
        any_value(station_label)                                          as station_label,
        any_value(climate_region)                                         as climate_region,
        season,
        any_value(season_order)                                           as season_order,
        any_value(window_start_month)                                     as window_start_month,
        any_value(window_start_day)                                       as window_start_day,
        any_value(window_starts_previous_year)                            as window_starts_previous_year,
        count(*)                                                          as n_years,
        min(season_year)                                                  as first_year,
        max(season_year)                                                  as last_year,
        median(onset_day_index)                                           as median_onset_day_index,
        percentile_cont(0.25) within group (order by onset_day_index)     as p25_onset_day_index,
        percentile_cont(0.75) within group (order by onset_day_index)     as p75_onset_day_index,
        min(onset_date)                                                   as earliest_onset_date_seen,
        max(onset_date)                                                   as latest_onset_date_seen,
        regr_slope(onset_day_index, season_year)                          as slope_days_per_year,
        regr_r2(onset_day_index, season_year)                             as r_squared,
        var_samp(onset_day_index)                                         as var_onset,
        var_samp(season_year)                                             as var_year
    from onsets
    group by station_id, season

)

select
    station_id,
    station_label,
    climate_region,
    season,
    season_order,
    n_years,
    first_year,
    last_year,

    -- Q1: pattern (typical date rendered on a non-leap reference calendar)
    median_onset_day_index,
    p75_onset_day_index - p25_onset_day_index                             as iqr_days,
    to_char(dateadd(day, round(median_onset_day_index),
        date_from_parts(2001 - iff(window_starts_previous_year, 1, 0),
                        window_start_month, window_start_day)), 'Mon DD') as typical_onset,
    to_char(dateadd(day, round(p25_onset_day_index),
        date_from_parts(2001 - iff(window_starts_previous_year, 1, 0),
                        window_start_month, window_start_day)), 'Mon DD') as typical_range_from,
    to_char(dateadd(day, round(p75_onset_day_index),
        date_from_parts(2001 - iff(window_starts_previous_year, 1, 0),
                        window_start_month, window_start_day)), 'Mon DD') as typical_range_to,

    -- Q2: trend
    slope_days_per_year * 10                                              as shift_days_per_decade,
    r_squared,
    sqrt((1 - r_squared) * var_onset / ((n_years - 2) * var_year))        as slope_std_error,
    slope_days_per_year / nullif(slope_std_error, 0)                      as t_statistic,
    n_years >= {{ var('min_years_for_trend') }}
        and abs(t_statistic) >= 2.1                                       as is_significant,
    case
        when n_years < {{ var('min_years_for_trend') }} then 'too_few_years'
        when abs(t_statistic) < 2.1                     then 'no_clear_trend'
        when slope_days_per_year < 0                    then 'earlier'
        else 'later'
    end                                                                   as trend_direction
from stats
