# Changelog

All notable changes to this project will be documented in this file.

## [1.3.0] - 2026-10-30

### Added
- "New game" once the puzzle is solved: the action bar shows it in place of
  Check, Hint and Undo, so the next puzzle no longer needs the menu.

### Changed
- Redesigned play screen, in line with the other games: a full-width action
  bar, a larger board that fills the available room, and one frame around
  it. The status line reads "size · difficulty · Unknown: n" and wraps in
  landscape instead of being cut off.
- Cells marked white are circled -- a ring around the number, the usual
  Hitori notation -- instead of a small ring in the corner that sat on top
  of the digit once the number filled the cell.
- Title-bar menu in the same order as every other game, with the current
  values shown: "Size: …" (was "Grid: …"), "Difficulty: …" (was "Diff:
  …"), and "Show solution" / "Hide solution" (was "Show result" / "Hide
  result").
- New README screenshot.

### Fixed
- Tapping Undo crashed the game ("attempt to call method 'undo'").
- Using Hint wiped the saved game: the board was saved as nothing. And when
  a hint fills the last cell, the status now shows the win message.
- The board's closing grid line was drawn just past its right and bottom
  edges.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.
- `i18n_fr.lua` shipped to the device but was never loaded: nothing called
  `i18n.extend()` on it, so the whole table was dead weight. main.lua now
  merges it in before the menu entry is built.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

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
