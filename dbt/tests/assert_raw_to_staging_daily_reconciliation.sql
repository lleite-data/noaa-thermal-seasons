-- Every distinct station-day in raw (daily summary rows, analysis period) must
-- appear exactly once in staging: nothing lost, nothing duplicated between layers.
-- Returns a row (= test failure) only if the two counts differ.
with raw_days as (

    select count(distinct station, left(date, 10)) as n
    from {{ source('lcd', 'raw_lcd_observations') }}
    where report_type = 'SOD'
      and try_to_date(left(date, 10)) >= '{{ var("analysis_start_date") }}'::date

),

staging_days as (

    select count(*) as n
    from {{ ref('stg_lcd__daily_observations') }}

)

select r.n as raw_station_days, s.n as staging_station_days
from raw_days as r
cross join staging_days as s
where r.n <> s.n
