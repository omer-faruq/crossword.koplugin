--[[
Guardian crossword client.

The Guardian publishes all their crosswords publicly at URLs like:
    https://www.theguardian.com/crosswords/<series>/<number>

The solver JSON is embedded in the rendered HTML inside a <gu-island> tag:
    <gu-island name="CrosswordComponent" props="<JSON-HTML-escaped>">...</gu-island>
HTML-decoding the `props` attribute yields a JSON object with a `data` field
containing the puzzle:

    {
      "data": {
        "id": "crosswords/quick/16155",
        "number": 16155,
        "name": "Quick crossword No 16,155",
        "date": 1644969600000,
        "dimensions": {"rows": 13, "cols": 13},
        "entries": [
          {"number":1,"direction":"across","length":7,
           "position":{"x":0,"y":0},"solution":"SIROCCO","clue":"..."},
          ...
        ]
      }
    }

This module:
  1. Parses a Guardian puzzle URL into (series, number).
  2. Fetches "today's" puzzle of a series by scraping the series landing page.
  3. Extracts the props JSON and returns a Puzzle-shaped table.

Supported series (all free, no auth needed):
    quick, cryptic, everyman, speedy, prize, weekend, quiptic
]]--

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local json = require("json")
local logger = require("logger")

local Guardian = {}

Guardian.BASE_URL = "https://www.theguardian.com/crosswords"
Guardian.TIMEOUT_CONNECT = 10
Guardian.TIMEOUT_READ = 30

-- Series the user can browse. Keep display labels stable for i18n.
Guardian.SERIES = {
    { id = "quick",    label = "Quick" },
    { id = "cryptic",  label = "Cryptic" },
    { id = "everyman", label = "Everyman (Sunday)" },
    { id = "speedy",   label = "Speedy (Sunday)" },
    { id = "prize",    label = "Prize" },
    { id = "weekend",  label = "Weekend" },
    { id = "quiptic",  label = "Quiptic" },
}

local USER_AGENT = "Mozilla/5.0 (KOReader-CrosswordPlugin/0.1)"

local function httpRequest(options)
    -- Always use https; Guardian redirects to https regardless.
    return https.request(options)
end

local function fetchString(url)
    local sink = {}
    socketutil:set_timeout(Guardian.TIMEOUT_CONNECT, Guardian.TIMEOUT_READ)
    local ok, code = httpRequest{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept"] = "text/html,*/*",
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

-- Parse a Guardian puzzle URL or "series/number" shorthand.
-- Returns (series, number) or nil.
function Guardian.parseRef(input)
    if type(input) ~= "string" then return nil end
    local s = input:gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil end
    local series, number = s:match("/crosswords/([%w%-]+)/(%d+)")
    if series and number then return series, tonumber(number) end
    series, number = s:match("^([%w%-]+)%s*/%s*(%d+)$")
    if series and number then return series, tonumber(number) end
    return nil
end

-- Minimal HTML entity decoder. The `props` attribute is HTML-escaped (mostly
-- just &quot; &amp; &lt; &gt; &#39; &#x27;).
local function htmlDecode(s)
    s = s:gsub("&quot;", "\""):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&#(%d+);", function(n) return string.char(tonumber(n) or 32) end)
    s = s:gsub("&#[xX](%x+);", function(h) return string.char(tonumber(h, 16) or 32) end)
    s = s:gsub("&apos;", "'")
    return s
end

-- Extract puzzle JSON `data` table from HTML of a crossword page.
local function extractDataFromHtml(html)
    -- Find the gu-island for the CrosswordComponent. Its `props` attribute
    -- holds the JSON we need.
    local props = html:match(
        "<gu%-island[^>]-name=\"CrosswordComponent\"[^>]-props=\"([^\"]+)\"")
    if not props then
        -- Try the reverse attribute ordering (props first, name later).
        props = html:match(
            "<gu%-island[^>]-props=\"([^\"]+)\"[^>]-name=\"CrosswordComponent\"")
    end
    if not props then
        return nil, "Could not locate CrosswordComponent in page."
    end
    local decoded = htmlDecode(props)
    local ok, doc = pcall(function() return json.decode(decoded) end)
    if not ok or type(doc) ~= "table" then
        return nil, "Failed to parse Guardian JSON payload."
    end
    local data = doc.data
    if type(data) ~= "table" then
        return nil, "Guardian payload missing `data` field."
    end
    return data
end

-- Convert the Guardian JSON structure into the shape Puzzle.new expects.
local function guardianDataToPuzzleData(data, series, number)
    local dims = data.dimensions or {}
    local width = tonumber(dims.cols)
    local height = tonumber(dims.rows)
    if not width or not height then
        return nil, "Missing dimensions in Guardian puzzle."
    end

    -- Start with an all-black grid; entries will reveal white cells.
    local solution = {}
    for r = 1, height do
        solution[r] = {}
        for c = 1, width do solution[r][c] = false end
    end

    local across_clues, down_clues = {}, {}
    if type(data.entries) ~= "table" then
        return nil, "Missing entries in Guardian puzzle."
    end
    for _, entry in ipairs(data.entries) do
        local dir = entry.direction
        local num = tonumber(entry.number)
        local length = tonumber(entry.length) or 0
        local pos = entry.position or {}
        local x = tonumber(pos.x)  -- 0-indexed column
        local y = tonumber(pos.y)  -- 0-indexed row
        local sol = entry.solution or ""
        if dir and num and x and y and length > 0 then
            local clue_text = tostring(entry.clue or "")
            if dir == "across" then
                across_clues[num] = clue_text
            elseif dir == "down" then
                down_clues[num] = clue_text
            end
            for i = 1, length do
                local rr, cc
                if dir == "across" then
                    rr = y + 1
                    cc = x + i
                else
                    rr = y + i
                    cc = x + 1
                end
                if rr >= 1 and rr <= height and cc >= 1 and cc <= width then
                    local ch = sol:sub(i, i)
                    if ch == "" then
                        if solution[rr][cc] == false then
                            solution[rr][cc] = "?"
                        end
                    else
                        solution[rr][cc] = ch:upper()
                    end
                end
            end
        end
    end

    return {
        title = tostring(data.name or ("Guardian " .. tostring(number))),
        author = tostring((data.creator and data.creator.name) or "The Guardian"),
        copyright = "© Guardian News & Media",
        notes = "",
        width = width,
        height = height,
        solution = solution,
        across_clues = across_clues,
        down_clues = down_clues,
        source = {
            type = "guardian",
            ref = series .. "/" .. tostring(number),
            series = series,
            number = number,
        },
    }
end

-- Fetch a specific Guardian puzzle as puzzle data (pass to Puzzle.new).
function Guardian.fetchPuzzle(series, number)
    if not series or not number then
        return nil, "Missing Guardian series/number."
    end
    local url = Guardian.BASE_URL .. "/" .. series .. "/" .. tostring(number)
    local html, err = fetchString(url)
    if not html then return nil, err end
    local data, derr = extractDataFromHtml(html)
    if not data then return nil, derr end
    return guardianDataToPuzzleData(data, series, number)
end

-- Scrape the series landing page to find the latest puzzle number of a series.
-- Returns the latest puzzle number or nil on failure.
function Guardian.findLatestNumber(series)
    local url = Guardian.BASE_URL .. "/series/" .. series
    local html, err = fetchString(url)
    if not html then return nil, err end
    -- Look for the first href matching /crosswords/<series>/<number>.
    local pattern = '/crosswords/' .. series:gsub("%-", "%%-") .. '/(%d+)'
    local first = html:match(pattern)
    if first then return tonumber(first) end
    -- Fallback: look at generic landing page.
    local html2, err2 = fetchString(Guardian.BASE_URL)
    if not html2 then return nil, err2 end
    local s2, n2 = html2:match('/crosswords/(' .. series .. ')/(%d+)')
    if n2 then return tonumber(n2) end
    return nil, "Could not find latest " .. series .. " puzzle."
end

-- Fetch the latest puzzle of a given series. Returns puzzle data.
function Guardian.fetchLatest(series)
    local number, err = Guardian.findLatestNumber(series)
    if not number then return nil, err end
    return Guardian.fetchPuzzle(series, number)
end

-- Expose a helper for series labels.
function Guardian.seriesLabel(series_id)
    for _, entry in ipairs(Guardian.SERIES) do
        if entry.id == series_id then return entry.label end
    end
    return series_id
end

return Guardian
