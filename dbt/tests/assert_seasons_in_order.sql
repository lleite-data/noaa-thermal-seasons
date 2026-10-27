-- Seasons are detected independently, in windows that overlap (e.g. summer Mar-Aug and
-- autumn Jul-Nov). Check that, wherever both are detected, they come in the natural
-- order: spring before summer before autumn in the same year, and autumn before the
-- winter that follows it. Warn only: an out-of-order pair is a finding to review
-- (e.g. a cool spell mistaken for autumn), not a broken pipeline.
{{ config(severity='warn') }}

with onsets as (

    select station_id, season, season_year, onset_date
    from {{ ref('fct_season_onset') }}
    where onset_status = 'detected'

),

pairs as (

    select a.station_id, a.season_year, a.season as earlier_season, b.season as later_season,
           a.onset_date as earlier_onset, b.onset_date as later_onset
    from onsets as a
    inner join onsets as b
        on a.station_id = b.station_id
       and (
               (a.season = 'spring' and b.season = 'summer' and b.season_year = a.season_year)
            or (a.season = 'summer' and b.season = 'autumn' and b.season_year = a.season_year)
            or (a.season = 'autumn' and b.season = 'winter' and b.season_year = a.season_year + 1)
       )

)

select *
from pairs
where later_onset <= earlier_onset
