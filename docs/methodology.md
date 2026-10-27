# Methodology

How the data is chosen, how a "season start" is defined and detected, how trends and
outliers are measured, and what the method cannot tell us. Results are in
[answers.md](answers.md); the system that runs it is in [architecture.md](architecture.md).

## 1. Data

**Source.** NOAA Local Climatological Data, version 2 (LCD v2): one CSV per weather station
per year, with hourly readings, a daily summary row and a monthly summary row in the same
file. Version 2 was chosen (and confirmed with the client) because it uses current
station identifiers, metric units and is the actively maintained product.

**What we use.** The **daily summary rows** (daily average, maximum and minimum
temperature). Hourly rows are kept in raw and used for one thing only: rebuilding days
whose daily summary is missing (section 6).

**Stations.** 12 US airport stations, one per NOAA climate region of the contiguous US,
with a second station in two large, varied regions (Southeast: Atlanta and Miami;
Southwest: Denver and Phoenix) and Anchorage for Alaska. Airports have long, complete,
well-maintained records. Stations are listed in a dbt seed (`stations_of_interest.csv`);
adding a station is one line there and nothing else.

**Period.** 2006 to today (about 21 years per station). The brief asks for at least 5
years; detecting a trend needs more, so about 20 years are loaded. The pipeline loads any
year range (a parameter), so extending the history is a re-run, not a change.

## 2. What a "season" means here

Seasons are **thermal**: defined by each station's own temperatures, not by the calendar.

| Alternative | Why not |
|---|---|
| Astronomical seasons (equinoxes, solstices) | Fixed dates: nothing to detect, the answer to Q2 would always be "no change". |
| Meteorological seasons (Mar–May, …) | Same problem: fixed by definition. |
| Absolute thresholds (e.g. summer = above 20 °C) | Fail across climates: Miami never leaves "summer", Anchorage barely enters it. |
| **Station-relative thresholds (chosen)** | Every station is judged against its own climate, so Miami and Minneapolis are comparable. |

**Thresholds.** For each station, from its own daily average temperatures:
- **cool level** = 25th percentile (p25): the coldest quarter of days is below it;
- **warm level** = 75th percentile (p75): the warmest quarter of days is above it.

**Fixed baseline.** The levels come from a fixed period, **2006–2020**, and never change
when new years load. Two reasons: a season start detected today stays the same tomorrow
(results are reproducible), and only new days need processing (the pipeline can be
incremental). The trade-off: the baseline overlaps the period whose trend we measure;
because the levels are constant, a trend still shows up as a shift in crossing dates.

**Stations without real seasons.** If the difference between the warmest and coldest
average month is under 5 °C (tropical climates), the station has no meaningful thermal
seasons and is excluded from trends (`has_thermal_seasons`). None of the 12 stations is
excluded.

## 3. Detecting when a season starts

1. **Smooth.** Use the **7-day rolling average** of the daily average temperature, so a
   single warm or cold day cannot start a season. The average is only computed when at
   least 5 of the 7 days have data.
2. **Cross.** A season starts on the day the rolling average crosses a level:

   | Season | Crossing |
   |---|---|
   | Spring | rises above the cool level (p25) |
   | Summer | rises above the warm level (p75) |
   | Autumn | falls below the warm level (p75) |
   | Winter | falls below the cool level (p25) |

3. **Persist.** The new side must hold for **5 consecutive days** with no missing days;
   otherwise it was a false start and the search continues.
4. **Search window.** Each season is searched only inside a plausible window (seed
   `season_definitions.csv`): spring Jan 15–Jun 30, summer Mar 1–Aug 31, autumn
   Jul 1–Nov 30, winter Sep 1–Mar 31. Winter crosses New Year, so it belongs to the year
   in which it **ends** (winter 2026 = Sep 2025–Mar 2026, labelled "winter 2025/26").
5. **Southern Hemisphere ready.** Stations south of the equator use a calendar shifted by
   182 days, so the same windows apply. (All current stations are northern.)

**A gap-aware calendar.** The series has one row per calendar day, including days with no
data, so "7 days" and "5 consecutive days" always mean calendar days, never "7 rows".

**Every season-year gets a status**, and only `detected` onsets are used:

| Status | Meaning |
|---|---|
| `detected` | start found |
| `window_incomplete` | the window is not fully covered by data: it opened before the record starts (an onset there could be a later crossing, not the real one) or it is still open |
| `insufficient_data` | too many missing days in the window to conclude |
| `not_detected` | enough data, but no sustained crossing |

Current result: spring, summer and autumn 252 of 252 station-years detected; winter 240
detected and 24 `window_incomplete` (each station's first winter, which started before the
data does, and the winter in progress).

**Spring relapses.** After spring starts, the 7-day average often falls back into the cold
quarter within 30 days (10 to 18 of 21 years per station, 5 to 13 days on average). We
define spring as **the first sustained warm-up** and report relapses as a finding; a
"stable spring" definition is a possible next step.

**Unit tests** cover the detection rule with small hand-made series: a 3-day warm spell
that must not count (false start), a missing day that breaks a streak, a record that starts
after the window opens (no onset published), and a station that never warms up. The rule's
edge cases are fixed by tests, not by reading code.

## 4. Measuring change (Q2)

**Per station and season:** a least-squares line through the start date (day within the
season window) by year. Reported:

| Measure | Meaning |
|---|---|
| shift, days per decade | slope × 10; negative = earlier |
| R² | share of the year-to-year variation the line explains |
| standard error, t | how sure we are the slope is not zero |
| clear trend | \|t\| ≥ 2.1 (about p < 0.05 with ~20 years) and at least 10 years |

**Across stations:** how many of the 12 move the same way, and the median shift. With 21
years per station, weather noise is much larger than any trend, so a single station is
weak evidence (48 station-season tests produce 2 to 3 "clear" results by chance). Agreement
across many stations in different climates is the stronger evidence; a sign test gives a
rough measure of it (nearby stations share weather, so they are not fully independent).

**Sensitivity check** ([`onset_sensitivity.sql`](../dbt/analyses/onset_sensitivity.sql)).
The choices of 7 days, 5 days and p25/p75 are judgment calls, so the whole analysis was
re-run with each one changed: persistence 10 days, smoothing 14 days, thresholds p20/p80.

| Season | Base | Range across settings | Conclusion |
|---|---|---|---|
| Spring | −4.3 | −3.6 to −9.8; 8–12 stations earlier | direction robust, size not |
| Summer | −2.6 | −1.8 to −2.6; 9–10 earlier | robust, modest |
| Autumn | +7.0 | +5.2 to +8.3; 11–12 later | robust, strongest |
| Winter | −0.4 | direction flips | no reliable trend |

The check is a one-off analysis, not part of the daily pipeline: the published numbers use
one definition, and the check shows how much they depend on it.

## 5. Outliers (Q3)

Two families, kept apart because they need opposite responses.

**Data quality: is the measurement doubtful?** Checked on every day, every run:

| Check | Rule | Treatment |
|---|---|---|
| NOAA flags | value marked suspect (`s`) or erroneous (`*`) | removed from all calculations |
| Physically inconsistent | max below min, or mean outside [min, max] beyond 0.5 °C rounding | removed; build warns |
| Physically out of range | outside −70 to 60 °C | removed; build warns |
| Stuck sensor | mean, max **and** min unchanged for 5 days | flagged for review only |
| Suspicious jump | daily average changes more than 20 °C from the day before | flagged for review only |

The two "review only" checks find candidates that were real weather when compared with the
hourly readings (a very stable Miami spring, arctic fronts in Denver and Bismarck), so they
stay in the analysis. The stuck-sensor rule needs mean, max and min all frozen because NOAA
values come from whole °F: in stable weather the same daily mean can repeat for days while
max and min still move. The same rules (one macro) decide both what is reported and what is
removed, and a test fails the build if the two ever disagree.

**Climate: the measurement is fine, the weather was extreme.**
- **Unusual day:** the daily average is 3 or more standard deviations from the station's
  normal for that time of year. The normal is the 2006–2020 average and spread of all days
  within ±15 days of the date (a monthly normal would be too coarse: temperatures move
  several degrees within a month). By chance alone, about one day per year per station.
- **Records:** each station's highest maximum and lowest minimum in the loaded period,
  from NOAA's official daily values only (rebuilt days excluded).

## 6. Data quality findings and fixes

- **Blank is not missing.** NOAA's CSV quotes empty fields (`""`), which load as empty text,
  not NULL. A first check reported "no missing values" for that reason. Staging parses
  every value explicitly (empty text becomes NULL, never zero; NOAA flags are read before
  the number is converted), and completeness is tested per station-year.
- **Denver 2013.** Daily summaries are blank from April to December 2013 and October's rows
  are missing, while the hourly sensor kept reporting. These 274 days are rebuilt as
  **(hourly max + hourly min) / 2**, only when at least 18 hours were reported. This matches
  how the daily average is defined, so it was tested on 90,509 days that have both:

  | Method | Bias | Mean absolute error | Within 1 °C |
  |---|---|---|---|
  | (hourly max + min) / 2 (used) | −0.07 °C | 0.24 °C | 99.2% |
  | plain average of hourly readings | −0.23 °C | 0.66 °C | not used |

  The accuracy check runs on every build and fails it if the error drifts (bias over 0.3 °C
  or mean error over 0.5 °C). Rebuilt days are labelled (`temp_source`) and never used for
  records.

## 7. Limitations

- **12 stations are a sample**, chosen for coverage of climate regions, not a national
  average. Airports may be warmed by surrounding development.
- **21 years is short** for climate trends (official climate normals use 30 years), and the
  first and last years influence a straight-line slope.
- **Thermal seasons are relative.** A "later autumn" means the station's warm quarter ends
  later relative to its own 2006–2020 climate; it says nothing about absolute temperatures.
- **Single-station trends are mostly noise**; only cross-station agreement is reported as
  a finding.
- **Records cover 2006 onward**, not each station's full history.
- **Spring's definition** (first sustained warm-up) is one reasonable choice; relapses are
  common, and the spring trend size depends on the settings.

## 8. Next steps

- Trend methods that resist outlier years (Theil–Sen slope, Mann–Kendall test).
- A "stable spring" definition (no relapse within N days) next to the current one.
- Are extreme days becoming more frequent? (unusual-day counts per year, with a trend).
- More stations and longer history (LCD reaches back decades for many airports), with a
  worldwide grouping such as Köppen–Geiger climate zones instead of US regions.

## Glossary

| Term | Meaning |
|---|---|
| NOAA / NCEI | US National Oceanic and Atmospheric Administration / its National Centers for Environmental Information, which publish the data |
| LCD | Local Climatological Data: hourly, daily and monthly weather summaries per station |
| Daily summary (SOD) | NOAA's one row per day per station, with daily average, max and min |
| Thermal season | a season defined by temperature crossing station-specific levels |
| p25 / p75 | 25th / 75th percentile: a quarter of days are below / above it |
| Baseline | the fixed period (2006–2020) used to set levels and normals |
| Rolling average | average of the last 7 days, recomputed each day |
| Persistence | number of days the temperature must stay on the new side |
| Days per decade | how far a start date moves in 10 years (slope × 10) |
| R² | share of variation explained by the trend line |
| t-statistic | slope divided by its standard error; \|t\| ≥ 2.1 ≈ "unlikely to be chance" |
| z-score | how many standard deviations a day is from its normal |
| Station-year / season-year | one station in one year / one season in one year |
