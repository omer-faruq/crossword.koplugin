--[[
On-screen letter keyboard for the crossword game.

Builds a ButtonTable with 3 letter rows plus an action row (prev/erase/next).
The letter set is derived from the puzzle's solution so that puzzles in any
language automatically get the right extra characters beyond standard QWERTY.

Public API:
    CrosswordKeyboard.build({
        puzzle      = Puzzle instance,
        width       = total pixel width,
        on_letter   = function(letter),
        on_erase    = function(),
        on_prev     = function(),
        on_next     = function(),
        on_dir      = function(),
    }) -> ButtonTable widget
]]--

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local _ = require("gettext")

local DEFAULT_LAYOUT = {
    { "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" },
    { "A", "S", "D", "F", "G", "H", "J", "K", "L" },
    { "Z", "X", "C", "V", "B", "N", "M" },
}

local Keyboard = {}

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function deriveLayoutFromPuzzle(puzzle)
    local alphabet = puzzle:alphabet()
    local default_flat = {}
    for _, row in ipairs(DEFAULT_LAYOUT) do
        for _, letter in ipairs(row) do
            default_flat[#default_flat + 1] = letter
        end
    end

    local extras = {}
    local seen_extras = {}
    
    for _, letter in ipairs(alphabet) do
        if not contains(default_flat, letter) and not seen_extras[letter] then
            extras[#extras + 1] = letter
            seen_extras[letter] = true
        end
    end

    local layout = {}
    for _, row in ipairs(DEFAULT_LAYOUT) do
        local copy = {}
        for _, letter in ipairs(row) do copy[#copy + 1] = letter end
        layout[#layout + 1] = copy
    end
    if #extras > 0 then
        layout[#layout + 1] = extras
    end
    return layout
end

function Keyboard.build(opts)
    assert(opts and opts.puzzle, "Keyboard.build requires a puzzle")
    local layout = deriveLayoutFromPuzzle(opts.puzzle)

    local rows = {}
    for _, letter_row in ipairs(layout) do
        local row = {}
        for _, letter in ipairs(letter_row) do
            local captured = letter
            row[#row + 1] = {
                text = letter,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    if opts.on_letter then opts.on_letter(captured) end
                end,
            }
        end
        rows[#rows + 1] = row
    end

    rows[#rows + 1] = {
        {
            text = _("◀ Prev"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                if opts.on_prev then opts.on_prev() end
            end,
        },
        {
            text = _("⌫ Erase"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                if opts.on_erase then opts.on_erase() end
            end,
        },
        {
            text = _("⇄ Dir"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                if opts.on_dir then opts.on_dir() end
            end,
        },
        {
            text = _("Next ▶"),
            background = Blitbuffer.COLOR_WHITE,
            callback = function()
                if opts.on_next then opts.on_next() end
            end,
        },
    }

    return ButtonTable:new{
        width = opts.width,
        shrink_unneeded_width = true,
        buttons = rows,
    }
end

return Keyboard
