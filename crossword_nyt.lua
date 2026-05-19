--[[
New York Times crossword downloader.

Uses the doshea/nyt_crosswords GitHub repository which contains every NYT
crossword since Jan 1st, 1977 in JSON format.

URL pattern:
https://raw.githubusercontent.com/doshea/nyt_crosswords/master/{year}/{month}/{day}.json

Known gaps in coverage:
- 1978: Aug 10 - Nov 5
- 2015-16: Aug 30 - May 1

JSON format example:
{
  "title": "NY TIMES, WED, AUG 12, 1998",
  "author": "Alan Arbesfeld",
  "editor": "Will Shortz",
  "copyright": "1998, The New York Times",
  "date": "8/12/1998",
  "size": {"cols": 15, "rows": 15},
  "grid": ["A","B","C",...],
  "gridnums": [1,2,3,...],
  "answers": {
    "across": ["ABCDE","ELK",...],
    "down": ["ATLAST","BRONCO",...]
  },
  "clues": {
    "across": ["1. Start of a well-known series",...],
    "down": ["1. It's about time!",...] 
  }
}
]]--

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local NYT = {}

NYT.BASE_URL = "https://raw.githubusercontent.com/doshea/nyt_crosswords/master"
NYT.TIMEOUT_CONNECT = 10
NYT.TIMEOUT_READ = 30

local USER_AGENT = "Mozilla/5.0 (KOReader-CrosswordPlugin/0.1)"

local function httpRequest(options)
    return https.request(options)
end

local function fetchString(url)
    local sink = {}
    socketutil:set_timeout(NYT.TIMEOUT_CONNECT, NYT.TIMEOUT_READ)
    local ok, code = httpRequest{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept"] = "application/json,*/*",
        },
    }
    socketutil:reset_timeout()
    if not ok then
        return nil, tostring(code or "network error")
    end
    if type(code) == "number" and code ~= 200 then
        return nil, string.format("HTTP %d", code)
    end
    return table.concat(sink)
end

-- Convert NYT JSON to internal puzzle data format
function NYT.jsonToPuzzleData(nyt_data)
    if type(nyt_data) ~= "table" then
        return nil, "Invalid NYT data: not a table"
    end
    
    local size = nyt_data.size
    if type(size) ~= "table" then
        return nil, "Missing size in NYT puzzle"
    end
    
    local width = tonumber(size.cols)
    local height = tonumber(size.rows)
    if not width or not height then
        return nil, "Invalid dimensions in NYT puzzle"
    end
    
    -- Build solution grid from grid array and gridnums
    local solution = {}
    local grid = nyt_data.grid
    local gridnums = nyt_data.gridnums
    
    if type(grid) ~= "table" or type(gridnums) ~= "table" then
        return nil, "Missing grid or gridnums in NYT puzzle"
    end
    
    for r = 1, height do
        solution[r] = {}
        for c = 1, width do
            local idx = (r - 1) * width + c
            local cell = grid[idx]
            if cell == "." then
                solution[r][c] = false  -- black square
            else
                solution[r][c] = tostring(cell):upper()
            end
        end
    end
    
    -- Extract clues
    local across_clues = {}
    local down_clues = {}
    
    local clues = nyt_data.clues
    if type(clues) == "table" then
        if type(clues.across) == "table" then
            for _, clue_text in ipairs(clues.across) do
                -- Parse "1. Clue text" format
                local num, text = tostring(clue_text):match("^(%d+)%.%s*(.+)$")
                if num and text then
                    across_clues[tonumber(num)] = text
                end
            end
        end
        if type(clues.down) == "table" then
            for _, clue_text in ipairs(clues.down) do
                local num, text = tostring(clue_text):match("^(%d+)%.%s*(.+)$")
                if num and text then
                    down_clues[tonumber(num)] = text
                end
            end
        end
    end
    
    return {
        title = tostring(nyt_data.title or "New York Times Crossword"),
        author = tostring(nyt_data.author or ""),
        copyright = tostring(nyt_data.copyright or "© The New York Times"),
        notes = tostring(nyt_data.notepad or ""),
        width = width,
        height = height,
        solution = solution,
        across_clues = across_clues,
        down_clues = down_clues,
    }
end

-- Fetch NYT puzzle for a given date
-- Returns puzzle data table (not .puz bytes)
function NYT.fetchPuzzle(date)
    if not date or not date.year or not date.month or not date.day then
        return nil, "Invalid date for NYT puzzle"
    end
    
    -- GitHub repo uses zero-padded month and day (e.g., 08 not 8)
    local url = string.format(
        "%s/%d/%02d/%02d.json",
        NYT.BASE_URL,
        date.year,
        date.month,
        date.day
    )
    
    local json_str, err = fetchString(url)
    if not json_str then
        -- Check if it's a known gap
        if date.year == 1978 and date.month >= 8 and date.month <= 11 then
            return nil, "NYT puzzle not available (known gap: Aug-Nov 1978)"
        elseif date.year == 2015 and date.month >= 8 then
            return nil, "NYT puzzle not available (known gap: Aug 2015 - May 2016)"
        elseif date.year == 2016 and date.month <= 5 then
            return nil, "NYT puzzle not available (known gap: Aug 2015 - May 2016)"
        end
        return nil, err or "Failed to download NYT puzzle"
    end
    
    local ok, nyt_data = pcall(function() return json.decode(json_str) end)
    if not ok or type(nyt_data) ~= "table" then
        return nil, "Failed to parse NYT JSON"
    end
    
    local data, cerr = NYT.jsonToPuzzleData(nyt_data)
    if not data then
        return nil, cerr or "Failed to convert NYT puzzle"
    end
    
    -- Return as special marker for main.lua to detect
    return {_nyt_data = data}
end

return NYT
