local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("HitoriBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local B_UNKNOWN   = 0
    local B_BLACK     = 1
    local B_WHITE_DOT = 2

    local function newBoard(n)
        math.randomseed(42)
        local b = Board:new({ n = n or 5 })
        b:generate("easy")
        return b
    end

    describe("construction and generate", function()
        it("creates an n×n puzzle grid", function()
            local b = newBoard(5)
            assert.are.equal(5, b.n)
            assert.are.equal(5, #b.puzzle)
            assert.are.equal(5, #b.puzzle[1])
        end)

        it("all user cells start as STATE_UNKNOWN", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    assert.are.equal(B_UNKNOWN, b.user[r][c])
                end
            end
        end)

        it("solution_black has at least one black cell", function()
            local b = newBoard(7)
            local n = b.n
            local count = 0
            for r = 1, n do
                for c = 1, n do
                    if b.solution_black[r][c] then count = count + 1 end
                end
            end
            assert.is_true(count > 0, "expected at least one black cell in solution")
        end)
    end)

    describe("setCellState / cycleCellState", function()
        it("setCellState sets the user state", function()
            local b = newBoard(5)
            local ok = b:setCellState(1, 1, B_BLACK)
            assert.is_true(ok)
            assert.are.equal(B_BLACK, b.user[1][1])
        end)

        it("setCellState rejects invalid state", function()
            local b = newBoard(5)
            local ok, err = b:setCellState(1, 1, 5)
            assert.is_false(ok)
            assert.are.equal("invalid_state", err)
        end)

        it("cycleCellState advances 0→1→2→0", function()
            local b = newBoard(5)
            assert.are.equal(B_UNKNOWN, b.user[2][2])
            b:cycleCellState(2, 2)
            assert.are.equal(B_BLACK, b.user[2][2])
            b:cycleCellState(2, 2)
            assert.are.equal(B_WHITE_DOT, b.user[2][2])
            b:cycleCellState(2, 2)
            assert.are.equal(B_UNKNOWN, b.user[2][2])
        end)
    end)

    describe("undo", function()
        it("canUndo is false on a fresh board", function()
            local b = newBoard(5)
            assert.is_false(b:canUndo())
        end)

        it("restores previous state after setCellState", function()
            local b = newBoard(5)
            b:setCellState(1, 1, B_BLACK)
            assert.is_true(b:canUndo())
            Board.undo(b)  -- b.undo field (UndoStack) shadows the :undo() method
            assert.are.equal(B_UNKNOWN, b.user[1][1])
            assert.is_false(b:canUndo())
        end)

        it("undo returns false when nothing to undo", function()
            local b = newBoard(5)
            local ok = Board.undo(b)
            assert.is_false(ok)
        end)
    end)

    describe("validateRules", function()
        it("no adjacent black cells in the user state", function()
            -- Place two adjacent blacks and check rule detects it
            local b = newBoard(5)
            b.user[1][1] = B_BLACK
            b.user[1][2] = B_BLACK
            local valid, violations = b:validateRules()
            assert.is_false(valid)
            local found = false
            for _, v in ipairs(violations) do
                if v:match("^adjacent:") then found = true end
            end
            assert.is_true(found)
        end)

        it("duplicate values in white rows are detected", function()
            -- Build a tiny board manually: puzzle row has duplicate, no cell marked black
            local b = Board:new({ n = 3 })
            b.puzzle = {
                {1, 1, 2},
                {2, 3, 1},
                {3, 2, 3},
            }
            b.solution_black = {
                {false, true,  false},
                {false, false, false},
                {false, false, true},
            }
            b.user = {
                {B_UNKNOWN, B_UNKNOWN, B_UNKNOWN},
                {B_UNKNOWN, B_UNKNOWN, B_UNKNOWN},
                {B_UNKNOWN, B_UNKNOWN, B_UNKNOWN},
            }
            -- Row 1: both col 1 and 2 show "1" (not black) → duplicate
            local valid, violations = b:validateRules()
            assert.is_false(valid)
            local found = false
            for _, v in ipairs(violations) do
                if v:match("^row_repeat:") then found = true end
            end
            assert.is_true(found)
        end)
    end)

    describe("isSolved", function()
        it("returns false for an untouched board", function()
            local b = newBoard(5)
            assert.is_false(b:isSolved())
        end)

        it("returns true when user matches solution exactly", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b.solution_black[r][c] then
                        b.user[r][c] = B_BLACK
                    else
                        b.user[r][c] = B_WHITE_DOT
                    end
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("getDuplicateMask", function()
        it("marks cells that share a value in a row", function()
            local b = Board:new({ n = 3 })
            b.puzzle = {
                {1, 1, 2},
                {2, 3, 1},
                {3, 2, 3},
            }
            b.solution_black = {
                {false, false, false},
                {false, false, false},
                {false, false, false},
            }
            b.user = {
                {B_UNKNOWN, B_UNKNOWN, B_UNKNOWN},
                {B_UNKNOWN, B_UNKNOWN, B_UNKNOWN},
                {B_UNKNOWN, B_UNKNOWN, B_UNKNOWN},
            }
            local mask = b:getDuplicateMask()
            assert.is_true(mask[1][1])
            assert.is_true(mask[1][2])
            assert.is_not_true(mask[1][3])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips board state", function()
            local b = newBoard(5)
            b:setCellState(1, 1, B_BLACK)
            b:setCellState(2, 2, B_WHITE_DOT)
            local data = b:serialize()

            local b2 = Board:new({ n = 5 })
            local ok = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(B_BLACK,     b2.user[1][1])
            assert.are.equal(B_WHITE_DOT, b2.user[2][2])
            assert.are.equal(b.n, b2.n)
        end)

        it("load returns false for invalid data", function()
            local b = newBoard(5)
            assert.is_false(b:load(nil))
            assert.is_false(b:load({ puzzle = {} }))
        end)
    end)
end)
