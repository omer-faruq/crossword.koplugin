--[[
Crossword puzzle data model.

A puzzle holds:
  - solution grid: 2D array of letters, or false for black squares
  - user grid: 2D array of user-entered letters (empty string for blank)
  - numbering: cell numbers derived from solution layout
  - clue dictionaries: across[num] = text, down[num] = text
  - cursor state: row, col, direction ("across" or "down")
  - marking state: checked/revealed flags per cell

Black squares are represented as the boolean false inside solution rows
(and empty string "" inside user rows; never letters).
]]--

local Puzzle = {}
Puzzle.__index = Puzzle

local function emptyCharGrid(h, w)
    local grid = {}
    for r = 1, h do
        grid[r] = {}
        for c = 1, w do
            grid[r][c] = ""
        end
    end
    return grid
end

local function emptyBoolGrid(h, w)
    local grid = {}
    for r = 1, h do
        grid[r] = {}
        for c = 1, w do
            grid[r][c] = false
        end
    end
    return grid
end

local function emptyIntGrid(h, w)
    local grid = {}
    for r = 1, h do
        grid[r] = {}
        for c = 1, w do
            grid[r][c] = 0
        end
    end
    return grid
end

-- Normalize a single cell of the solution.
-- Returns either a letter (string, uppercase) or false for black squares.
local function normalizeSolutionCell(value)
    if value == nil or value == false then
        return false
    end
    if type(value) == "string" then
        if value == "" or value == "." or value == "#" then
            return false
        end
        return value
    end
    return false
end

function Puzzle.new(data)
    local self = setmetatable({}, Puzzle)
    self.title = data.title or ""
    self.author = data.author or ""
    self.copyright = data.copyright or ""
    self.notes = data.notes or ""
    self.width = data.width
    self.height = data.height
    assert(self.width and self.height, "Puzzle requires width and height")

    self.solution = emptyCharGrid(self.height, self.width)
    for r = 1, self.height do
        for c = 1, self.width do
            local cell = data.solution and data.solution[r] and data.solution[r][c]
            self.solution[r][c] = normalizeSolutionCell(cell)
        end
    end

    self.user = emptyCharGrid(self.height, self.width)
    if data.user then
        for r = 1, self.height do
            for c = 1, self.width do
                local v = data.user[r] and data.user[r][c]
                if type(v) == "string" and v ~= "" then
                    self.user[r][c] = v
                end
            end
        end
    end

    self.checked = emptyBoolGrid(self.height, self.width)
    self.revealed = emptyBoolGrid(self.height, self.width)
    if data.checked then
        for r = 1, self.height do
            for c = 1, self.width do
                self.checked[r][c] = (data.checked[r] and data.checked[r][c]) and true or false
            end
        end
    end
    if data.revealed then
        for r = 1, self.height do
            for c = 1, self.width do
                self.revealed[r][c] = (data.revealed[r] and data.revealed[r][c]) and true or false
            end
        end
    end

    self.across_clues = {}
    self.down_clues = {}
    if data.across_clues then
        for k, v in pairs(data.across_clues) do self.across_clues[k] = v end
    end
    if data.down_clues then
        for k, v in pairs(data.down_clues) do self.down_clues[k] = v end
    end

    self:computeNumbering()
    self:computeClueLists()

    self.cursor = {
        row = (data.cursor and data.cursor.row) or 1,
        col = (data.cursor and data.cursor.col) or 1,
        direction = (data.cursor and data.cursor.direction) or "across",
    }
    self:ensureCursorOnWhite()

    self.source = data.source or { type = "unknown" }
    self.created_at = data.created_at or os.time()

    return self
end

function Puzzle:isBlack(row, col)
    if row < 1 or row > self.height or col < 1 or col > self.width then
        return true
    end
    return self.solution[row][col] == false
end

function Puzzle:isWhite(row, col)
    return not self:isBlack(row, col)
end

-- Compute cell numbering and across/down starting positions.
function Puzzle:computeNumbering()
    self.numbers = emptyIntGrid(self.height, self.width)
    self.across_cells = {}
    self.down_cells = {}
    local num = 0
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                local starts_across = (c == 1 or self:isBlack(r, c - 1))
                    and (c < self.width and self:isWhite(r, c + 1))
                local starts_down = (r == 1 or self:isBlack(r - 1, c))
                    and (r < self.height and self:isWhite(r + 1, c))
                if starts_across or starts_down then
                    num = num + 1
                    self.numbers[r][c] = num
                    if starts_across then
                        local length = 0
                        local cc = c
                        while cc <= self.width and self:isWhite(r, cc) do
                            length = length + 1
                            cc = cc + 1
                        end
                        self.across_cells[num] = { row = r, col = c, length = length }
                    end
                    if starts_down then
                        local length = 0
                        local rr = r
                        while rr <= self.height and self:isWhite(rr, c) do
                            length = length + 1
                            rr = rr + 1
                        end
                        self.down_cells[num] = { row = r, col = c, length = length }
                    end
                end
            end
        end
    end
end

function Puzzle:computeClueLists()
    self.across_list = {}
    for num, cell in pairs(self.across_cells) do
        self.across_list[#self.across_list + 1] = {
            num = num,
            row = cell.row,
            col = cell.col,
            length = cell.length,
            text = self.across_clues[num] or "",
        }
    end
    table.sort(self.across_list, function(a, b) return a.num < b.num end)

    self.down_list = {}
    for num, cell in pairs(self.down_cells) do
        self.down_list[#self.down_list + 1] = {
            num = num,
            row = cell.row,
            col = cell.col,
            length = cell.length,
            text = self.down_clues[num] or "",
        }
    end
    table.sort(self.down_list, function(a, b) return a.num < b.num end)
end

function Puzzle:ensureCursorOnWhite()
    if self:isWhite(self.cursor.row, self.cursor.col) then
        return
    end
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                self.cursor.row, self.cursor.col = r, c
                return
            end
        end
    end
end

function Puzzle:getCursor()
    return self.cursor.row, self.cursor.col, self.cursor.direction
end

function Puzzle:setCursor(row, col, direction)
    if row and col and self:isWhite(row, col) then
        self.cursor.row, self.cursor.col = row, col
    end
    if direction == "across" or direction == "down" then
        self.cursor.direction = direction
    end
end

function Puzzle:toggleDirection()
    self.cursor.direction = (self.cursor.direction == "across") and "down" or "across"
end

-- Find the word (cells list) containing (row, col) in the given direction.
function Puzzle:wordCells(row, col, direction)
    if self:isBlack(row, col) then
        return nil
    end
    local cells = {}
    local start_row, start_col = row, col
    if direction == "across" then
        while start_col > 1 and self:isWhite(row, start_col - 1) do
            start_col = start_col - 1
        end
        local cc = start_col
        while cc <= self.width and self:isWhite(row, cc) do
            cells[#cells + 1] = { row = row, col = cc }
            cc = cc + 1
        end
    else
        while start_row > 1 and self:isWhite(start_row - 1, col) do
            start_row = start_row - 1
        end
        local rr = start_row
        while rr <= self.height and self:isWhite(rr, col) do
            cells[#cells + 1] = { row = rr, col = col }
            rr = rr + 1
        end
    end
    return cells, start_row, start_col
end

function Puzzle:currentWord()
    local row, col, dir = self:getCursor()
    local cells, sr, sc = self:wordCells(row, col, dir)
    if not cells then
        return nil
    end
    local num = self.numbers[sr][sc]
    local clue_map = (dir == "across") and self.across_clues or self.down_clues
    return {
        num = num,
        direction = dir,
        start_row = sr,
        start_col = sc,
        cells = cells,
        clue = clue_map[num] or "",
    }
end

function Puzzle:getUser(row, col)
    if self:isBlack(row, col) then return "" end
    return self.user[row][col] or ""
end

function Puzzle:getSolution(row, col)
    if self:isBlack(row, col) then return "" end
    return self.solution[row][col] or ""
end

function Puzzle:getNumber(row, col)
    return self.numbers[row][col] or 0
end

-- Set a user letter. Does nothing for black squares. Clears checked/revealed flags.
function Puzzle:setLetter(row, col, letter)
    if self:isBlack(row, col) then return false end
    self.user[row][col] = letter or ""
    self.checked[row][col] = false
    if letter == "" or letter == nil then
        self.revealed[row][col] = false
    end
    return true
end

function Puzzle:clearCell(row, col)
    return self:setLetter(row, col, "")
end

-- Advance cursor one cell in the current direction, skipping black cells.
-- Returns true if advanced, false if at end.
function Puzzle:advance()
    local r, c, dir = self:getCursor()
    if dir == "across" then
        for cc = c + 1, self.width do
            if self:isWhite(r, cc) then
                self.cursor.row, self.cursor.col = r, cc
                return true
            end
        end
    else
        for rr = r + 1, self.height do
            if self:isWhite(rr, c) then
                self.cursor.row, self.cursor.col = rr, c
                return true
            end
        end
    end
    return false
end

function Puzzle:retreat()
    local r, c, dir = self:getCursor()
    if dir == "across" then
        for cc = c - 1, 1, -1 do
            if self:isWhite(r, cc) then
                self.cursor.row, self.cursor.col = r, cc
                return true
            end
        end
    else
        for rr = r - 1, 1, -1 do
            if self:isWhite(rr, c) then
                self.cursor.row, self.cursor.col = rr, c
                return true
            end
        end
    end
    return false
end

-- Advance to the next empty cell in the current word; wrap to start of word.
function Puzzle:advanceInWord()
    local word = self:currentWord()
    if not word then return false end
    local cur_idx
    for i, cell in ipairs(word.cells) do
        if cell.row == self.cursor.row and cell.col == self.cursor.col then
            cur_idx = i
            break
        end
    end
    if not cur_idx then return false end
    for offset = 1, #word.cells - 1 do
        local idx = ((cur_idx - 1 + offset) % #word.cells) + 1
        local cell = word.cells[idx]
        if self:getUser(cell.row, cell.col) == "" then
            self.cursor.row, self.cursor.col = cell.row, cell.col
            return true
        end
    end
    -- No empty cell in word: just step one cell forward (possibly to next word).
    if cur_idx < #word.cells then
        local cell = word.cells[cur_idx + 1]
        self.cursor.row, self.cursor.col = cell.row, cell.col
        return true
    end
    return false
end

function Puzzle:moveToClue(direction, num)
    local cells_map = (direction == "across") and self.across_cells or self.down_cells
    local cell = cells_map[num]
    if not cell then return false end
    self.cursor.row = cell.row
    self.cursor.col = cell.col
    self.cursor.direction = direction
    return true
end

function Puzzle:nextClue()
    local word = self:currentWord()
    if not word then return false end
    local list = (word.direction == "across") and self.across_list or self.down_list
    local other = (word.direction == "across") and self.down_list or self.across_list
    for i, entry in ipairs(list) do
        if entry.num == word.num then
            if i < #list then
                return self:moveToClue(word.direction, list[i + 1].num)
            end
            -- Wrap to the first clue of the other direction.
            if other[1] then
                local other_dir = (word.direction == "across") and "down" or "across"
                return self:moveToClue(other_dir, other[1].num)
            end
            return self:moveToClue(word.direction, list[1].num)
        end
    end
    return false
end

function Puzzle:prevClue()
    local word = self:currentWord()
    if not word then return false end
    local list = (word.direction == "across") and self.across_list or self.down_list
    local other = (word.direction == "across") and self.down_list or self.across_list
    for i, entry in ipairs(list) do
        if entry.num == word.num then
            if i > 1 then
                return self:moveToClue(word.direction, list[i - 1].num)
            end
            if other[#other] then
                local other_dir = (word.direction == "across") and "down" or "across"
                return self:moveToClue(other_dir, other[#other].num)
            end
            return self:moveToClue(word.direction, list[#list].num)
        end
    end
    return false
end

function Puzzle:checkCell(row, col)
    if self:isBlack(row, col) then return nil end
    local u = self:getUser(row, col)
    if u == "" then return nil end
    local match = u:upper() == self:getSolution(row, col):upper()
    self.checked[row][col] = not match
    return match
end

function Puzzle:checkAllFilled()
    local correct, total = 0, 0
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                local u = self:getUser(r, c)
                if u ~= "" then
                    total = total + 1
                    local ok = self:checkCell(r, c)
                    if ok then correct = correct + 1 end
                end
            end
        end
    end
    return correct, total
end

function Puzzle:checkWord()
    local word = self:currentWord()
    if not word then return 0, 0 end
    local correct, total = 0, 0
    for _, cell in ipairs(word.cells) do
        total = total + 1
        local ok = self:checkCell(cell.row, cell.col)
        if ok then correct = correct + 1 end
    end
    return correct, total
end

function Puzzle:checkAll()
    local correct, total = 0, 0
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                total = total + 1
                local ok = self:checkCell(r, c)
                if ok then correct = correct + 1 end
            end
        end
    end
    return correct, total
end

function Puzzle:revealCell(row, col)
    if self:isBlack(row, col) then return false end
    self.user[row][col] = self.solution[row][col]
    self.revealed[row][col] = true
    self.checked[row][col] = false
    return true
end

function Puzzle:revealWord()
    local word = self:currentWord()
    if not word then return 0 end
    local count = 0
    for _, cell in ipairs(word.cells) do
        if self:revealCell(cell.row, cell.col) then count = count + 1 end
    end
    return count
end

function Puzzle:revealAll()
    local count = 0
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                if self:revealCell(r, c) then count = count + 1 end
            end
        end
    end
    return count
end

function Puzzle:resetUser()
    self.user = emptyCharGrid(self.height, self.width)
    self.checked = emptyBoolGrid(self.height, self.width)
    self.revealed = emptyBoolGrid(self.height, self.width)
end

function Puzzle:progress()
    local filled, total = 0, 0
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                total = total + 1
                if self:getUser(r, c) ~= "" then filled = filled + 1 end
            end
        end
    end
    return filled, total
end

function Puzzle:isSolved()
    for r = 1, self.height do
        for c = 1, self.width do
            if self:isWhite(r, c) then
                local u = self:getUser(r, c):upper()
                local s = self:getSolution(r, c):upper()
                if u == "" or u ~= s then return false end
            end
        end
    end
    return true
end

-- Collect the set of all letters appearing in the solution. Useful to build
-- an on-screen keyboard sized for the puzzle's alphabet.
function Puzzle:alphabet()
    local seen = {}
    for r = 1, self.height do
        for c = 1, self.width do
            local s = self.solution[r][c]
            if s then
                seen[s:upper()] = true
            end
        end
    end
    local letters = {}
    for letter in pairs(seen) do
        letters[#letters + 1] = letter
    end
    table.sort(letters)
    return letters
end

function Puzzle:serialize()
    local function cloneGrid(g)
        local out = {}
        for r = 1, self.height do
            out[r] = {}
            for c = 1, self.width do
                out[r][c] = g[r][c]
            end
        end
        return out
    end
    return {
        title = self.title,
        author = self.author,
        copyright = self.copyright,
        notes = self.notes,
        width = self.width,
        height = self.height,
        solution = cloneGrid(self.solution),
        user = cloneGrid(self.user),
        checked = cloneGrid(self.checked),
        revealed = cloneGrid(self.revealed),
        across_clues = self.across_clues,
        down_clues = self.down_clues,
        cursor = { row = self.cursor.row, col = self.cursor.col, direction = self.cursor.direction },
        source = self.source,
        created_at = self.created_at,
    }
end

function Puzzle.deserialize(state)
    return Puzzle.new(state)
end

return Puzzle
