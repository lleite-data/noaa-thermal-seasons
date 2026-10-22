{#
  Warm-season length per station: days from summer onset to autumn onset in the
  same year, and its trend. Combines the two Q2 signals (summer earlier, autumn
  later) into one number: is the warm season getting longer?
  Only years where both onsets were detected are used.
#}
with onsets as (

    select station_id, station_label, climate_region, season_year, season, onset_date
    from {{ ref('fct_season_onset') }}
    where onset_status = 'detected'
      and has_thermal_seasons
      and season in ('summer', 'autumn')

),

per_year as (

    select
        station_id,
        any_value(station_label)                                      as station_label,
        any_value(climate_region)                                     as climate_region,
        season_year,
        max(iff(season = 'summer', onset_date, null))                 as summer_onset_date,
        max(iff(season = 'autumn', onset_date, null))                 as autumn_onset_date
    from onsets
    group by station_id, season_year
    having max(iff(season = 'summer', onset_date, null)) is not null
       and max(iff(season = 'autumn', onset_date, null)) is not null

),

lengths as (

    select *, datediff(day, summer_onset_date, autumn_onset_date) as warm_season_days
    from per_year

),

stats as (

    select
        station_id,
        any_value(station_label)                                      as station_label,
        any_value(climate_region)                                     as climate_region,
        count(*)                                                      as n_years,
        min(season_year)                                              as first_year,
        max(season_year)                                              as last_year,
        median(warm_season_days)                                      as median_warm_season_days,
        min(warm_season_days)                                         as min_warm_season_days,
        max(warm_season_days)                                         as max_warm_season_days,
        regr_slope(warm_season_days, season_year)                     as slope_days_per_year,
        regr_r2(warm_season_days, season_year)                        as r_squared,
        var_samp(warm_season_days)                                    as var_length,
        var_samp(season_year)                                         as var_year
    from lengths
    group by station_id

)

select
    station_id,
    station_label,
    climate_region,
    n_years,
    first_year,
    last_year,
    median_warm_season_days,
    min_warm_season_days,
    max_warm_season_days,
    slope_days_per_year * 10                                          as change_days_per_decade,
    r_squared,
    sqrt((1 - r_squared) * var_length / ((n_years - 2) * var_year))   as slope_std_error,
    slope_days_per_year / nullif(slope_std_error, 0)                  as t_statistic,
    n_years >= {{ var('min_years_for_trend') }} and abs(t_statistic) >= 2.1
                                                                      as is_significant
from stats
