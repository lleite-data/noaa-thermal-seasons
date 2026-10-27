{#
  Physical plausibility rules for one day's temperatures, defined ONCE and used by:
    - int_station_daily_series: such values never reach the analysis (temp_mean_clean_c)
    - fct_weather_outliers:     each hit is reported as a DATA_QUALITY row
  NULL-safe: a missing value is "no evidence", never a violation.
#}
{% macro is_physically_inconsistent(mean_c, max_c, min_c) -%}
    coalesce(
        {{ max_c }} < {{ min_c }}
        or {{ mean_c }} not between {{ min_c }} - 0.5 and {{ max_c }} + 0.5,   -- 0.5 C rounding tolerance
        false
    )
{%- endmacro %}

{% macro is_physically_out_of_range(mean_c, max_c, min_c) -%}
    coalesce(
        {{ mean_c }} not between -70 and 60
        or {{ max_c }} not between -70 and 60
        or {{ min_c }} not between -70 and 60,
        false
    )
{%- endmacro %}
