local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine
local drawDiagonalLine = gwb.drawDiagonalLine

local HitoriBoard = require("board")

local C_BG        = Blitbuffer.COLOR_WHITE
local C_BLACK_BG  = Blitbuffer.COLOR_BLACK
local C_DUP_BG    = Blitbuffer.COLOR_GRAY_C
local C_WRONG_BG  = Blitbuffer.COLOR_GRAY_A
local C_LINE      = Blitbuffer.COLOR_BLACK
local C_NUM_DARK  = Blitbuffer.COLOR_BLACK
local C_NUM_WHITE = Blitbuffer.COLOR_WHITE
local C_NUM_GREY  = Blitbuffer.COLOR_GRAY_4
local C_DOT_RING  = Blitbuffer.COLOR_GRAY_4

-- ---------------------------------------------------------------------------
-- HitoriBoardWidget
-- ---------------------------------------------------------------------------

local HitoriBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function HitoriBoardWidget:init()
    local n   = self.board and self.board.n or 5
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function HitoriBoardWidget:onCellTap(row, col)
    if self.onCellAction then
        self.onCellAction(row, col, false)
    end
end

function HitoriBoardWidget:onCellHold(row, col)
    if self.onCellAction then
        self.onCellAction(row, col, true)
    end
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function HitoriBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local n    = self.board.n
    local cell = self.dimen.w / n

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    local dup_mask = self.board:getDuplicateMask()

    -- -----------------------------------------------------------------------
    -- Cell backgrounds
    -- -----------------------------------------------------------------------
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)

            local state = self.board.user[r][c]
            local show_sol = self.board:isShowingSolution()

            if show_sol then
                if self.board.solution_black[r][c] then
                    bb:paintRect(cx, cy, cw, ch, C_BLACK_BG)
                end
            elseif state == HitoriBoard.STATE_BLACK then
                bb:paintRect(cx, cy, cw, ch, C_BLACK_BG)
            elseif self.board.wrong_marks[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_WRONG_BG)
            elseif state == HitoriBoard.STATE_UNKNOWN and dup_mask[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_DUP_BG)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Grid lines
    -- -----------------------------------------------------------------------
    local thin  = Size.line.thin  or 1
    local thick = Size.line.thick or 2

    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_LINE)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_LINE)
    end

    -- -----------------------------------------------------------------------
    -- Cell content
    -- -----------------------------------------------------------------------
    local cell_padding = self.number_padding or 2
    local cell_inner   = math.max(1, math.floor(cell - 2 * cell_padding))

    for r = 1, n do
        for c = 1, n do
            local cx    = x + math.floor((c - 1) * cell)
            local cy    = y + math.floor((r - 1) * cell)
            local cw    = math.ceil(cell)
            local ch    = math.ceil(cell)
            local state = self.board.user[r][c]
            local v     = self.board.puzzle[r][c]
            local show_sol = self.board:isShowingSolution()

            local is_black_display = show_sol and self.board.solution_black[r][c]
                or (not show_sol and state == HitoriBoard.STATE_BLACK)

            local text  = tostring(v)
            local color = is_black_display and C_NUM_WHITE or C_NUM_DARK

            if show_sol and not self.board.solution_black[r][c] then
                color = C_NUM_GREY
            end

            local metrics  = RenderText:sizeUtf8Text(0, cell_inner, self.number_face, text, true, false)
            local text_w   = metrics.x
            local baseline = cy + cell_padding + math.floor((cell_inner + metrics.y_top - metrics.y_bottom) / 2)
            local text_x   = cx + cell_padding + math.floor((cell_inner - text_w) / 2)
            RenderText:renderUtf8Text(bb, text_x, baseline, self.number_face, text, true, false, color)

            -- White-dot ring: small circle outline in corner
            if not show_sol and state == HitoriBoard.STATE_WHITE_DOT then
                local dot_r = math.max(2, math.floor(cell * 0.12))
                local dot_x = cx + cw - dot_r - math.max(2, math.floor(cell * 0.08))
                local dot_y = cy + dot_r + math.max(2, math.floor(cell * 0.08))
                -- Draw a small filled circle then a slightly smaller inner circle to make a ring
                bb:paintCircle(dot_x, dot_y, dot_r, C_DOT_RING)
                local inner_r = math.max(0, dot_r - math.max(1, math.floor(dot_r * 0.45)))
                if inner_r > 0 then
                    bb:paintCircle(dot_x, dot_y, inner_r, C_BG)
                end
            end

            -- Wrong mark: X overlay
            if not show_sol and self.board.wrong_marks[r][c] then
                local padding   = math.max(1, math.floor(cell * 0.12))
                local diag_len  = math.max(0, math.floor(cell - padding * 2))
                local thickness = math.max(1, math.floor(cell / 18))
                drawDiagonalLine(bb, cx + padding, cy + padding,      diag_len, 1,  1, C_LINE, thickness)
                drawDiagonalLine(bb, cx + padding, cy + ch - padding, diag_len, 1, -1, C_LINE, thickness)
            end
        end
    end
end

return HitoriBoardWidget
