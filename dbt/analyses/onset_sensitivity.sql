{#
  Robustness check for the season onset rule (run on demand, not part of the pipeline).

  Question: do the conclusions depend on the parameters we chose?
  Recomputes onsets and trends for several parameter scenarios side by side and
  summarises, per season, how many stations trend earlier/later and the median shift.
  The base scenario reproduces the production model (mart_season_trend_summary).

  Run: dbt compile --select onset_sensitivity  (then run the compiled SQL in Snowflake),
       or "Compile" in the dbt Cloud IDE and run the result.

  Result on 2026-10-26 (12 stations, 2006-2026):
    autumn  later at 11-12/12 in every scenario, median +5.2 to +8.3 days/decade  -> robust
    summer  earlier at 9-10/12 in every scenario, median -1.8 to -2.6             -> robust (small)
    spring  earlier at 8-12/12 in every scenario, median -3.6 to -9.8             -> direction robust,
            size depends on the definition (false springs): report a range
    winter  direction flips between scenarios (median -0.4 to +2.7)               -> no robust trend
#}
with scenarios as (
    select column1 as scenario, column2 as smoothing_days, column3 as persistence_days,
           column4 as lower_pct, column5 as upper_pct
    from values ('1_base',              7,  5, 0.25, 0.75),
                ('2_persistence_10',    7, 10, 0.25, 0.75),
                ('3_smoothing_14',     14,  5, 0.25, 0.75),
                ('4_thresholds_20_80',  7,  5, 0.20, 0.80)
),

daily as (
    select station_id, calendar_date, calendar_year, season_calendar_date,
           temp_mean_clean_c as t
    from {{ ref('int_station_daily_series') }}
),

rolled as (
    select *,
        iff(count(t) over (partition by station_id order by calendar_date rows between 6 preceding and current row) >= 5,
            avg(t)   over (partition by station_id order by calendar_date rows between 6 preceding and current row), null) as r7,
        iff(count(t) over (partition by station_id order by calendar_date rows between 13 preceding and current row) >= 10,
            avg(t)   over (partition by station_id order by calendar_date rows between 13 preceding and current row), null) as r14
    from daily
),

thresholds as (
    select station_id,
        percentile_cont(0.20) within group (order by t) as p20,
        percentile_cont(0.25) within group (order by t) as p25,
        percentile_cont(0.75) within group (order by t) as p75,
        percentile_cont(0.80) within group (order by t) as p80
    from daily
    where calendar_year between {{ var('baseline_start_year') }} and {{ var('baseline_end_year') }}
      and t is not null
    group by station_id
),

series as (
    select s.scenario, s.persistence_days, r.station_id, r.calendar_date, r.season_calendar_date,
           iff(s.smoothing_days = 14, r.r14, r.r7) as r,
           iff(s.lower_pct = 0.20, th.p20, th.p25) as lo,
           iff(s.upper_pct = 0.80, th.p80, th.p75) as hi
    from rolled r
    join thresholds th using (station_id)
    cross join scenarios s
),

{% set f5 = "over (partition by scenario, station_id order by calendar_date rows between current row and 4 following)" %}
{% set f10 = "over (partition by scenario, station_id order by calendar_date rows between current row and 9 following)" %}
flags as (
    select *,
        lag(r) over (partition by scenario, station_id order by calendar_date) as prev_r,
        count(r) {{ f5 }}                  as n5,
        min(iff(r >= lo, 1, 0)) {{ f5 }}   as above_lo_5,
        min(iff(r <  lo, 1, 0)) {{ f5 }}   as below_lo_5,
        min(iff(r >= hi, 1, 0)) {{ f5 }}   as above_hi_5,
        min(iff(r <  hi, 1, 0)) {{ f5 }}   as below_hi_5,
        count(r) {{ f10 }}                 as n10,
        min(iff(r >= lo, 1, 0)) {{ f10 }}  as above_lo_10,
        min(iff(r <  lo, 1, 0)) {{ f10 }}  as below_lo_10,
        min(iff(r >= hi, 1, 0)) {{ f10 }}  as above_hi_10,
        min(iff(r <  hi, 1, 0)) {{ f10 }}  as below_hi_10
    from series
),

crossings as (
    select scenario, station_id, calendar_date, season_calendar_date,
        iff(persistence_days = 10, n10 = 10 and above_lo_10 = 1, n5 = 5 and above_lo_5 = 1) and prev_r <  lo as up_lower,
        iff(persistence_days = 10, n10 = 10 and above_hi_10 = 1, n5 = 5 and above_hi_5 = 1) and prev_r <  hi as up_upper,
        iff(persistence_days = 10, n10 = 10 and below_hi_10 = 1, n5 = 5 and below_hi_5 = 1) and prev_r >= hi as down_upper,
        iff(persistence_days = 10, n10 = 10 and below_lo_10 = 1, n5 = 5 and below_lo_5 = 1) and prev_r >= lo as down_lower
    from flags
),

bounds as (
    select station_id, min(season_calendar_date) as first_d
    from daily group by station_id
),

windows as (
    select b.station_id, y.season_year, sd.season, sd.season_order,
           date_from_parts(y.season_year - iff(sd.window_starts_previous_year, 1, 0),
                           sd.window_start_month, sd.window_start_day)        as ws,
           date_from_parts(y.season_year, sd.window_end_month, sd.window_end_day) as we,
           b.first_d
    from bounds b
    cross join (select {{ var('baseline_start_year') }} - 1 + row_number() over (order by seq4()) as season_year
                from table(generator(rowcount => 30))) y
    cross join {{ ref('season_definitions') }} sd
),

onsets as (
    select c.scenario, w.station_id, w.season, w.season_order, w.season_year, w.ws,
           min(iff(case w.season when 'spring' then c.up_lower
                                 when 'summer' then c.up_upper
                                 when 'autumn' then c.down_upper
                                 else c.down_lower end,
                   c.season_calendar_date, null)) as onset_season_date
    from windows w
    join crossings c
      on c.station_id = w.station_id
     and c.season_calendar_date between w.ws and w.we
    where w.ws >= w.first_d                   -- left-censored windows skipped
    group by 1, 2, 3, 4, 5, 6
),

trends as (
    select scenario, station_id, season, any_value(season_order) as season_order,
           count(*) as n_years,
           regr_slope(datediff(day, ws, onset_season_date), season_year) * 10 as shift_per_decade,
           regr_r2(datediff(day, ws, onset_season_date), season_year)         as r2,
           var_samp(datediff(day, ws, onset_season_date))                     as var_y,
           var_samp(season_year)                                              as var_x
    from onsets
    where onset_season_date is not null
    group by 1, 2, 3
),

trend_t as (
    select *, (shift_per_decade / 10) / nullif(sqrt((1 - r2) * var_y / ((n_years - 2) * var_x)), 0) as t_stat
    from trends
)

select scenario, season,
       count(*)                           as stations,
       sum(n_years)                       as detected_station_years,
       count_if(shift_per_decade < 0)     as stations_earlier,
       count_if(shift_per_decade > 0)     as stations_later,
       count_if(t_stat <= -2.1)           as significantly_earlier,
       count_if(t_stat >=  2.1)           as significantly_later,
       round(median(shift_per_decade), 1) as median_shift_days_per_decade
from trend_t
group by scenario, season
order by any_value(season_order), scenario
