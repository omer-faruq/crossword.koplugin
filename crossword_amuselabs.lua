--[[
AmuseLabs puzzle format converter.

AmuseLabs (PuzzleMe) is used by The Atlantic, LA Times, New Yorker, and others.
Their JSON format needs to be converted to our internal puzzle data structure.

Example JSON structure:
{
  "title": "Puzzle Title",
  "author": "Author Name",
  "w": 15,
  "h": 15,
  "box": [
    ["A", "B", "C", ...],  -- row 1
    ["D", "E", "F", ...],  -- row 2
    ...
  ],
  "clues": {
    "across": [
      {"clue": "Clue text", "answer": "ANSWER", "number": 1},
      ...
    ],
    "down": [
      {"clue": "Clue text", "answer": "ANSWER", "number": 1},
      ...
    ]
  }
}

Or alternative format with "gridnums" and separate clues arrays.
]]--

local AmuseLabs = {}

-- Convert AmuseLabs JSON to internal puzzle data format
function AmuseLabs.jsonToPuzzleData(json_data)
    if type(json_data) ~= "table" then
        return nil, "Invalid AmuseLabs data: not a table"
    end
    
    local width = tonumber(json_data.w)
    local height = tonumber(json_data.h)
    
    if not width or not height then
        return nil, "Missing or invalid dimensions in AmuseLabs puzzle"
    end
    
    -- Build solution grid from box array
    local solution = {}
    local box = json_data.box
    if type(box) ~= "table" then
        return nil, "Missing box array in AmuseLabs puzzle"
    end
    
    for r = 1, height do
        solution[r] = {}
        local row = box[r]
        if type(row) ~= "table" then
            return nil, "Invalid row in AmuseLabs box array"
        end
        for c = 1, width do
            local cell = row[c]
            if cell == "." or cell == "#" or cell == nil then
                solution[r][c] = false  -- black square
            else
                solution[r][c] = tostring(cell):upper()
            end
        end
    end
    
    -- Extract clues
    local across_clues = {}
    local down_clues = {}
    
    local clues = json_data.clues
    if type(clues) == "table" then
        -- Format 1: clues.across and clues.down arrays with objects
        if type(clues.across) == "table" then
            for _, entry in ipairs(clues.across) do
                local num = tonumber(entry.number)
                if num then
                    across_clues[num] = tostring(entry.clue or "")
                end
            end
        end
        if type(clues.down) == "table" then
            for _, entry in ipairs(clues.down) do
                local num = tonumber(entry.number)
                if num then
                    down_clues[num] = tostring(entry.clue or "")
                end
            end
        end
    end
    
    -- Alternative format: separate "acrossClues" and "downClues" arrays
    if json_data.acrossClues and type(json_data.acrossClues) == "table" then
        for _, clue_text in ipairs(json_data.acrossClues) do
            -- Parse "1. Clue text" format
            local num, text = tostring(clue_text):match("^(%d+)%.%s*(.+)$")
            if num and text then
                across_clues[tonumber(num)] = text
            end
        end
    end
    if json_data.downClues and type(json_data.downClues) == "table" then
        for _, clue_text in ipairs(json_data.downClues) do
            local num, text = tostring(clue_text):match("^(%d+)%.%s*(.+)$")
            if num and text then
                down_clues[tonumber(num)] = text
            end
        end
    end
    
    return {
        title = tostring(json_data.title or "AmuseLabs Puzzle"),
        author = tostring(json_data.author or ""),
        copyright = tostring(json_data.copyright or ""),
        notes = tostring(json_data.notes or json_data.notepad or ""),
        width = width,
        height = height,
        solution = solution,
        across_clues = across_clues,
        down_clues = down_clues,
    }
end

return AmuseLabs
