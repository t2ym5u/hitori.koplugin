# hitori.koplugin

A Hitori plugin for [KOReader](https://github.com/koreader/koreader).


## Screenshot

*(Screenshot to be added.)*

## Rules

Shade cells black so that: no row or column has duplicate numbers among white cells; no two black cells touch orthogonally; all white cells form one connected group.

## Concept

Hitori (Japanese: "leave me alone") is a logic puzzle on a square grid filled with
numbers. The goal is to blacken some cells so that:

1. No number appears more than once in any row or column (among unblackened cells).
2. Blackened cells never share an edge.
3. All unblackened cells form a single connected region.

## Features

- **Multiple grid sizes** — 5×5, 7×7, 9×9
- **Three difficulty levels** — Easy, Medium, Hard
- **Cell states** — white (keep), black (eliminate), circled (confirmed keep)
- **Constraint highlighting** — tap a number to highlight its duplicates
- **Check** — verifies all three rules and highlights violations
- **Reveal solution** — shows the full solution
- **Undo** — step back through your moves
- **Auto-save** — game state saved and restored on next launch

## Controls

| Action | How |
|--------|-----|
| Blacken a cell | Tap it once |
| Circle a cell (confirmed white) | Tap it twice |
| Reset a cell | Tap it a third time |
| Undo last move | Tap **Undo** |
| Check progress | Tap **Check** |
| New game | Tap **New game** |
| Change grid size | Tap **Grid** |
| Change difficulty | Tap **Diff** |
| Show rules | Tap **Rules** |

## Why e-ink friendly?

Hitori has three distinct cell states rendered as simple fill patterns (empty /
solid / circled), requiring no colour and minimal screen refreshes.

## License

GPL-3.0
