-- What the raw NOAA files contain (docs/methodology.md section 1): rows per year by kind
-- of row, using the latest loaded version of each file (raw keeps every version).
with latest as (

    select *
    from {{ source('lcd', 'raw_lcd_observations') }}
    qualify _loaded_at = max(_loaded_at) over (partition by _source_file)

)

select
    year(try_to_date(left(date, 10)))                   as year,
    case report_type
        when 'SOD' then 'daily summary (SOD)'
        when 'SOM' then 'monthly summary (SOM)'
        else 'hourly / sub-hourly'
    end                                                 as row_kind,
    count(*)                                            as rows,
    count(distinct station)                             as stations,
    count(distinct _source_file)                        as files
from latest
group by 1, 2
order by 1, 2
