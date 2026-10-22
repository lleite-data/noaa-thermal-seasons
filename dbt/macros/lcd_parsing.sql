{#
  NOAA LCD values arrive as text with inline flags:
    "23.4"   valid value
    "23.4s"  suspect value
    "23.4*"  erroneous value
    "T"      trace precipitation (measurable amount too small, not zero)
    blank    missing (never zero)
  Flags are extracted BEFORE casting; TRY_TO_DOUBLE on "23.4s" would return NULL.
#}

{% macro lcd_number(col) -%}
    try_to_double(nullif(regexp_replace({{ col }}, '[^0-9.-]', ''), ''))
{%- endmacro %}

{% macro lcd_is_suspect(col) -%}
    coalesce(endswith(trim({{ col }}), 's'), false)
{%- endmacro %}

{% macro lcd_is_erroneous(col) -%}
    coalesce(contains({{ col }}, '*'), false)
{%- endmacro %}

{% macro lcd_is_trace(col) -%}
    coalesce(upper(trim({{ col }})) = 'T', false)
{%- endmacro %}
