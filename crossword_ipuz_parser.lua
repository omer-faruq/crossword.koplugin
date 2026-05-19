--[[
.ipuz JSON crossword parser (http://www.ipuz.org/).

An .ipuz file is a JSON document with these relevant fields:
  version, kind, title, author, copyright, notes,
  dimensions = { width, height },
  puzzle     = 2D array of cell definitions (numbers, "#" for black, or object),
  solution   = 2D array of letters or "#" for black,
  clues      = { Across = [[num, text], ...], Down = [[num, text], ...] }

Cell definitions can be:
  - a number (clue number)
  - 0 or null (blank white)
  - "#" (black square)
  - an object {"cell": n, "style": ...}

We support the common crossword kind. Variants (diagramless, acrostic) are not
supported and will produce a best-effort result.
]]--

local json = require("json")

local IpuzParser = {}

local function isBlackCell(cell)
    if cell == "#" then return true end
    if type(cell) == "table" and cell.cell == "#" then return true end
    return false
end

local function normalizeClueList(list)
    -- ipuz clue entries can be [num, text] arrays or {number, clue, ...} objects.
    local out = {}
    if type(list) ~= "table" then return out end
    for _, entry in ipairs(list) do
        local num, text
        if type(entry) == "table" then
            if entry[1] ~= nil and entry[2] ~= nil then
                num = tonumber(entry[1])
                text = tostring(entry[2])
            elseif entry.number ~= nil then
                num = tonumber(entry.number)
                text = tostring(entry.clue or entry.text or "")
            end
        end
        if num and text then
            out[num] = text
        end
    end
    return out
end

function IpuzParser.parse(path_or_data, from_data)
    local text
    if from_data then
        text = path_or_data
    else
        local f, err = io.open(path_or_data, "rb")
        if not f then return nil, err end
        text = f:read("*all")
        f:close()
    end

    -- Strip optional "ipuz(" JSONP wrapper that some sites use.
    text = text:gsub("^%s*ipuz%(%s*", ""):gsub("%)%s*;?%s*$", "")

    local ok, doc = pcall(function() return json.decode(text) end)
    if not ok or type(doc) ~= "table" then
        return nil, "Invalid JSON in .ipuz file"
    end

    local dims = doc.dimensions
    if type(dims) ~= "table" or not dims.width or not dims.height then
        return nil, "Missing dimensions in .ipuz"
    end
    local width = tonumber(dims.width)
    local height = tonumber(dims.height)
    if not width or not height or width < 1 or height < 1 then
        return nil, "Invalid dimensions in .ipuz"
    end

    local puzzle_grid = doc.puzzle
    local solution_grid = doc.solution
    if type(puzzle_grid) ~= "table" then
        return nil, "Missing puzzle grid in .ipuz"
    end

    local solution = {}
    for r = 1, height do
        solution[r] = {}
        local puz_row = puzzle_grid[r] or {}
        local sol_row = (type(solution_grid) == "table") and solution_grid[r] or nil
        for c = 1, width do
            local puz_cell = puz_row[c]
            if isBlackCell(puz_cell) then
                solution[r][c] = false
            else
                local letter = sol_row and sol_row[c]
                if type(letter) == "table" then
                    letter = letter.value or letter.cell or letter[1]
                end
                if letter == nil or letter == "#" or letter == 0 then
                    if isBlackCell(letter) then
                        solution[r][c] = false
                    else
                        -- Missing solution letter; mark as white but unknown.
                        solution[r][c] = "?"
                    end
                elseif type(letter) == "string" then
                    if letter == "" then
                        solution[r][c] = "?"
                    else
                        -- ipuz allows multi-letter rebus entries; we just take first glyph
                        -- of the letter, preserving unicode byte sequence.
                        solution[r][c] = letter:upper()
                    end
                else
                    solution[r][c] = "?"
                end
            end
        end
    end

    local clues_in = doc.clues or {}
    -- ipuz is case-sensitive with "Across"/"Down" keys; check multiple variants.
    local function pick(tbl, ...)
        for _, key in ipairs({ ... }) do
            if tbl[key] ~= nil then return tbl[key] end
        end
        return nil
    end
    local across_clues = normalizeClueList(pick(clues_in, "Across", "ACROSS", "across"))
    local down_clues = normalizeClueList(pick(clues_in, "Down", "DOWN", "down"))

    return {
        title = tostring(doc.title or ""),
        author = tostring(doc.author or ""),
        copyright = tostring(doc.copyright or ""),
        notes = tostring(doc.notes or ""),
        width = width,
        height = height,
        solution = solution,
        across_clues = across_clues,
        down_clues = down_clues,
    }
end

return IpuzParser
