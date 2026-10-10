--[[
New York Times crossword downloader.

Uses the doshea/nyt_crosswords GitHub repository which contains every NYT
crossword from Jan 1st, 1976 to Mar 9th, 2018 in JSON format. The repository
is no longer updated, so later dates do not exist.

URL pattern:
https://raw.githubusercontent.com/doshea/nyt_crosswords/master/{year}/{month}/{day}.json

A local copy of the repo (see NYT.LOCAL_ARCHIVE_NAMES) is used before the
network when the caller passes the folders that may hold it.

Gaps in coverage (full list in NYT.GAPS): the longest are 1978 Aug 10 - Nov 5
and 2015 Aug 30 - 2016 May 1 (except 2016 Mar 1); about 100 more stretches
are missing, and from mid-2016 on only scattered days exist.

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

-- Coverage of the archive (it stopped being updated in March 2018)
NYT.FIRST_DATE = {year = 1976, month = 1, day = 1}
NYT.LAST_DATE = {year = 2018, month = 3, day = 9}

local function dateKey(date)
    return date.year * 10000 + date.month * 100 + date.day
end

function NYT.formatDate(date)
    return string.format("%04d-%02d-%02d", date.year, date.month, date.day)
end

function NYT.inRange(date)
    local key = dateKey(date)
    return key >= dateKey(NYT.FIRST_DATE) and key <= dateKey(NYT.LAST_DATE)
end

-- Missing stretches inside the range as {first, last} YYYYMMDD pairs, both
-- ends inclusive. Built from the repo's full file list (the archive is frozen
-- since 2018); its README names only the two longest gaps.
local GAP_KEYS = {
    {19780810, 19781105}, {19801229, 19801229}, {19840626, 19840626}, {19850828, 19850829},
    {19860817, 19860817}, {19920906, 19920906}, {19940114, 19940114}, {20020128, 20020131},
    {20020305, 20020305}, {20080217, 20080217}, {20131209, 20131209}, {20141010, 20141010},
    {20150810, 20150810}, {20150830, 20160229}, {20160302, 20160501}, {20160517, 20160517},
    {20160520, 20160522}, {20160526, 20160526}, {20160531, 20160531}, {20160602, 20160602},
    {20160605, 20160605}, {20160609, 20160609}, {20160611, 20160611}, {20160613, 20160613},
    {20160615, 20160615}, {20160619, 20160620}, {20160622, 20160701}, {20160703, 20160705},
    {20160707, 20160710}, {20160714, 20160715}, {20160720, 20160724}, {20160726, 20160726},
    {20160728, 20160728}, {20160730, 20160731}, {20160804, 20160807}, {20160810, 20160811},
    {20160813, 20160814}, {20160817, 20160820}, {20160822, 20160824}, {20160828, 20160828},
    {20160903, 20160903}, {20160908, 20160911}, {20160913, 20160913}, {20160915, 20160918},
    {20160922, 20160924}, {20160926, 20160926}, {20160928, 20160930}, {20161003, 20161003},
    {20161005, 20161007}, {20161010, 20161012}, {20161014, 20161015}, {20161017, 20161018},
    {20161021, 20161030}, {20161101, 20161105}, {20161108, 20161109}, {20161114, 20161114},
    {20161117, 20161117}, {20161120, 20161120}, {20161123, 20161126}, {20161201, 20161201},
    {20161203, 20161204}, {20161206, 20161209}, {20161211, 20161211}, {20161213, 20161217},
    {20161220, 20161220}, {20161222, 20161223}, {20161225, 20170103}, {20170105, 20170116},
    {20170118, 20170122}, {20170124, 20170124}, {20170126, 20170130}, {20170203, 20170203},
    {20170206, 20170207}, {20170209, 20170210}, {20170212, 20170212}, {20170214, 20170215},
    {20170218, 20170219}, {20170221, 20170221}, {20170224, 20170224}, {20170226, 20170226},
    {20170304, 20170305}, {20170307, 20170308}, {20170310, 20170312}, {20170316, 20170316},
    {20170318, 20170322}, {20170324, 20170326}, {20170330, 20170403}, {20170406, 20170409},
    {20170411, 20170411}, {20170413, 20170417}, {20170420, 20170421}, {20170423, 20170423},
    {20170425, 20170428}, {20170430, 20170501}, {20170503, 20170506}, {20170510, 20170514},
    {20170516, 20170522}, {20170524, 20170528}, {20170530, 20171130}, {20171202, 20171202},
    {20171204, 20180307},
}

local function keyToDate(key)
    return {year = math.floor(key / 10000), month = math.floor(key / 100) % 100, day = key % 100}
end

NYT.GAPS = {}
for _, pair in ipairs(GAP_KEYS) do
    NYT.GAPS[#NYT.GAPS + 1] = { first = keyToDate(pair[1]), last = keyToDate(pair[2]) }
end

function NYT.findGap(date)
    local key = dateKey(date)
    for i, pair in ipairs(GAP_KEYS) do
        if key >= pair[1] and key <= pair[2] then
            return NYT.GAPS[i]
        end
    end
end

-- Shift a date by `days`; noon keeps DST changes from skipping a day
local function addDays(date, days)
    local t = os.time{year = date.year, month = date.month, day = date.day, hour = 12}
    local d = os.date("*t", t + days * 86400)
    return {year = d.year, month = d.month, day = d.day}
end

-- The archive puzzle before (step = -1) or after (step = 1) `date`, jumping
-- over gaps. Returns nil at either end of the archive.
function NYT.adjacentDate(date, step)
    local next_date = addDays(date, step)
    local gap = NYT.findGap(next_date)
    if gap then
        next_date = addDays(step > 0 and gap.last or gap.first, step)
    end
    if not NYT.inRange(next_date) then
        return nil
    end
    return next_date
end

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

-- Decode an archive JSON string into internal puzzle data
function NYT.parseJSON(json_str)
    local ok, nyt_data = pcall(function() return json.decode(json_str) end)
    if not ok or type(nyt_data) ~= "table" then
        return nil, "Failed to parse NYT JSON"
    end
    return NYT.jsonToPuzzleData(nyt_data)
end

-- Load an archive JSON file from disk
function NYT.parseFile(path)
    local f, err = io.open(path, "rb")
    if not f then
        return nil, tostring(err or "Cannot open file")
    end
    local json_str = f:read("*a")
    f:close()
    local data, perr = NYT.parseJSON(json_str)
    if not data then
        return nil, "Not an NYT archive file: " .. tostring(perr)
    end
    return data
end

-- Relative path of a date inside the archive.
-- The repo uses zero-padded month and day (e.g., 08 not 8)
function NYT.datePath(date)
    return string.format("%d/%02d/%02d.json", date.year, date.month, date.day)
end

-- Folder names a local copy of the repo may have: a git clone, a GitHub zip
-- download, or the year folders copied directly.
NYT.LOCAL_ARCHIVE_NAMES = { "nyt_crosswords", "nyt_crosswords-master", "" }

-- Find the date's file in a local copy of the archive under any of `roots`
function NYT.findLocalFile(date, roots)
    local rel = NYT.datePath(date)
    for _, root in ipairs(roots or {}) do
        for _, name in ipairs(NYT.LOCAL_ARCHIVE_NAMES) do
            local path = name == "" and (root .. "/" .. rel)
                or (root .. "/" .. name .. "/" .. rel)
            local f = io.open(path, "rb")
            if f then
                f:close()
                return path
            end
        end
    end
end

-- Fetch NYT puzzle for a given date, preferring a local copy of the archive
-- under `local_roots`.
-- Returns puzzle data table (not .puz bytes)
function NYT.fetchPuzzle(date, local_roots)
    if not date or not date.year or not date.month or not date.day then
        return nil, "Invalid date for NYT puzzle"
    end
    
    local local_path = NYT.findLocalFile(date, local_roots)
    if local_path then
        logger.dbg("NYT: using local archive file", local_path)
        local data, lerr = NYT.parseFile(local_path)
        if not data then
            return nil, lerr
        end
        return {_nyt_data = data}
    end
    
    if not NYT.inRange(date) then
        return nil, string.format("NYT archive covers %s to %s",
            NYT.formatDate(NYT.FIRST_DATE), NYT.formatDate(NYT.LAST_DATE))
    end
    local gap = NYT.findGap(date)
    if gap then
        local first, last = NYT.formatDate(gap.first), NYT.formatDate(gap.last)
        if first == last then
            return nil, string.format("No NYT puzzle on %s (missing from the archive)", first)
        end
        return nil, string.format("No NYT puzzle on %s (archive gap: %s to %s)",
            NYT.formatDate(date), first, last)
    end
    
    local url = NYT.BASE_URL .. "/" .. NYT.datePath(date)
    
    local json_str, err = fetchString(url)
    if not json_str then
        return nil, err or "Failed to download NYT puzzle"
    end
    
    local data, cerr = NYT.parseJSON(json_str)
    if not data then
        return nil, cerr or "Failed to convert NYT puzzle"
    end
    
    -- Return as special marker for main.lua to detect
    return {_nyt_data = data}
end

return NYT
