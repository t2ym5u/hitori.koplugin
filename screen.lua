local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase         = require("screen_base")
local MenuHelper         = require("menu_helper")
local HitoriBoard        = lrequire("board")
local HitoriBoardWidget  = lrequire("board_widget")

local DeviceScreen = Device.screen

local GRID_SIZES = { 5, 7 }

-- ---------------------------------------------------------------------------
-- HitoriScreen
-- ---------------------------------------------------------------------------

local GAME_RULES_EN = _([[
Hitori — Rules

Shade some cells black so that the remaining white cells satisfy three rules:

1. No row or column contains the same number more than once among white cells.
2. No two black cells touch each other orthogonally (diagonal touching is allowed).
3. All white cells form one single orthogonally connected group.

Tap a cell to shade it black. Tap again to unshade. The puzzle is solved when all three rules are met.
]])

local GAME_RULES_FR = [[
Hitori — Règles

Noircissez certaines cases de façon à ce que les cases blanches restantes satisfassent trois règles :

1. Aucune ligne ou colonne ne contient le même chiffre plus d'une fois parmi les cases blanches.
2. Deux cases noires ne peuvent pas se toucher orthogonalement (le contact en diagonale est autorisé).
3. Toutes les cases blanches forment un seul groupe orthogonalement connecté.

Appuyez sur une case pour la noircir. Appuyez à nouveau pour la dénoircir.
]]

local HitoriScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function HitoriScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 5)
    self.board  = HitoriBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.last_check_result = nil
    ScreenBase.init(self)
end

function HitoriScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function HitoriScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = HitoriBoardWidget:new{
        board        = self.board,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("New game"),  callback = function() self:onNewGame() end },
                { id = "grid_button",    text = self:getGridButtonText(),
                  callback = function() self:openGridMenu() end },
                { id = "diff_button",    text = self:getDiffButtonText(),
                  callback = function() self:openDifficultyMenu() end },
                { id = "reveal_button",  text = self:getRevealButtonText(),
                  callback = function() self:toggleSolution() end },
                self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
                self:makeCloseButtonConfig(),
            },
        },
    }
    self.grid_button   = top_buttons:getButtonById("grid_button")
    self.diff_button   = top_buttons:getButtonById("diff_button")
    self.reveal_button = top_buttons:getButtonById("reveal_button")

    local bottom_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {
            {
                { text = _("Check"),  callback = function() self:onCheck() end },
                { id = "undo_button", text = _("Undo"),
                  callback = function() self:onUndo() end },
                { text = _("Rules"),  callback = function() self:showRulesHint() end },
            },
        },
    }
    self.undo_button = bottom_buttons:getButtonById("undo_button")
    self:_updateUndoButton()

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
        }
        self.layout = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
            bottom_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Cell interaction
-- ---------------------------------------------------------------------------

function HitoriScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() then return end
    if is_hold then
        self.board:setCellState(r, c, HitoriBoard.STATE_UNKNOWN)
    else
        self.board:cycleCellState(r, c)
    end
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! Puzzle solved."))
    else
        self:updateStatus()
    end
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function HitoriScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", 5)
    self.board = HitoriBoard:new{ n = n }
    self.board:generate(diff)
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function HitoriScreen:onUndo()
    local ok, msg = self.board:undo()
    if ok then
        self.last_check_result = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
end

function HitoriScreen:onCheck()
    self.board:checkProgress()
    local ok, violations = self.board:validateRules()
    self.last_check_result = ok
    self.board_widget:refresh()
    if ok then
        if self.board:isSolved() then
            self:updateStatus(_("Congratulations! Puzzle solved."))
        else
            self:updateStatus(_("No violations found so far."))
        end
    else
        local n_v = #violations
        self:updateStatus(T(_("Check: %1 violation(s) found."), n_v))
    end
end

function HitoriScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

function HitoriScreen:showRulesHint()
    self:showMessage(_(
        "1. No number repeats in any row or column (among non-black cells).\n" ..
        "2. No two black cells may touch orthogonally.\n" ..
        "3. All non-black cells must form one connected region.\n\n" ..
        "Tap: cycle Unknown → Black → White-dot → Unknown\n" ..
        "Hold: reset to Unknown"
    ), 8)
end

-- ---------------------------------------------------------------------------
-- Grid size menu
-- ---------------------------------------------------------------------------

function HitoriScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes + 1] = {
            id   = sz,
            text = sz .. "\xC3\x97" .. sz,
        }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 5),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Difficulty menu
-- ---------------------------------------------------------------------------

function HitoriScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function HitoriScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = _("Congratulations! Puzzle solved.")
    else
        local remaining = self.board:getRemainingCells()
        local diff      = self.plugin:getSetting("difficulty", "easy")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3 \xC2\xB7 Unknown: %4"),
            self.board.n, self.board.n, label, remaining)
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function HitoriScreen:getGridButtonText()
    return T(_("Grid: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function HitoriScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Diff: %1"), label)
end

function HitoriScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide result") or _("Show result")
end

function HitoriScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return HitoriScreen
