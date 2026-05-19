--[[
Crossword grid rendering widget.

Displays a Puzzle instance as a square grid with:
  - Black squares painted solid black
  - White squares with user letters centered
  - Small cell numbers in the top-left corner of cells that start a word
  - Active word highlighted with a light gray band
  - Active cell highlighted with a darker gray
  - Cells with a "checked-wrong" mark get a small red corner triangle
  - Revealed (given) cells get a tiny dot in the corner

The widget is fixed-size (square). Tap events are relayed to on_tap(row, col).
]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText = require("ui/rendertext")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local GridWidget = InputContainer:extend{
    puzzle = nil,
    size = nil,
    on_tap = nil, -- function(row, col, is_same_cell)
}

function GridWidget:init()
    assert(self.puzzle, "GridWidget requires a puzzle")
    if not self.size then
        local max_dim = math.min(Screen:getWidth(), Screen:getHeight())
        self.size = math.floor(max_dim * 0.9)
    end
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }
    self:computeFonts()
    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.paint_rect end,
            },
        },
    }
end

function GridWidget:computeFonts()
    local cells_per_side = math.max(self.puzzle.width, self.puzzle.height)
    local cell_size = self.size / cells_per_side
    local letter_face_size = math.max(10, math.floor(cell_size * 0.55))
    local number_face_size = math.max(6, math.floor(cell_size * 0.22))
    self.letter_face = Font:getFace("cfont", letter_face_size)
    self.number_face = Font:getFace("smallinfofont", number_face_size)
    self.cell_size = cell_size
end

function GridWidget:setPuzzle(puzzle)
    self.puzzle = puzzle
    self:computeFonts()
end

function GridWidget:getCellSize()
    return self.size / math.max(self.puzzle.width, self.puzzle.height)
end

function GridWidget:getCellFromPoint(x, y)
    local rect = self.paint_rect
    local local_x = x - rect.x
    local local_y = y - rect.y
    if local_x < 0 or local_y < 0 then return nil end
    -- The grid may not be square if width != height. Compute actual grid origin.
    local cell = self:getCellSize()
    local grid_w = cell * self.puzzle.width
    local grid_h = cell * self.puzzle.height
    local grid_offset_x = math.floor((rect.w - grid_w) / 2)
    local grid_offset_y = math.floor((rect.h - grid_h) / 2)
    if local_x < grid_offset_x or local_y < grid_offset_y
        or local_x >= grid_offset_x + grid_w or local_y >= grid_offset_y + grid_h then
        return nil
    end
    local col = math.floor((local_x - grid_offset_x) / cell) + 1
    local row = math.floor((local_y - grid_offset_y) / cell) + 1
    if row < 1 or row > self.puzzle.height or col < 1 or col > self.puzzle.width then
        return nil
    end
    return row, col
end

function GridWidget:onTap(_, ges)
    if not self.on_tap or not (ges and ges.pos) then return false end
    local row, col = self:getCellFromPoint(ges.pos.x, ges.pos.y)
    if not row then return false end
    local cur_r, cur_c = self.puzzle:getCursor()
    local is_same = (cur_r == row and cur_c == col)
    self.on_tap(row, col, is_same)
    return true
end

function GridWidget:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect
    end)
end

function GridWidget:paintTo(bb, x, y)
    local puzzle = self.puzzle
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local cell = self:getCellSize()
    local grid_w = cell * puzzle.width
    local grid_h = cell * puzzle.height
    local grid_x = x + math.floor((self.dimen.w - grid_w) / 2)
    local grid_y = y + math.floor((self.dimen.h - grid_h) / 2)

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)

    -- Current word highlight.
    local word = puzzle:currentWord()
    if word then
        for _, wc in ipairs(word.cells) do
            local cx = grid_x + math.floor((wc.col - 1) * cell)
            local cy = grid_y + math.floor((wc.row - 1) * cell)
            bb:paintRect(cx, cy, math.floor(cell) + 1, math.floor(cell) + 1, Blitbuffer.COLOR_GRAY_E)
        end
    end

    -- Active cell highlight.
    local cur_r, cur_c = puzzle:getCursor()
    if cur_r and puzzle:isWhite(cur_r, cur_c) then
        local cx = grid_x + math.floor((cur_c - 1) * cell)
        local cy = grid_y + math.floor((cur_r - 1) * cell)
        bb:paintRect(cx, cy, math.floor(cell) + 1, math.floor(cell) + 1, Blitbuffer.COLOR_GRAY_9)
    end

    -- Black squares and cell content.
    for r = 1, puzzle.height do
        for c = 1, puzzle.width do
            local cx = grid_x + math.floor((c - 1) * cell)
            local cy = grid_y + math.floor((r - 1) * cell)
            local icell = math.floor(cell) + 1
            if puzzle:isBlack(r, c) then
                bb:paintRect(cx, cy, icell, icell, Blitbuffer.COLOR_BLACK)
            else
                -- Cell number.
                local num = puzzle:getNumber(r, c)
                if num > 0 then
                    local text = tostring(num)
                    local pad = math.max(1, math.floor(cell * 0.06))
                    RenderText:renderUtf8Text(
                        bb,
                        cx + pad,
                        cy + pad + self.number_face.size,
                        self.number_face,
                        text,
                        true, false,
                        Blitbuffer.COLOR_BLACK
                    )
                end
                -- Letter.
                local letter = puzzle:getUser(r, c)
                if letter and letter ~= "" then
                    local text = letter:upper()
                    local metrics = RenderText:sizeUtf8Text(0, icell, self.letter_face, text, true, false)
                    local text_w = metrics.x
                    local text_x = cx + math.floor((icell - text_w) / 2)
                    -- Vertical centering formula used by the Sudoku plugin; keeps
                    -- the baseline tuned for the e-reader font set at runtime.
                    local baseline = cy + math.floor((icell + metrics.y_top - metrics.y_bottom) / 2)
                    
                    -- If cell has a number, shift letter down slightly to avoid overlap
                    local num = puzzle:getNumber(r, c)
                    if num > 0 then
                        local shift = math.floor(cell * 0.08)
                        baseline = baseline + shift
                    end
                    
                    local color = Blitbuffer.COLOR_BLACK
                    if puzzle.checked[r][c] then
                        color = Blitbuffer.COLOR_GRAY_4
                    elseif puzzle.revealed[r][c] then
                        color = Blitbuffer.COLOR_GRAY_4
                    end
                    RenderText:renderUtf8Text(
                        bb,
                        text_x,
                        baseline,
                        self.letter_face,
                        text,
                        true, false,
                        color
                    )
                end
                -- Wrong-check corner marker.
                if puzzle.checked[r][c] then
                    local triangle = math.max(3, math.floor(cell * 0.18))
                    for t = 0, triangle do
                        bb:paintRect(cx + icell - 1 - t, cy, 1, triangle - t, Blitbuffer.COLOR_BLACK)
                    end
                end
                -- Revealed hint marker (tiny dot bottom-right).
                if puzzle.revealed[r][c] then
                    local dot = math.max(2, math.floor(cell * 0.08))
                    local pad = math.max(1, math.floor(cell * 0.08))
                    bb:paintRect(cx + icell - pad - dot, cy + icell - pad - dot, dot, dot, Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end

    -- Grid lines.
    local line = Size.line.thin
    for i = 0, puzzle.height do
        bb:paintRect(grid_x, grid_y + math.floor(i * cell), grid_w, line, Blitbuffer.COLOR_BLACK)
    end
    for j = 0, puzzle.width do
        bb:paintRect(grid_x + math.floor(j * cell), grid_y, line, grid_h, Blitbuffer.COLOR_BLACK)
    end
end

return GridWidget
