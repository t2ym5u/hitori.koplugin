# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

## [1.1.12] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_C / COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY / COLOR_LIGHT_GRAY).

## [1.1.8] - 2026-07-29

### Fixed
- Generated puzzles had no uniqueness verification — a candidate
  black-cell shading was accepted as soon as it was structurally valid
  (no adjacent black cells, connected white region, a valid row/column
  number assignment), with no check that it was the only shading
  consistent with the numbers shown. At the nominal per-difficulty
  density this meant puzzles were essentially never unique. Generation
  now escalates the black-cell density in bounded steps and verifies
  each candidate with a backtracking solution counter, accepting only
  a puzzle proven to have exactly one solution.
