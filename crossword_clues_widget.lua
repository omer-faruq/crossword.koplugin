--[[
Full clues list dialog.

Shows Across clues first, then Down clues, as a scrollable Menu with items
that jump the cursor to the chosen clue when tapped.
]]--

local Device = require("device")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local Clues = {}

local function formatItem(prefix, entry, user_letters)
    local filled = 0
    for i = 1, entry.length do
        if user_letters[i] and user_letters[i] ~= "" then filled = filled + 1 end
    end
    local progress = ""
    if entry.length > 0 then
        if filled == entry.length then
            progress = " ✓"
        elseif filled > 0 then
            progress = string.format(" (%d/%d)", filled, entry.length)
        end
    end
    return string.format("%s%d. %s%s", prefix, entry.num, entry.text or "", progress)
end

local function gatherUserLetters(puzzle, entry, direction)
    local letters = {}
    for i = 0, entry.length - 1 do
        local r, c = entry.row, entry.col
        if direction == "across" then c = c + i else r = r + i end
        letters[#letters + 1] = puzzle:getUser(r, c)
    end
    return letters
end

function Clues.show(opts)
    local puzzle = opts.puzzle
    assert(puzzle, "Clues.show needs a puzzle")
    local menu -- forward declaration for callback closures below.
    local items = {}
    items[#items + 1] = {
        text = _("— ACROSS —"),
        enabled = false,
    }
    for _, entry in ipairs(puzzle.across_list) do
        local letters = gatherUserLetters(puzzle, entry, "across")
        items[#items + 1] = {
            text = formatItem("", entry, letters),
            callback = function()
                puzzle:moveToClue("across", entry.num)
                if opts.on_jump then opts.on_jump() end
                UIManager:close(menu)
            end,
        }
    end
    items[#items + 1] = {
        text = _("— DOWN —"),
        enabled = false,
    }
    for _, entry in ipairs(puzzle.down_list) do
        local letters = gatherUserLetters(puzzle, entry, "down")
        items[#items + 1] = {
            text = formatItem("", entry, letters),
            callback = function()
                puzzle:moveToClue("down", entry.num)
                if opts.on_jump then opts.on_jump() end
                UIManager:close(menu)
            end,
        }
    end

    menu = Menu:new{
        title = T(_("Clues — %1"), puzzle.title ~= "" and puzzle.title or _("Crossword")),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
        is_enable_shortcut = false,
    }
    UIManager:show(menu)
end

return Clues
