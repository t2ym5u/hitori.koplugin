local UndoStack  = require("undo_stack")
local grid_utils = require("grid_utils")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid
local shuffle       = grid_utils.shuffle

local STATE_UNKNOWN   = 0
local STATE_BLACK     = 1
local STATE_WHITE_DOT = 2

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

local DENSITY = { easy = 0.15, medium = 0.22, hard = 0.28 }

-- How far generation is allowed to escalate density before giving up on
-- proving uniqueness (see countSolutions below). Verified empirically: at
-- the nominal easy/medium densities a puzzle is essentially *never* unique
-- (0% in independent 60-trial samples at n=5/7), but success climbs
-- sharply once density crosses ~0.30 (75-90%+). Escalating is a deliberate
-- correctness-over-nominal-density tradeoff, same precedent as hidato/
-- numbrix's given-count drift (see docs/generator_robustness_audit.md).
local MAX_DENSITY          = 0.5
local DENSITY_STEP         = 0.04
local ATTEMPTS_PER_DENSITY = 25
local UNIQUENESS_NODE_BUDGET = 300000

-- ---------------------------------------------------------------------------
-- Connectivity check (DFS over non-black cells)
-- ---------------------------------------------------------------------------

local function isConnected(black, n)
    local start_r, start_c
    for r = 1, n do
        for c = 1, n do
            if not black[r][c] then
                start_r, start_c = r, c
                break
            end
        end
        if start_r then break end
    end
    if not start_r then return true end

    local visited = {}
    for r = 1, n do visited[r] = {} end
    local stack = { { start_r, start_c } }
    visited[start_r][start_c] = true
    local count = 1
    while #stack > 0 do
        local cell = table.remove(stack)
        local r, c = cell[1], cell[2]
        for _, d in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                and not black[nr][nc] and not visited[nr][nc] then
                visited[nr][nc] = true
                count = count + 1
                stack[#stack + 1] = { nr, nc }
            end
        end
    end
    local total_white = 0
    for r = 1, n do
        for c = 1, n do
            if not black[r][c] then total_white = total_white + 1 end
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

-- Shading-CSP counter (up to `limit` solutions): for each cell (processed
-- row-major), decide shaded/unshaded, pruning on (a) no 2 adjacent shaded,
-- (b) no duplicate value left unshaded in a completed row, (c) same for
-- completed columns, (d) full connectivity of unshaded cells, checked once
-- the grid is fully decided. Returns (solutions_found, exhausted);
-- exhausted=true means node_budget was hit before the search concluded, so
-- the count isn't proof. Mirrors sudokukiller.koplugin/board.lua's
-- countCageSolutions.
local function countSolutions(puzzle, n, limit, node_budget)
    local shaded = {}
    for r = 1, n do shaded[r] = {} end
    local solutions, nodes, exhausted = 0, 0, false

    local function rowComplete(r) for c = 1, n do if shaded[r][c] == nil then return false end end return true end
    local function colComplete(c) for r = 1, n do if shaded[r][c] == nil then return false end end return true end

    local function checkRow(r)
        local seen = {}
        for c = 1, n do
            if not shaded[r][c] then
                local v = puzzle[r][c]
                if seen[v] then return false end
                seen[v] = true
            end
        end
        return true
    end
    local function checkCol(c)
        local seen = {}
        for r = 1, n do
            if not shaded[r][c] then
                local v = puzzle[r][c]
                if seen[v] then return false end
                seen[v] = true
            end
        end
        return true
    end

    local function isFullyConnected()
        local start_r, start_c, total_unshaded = nil, nil, 0
        for r = 1, n do for c = 1, n do
            if not shaded[r][c] then
                total_unshaded = total_unshaded + 1
                if not start_r then start_r, start_c = r, c end
            end
        end end
        if total_unshaded == 0 then return true end
        local visited = {}
        for r = 1, n do visited[r] = {} end
        local stack = { { start_r, start_c } }
        visited[start_r][start_c] = true
        local count = 1
        local dirs = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
        while #stack > 0 do
            local cur = table.remove(stack)
            for _, d in ipairs(dirs) do
                local nr, nc = cur[1] + d[1], cur[2] + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and not shaded[nr][nc] and not visited[nr][nc] then
                    visited[nr][nc] = true
                    count = count + 1
                    stack[#stack + 1] = { nr, nc }
                end
            end
        end
        return count == total_unshaded
    end

    local cells = {}
    for r = 1, n do for c = 1, n do cells[#cells + 1] = { r = r, c = c } end end

    local function search(idx)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if idx > #cells then
            if isFullyConnected() then solutions = solutions + 1 end
            return
        end
        local cell = cells[idx]
        local r, c = cell.r, cell.c
        for _, choice in ipairs({ false, true }) do
            local ok = true
            if choice then
                if (r > 1 and shaded[r - 1][c]) or (c > 1 and shaded[r][c - 1]) then ok = false end
            end
            if ok then
                shaded[r][c] = choice
                if rowComplete(r) and not checkRow(r) then ok = false end
                if ok and colComplete(c) and not checkCol(c) then ok = false end
                if ok then search(idx + 1) end
                shaded[r][c] = nil
            end
            if solutions >= limit or exhausted then return end
        end
    end
    search(1)
    return solutions, exhausted
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

-- Hitori has no "reveal a subset of cells" mechanic to dig -- every number
-- is visible from the start, and the puzzle to find is a *shading*. So
-- unlike the other Tier 2 fixes (dig cells one at a time from a fully
-- revealed state), this verifies whole candidate puzzles and retries: at
-- the nominal per-difficulty density a puzzle is essentially never unique
-- (0% in independent samples), but success climbs sharply once density
-- crosses ~0.30 (75-90%+) -- see the MAX_DENSITY/DENSITY_STEP comment
-- above. So this escalates density in bounded steps, trying several random
-- black-patterns + number-assignments per step, until one is proven
-- unique.
function HitoriBoard:generate(difficulty)
    self.difficulty     = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()

    local n = self.n
    local base_density = DENSITY[self.difficulty] or DENSITY.easy

    local best_black, best_puzzle
    local density = base_density
    while density <= MAX_DENSITY do
        for _attempt = 1, ATTEMPTS_PER_DENSITY do
            local black = generateBlackPattern(n, density)
            local puzzle = emptyGrid(n)
            if assignNumbers(black, n, puzzle) then
                assignBlackNumbers(black, puzzle, n)
                if not best_black then best_black, best_puzzle = black, puzzle end
                local solutions, exhausted = countSolutions(puzzle, n, 2, UNIQUENESS_NODE_BUDGET)
                if not exhausted and solutions == 1 then
                    self.puzzle         = puzzle
                    self.solution_black = black
                    self.user           = emptyGrid(n)
                    self.wrong_marks    = emptyBoolGrid(n)
                    return
                end
            end
        end
        density = density + DENSITY_STEP
    end

    if best_black then
        -- Every attempt's uniqueness came back ambiguous/inconclusive
        -- (should be rare given the density escalation above) -- prefer a
        -- real, structurally valid puzzle over a degenerate fallback, same
        -- precedent as sudokukiller/kakuro's graceful-degradation tiers.
        self.puzzle         = best_puzzle
        self.solution_black = best_black
        self.user            = emptyGrid(n)
        self.wrong_marks     = emptyBoolGrid(n)
        return
    end

    -- Fallback: no black cells at all, a cyclic Latin square so every row
    -- and column is already free of duplicates (unlike a flat `c` for
    -- every row, which would make every column constant and violate
    -- Hitori's own rules) -- only reached if assignNumbers failed on every
    -- single attempt above, which shouldn't happen in practice.
    local puzzle = emptyGrid(n)
    for r = 1, n do
        for c = 1, n do
            puzzle[r][c] = ((c - 1 + r - 1) % n) + 1
        end
    end
    self.puzzle         = puzzle
    self.solution_black = emptyBoolGrid(n)
    self.user           = emptyGrid(n)
    self.wrong_marks    = emptyBoolGrid(n)
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

function HitoriBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local u  = self.user[r][c]
            local sb = self.solution_black[r][c]
            if u == STATE_UNKNOWN then return false end
            if u == STATE_BLACK and not sb then return false end
            if u == STATE_WHITE_DOT and sb then return false end
        end
    end
    return true
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

return HitoriBoard
