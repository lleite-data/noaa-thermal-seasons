select
    station_id,
    station_name,
    nullif(wmo_id, '')          as wmo_id,
    try_to_double(latitude)     as latitude,
    try_to_double(longitude)    as longitude,
    try_to_double(elevation_m)  as elevation_m,
    left(station_id, 2)         as country_code,
    _loaded_at
from {{ source('lcd', 'raw_lcd_stations') }}
