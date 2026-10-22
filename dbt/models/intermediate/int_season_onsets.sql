{#
  Thermal season onset detection. One row per station x season x season_year.

  Rule (per station, on the 7-day rolling mean temperature):
    spring  = first sustained UPWARD   crossing of the lower threshold (p25)
    summer  = first sustained UPWARD   crossing of the upper threshold (p75)
    autumn  = first sustained DOWNWARD crossing of the upper threshold (p75)
    winter  = first sustained DOWNWARD crossing of the lower threshold (p25)
  "Crossing": the day before was on the other side of the threshold.
  "Sustained": the next persistence_days days (inclusive) all stay on the new side,
  with no missing days (missing = NULL rolling mean = streak broken).

  Each season is searched inside a bounded window (seed season_definitions), on the
  season calendar (Southern Hemisphere shifted by 182 days). Winter's window runs
  Sep 1 to Mar 31 and belongs to the season_year in which it ENDS (winter 2007 =
  Sep 2006 - Mar 2007), so year boundaries never split a season.

  status:
    detected          onset found
    window_incomplete window not fully covered by the station's data: it opened before
                      the record starts (an onset found there could be a later crossing,
                      not the real one) or it is still open with no onset yet
    insufficient_data too many missing days in the window to conclude
    not_detected      enough data, but no sustained crossing in the window
#}
{% set persistence = var('persistence_days') %}
{# forward frame: this day and the next persistence-1 days #}
{% set forward_frame = "over (partition by station_id order by calendar_date rows between current row and " ~ (persistence - 1) ~ " following)" %}

with series as (

    select
        d.station_id,
        d.calendar_date,
        d.season_calendar_date,
        d.temp_rolling_mean_c,
        t.lower_threshold_c,
        t.upper_threshold_c,
        lag(d.temp_rolling_mean_c) over (partition by d.station_id order by d.calendar_date)
                                                                  as prev_rolling_mean_c
    from {{ ref('int_station_daily_series') }} as d
    inner join {{ ref('int_station_thresholds') }} as t
        on d.station_id = t.station_id

),

streaks as (

    select
        *,
        -- number of non-missing days in the forward persistence frame
        count(temp_rolling_mean_c) {{ forward_frame }} as frame_obs,
        min(iff(temp_rolling_mean_c >= lower_threshold_c, 1, 0)) {{ forward_frame }} = 1 as holds_above_lower,
        min(iff(temp_rolling_mean_c <  lower_threshold_c, 1, 0)) {{ forward_frame }} = 1 as holds_below_lower,
        min(iff(temp_rolling_mean_c >= upper_threshold_c, 1, 0)) {{ forward_frame }} = 1 as holds_above_upper,
        min(iff(temp_rolling_mean_c <  upper_threshold_c, 1, 0)) {{ forward_frame }} = 1 as holds_below_upper
    from series

),

crossings as (

    select
        station_id,
        calendar_date,
        season_calendar_date,
        temp_rolling_mean_c,
        frame_obs = {{ persistence }} and holds_above_lower and prev_rolling_mean_c <  lower_threshold_c as up_lower,
        frame_obs = {{ persistence }} and holds_above_upper and prev_rolling_mean_c <  upper_threshold_c as up_upper,
        frame_obs = {{ persistence }} and holds_below_upper and prev_rolling_mean_c >= upper_threshold_c as down_upper,
        frame_obs = {{ persistence }} and holds_below_lower and prev_rolling_mean_c >= lower_threshold_c as down_lower
    from streaks

),

station_bounds as (

    select
        station_id,
        min(season_calendar_date) as first_season_date,
        max(season_calendar_date) as last_season_date
    from series
    group by station_id

),

season_years as (

    select
        b.station_id,
        b.first_season_date,
        b.last_season_date,
        year(b.first_season_date) + y.offset_years as season_year
    from station_bounds as b
    inner join (
        select row_number() over (order by seq4()) - 1 as offset_years
        from table(generator(rowcount => 200))
    ) as y
        on y.offset_years <= year(b.last_season_date) - year(b.first_season_date) + 1

),

windows as (

    select
        sy.station_id,
        sy.season_year,
        sd.season,
        sd.season_order,
        sd.crossing_direction,
        sd.threshold,
        date_from_parts(sy.season_year - iff(sd.window_starts_previous_year, 1, 0),
                        sd.window_start_month, sd.window_start_day)              as window_start,
        date_from_parts(sy.season_year, sd.window_end_month, sd.window_end_day)  as window_end,
        sy.first_season_date,
        sy.last_season_date
    from season_years as sy
    cross join {{ ref('season_definitions') }} as sd

),

window_days as (

    select
        w.station_id,
        w.season_year,
        w.season,
        c.calendar_date,
        c.season_calendar_date,
        c.temp_rolling_mean_c,
        case w.season
            when 'spring' then c.up_lower
            when 'summer' then c.up_upper
            when 'autumn' then c.down_upper
            when 'winter' then c.down_lower
        end as is_onset_candidate
    from windows as w
    inner join crossings as c
        on c.station_id = w.station_id
       and c.season_calendar_date between w.window_start and w.window_end

),

onsets as (

    select
        station_id,
        season_year,
        season,
        count(temp_rolling_mean_c)                                        as valid_days,
        min(iff(is_onset_candidate, calendar_date, null))                 as onset_date,
        min(iff(is_onset_candidate, season_calendar_date, null))          as onset_season_calendar_date
    from window_days
    group by station_id, season_year, season

),

classified as (

    select
        w.station_id,
        w.season,
        w.season_order,
        w.season_year,
        w.crossing_direction,
        w.threshold,
        w.window_start,
        w.window_end,
        o.onset_date                                                      as candidate_onset_date,
        datediff(day, w.window_start, o.onset_season_calendar_date)       as candidate_onset_day_index,
        coalesce(o.valid_days, 0)                                         as valid_days_in_window,
        datediff(day, w.window_start, w.window_end) + 1                   as window_days,
        coalesce(o.valid_days, 0) / (datediff(day, w.window_start, w.window_end) + 1)
                                                                          as window_coverage,
        case
            -- left-censored: the record starts after the window opened, so the true
            -- onset may have happened before the data begins. Never report it.
            when w.window_start < w.first_season_date                     then 'window_incomplete'
            when o.onset_date is not null                                 then 'detected'
            -- right-censored: window still open (current season) and no onset yet
            when w.window_end   > w.last_season_date                      then 'window_incomplete'
            when coalesce(o.valid_days, 0) / (datediff(day, w.window_start, w.window_end) + 1)
                 < {{ var('min_window_coverage') }}                       then 'insufficient_data'
            else 'not_detected'
        end                                                               as onset_status
    from windows as w
    left join onsets as o
        on w.station_id = o.station_id
       and w.season_year = o.season_year
       and w.season = o.season
    -- drop windows entirely outside the station's record
    where w.window_end   >= w.first_season_date
      and w.window_start <= w.last_season_date

)

select
    station_id,
    season,
    season_order,
    season_year,
    crossing_direction,
    threshold,
    window_start,
    window_end,
    -- an onset date is only published when the status says it can be trusted
    iff(onset_status = 'detected', candidate_onset_date, null)            as onset_date,
    iff(onset_status = 'detected', candidate_onset_day_index, null)       as onset_day_index,
    valid_days_in_window,
    window_days,
    window_coverage,
    onset_status
from classified
