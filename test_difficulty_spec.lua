-- Difficulty guarantees for Hitori (see docs/dev/TESTING.md, "Difficulty
-- specs"): every size x level builds fast, is unique, is solved by the
-- game's own no-trial solver within the level's connectivity range, Easy
-- needs the basic rules only, the levels are ordered on average, and a
-- seed always gives the same puzzle without reading the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

local SIZES  = { 5, 7 }
local LEVELS = { "easy", "medium", "hard" }

-- Runs fn with os.clock/os.time/os.date counted; returns how many times
-- they were read. The play timer (game-common timer.lua, started when a new
-- round begins) is not part of the generator and is left out.
local function clockReads(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local reads = 0
    local function count()
        local src = debug.getinfo(3, "S").source
        if not src:find("timer%.lua$") then reads = reads + 1 end
    end
    os.clock = function(...) count(); return oc(...) end
    os.time  = function(...) count(); return ot(...) end
    os.date  = function(...) count(); return od(...) end
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
    return reads
end

describe("Hitori difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    -- moved from test_board_spec.lua ("uniqueness check (1.5.0)")
    it("every generated puzzle is unique, and generation is fast", function()
        for _, n in ipairs(SIZES) do
            for _, diff in ipairs(LEVELS) do
                local worst = 0
                for seed = 1, 8 do
                    math.randomseed(seed * 7919 + n)
                    local t0 = os.clock()
                    local b = Board:new{ n = n }
                    b:generate(diff)
                    worst = math.max(worst, os.clock() - t0)
                    local solutions, exhausted = Board.countSolutions(b.puzzle, n, 2, 1e6)
                    assert.is_false(exhausted)
                    assert.are.equal(1, solutions,
                        ("n=%d diff=%s seed=%d: not unique"):format(n, diff, seed))
                end
                -- ~35 ms worst on a desktop (2.9 s before 1.5.0);
                -- generous for slow CI.
                assert.is_true(worst < 1.5, ("n=%d diff=%s took %.2fs"):format(n, diff, worst))
            end
        end
    end)

    -- moved from test_board_spec.lua ("levels (1.6.0)")
    it("every level is solved without guessing, within its own range", function()
        for _, n in ipairs(SIZES) do
            local avg = {}
            for _, diff in ipairs(LEVELS) do
                local level, sum, seeds = Board.LEVELS[diff](n), 0, 12
                for seed = 1, seeds do
                    math.randomseed(seed * 104729 + n)
                    local b = Board:new{ n = n }
                    b:generate(diff)
                    local solutions, exhausted = Board.countSolutions(b.puzzle, n, 2, 1e6)
                    assert.is_false(exhausted)
                    assert.are.equal(1, solutions)
                    local ok, _, t2 = Board.logicSolve(b.puzzle, n, 2)
                    assert.is_true(ok, ("n=%d %s seed=%d needs guessing"):format(n, diff, seed))
                    assert.is_true(t2 >= level.t2_min and t2 <= level.t2_max,
                        ("n=%d %s seed=%d: %d connectivity steps"):format(n, diff, seed, t2))
                    -- Easy needs the basic rules only, the others connectivity
                    assert.are.equal(diff == "easy", (Board.logicSolve(b.puzzle, n, 1)))
                    sum = sum + t2
                end
                avg[diff] = sum / seeds
            end
            assert.is_true(avg.easy < avg.medium and avg.medium < avg.hard,
                ("n=%d: levels not distinct (%.1f %.1f %.1f)"):format(n, avg.easy, avg.medium, avg.hard))
        end
    end)

    it("the level table is ordered", function()
        for _, n in ipairs(SIZES) do
            local e, m, h = Board.LEVELS.easy(n), Board.LEVELS.medium(n), Board.LEVELS.hard(n)
            assert.is_true(e.t2_min <= m.t2_min and m.t2_min <= h.t2_min)
            assert.is_true(e.t2_max <= m.t2_max and m.t2_max <= h.t2_max)
        end
    end)

    -- moved from test_board_spec.lua ("levels (1.6.0)")
    it("the solver never guesses", function()
        -- a grid with no repeat is all white at once
        assert.is_true((Board.logicSolve({ { 1, 2, 3 }, { 2, 3, 1 }, { 3, 1, 2 } }, 3, 1)))
        -- 1 1 / 2 1 has one solution (shade the top-right 1), but only
        -- "suppose it is white, then..." finds it: the solver stops
        assert.are.equal(1, (Board.countSolutions({ { 1, 1 }, { 2, 1 } }, 2, 100, 1e6)))
        assert.is_false((Board.logicSolve({ { 1, 1 }, { 2, 1 } }, 2, 2)))
    end)

    -- moved from test_board_spec.lua ("levels (1.6.0)")
    it("a seed always gives the same puzzle", function()
        for _, diff in ipairs(LEVELS) do
            math.randomseed(77)
            local a = Board:new{ n = 7 }; a:generate(diff)
            math.randomseed(77)
            local b = Board:new{ n = 7 }; b:generate(diff)
            assert.are.same(a.puzzle, b.puzzle)
            assert.are.same(a.solution_black, b.solution_black)
        end
    end)

    it("generation never reads the clock", function()
        for _, n in ipairs(SIZES) do
            for _, diff in ipairs(LEVELS) do
                local reads = clockReads(function()
                    math.randomseed(11 + n)
                    Board:new{ n = n }:generate(diff)
                end)
                assert.are.equal(0, reads, ("n=%d %s read the clock"):format(n, diff))
            end
        end
    end)

    -- moved from test_board_spec.lua ("levels (1.6.0)")
    it("generation stays fast at every level", function()
        for _, n in ipairs(SIZES) do
            for _, diff in ipairs(LEVELS) do
                local worst = 0
                for seed = 1, 10 do
                    math.randomseed(seed)
                    local t0 = os.clock()
                    Board:new{ n = n }:generate(diff)
                    worst = math.max(worst, os.clock() - t0)
                end
                -- ~40 ms worst on a desktop (300 seeds); generous for CI
                assert.is_true(worst < 1.0, ("n=%d %s took %.2fs"):format(n, diff, worst))
            end
        end
    end)
end)
