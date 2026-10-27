-- Spring relapses (docs/answers.md Q1, docs/methodology.md section 3).
-- After spring starts, does the 7-day average fall back below the station's cool level
-- (p25) within the next 30 days?
--   relapse_days = days in the 30 days after the start with the 7-day average below p25
--   years_with_relapse = spring starts followed by at least one such day
select
    o.station_label,
    count(*)                                                             as years,
    count_if(r.relapse_days > 0)                                         as years_with_relapse,
    round(avg(iff(r.relapse_days > 0, r.relapse_days, null)), 1)         as avg_relapse_days,
    max(r.relapse_days)                                                  as worst_relapse_days
from {{ ref('fct_season_onset') }} as o
inner join (
    select o2.station_id, o2.season_year,
           count_if(d.temp_rolling_mean_c < t.lower_threshold_c) as relapse_days
    from {{ ref('fct_season_onset') }} as o2
    inner join {{ ref('int_station_daily_series') }} as d
        on d.station_id = o2.station_id
       and d.calendar_date > o2.onset_date
       and d.calendar_date <= dateadd(day, 30, o2.onset_date)
    inner join {{ ref('int_station_thresholds') }} as t
        on t.station_id = o2.station_id
    where o2.season = 'spring' and o2.onset_status = 'detected'
    group by o2.station_id, o2.season_year
) as r
    on r.station_id = o.station_id and r.season_year = o.season_year
where o.season = 'spring' and o.onset_status = 'detected'
group by o.station_label
order by avg_relapse_days desc
