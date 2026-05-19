--[[
Crossword puzzle generator.

Algorithm:
  1. Pick a grid size and target word-density.
  2. Place the longest seed word horizontally through the middle.
  3. Repeat:
       - Find an existing placed letter that's a candidate for crossing.
       - Search the dictionary for a word that fits the crossing pattern and
         doesn't produce invalid adjacent-letter runs.
       - Place it perpendicular to the seed letter.
     Stop when we've placed `target_words` or exhausted attempts.
  4. Mark any cells not used by a word as black squares.
  5. Compact the grid by removing empty rows and columns.
  6. Look up clues from the word source map.
  7. Return a Puzzle instance.

This is a classic "crossword compiler lite" approach. It is not as tight as
Crossfire/Phil but it generates playable grids in a few hundred ms on the
devices we care about.

Word source must expose:
    source:getLanguage()  -> string (informational only)
    source:randomSample(n, filter) -> list of {word, clue} pairs
The StarDict reader, TSV list reader, and book source all satisfy this contract.
]]--

local Puzzle = require("crossword_puzzle")

local Generator = {}

-- ---------------------------------------------------------------------------
-- UTF-8 aware helpers.
-- The generator needs to treat "Ç" as a single letter, not two bytes. We
-- break words into UTF-8 code-point strings up-front.
-- ---------------------------------------------------------------------------

local function utf8Chars(s)
    local chars = {}
    local i = 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        local size
        if b < 0x80 then size = 1
        elseif b < 0xC0 then size = 1 -- invalid continuation, treat as single byte
        elseif b < 0xE0 then size = 2
        elseif b < 0xF0 then size = 3
        else size = 4 end
        chars[#chars + 1] = s:sub(i, i + size - 1)
        i = i + size
    end
    return chars
end

local function upperLua(s)
    local chars = utf8Chars(s)
    for i, ch in ipairs(chars) do
        chars[i] = ch:upper()
    end
    return table.concat(chars), chars
end

-- Validate a word for use in a crossword: only letters, no spaces/digits,
-- length in allowed range.
local function wordAcceptable(word, min_len, max_len)
    if not word or word == "" then return false end
    if word:find("[%s%d%p]") then return false end
    local chars = utf8Chars(word)
    local n = #chars
    return n >= min_len and n <= max_len
end

-- ---------------------------------------------------------------------------
-- TSV word source (word<TAB>clue per line).
-- ---------------------------------------------------------------------------

local TsvSource = {}
TsvSource.__index = TsvSource

function TsvSource.open(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local entries = {}
    for line in f:lines() do
        local word, clue = line:match("^([^\t]+)\t(.+)$")
        if word then
            local w = (word:gsub("^%s+", ""):gsub("%s+$", ""))
            local c = (clue:gsub("^%s+", ""):gsub("%s+$", ""))
            if w ~= "" and c ~= "" then
                entries[#entries + 1] = { word = w, clue = c }
            end
        end
    end
    f:close()
    return setmetatable({ entries = entries }, TsvSource)
end

function TsvSource:getLanguage() return "unknown" end

function TsvSource:randomSample(count, filter)
    local kept = {}
    local considered = 0
    for _, entry in ipairs(self.entries) do
        if not filter or filter(entry.word) then
            considered = considered + 1
            if #kept < count then
                kept[#kept + 1] = entry
            else
                local j = math.random(considered)
                if j <= count then kept[j] = entry end
            end
        end
    end
    return kept
end

Generator.TsvSource = TsvSource

-- ---------------------------------------------------------------------------
-- StarDict wrapper: adapt crossword_stardict.Reader into the source contract.
-- ---------------------------------------------------------------------------

local StarDictSource = {}
StarDictSource.__index = StarDictSource

function StarDictSource.wrap(reader)
    return setmetatable({ reader = reader }, StarDictSource)
end

function StarDictSource:getLanguage() return "unknown" end

function StarDictSource:randomSample(count, filter)
    return self.reader:randomSample(count, filter)
end

Generator.StarDictSource = StarDictSource

-- ---------------------------------------------------------------------------
-- Core generator.
-- ---------------------------------------------------------------------------

-- Build a bucket index { [length] = { {word, clue, chars}, ... } } capped at
-- `per_length` entries per length. This gives the generator fast lookups
-- by word length without materializing the entire dictionary.
local function buildBuckets(source, per_length, min_len, max_len)
    local buckets = {}
    local total_needed = per_length * (max_len - min_len + 1)
    local sample = source:randomSample(math.max(total_needed, 500), function(word)
        return wordAcceptable(word, min_len, max_len)
    end)
    for _, entry in ipairs(sample) do
        local upper, chars = upperLua(entry.word)
        local n = #chars
        if n >= min_len and n <= max_len then
            buckets[n] = buckets[n] or {}
            if #buckets[n] < per_length * 3 then -- keep extras in case of pattern misses
                buckets[n][#buckets[n] + 1] = {
                    word = upper,
                    clue = entry.clue,
                    chars = chars,
                }
            end
        end
    end
    return buckets
end

local function matchesPattern(chars, pattern)
    if #chars ~= #pattern then return false end
    for i = 1, #pattern do
        local req = pattern[i]
        if req and req ~= "" and req ~= chars[i] then return false end
    end
    return true
end

local function emptyGrid(w, h)
    local g = {}
    for r = 1, h do
        g[r] = {}
        for c = 1, w do g[r][c] = "" end
    end
    return g
end

-- Try to place a word at (row, col, direction). Returns true if successful.
local function canPlace(grid, w, h, row, col, direction, chars)
    local len = #chars
    -- Must fit in bounds.
    if direction == "across" then
        if col + len - 1 > w then return false end
        -- Preceding/trailing cell must be out-of-bounds or black-equivalent
        -- (we treat an empty grid cell immediately before/after as blocker
        -- risk unless we later mark it black; for simplicity, require the
        -- cells to be literally outside the grid).
        if col - 1 >= 1 and grid[row][col - 1] ~= "" then return false end
        if col + len <= w and grid[row][col + len] ~= "" then return false end
        for i = 1, len do
            local cur = grid[row][col + i - 1]
            if cur ~= "" and cur ~= chars[i] then return false end
            -- Adjacent-cell check: perpendicular neighbors must be empty or
            -- complete a valid existing word. We approximate this by only
            -- allowing neighbors when the current cell is a cross-point
            -- (existing letter matching chars[i]).
            if cur == "" then
                if row > 1 and grid[row - 1][col + i - 1] ~= "" then return false end
                if row < h and grid[row + 1][col + i - 1] ~= "" then return false end
            end
        end
    else
        if row + len - 1 > h then return false end
        if row - 1 >= 1 and grid[row - 1][col] ~= "" then return false end
        if row + len <= h and grid[row + len][col] ~= "" then return false end
        for i = 1, len do
            local cur = grid[row + i - 1][col]
            if cur ~= "" and cur ~= chars[i] then return false end
            if cur == "" then
                if col > 1 and grid[row + i - 1][col - 1] ~= "" then return false end
                if col < w and grid[row + i - 1][col + 1] ~= "" then return false end
            end
        end
    end
    return true
end

local function placeWord(grid, row, col, direction, chars)
    if direction == "across" then
        for i = 1, #chars do
            grid[row][col + i - 1] = chars[i]
        end
    else
        for i = 1, #chars do
            grid[row + i - 1][col] = chars[i]
        end
    end
end

-- Collect all existing cells on the grid, with useful metadata for the
-- next-word search step.
local function collectPlacedLetters(grid, w, h)
    local out = {}
    for r = 1, h do
        for c = 1, w do
            if grid[r][c] ~= "" then
                out[#out + 1] = { row = r, col = c, ch = grid[r][c] }
            end
        end
    end
    return out
end

local function shuffleInPlace(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
end

-- Try to place a second or later word that crosses some existing letter.
-- Returns true on success.
local function tryCross(grid, w, h, buckets, used, placed_out, target_len_range)
    local letters = collectPlacedLetters(grid, w, h)
    shuffleInPlace(letters)
    for _, lc in ipairs(letters) do
        for len = target_len_range[2], target_len_range[1], -1 do
            local bucket = buckets[len]
            if bucket then
                local indices = {}
                for i = 1, #bucket do indices[i] = i end
                shuffleInPlace(indices)
                for _, bi in ipairs(indices) do
                    local candidate = bucket[bi]
                    if not used[candidate.word] then
                        -- Figure out orientation from lc.
                        -- Direction of the new word must be perpendicular
                        -- to whatever word is already at lc. For simplicity
                        -- we just try both "across" and "down" alignments.
                        for _, dir in ipairs({ "across", "down" }) do
                            for offset = 1, #candidate.chars do
                                if candidate.chars[offset] == lc.ch then
                                    local row, col
                                    if dir == "across" then
                                        row = lc.row
                                        col = lc.col - offset + 1
                                    else
                                        row = lc.row - offset + 1
                                        col = lc.col
                                    end
                                    if row >= 1 and col >= 1 and
                                        canPlace(grid, w, h, row, col, dir, candidate.chars) then
                                        placeWord(grid, row, col, dir, candidate.chars)
                                        used[candidate.word] = true
                                        placed_out[#placed_out + 1] = {
                                            word = candidate.word,
                                            clue = candidate.clue,
                                            row = row,
                                            col = col,
                                            direction = dir,
                                            chars = candidate.chars,
                                        }
                                        return true
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return false
end

local function placeSeedWord(grid, w, h, buckets, used, placed_out)
    local len = math.min(w, 13)
    while len >= 3 do
        local bucket = buckets[len]
        if bucket and #bucket > 0 then
            local indices = {}
            for i = 1, #bucket do indices[i] = i end
            shuffleInPlace(indices)
            for _, bi in ipairs(indices) do
                local candidate = bucket[bi]
                local row = math.floor(h / 2) + 1
                local col = math.floor((w - len) / 2) + 1
                if canPlace(grid, w, h, row, col, "across", candidate.chars) then
                    placeWord(grid, row, col, "across", candidate.chars)
                    used[candidate.word] = true
                    placed_out[#placed_out + 1] = {
                        word = candidate.word,
                        clue = candidate.clue,
                        row = row,
                        col = col,
                        direction = "across",
                        chars = candidate.chars,
                    }
                    return true
                end
            end
        end
        len = len - 1
    end
    return false
end

local function compactGrid(grid, w, h, placed)
    local min_row, max_row = h, 1
    local min_col, max_col = w, 1
    
    for r = 1, h do
        for c = 1, w do
            if grid[r][c] ~= "" then
                min_row = math.min(min_row, r)
                max_row = math.max(max_row, r)
                min_col = math.min(min_col, c)
                max_col = math.max(max_col, c)
            end
        end
    end
    
    if min_row > max_row or min_col > max_col then
        return grid, w, h, placed
    end
    
    local new_h = max_row - min_row + 1
    local new_w = max_col - min_col + 1
    local new_grid = {}
    
    for r = 1, new_h do
        new_grid[r] = {}
        for c = 1, new_w do
            new_grid[r][c] = grid[r + min_row - 1][c + min_col - 1]
        end
    end
    
    local new_placed = {}
    for _, p in ipairs(placed) do
        new_placed[#new_placed + 1] = {
            word = p.word,
            clue = p.clue,
            row = p.row - min_row + 1,
            col = p.col - min_col + 1,
            direction = p.direction,
            chars = p.chars,
        }
    end
    
    return new_grid, new_w, new_h, new_placed
end

local function toSolutionGrid(grid, w, h)
    local solution = {}
    for r = 1, h do
        solution[r] = {}
        for c = 1, w do
            if grid[r][c] == "" then
                solution[r][c] = false
            else
                solution[r][c] = grid[r][c]
            end
        end
    end
    return solution
end

-- Derive numbering to match each placed word to its clue number. The Puzzle
-- class computes numbering itself on construction; we just need to map
-- (row, col, direction) -> number, which we derive from the final solution.
local function placedToClues(placed, solution)
    -- Temporary numbering pass identical to Puzzle:computeNumbering().
    local h = #solution
    local w = (h > 0) and #solution[1] or 0
    local function isBlack(r, c)
        if r < 1 or r > h or c < 1 or c > w then return true end
        return solution[r][c] == false
    end
    local numbers = {}
    for r = 1, h do numbers[r] = {} end
    local num = 0
    for r = 1, h do
        for c = 1, w do
            if not isBlack(r, c) then
                local starts_across = (c == 1 or isBlack(r, c - 1))
                    and (c < w and not isBlack(r, c + 1))
                local starts_down = (r == 1 or isBlack(r - 1, c))
                    and (r < h and not isBlack(r + 1, c))
                if starts_across or starts_down then
                    num = num + 1
                    numbers[r][c] = num
                end
            end
        end
    end

    local across_clues, down_clues = {}, {}
    for _, p in ipairs(placed) do
        local n = numbers[p.row] and numbers[p.row][p.col]
        if n then
            if p.direction == "across" then
                across_clues[n] = p.clue
            else
                down_clues[n] = p.clue
            end
        end
    end
    return across_clues, down_clues
end

-- Public entry point.
--   opts = {
--     source = wordSource,
--     width = 11, height = 11,
--     target_words = 20,
--     min_word_len = 3,
--     max_word_len = 11,
--     seed = optional integer (deterministic generation),
--     title = optional string,
--   }
function Generator.generate(opts)
    assert(opts and opts.source, "Generator.generate requires a source")
    local w = opts.width or 11
    local h = opts.height or 11
    local target = opts.target_words or math.floor((w + h) * 1.2)
    local min_len = opts.min_word_len or 3
    local max_len = opts.max_word_len or math.min(w, h)
    if opts.seed then math.randomseed(opts.seed) end

    local buckets = buildBuckets(opts.source, math.max(200, target * 10), min_len, max_len)
    local grid = emptyGrid(w, h)
    local used = {}
    local placed = {}

    if not placeSeedWord(grid, w, h, buckets, used, placed) then
        return nil, "Could not place seed word"
    end

    local attempts = 0
    local max_attempts = target * 100
    local logger = require("logger")
    local consecutive_failures = 0
    while attempts < max_attempts and consecutive_failures < 50 do
        local ok = tryCross(grid, w, h, buckets, used, placed, { min_len, max_len })
        if ok then
            consecutive_failures = 0
        else
            consecutive_failures = consecutive_failures + 1
        end
        attempts = attempts + 1
        if attempts % 100 == 0 then
            logger.info("Generator: placed", #placed, "words (target:", target, ") after", attempts, "attempts")
        end
    end

    logger.info("Generator: finished with", #placed, "words (target:", target, ") after", attempts, "attempts")

    local min_words = math.max(2, math.floor(target * 0.3))
    if #placed < min_words then
        return nil, "Generator could not place enough words (only " .. #placed .. " of " .. target .. " target). Try with more diverse words or a smaller grid."
    end

    grid, w, h, placed = compactGrid(grid, w, h, placed)
    
    local solution = toSolutionGrid(grid, w, h)
    local across_clues, down_clues = placedToClues(placed, solution)

    return Puzzle.new{
        title = opts.title or "Generated Crossword",
        author = "",
        copyright = "",
        notes = "",
        width = w,
        height = h,
        solution = solution,
        across_clues = across_clues,
        down_clues = down_clues,
        source = {
            type = "generator",
            ref = opts.source_ref or "",
            language = opts.source:getLanguage(),
            word_count = #placed,
        },
    }
end

return Generator
