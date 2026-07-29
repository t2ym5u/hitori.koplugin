# Changelog

All notable changes to this project will be documented in this file.

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
