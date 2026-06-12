--[[
Crossword game screen.

Combines the grid widget, a live clue banner, the letter keyboard, and a
small top toolbar into a full-screen playable view.
]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local T = require("ffi/util").template

local CluesWidget = require("crossword_clues_widget")
local GridWidget = require("crossword_grid_widget")
local Keyboard = require("crossword_keyboard")

local Screen = Device.screen

-- A tappable clue banner. Shows the (possibly truncated) clue text and, when
-- tapped, calls on_tap so the caller can surface the full, untruncated clue in
-- a popup. Kept self-contained so it can be rebuilt on refresh like the plain
-- TextBoxWidget it replaces.
local ClueBar = InputContainer:extend{
    text = "",
    face = nil,
    bar_width = nil,
    bar_height = nil,
    on_tap = nil,
}

function ClueBar:init()
    self.text_widget = TextBoxWidget:new{
        text = self.text,
        face = self.face,
        width = self.bar_width,
        height = self.bar_height,
        alignment = "center",
    }
    self[1] = self.text_widget
    self.dimen = Geom:new{ x = 0, y = 0, w = self.bar_width, h = self.bar_height }
    if Device:isTouchDevice() then
        self.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = function() return self.dimen end,
                },
            },
        }
    end
end

function ClueBar:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    InputContainer.paintTo(self, bb, x, y)
end

function ClueBar:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

function ClueBar:free()
    if self.text_widget then self.text_widget:free() end
end

local GameScreen = InputContainer:extend{
    puzzle = nil,
    plugin = nil,
}

function GameScreen:init()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    -- Build widgets in a specific order so we can measure keyboard height
    -- before sizing the grid. The keyboard dominates the bottom region, the
    -- clue line sits just above it, the grid fills the remainder at top.
    self.clue_face = Font:getFace("infofont")
    -- Reserve vertical space for up to two wrapped lines of clue text so a
    -- long clue never collides with the keyboard.
    self.clue_height = math.floor(self.clue_face.size * 2.6)

    self.clue_widget = self:buildClueWidget()

    -- Bottom band sizing. The d-pad takes a fixed slice of the right edge and
    -- the keyboard expands to fill all the remaining width, so it no longer sits
    -- shrunk-and-centered with empty side margins. shrink_unneeded_width is off
    -- for the keyboard so it actually grows its keys to the given width.
    local gap = Size.span.horizontal_default
    local dpad_w = math.floor(screen_w * 0.24)
    self.dpad = self:buildDpad(dpad_w)
    local dpad_h = self.dpad:getSize().h

    self.keyboard = Keyboard.build{
        puzzle = self.puzzle,
        width = screen_w - dpad_w - gap,
        shrink_unneeded_width = false,
        on_letter = function(letter) self:onLetter(letter) end,
        on_erase = function() self:onErase() end,
        on_prev = function() self:onPrevClue() end,
        on_next = function() self:onNextClue() end,
        on_dir = function() self:onToggleDirection() end,
    }
    local keyboard_h = self.keyboard:getSize().h

    -- Toolbar row.
    self.top_buttons = ButtonTable:new{
        width = math.floor(screen_w * 0.95),
        shrink_unneeded_width = true,
        buttons = {
            {
                {
                    text = _("☰ Menu"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() self:openMenu() end,
                },
                {
                    text = _("Clues"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() self:showClues() end,
                },
                {
                    text = _("Check"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() self:checkWord() end,
                },
                {
                    text = _("Close"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        self:onClose()
                        UIManager:close(self)
                        UIManager:setDirty(nil, "full")
                    end,
                },
            },
        },
    }
    local toolbar_h = self.top_buttons:getSize().h

    -- The d-pad is shorter than the keyboard, so the band is as tall as the
    -- keyboard and the d-pad costs no extra vertical space.
    local bottom_h = math.max(keyboard_h, dpad_h)

    -- Grid takes whatever height remains minus padding spans.
    local reserved = toolbar_h + self.clue_height + bottom_h
                   + 5 * Size.span.vertical_default
    local grid_max_h = screen_h - reserved
    local grid_size = math.min(screen_w - 40, grid_max_h)
    if grid_size < 160 then grid_size = 160 end -- safety minimum

    self.grid_widget = GridWidget:new{
        puzzle = self.puzzle,
        size = grid_size,
        on_tap = function(row, col, is_same)
            if is_same then
                self.puzzle:toggleDirection()
            else
                self.puzzle:setCursor(row, col)
            end
            self:onCursorChanged()
        end,
    }

    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function GameScreen:buildClueText()
    local word = self.puzzle:currentWord()
    if not word then
        return _("No clue selected.")
    end
    -- Always show the clue for the word under the cursor, regardless of which
    -- cell within the word is focused. currentWord() resolves the number from
    -- the word's first cell, so the displayed number is always the right one
    -- for the highlighted word.
    local dir_label = (word.direction == "across") and _("Across") or _("Down")
    local clue = word.clue
    if clue == nil or clue == "" then clue = _("(no clue)") end
    local filled = 0
    for _, cell in ipairs(word.cells) do
        if self.puzzle:getUser(cell.row, cell.col) ~= "" then filled = filled + 1 end
    end
    return T(_("%1 %2 — %3 (%4/%5)"), dir_label, word.num, clue, filled, #word.cells)
end

-- Full, untruncated clue text for the popup shown when the banner is tapped.
function GameScreen:currentClueFull()
    local word = self.puzzle:currentWord()
    if not word then
        return _("No clue selected.")
    end
    local dir_label = (word.direction == "across") and _("Across") or _("Down")
    local clue = word.clue
    if clue == nil or clue == "" then clue = _("(no clue)") end
    return T(_("%1 %2 — %3"), dir_label, word.num, clue)
end

function GameScreen:showFullClue()
    UIManager:show(InfoMessage:new{ text = self:currentClueFull() })
end

function GameScreen:buildClueWidget()
    return ClueBar:new{
        text = self:buildClueText(),
        face = self.clue_face,
        bar_width = math.floor(Screen:getWidth() * 0.92),
        bar_height = self.clue_height,
        on_tap = function() self:showFullClue() end,
    }
end

-- A compact directional pad laid out as a cross of four arrows that step the
-- cursor one cell, skipping black squares. The center is intentionally blank:
-- direction toggling lives on the keyboard's ⇄ Dir button (and tapping the
-- current cell), so the pad stays a pure navigation control.
function GameScreen:buildDpad(width)
    local function arrow(label, on_press)
        return {
            text = label,
            background = Blitbuffer.COLOR_WHITE,
            callback = on_press,
        }
    end
    local function blank()
        return {
            text = " ",
            background = Blitbuffer.COLOR_WHITE,
            enabled = false,
            callback = function() end,
        }
    end
    return ButtonTable:new{
        width = width or math.floor(Screen:getWidth() * 0.26),
        buttons = {
            { blank(), arrow("▲", function() self:onMove("up") end), blank() },
            {
                arrow("◀", function() self:onMove("left") end),
                blank(),
                arrow("▶", function() self:onMove("right") end),
            },
            { blank(), arrow("▼", function() self:onMove("down") end), blank() },
        },
    }
end

function GameScreen:onMove(direction)
    if self.puzzle:moveCursorDir(direction) then
        self:onCursorChanged()
    end
end

function GameScreen:buildLayout()
    local grid_frame = FrameContainer:new{
        padding = Size.padding.small,
        margin = 0,
        self.grid_widget,
    }

    -- Top half: toolbar + grid + clue, stacked from the top.
    local top_stack = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.top_buttons,
        VerticalSpan:new{ width = Size.span.vertical_default },
        grid_frame,
        VerticalSpan:new{ width = Size.span.vertical_default },
        self.clue_widget,
    }
    -- Kept around so refresh() can swap in a freshly-built clue widget.
    self.top_stack = top_stack

    -- Bottom band: keyboard on the left, d-pad on its right, the pair centered
    -- horizontally. align="center" vertically centers the shorter d-pad against
    -- the taller keyboard.
    local bottom_band = HorizontalGroup:new{
        align = "center",
        self.keyboard,
        HorizontalSpan:new{ width = Size.span.horizontal_default },
        self.dpad,
    }

    -- Pin the band to the bottom edge of the screen so it never overlaps the
    -- clue line, even if the clue wraps to two lines.
    local bottom_pin = BottomContainer:new{
        dimen = self.dimen:copy(),
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = bottom_band:getSize().h },
            bottom_band,
        },
    }

    -- OverlapGroup places each child at its own top-left: top_stack naturally
    -- anchors to the top of the screen; bottom_pin (a BottomContainer sized
    -- to the full screen) anchors the keyboard/d-pad band to the bottom.
    self.layout = OverlapGroup:new{
        dimen = self.dimen:copy(),
        top_stack,
        bottom_pin,
    }
    self[1] = self.layout
end

function GameScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    self.layout:paintTo(bb, x, y)
end

function GameScreen:refresh()
    local new_text = self:buildClueText()
    if new_text ~= self.clue_widget.text then
        -- Reusing the existing widget via setText() leaves the banner blank on
        -- some setups (internal render state survives the content swap
        -- incorrectly), even though the new text is computed correctly.
        -- Building a fresh widget -- exactly what happens when the screen is
        -- closed and reopened, where the banner does render correctly --
        -- sidesteps that stale state entirely.
        local old_clue_widget = self.clue_widget
        local new_clue_widget = self:buildClueWidget()
        for i, w in ipairs(self.top_stack) do
            if w == old_clue_widget then
                self.top_stack[i] = new_clue_widget
                break
            end
        end
        self.clue_widget = new_clue_widget
        self.top_stack:resetLayout()
        old_clue_widget:free()
    end
    self.grid_widget:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function GameScreen:onCursorChanged()
    self:save()
    self:refresh()
end

function GameScreen:save()
    if self.plugin and self.plugin.saveCurrent then
        self.plugin:saveCurrent(self.puzzle)
    end
end

function GameScreen:onLetter(letter)
    local r, c = self.puzzle:getCursor()
    if self.puzzle:isBlack(r, c) then return end
    self.puzzle:setLetter(r, c, letter)
    if not self.puzzle:advanceInWord() then
        -- If already at end of word, optionally advance to next word.
        self.puzzle:nextClue()
    end
    self:save()
    self:refresh()
    if self.puzzle:isSolved() then
        self:onSolved()
    end
end

function GameScreen:onErase()
    local r, c = self.puzzle:getCursor()
    self.puzzle:clearCell(r, c)
    -- Move one cell back within the word for typewriter-style erase.
    self.puzzle:retreat()
    self:save()
    self:refresh()
end

function GameScreen:onPrevClue()
    self.puzzle:prevClue()
    self:save()
    self:refresh()
end

function GameScreen:onNextClue()
    self.puzzle:nextClue()
    self:save()
    self:refresh()
end

function GameScreen:onToggleDirection()
    self.puzzle:toggleDirection()
    self:save()
    self:refresh()
end

function GameScreen:showClues()
    CluesWidget.show{
        puzzle = self.puzzle,
        on_jump = function() self:onCursorChanged() end,
    }
end

function GameScreen:checkWord()
    local correct, total = self.puzzle:checkWord()
    self:save()
    self:refresh()
    UIManager:show(InfoMessage:new{
        text = T(_("Word: %1/%2 correct"), correct, total),
        timeout = 2,
    })
end

function GameScreen:openMenu()
    local dialog
    local function close() UIManager:close(dialog) end
    dialog = ButtonDialog:new{
        title = _("Crossword"),
        buttons = {
            {
                {
                    text = _("Check word"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() close(); self:checkWord() end,
                },
                {
                    text = _("Check puzzle"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        close()
                        local correct, total = self.puzzle:checkAllFilled()
                        self:save()
                        self:refresh()
                        
                        if total == 0 then
                            UIManager:show(InfoMessage:new{
                                text = _("No letters filled yet."),
                                timeout = 2,
                            })
                        elseif correct == total and self.puzzle:isSolved() then
                            UIManager:show(InfoMessage:new{
                                text = _("Congratulations! Puzzle completed successfully!"),
                                timeout = 4,
                            })
                        elseif correct == total then
                            UIManager:show(InfoMessage:new{
                                text = T(_("All filled letters correct! (%1/%1)"), total),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("Filled letters: %1/%2 correct"), correct, total),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
            {
                {
                    text = _("Reveal letter"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        close()
                        local r, c = self.puzzle:getCursor()
                        self.puzzle:revealCell(r, c)
                        self:save(); self:refresh()
                    end,
                },
                {
                    text = _("Reveal word"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        close()
                        self.puzzle:revealWord()
                        self:save(); self:refresh()
                    end,
                },
                {
                    text = _("Reveal all"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        close()
                        UIManager:show(ConfirmBox:new{
                            text = _("Reveal every letter? This ends the puzzle."),
                            ok_text = _("Reveal"),
                            ok_callback = function()
                                self.puzzle:revealAll()
                                self:save(); self:refresh()
                            end,
                        })
                    end,
                },
            },
            {
                {
                    text = _("Reset puzzle"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        close()
                        UIManager:show(ConfirmBox:new{
                            text = _("Clear all your answers?"),
                            ok_text = _("Reset"),
                            ok_callback = function()
                                self.puzzle:resetUser()
                                self.puzzle:ensureCursorOnWhite()
                                self:save(); self:refresh()
                            end,
                        })
                    end,
                },
                {
                    text = _("Info"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function()
                        close()
                        local lines = {}
                        if self.puzzle.title ~= "" then lines[#lines+1] = T(_("Title: %1"), self.puzzle.title) end
                        if self.puzzle.author ~= "" then lines[#lines+1] = T(_("Author: %1"), self.puzzle.author) end
                        if self.puzzle.copyright ~= "" then lines[#lines+1] = T(_("Copyright: %1"), self.puzzle.copyright) end
                        local filled, total = self.puzzle:progress()
                        lines[#lines+1] = T(_("Progress: %1/%2 cells"), filled, total)
                        if self.puzzle.notes and self.puzzle.notes ~= "" then
                            lines[#lines+1] = ""
                            lines[#lines+1] = self.puzzle.notes
                        end
                        UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = close,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function GameScreen:onSolved()
    UIManager:show(InfoMessage:new{
        text = _("Congratulations! Puzzle completed successfully!"),
        timeout = 4,
    })
    if self.plugin and self.plugin.onPuzzleSolved then
        self.plugin:onPuzzleSolved(self.puzzle)
    end
end

function GameScreen:onClose()
    self:save()
    if self.plugin and self.plugin.onScreenClosed then
        self.plugin:onScreenClosed()
    end
end

return GameScreen
