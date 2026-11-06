local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")
local Hint      = require("hint")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

local STATE_UNKNOWN   = 0
local STATE_BLACK     = 1
local STATE_WHITE_DOT = 2

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

-- Share of cells the black pattern aims for. A unique Hitori is dense by
-- nature: any white cell that could be shaded without breaking a rule
-- would give a second solution, so about 30% of the cells end up black at
-- every level. What sets the levels apart is the reasoning (see LEVELS).
local PATTERN_DENSITY = 0.34
-- Search nodes per uniqueness check (running out counts as "not unique"):
-- with propagation every candidate settles in under 25 nodes (measured on
-- 1,500 7x7 checks), so this is only a safety cap.
local UNIQUENESS_NODE_BUDGET = 5000

-- ---------------------------------------------------------------------------
-- Connectivity check (DFS over non-black cells)
-- ---------------------------------------------------------------------------

-- Scratch space reused across calls (generation calls this once per
-- black cell placed, a few thousand times per 7x7 puzzle): a visit stamp
-- per cell and an explicit stack of row/column pairs, no tables per cell.
local conn_seen, conn_stamp, conn_stack = {}, 0, {}

local function isConnected(black, n)
    local start_r, start_c
    local total_white = 0
    for r = 1, n do
        local row = black[r]
        for c = 1, n do
            if not row[c] then
                total_white = total_white + 1
                if not start_r then start_r, start_c = r, c end
            end
        end
    end
    if not start_r then return true end

    conn_stamp = conn_stamp + 1
    local stamp, seen, stack = conn_stamp, conn_seen, conn_stack
    seen[start_r * 64 + start_c] = stamp
    stack[1], stack[2] = start_r, start_c
    local top, count = 2, 1
    while top > 0 do
        local r, c = stack[top - 1], stack[top]
        top = top - 2
        for k = 1, 4 do
            local nr, nc = r, c
            if k == 1 then nr = r - 1 elseif k == 2 then nr = r + 1
            elseif k == 3 then nc = c - 1 else nc = c + 1 end
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not black[nr][nc] then
                local key = nr * 64 + nc
                if seen[key] ~= stamp then
                    seen[key] = stamp
                    count = count + 1
                    stack[top + 1], stack[top + 2] = nr, nc
                    top = top + 2
                end
            end
        end
    end
    return count == total_white
end

-- ---------------------------------------------------------------------------
-- No two adjacent black cells
-- ---------------------------------------------------------------------------

local function hasAdjacentBlack(black, n, r, c)
    for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
        local nr, nc = r + d[1], c + d[2]
        if nr >= 1 and nr <= n and nc >= 1 and nc <= n and black[nr][nc] then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Assign numbers to white cells via backtracking
-- ---------------------------------------------------------------------------

local function assignNumbers(black, n, puzzle)
    for r = 1, n do
        for c = 1, n do
            puzzle[r][c] = 0
        end
    end

    local whites = {}
    for r = 1, n do
        for c = 1, n do
            if not black[r][c] then
                whites[#whites + 1] = { r, c }
            end
        end
    end

    local function tryAssign(idx)
        if idx > #whites then return true end
        local r, c = whites[idx][1], whites[idx][2]
        local used = {}
        for cc = 1, n do
            if puzzle[r][cc] ~= 0 then used[puzzle[r][cc]] = true end
        end
        for rr = 1, n do
            if puzzle[rr][c] ~= 0 then used[puzzle[rr][c]] = true end
        end
        local vals = {}
        for v = 1, n do
            if not used[v] then vals[#vals + 1] = v end
        end
        for i = #vals, 2, -1 do
            local j = math.random(i)
            vals[i], vals[j] = vals[j], vals[i]
        end
        for _, v in ipairs(vals) do
            puzzle[r][c] = v
            if tryAssign(idx + 1) then return true end
            puzzle[r][c] = 0
        end
        return false
    end

    return tryAssign(1)
end

-- ---------------------------------------------------------------------------
-- Generate black cell pattern
-- ---------------------------------------------------------------------------

local function generateBlackPattern(n, density)
    local black = emptyBoolGrid(n)
    local candidates = {}
    for r = 1, n do
        for c = 1, n do
            candidates[#candidates + 1] = { r, c }
        end
    end
    shuffle(candidates)

    local target = math.floor(n * n * density)
    local placed = 0
    for _, pos in ipairs(candidates) do
        if placed >= target then break end
        local r, c = pos[1], pos[2]
        if not hasAdjacentBlack(black, n, r, c) then
            black[r][c] = true
            if not isConnected(black, n) then
                black[r][c] = false
            else
                placed = placed + 1
            end
        end
    end
    return black
end

-- ---------------------------------------------------------------------------
-- Assign numbers to black cells (create "fake" duplicates)
-- ---------------------------------------------------------------------------

local function assignBlackNumbers(black, puzzle, n)
    for r = 1, n do
        for c = 1, n do
            if black[r][c] then
                local row_vals = {}
                for cc = 1, n do
                    if not black[r][cc] and puzzle[r][cc] ~= 0 then
                        row_vals[puzzle[r][cc]] = true
                    end
                end
                local col_vals = {}
                for rr = 1, n do
                    if not black[rr][c] and puzzle[rr][c] ~= 0 then
                        col_vals[puzzle[rr][c]] = true
                    end
                end
                local both = {}
                for v = 1, n do
                    if row_vals[v] and col_vals[v] then
                        both[#both + 1] = v
                    end
                end
                if #both > 0 then
                    puzzle[r][c] = both[math.random(#both)]
                else
                    local either = {}
                    for v = 1, n do
                        if row_vals[v] or col_vals[v] then
                            either[#either + 1] = v
                        end
                    end
                    if #either > 0 then
                        puzzle[r][c] = either[math.random(#either)]
                    else
                        puzzle[r][c] = math.random(n)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Uniqueness check
-- ---------------------------------------------------------------------------

-- Shading-CSP counter (up to `limit` solutions) for Hitori's rules: no
-- value twice among a row's or a column's unshaded cells, no two shaded
-- cells side by side, unshaded cells all connected. Returns
-- (solutions_found, exhausted); exhausted=true means node_budget was hit
-- before the search concluded, so the count isn't proof.
--
-- Backtracking with propagation to a fixpoint at every node; each rule
-- only forces what every solution extending the current grid shares, so
-- solutions are counted exactly:
--   - a shaded cell's neighbours are unshaded;
--   - an unshaded cell shades every other cell of its row and column
--     holding the same value;
--   - connectivity: undecided cells that can no longer reach the unshaded
--     cells (through non-shaded cells) are shaded; an undecided cell
--     whose shading would cut the unshaded cells apart is unshaded; an
--     unshaded cell already cut off is a dead end.
-- It branches on an undecided cell that still shares its value with
-- another non-shaded cell of its row or column, else on any undecided
-- cell (shading a cell isn't limited to duplicates by the rules above).
-- Cell state: 0 undecided, 1 shaded, 2 unshaded. node_budget counts search
-- nodes, so a seed gives the same verdict on every device.
-- 1.5.0: replaces a row-major backtracker that checked a row or column
-- only once complete and connectivity only at the end (up to 2.9 s per
-- 7x7 puzzle on a desktop, over a minute on an e-reader).
local function countSolutions(puzzle, n, limit, node_budget)
    local N = n * n
    local val, nbr, peers = {}, {}, {}
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        val[i] = puzzle[r][c]
        local l = {}
        if r > 1 then l[#l + 1] = i - n end
        if r < n then l[#l + 1] = i + n end
        if c > 1 then l[#l + 1] = i - 1 end
        if c < n then l[#l + 1] = i + 1 end
        nbr[i] = l
    end end
    -- peers[i]: the other cells of i's row and column with the same value
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        local p = {}
        for cc = 1, n do
            local j = (r - 1) * n + cc
            if cc ~= c and val[j] == val[i] then p[#p + 1] = j end
        end
        for rr = 1, n do
            local j = (rr - 1) * n + c
            if rr ~= r and val[j] == val[i] then p[#p + 1] = j end
        end
        peers[i] = p
    end end

    local state = {}
    for i = 1, N do state[i] = 0 end
    local trail, tn = {}, 0
    local changed = false
    local function set(i, v)
        local s = state[i]
        if s == v then return true end
        if s ~= 0 then return false end
        state[i] = v
        tn = tn + 1; trail[tn] = i
        changed = true
        return true
    end
    local function undo(mark)
        while tn > mark do state[trail[tn]] = 0; trail[tn] = nil; tn = tn - 1 end
    end

    local function localProp()
        for i = 1, N do
            local s = state[i]
            if s == 1 then
                for _, j in ipairs(nbr[i]) do
                    if not set(j, 2) then return false end
                end
            elseif s == 2 then
                for _, j in ipairs(peers[i]) do
                    if not set(j, 1) then return false end
                end
            end
        end
        return true
    end

    -- Articulation points of the non-shaded cells (Tarjan, from a white
    -- cell): an undecided cell whose DFS subtree below it holds white
    -- cells that can't get around it is the only link to them.
    local disc, low, timer, base = {}, {}, 0, 1
    for i = 1, N do disc[i] = 0 end
    local must_white = {}
    local function dfs(i, parent)
        timer = timer + 1
        disc[i], low[i] = timer, timer
        local whites = state[i] == 2 and 1 or 0
        for _, j in ipairs(nbr[i]) do
            if state[j] ~= 1 then
                if disc[j] < base then
                    local below = dfs(j, i)
                    whites = whites + below
                    if low[j] < low[i] then low[i] = low[j] end
                    if low[j] >= disc[i] and below > 0 and state[i] == 0 then
                        must_white[#must_white + 1] = i
                    end
                elseif j ~= parent and disc[j] < low[i] then
                    low[i] = disc[j]
                end
            end
        end
        return whites
    end

    local function connectProp()
        local start, whites = nil, 0
        for i = 1, N do
            if state[i] == 2 then
                whites = whites + 1
                start = start or i
            end
        end
        if not start then return true end
        base = timer + 1
        for k = #must_white, 1, -1 do must_white[k] = nil end
        if dfs(start, nil) ~= whites then return false end
        for i = 1, N do
            if state[i] == 0 and disc[i] < base then
                if not set(i, 1) then return false end
            end
        end
        for _, i in ipairs(must_white) do
            if not set(i, 2) then return false end
        end
        return true
    end

    local function propagate()
        repeat
            changed = false
            if not localProp() or not connectProp() then return false end
        until not changed
        return true
    end

    local function pick()
        local any
        for i = 1, N do
            if state[i] == 0 then
                any = any or i
                for _, j in ipairs(peers[i]) do
                    if state[j] ~= 1 then return i end
                end
            end
        end
        return any
    end

    local solutions, nodes, exhausted = 0, 0, false
    local function search()
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if not propagate() then return end
        local i = pick()
        if not i then
            solutions = solutions + 1  -- every rule holds once all is decided
            return
        end
        for v = 1, 2 do
            local mark = tn
            set(i, v)
            search()
            undo(mark)
            if solutions >= limit or exhausted then return end
        end
    end
    search()
    return solutions, exhausted, nodes
end

-- ---------------------------------------------------------------------------
-- Human-style solver (1.6.0), used to grade puzzles
-- ---------------------------------------------------------------------------

-- logicSolve(puzzle, n, max_tier) -> solved, t1_steps, t2_steps, rounds
-- Solves the shading the way a person does, never by trial and error:
--   tier 1, the basic rules a beginner applies at a glance:
--     - a number with no twin left in its row and column stays white;
--     - sandwich: in X Y X, the middle Y stays white (shading it would
--       leave both X white);
--     - pair: in A A side by side one A is white, so every other A of
--       that line is black;
--     - a black cell's neighbours are white;
--     - a white cell blackens its twins in its row and column.
--   tier 2, connectivity: an undecided cell whose shading would cut the
--     white area in two stays white (this covers the corner and edge
--     patterns).
-- Tier 2 is only used when tier 1 is stuck, one cell at a time, so
-- t2_steps counts how many times the solver needed connectivity to move
-- on. Every rule only states what all solutions share (the first one
-- holds for any unique puzzle: shading a cell with no twin would leave a
-- second solution), so finishing means the puzzle needs no guessing; the
-- generator still confirms uniqueness with countSolutions.
local nbr_cache = {}
local function neighbours(n)
    local nbr = nbr_cache[n]
    if nbr then return nbr end
    nbr = {}
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        local l = {}
        if r > 1 then l[#l + 1] = i - n end
        if r < n then l[#l + 1] = i + n end
        if c > 1 then l[#l + 1] = i - 1 end
        if c < n then l[#l + 1] = i + 1 end
        nbr[i] = l
    end end
    nbr_cache[n] = nbr
    return nbr
end

local ls_seen, ls_stack, ls_stamp = {}, {}, 0

local function logicSolve(puzzle, n, max_tier)
    local N = n * n
    local nbr = neighbours(n)
    local val, peers, state = {}, {}, {}
    for r = 1, n do
        local row = puzzle[r]
        for c = 1, n do val[(r - 1) * n + c] = row[c] end
    end
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        local v, p = val[i], {}
        for cc = 1, n do
            local j = (r - 1) * n + cc
            if cc ~= c and val[j] == v then p[#p + 1] = j end
        end
        for rr = 1, n do
            local j = (rr - 1) * n + c
            if rr ~= r and val[j] == v then p[#p + 1] = j end
        end
        peers[i] = p
        state[i] = 0
    end end

    local bad, t1, t2, rounds = false, 0, 0, 0
    local function set(i, v)
        local s = state[i]
        if s == v then return false end
        if s ~= 0 then bad = true; return false end
        state[i] = v
        return true
    end

    -- the patterns read straight off the numbers
    for r = 1, n do for c = 1, n do
        local i, v = (r - 1) * n + c, val[(r - 1) * n + c]
        if c + 2 <= n and v == val[i + 2] and set(i + 1, 2) then t1 = t1 + 1 end
        if r + 2 <= n and v == val[i + 2 * n] and set(i + n, 2) then t1 = t1 + 1 end
        if c + 1 <= n and v == val[i + 1] then
            for cc = 1, n do
                local j = (r - 1) * n + cc
                if cc ~= c and cc ~= c + 1 and val[j] == v and set(j, 1) then t1 = t1 + 1 end
            end
        end
        if r + 1 <= n and v == val[i + n] then
            for rr = 1, n do
                local j = (rr - 1) * n + c
                if rr ~= r and rr ~= r + 1 and val[j] == v and set(j, 1) then t1 = t1 + 1 end
            end
        end
    end end
    if bad then return false, t1, t2, rounds end

    -- would shading undecided cell x cut the non-black cells apart?
    local seen, stack = ls_seen, ls_stack
    local function cuts(x)
        local start, total = nil, 0
        for i = 1, N do
            if i ~= x and state[i] ~= 1 then
                total = total + 1
                start = start or i
            end
        end
        if not start then return false end
        ls_stamp = ls_stamp + 1
        local stamp = ls_stamp
        seen[start] = stamp
        stack[1] = start
        local top, count = 1, 1
        while top > 0 do
            local i = stack[top]
            top = top - 1
            local l = nbr[i]
            for k = 1, #l do
                local j = l[k]
                if j ~= x and state[j] ~= 1 and seen[j] ~= stamp then
                    seen[j] = stamp
                    count = count + 1
                    top = top + 1
                    stack[top] = j
                end
            end
        end
        return count ~= total
    end

    while true do
        rounds = rounds + 1
        local progress = false
        for i = 1, N do
            local s = state[i]
            if s == 1 then
                local l = nbr[i]
                for k = 1, #l do
                    if set(l[k], 2) then progress = true; t1 = t1 + 1 end
                end
            elseif s == 2 then
                local p = peers[i]
                for k = 1, #p do
                    if set(p[k], 1) then progress = true; t1 = t1 + 1 end
                end
            else
                local p, alone = peers[i], true
                for k = 1, #p do
                    if state[p[k]] ~= 1 then alone = false; break end
                end
                if alone and set(i, 2) then progress = true; t1 = t1 + 1 end
            end
        end
        if bad then return false, t1, t2, rounds end
        if not progress then
            if max_tier < 2 then break end
            for i = 1, N do
                if state[i] == 0 and cuts(i) then
                    set(i, 2)
                    t2 = t2 + 1
                    progress = true
                    break
                end
            end
            if not progress then break end
        end
    end
    for i = 1, N do
        if state[i] == 0 then return false, t1, t2, rounds end
    end
    return true, t1, t2, rounds
end

-- ---------------------------------------------------------------------------
-- HitoriBoard
-- ---------------------------------------------------------------------------

local HitoriBoard = {}
HitoriBoard.__index = HitoriBoard

function HitoriBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    local obj = {
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        puzzle          = emptyGrid(n),
        solution_black  = emptyBoolGrid(n),
        user            = emptyGrid(n),
        wrong_marks     = emptyBoolGrid(n),
        reveal_solution = false,
        undo            = UndoStack:new{ max_size = 200 },
    }
    setmetatable(obj, self)
    return obj
end

-- What each level asks of the solver (see logicSolve), by grid size:
-- t2_min/t2_max is how many times connectivity is needed.
--   Easy:   the basic rules alone, from start to finish.
--   Medium: connectivity a few times.
--   Hard:   connectivity again and again.
-- Never trial and error, at any level. Before 1.6.0 every level escalated
-- density until the puzzle was unique, so all three looked the same
-- (about 25% black) and up to 40% of them stalled a logical solver.
local LEVELS = {
    easy   = function(n) return { t2_min = 0, t2_max = 0 } end,
    medium = function(n) return { t2_min = 1, t2_max = 2 } end,
    hard   = function(n) return { t2_min = n >= 7 and 4 or 3, t2_max = math.huge } end,
}
HitoriBoard.LEVELS = LEVELS
-- Work caps (counts, never the clock: a seed gives the same puzzle on every
-- device, which the Daily Challenge relies on).
HitoriBoard.MAX_PATTERNS  = 40    -- fresh black patterns
HitoriBoard.CLIMB_STEPS   = 120   -- number tweaks per pattern
HitoriBoard.MAX_EVALS     = 1200  -- solver runs per generate()

-- How far a candidate is from the level: 0 = in range, larger = further;
-- a candidate the solver can't finish is the furthest of all.
local function distance(level, solved, t2)
    if not solved then return 1000 end
    if t2 < level.t2_min then return level.t2_min - t2 end
    if t2 > level.t2_max then return t2 - level.t2_max end
    return 0
end

-- Hitori shows every number from the start and the puzzle to find is a
-- shading, so whole candidates are built and graded: a random black
-- pattern (no two blacks touching, whites connected), white numbers with no
-- repeat, and for each black cell a number repeating a white of its row or
-- column. The black cells' numbers are what the solver's path depends on,
-- so they are then tweaked one at a time, keeping a tweak when it brings
-- the solver's work no further from the level's range (a hill climb). A
-- candidate in range is kept once countSolutions proves it unique.
-- The closest verified candidate is the fallback if none hits the range.
-- on_progress(fraction), optional: called after every pattern
-- (screen.lua wires it to the shared "Generating puzzle…" bar).
function HitoriBoard:generate(difficulty, on_progress)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()

    local n = self.n
    local level = (LEVELS[self.difficulty] or LEVELS.easy)(n)
    local evals = 0
    local best_black, best_puzzle, best_dist

    local function finish(black, puzzle)
        self.puzzle         = puzzle
        self.solution_black = black
        self.user           = emptyGrid(n)
        self.wrong_marks    = emptyBoolGrid(n)
    end

    -- the candidate counts only if the solver finishes it and it is unique
    local function verified(puzzle)
        local solutions, exhausted = countSolutions(puzzle, n, 2, UNIQUENESS_NODE_BUDGET)
        return solutions == 1 and not exhausted
    end

    for pattern = 1, HitoriBoard.MAX_PATTERNS do
        if evals >= HitoriBoard.MAX_EVALS and best_black then break end
        local black = generateBlackPattern(n, PATTERN_DENSITY)
        local puzzle = emptyGrid(n)
        if assignNumbers(black, n, puzzle) then
            assignBlackNumbers(black, puzzle, n)
            -- each black cell's choices: the numbers of its row's and
            -- column's white cells
            local blacks = {}
            for r = 1, n do for c = 1, n do
                if black[r][c] then
                    local opts, have = {}, {}
                    for k = 1, n do
                        local a = not black[r][k] and puzzle[r][k]
                        if a and not have[a] then have[a] = true; opts[#opts + 1] = a end
                        local b = not black[k][c] and puzzle[k][c]
                        if b and not have[b] then have[b] = true; opts[#opts + 1] = b end
                    end
                    blacks[#blacks + 1] = { r, c, opts }
                end
            end end
            local solved, _, t2 = logicSolve(puzzle, n, 2)
            evals = evals + 1
            local dist = distance(level, solved, t2)
            for step = 0, HitoriBoard.CLIMB_STEPS do
                if step > 0 then
                    if #blacks == 0 then break end
                    local b = blacks[math.random(#blacks)]
                    local r, c, opts = b[1], b[2], b[3]
                    local v, old = opts[math.random(#opts)], puzzle[b[1]][b[2]]
                    if v ~= old then
                        puzzle[r][c] = v
                        local s2, _, x2 = logicSolve(puzzle, n, 2)
                        evals = evals + 1
                        local d2 = distance(level, s2, x2)
                        if d2 <= dist then dist = d2 else puzzle[r][c] = old end
                    end
                end
                if dist < 1000 and (not best_dist or dist < best_dist) and verified(puzzle) then
                    best_dist, best_black, best_puzzle = dist, black, copyGrid(puzzle, n)
                end
                if dist == 0 and best_dist == 0 then
                    finish(best_black, best_puzzle)
                    if on_progress then on_progress(1) end
                    return
                end
                if evals >= HitoriBoard.MAX_EVALS and best_black then break end
            end
        end
        if on_progress then on_progress(pattern / HitoriBoard.MAX_PATTERNS) end
    end

    if best_black then
        -- nothing hit the level's range within the caps: the closest
        -- candidate, still proven unique and solvable without guessing
        finish(best_black, best_puzzle)
        return
    end

    -- Unreachable in practice (measured: a verified candidate within the
    -- first few patterns at every size and level): no black cells at all,
    -- a cyclic Latin square, every number already alone in its lines.
    local puzzle = emptyGrid(n)
    for r = 1, n do
        for c = 1, n do
            puzzle[r][c] = ((c - 1 + r - 1) % n) + 1
        end
    end
    finish(emptyBoolGrid(n), puzzle)
end

-- ---------------------------------------------------------------------------
-- Cell state mutation
-- ---------------------------------------------------------------------------

function HitoriBoard:setCellState(r, c, state)
    if state < 0 or state > 2 then
        return false, "invalid_state"
    end
    local prev = self.user[r][c]
    self.undo:push{ r = r, c = c, prev_state = prev }
    self.user[r][c] = state
    self.wrong_marks[r][c] = false
    return true
end

function HitoriBoard:cycleCellState(r, c)
    local cur   = self.user[r][c]
    local next  = (cur + 1) % 3
    return self:setCellState(r, c, next)
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

function HitoriBoard:canUndo()
    return self.undo:canUndo()
end

function HitoriBoard:undo()
    local entry = self.undo:pop()
    if not entry then
        return false, UndoStack.NOTHING_TO_UNDO
    end
    self.user[entry.r][entry.c]        = entry.prev_state
    self.wrong_marks[entry.r][entry.c] = false
    return true
end

-- ---------------------------------------------------------------------------
-- Progress / validation
-- ---------------------------------------------------------------------------

function HitoriBoard:checkProgress()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local u  = self.user[r][c]
            local sb = self.solution_black[r][c]
            if u == STATE_BLACK and not sb then
                self.wrong_marks[r][c] = true
            elseif u == STATE_WHITE_DOT and sb then
                self.wrong_marks[r][c] = true
            else
                self.wrong_marks[r][c] = false
            end
        end
    end
end

-- Every cell decided, and the shading keeps the three rules. The puzzle
-- has one solution, so this is the stored one; checking the rules rather
-- than comparing with it means a valid grid is never refused.
function HitoriBoard:isSolved()
    local n = self.n
    local same = true
    for r = 1, n do
        for c = 1, n do
            local u = self.user[r][c]
            if u == STATE_UNKNOWN then return false end
            if (u == STATE_BLACK) ~= (self.solution_black[r][c] and true or false) then
                same = false
            end
        end
    end
    if same then return true end
    return (self:validateRules())
end

function HitoriBoard:validateRules()
    local n = self.n
    local violations = {}

    -- Rule 1: no number repeats among white cells in any row/col
    for r = 1, n do
        local seen = {}
        for c = 1, n do
            if self.user[r][c] ~= STATE_BLACK then
                local v = self.puzzle[r][c]
                if seen[v] then
                    violations[#violations + 1] = "row_repeat:" .. r .. ":" .. v
                end
                seen[v] = true
            end
        end
    end
    for c = 1, n do
        local seen = {}
        for r = 1, n do
            if self.user[r][c] ~= STATE_BLACK then
                local v = self.puzzle[r][c]
                if seen[v] then
                    violations[#violations + 1] = "col_repeat:" .. c .. ":" .. v
                end
                seen[v] = true
            end
        end
    end

    -- Rule 2: no adjacent black cells
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == STATE_BLACK then
                if c < n and self.user[r][c + 1] == STATE_BLACK then
                    violations[#violations + 1] = "adjacent:" .. r .. ":" .. c
                end
                if r < n and self.user[r + 1][c] == STATE_BLACK then
                    violations[#violations + 1] = "adjacent:" .. r .. ":" .. c
                end
            end
        end
    end

    -- Rule 3: white cells connected
    local black_mask = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            black_mask[r][c] = (self.user[r][c] == STATE_BLACK)
        end
    end
    if not isConnected(black_mask, n) then
        violations[#violations + 1] = "disconnected"
    end

    return #violations == 0, violations
end

function HitoriBoard:getRemainingCells()
    local n     = self.n
    local count = 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == STATE_UNKNOWN then count = count + 1 end
        end
    end
    return count
end

-- ---------------------------------------------------------------------------
-- Solution reveal
-- ---------------------------------------------------------------------------

function HitoriBoard:toggleSolution()
    self.reveal_solution = not self.reveal_solution
end

function HitoriBoard:isShowingSolution()
    return self.reveal_solution
end

-- ---------------------------------------------------------------------------
-- Duplicate detection (for highlighting)
-- ---------------------------------------------------------------------------

function HitoriBoard:getDuplicateMask()
    local n    = self.n
    local mask = emptyBoolGrid(n)
    for r = 1, n do
        local seen = {}
        local dups = {}
        for c = 1, n do
            if self.user[r][c] ~= STATE_BLACK then
                local v = self.puzzle[r][c]
                if seen[v] then
                    dups[v] = true
                end
                seen[v] = true
            end
        end
        for c = 1, n do
            if self.user[r][c] ~= STATE_BLACK and dups[self.puzzle[r][c]] then
                mask[r][c] = true
            end
        end
    end
    for c = 1, n do
        local seen = {}
        local dups = {}
        for r = 1, n do
            if self.user[r][c] ~= STATE_BLACK then
                local v = self.puzzle[r][c]
                if seen[v] then
                    dups[v] = true
                end
                seen[v] = true
            end
        end
        for r = 1, n do
            if self.user[r][c] ~= STATE_BLACK and dups[self.puzzle[r][c]] then
                mask[r][c] = true
            end
        end
    end
    return mask
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

-- isSolved() requires every cell decided, so white dots are offered too, not
-- just the blacks.
Hint.install(HitoriBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c)
        return b.solution_black[r][c] and STATE_BLACK or STATE_WHITE_DOT
    end,
    isEmpty     = function(v) return v == STATE_UNKNOWN end,
    setCell     = function(b, r, c, v) return b:setCellState(r, c, v) end,
    blank       = STATE_UNKNOWN,
})

function HitoriBoard:serialize()
    local n = self.n
    local sb_out = emptyBoolGrid(n)
    local wm_out = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            sb_out[r][c] = self.solution_black[r][c] and true or false
            wm_out[r][c] = self.wrong_marks[r][c] and true or false
        end
    end
    return {
        n               = n,
        difficulty      = self.difficulty,
        puzzle          = copyGrid(self.puzzle, n),
        solution_black  = sb_out,
        user            = copyGrid(self.user, n),
        wrong_marks     = wm_out,
        reveal_solution = self.reveal_solution,
        undo            = self.undo:serialize(),
    }
end

function HitoriBoard:load(data)
    if type(data) ~= "table" or not data.puzzle or not data.solution_black then
        return false
    end
    local n = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.puzzle     = copyGrid(data.puzzle, n)
    self.user       = copyGrid(data.user or {}, n)

    self.solution_black = emptyBoolGrid(n)
    if data.solution_black then
        for r = 1, n do
            for c = 1, n do
                local v = data.solution_black[r] and data.solution_black[r][c]
                self.solution_black[r][c] = (v == true or v == 1)
            end
        end
    end

    self.wrong_marks = emptyBoolGrid(n)
    if data.wrong_marks then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong_marks[r] and data.wrong_marks[r][c]
                self.wrong_marks[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal_solution = data.reveal_solution or false
    self.undo = UndoStack:new{ max_size = 200 }
    if data.undo then self.undo:load(data.undo) end

    return true
end

HitoriBoard.STATE_UNKNOWN   = STATE_UNKNOWN
HitoriBoard.STATE_BLACK     = STATE_BLACK
HitoriBoard.STATE_WHITE_DOT = STATE_WHITE_DOT

-- exposed for the specs
HitoriBoard.countSolutions = countSolutions
HitoriBoard.logicSolve     = logicSolve

return HitoriBoard
