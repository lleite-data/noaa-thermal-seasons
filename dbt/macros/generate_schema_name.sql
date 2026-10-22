{#
  dev:  <target schema>_<custom schema>   e.g. dbt_lleite_staging (isolated per developer)
  prod: <custom schema>                   e.g. staging, marts      (clean names)

  "prod" = target name 'prod', OR the dbt Cloud environment is a Production
  deployment (DBT_CLOUD_ENVIRONMENT_TYPE = 'prod'), so it works whether the
  target name is set on the connection profile or not.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- set is_prod = target.name == 'prod' or env_var('DBT_CLOUD_ENVIRONMENT_TYPE', '') == 'prod' -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- elif is_prod -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
