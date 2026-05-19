--[[
Multi-source crossword puzzle downloader.

Supports downloading puzzles from various free sources:
- USA Today
- Universal Crossword
- The Atlantic
- Los Angeles Times
- Newsday
- Wall Street Journal
- Washington Post
- New Yorker

Each source provides a fetch function that returns .puz bytes or puzzle data.
]]--

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local json = require("json")
local logger = require("logger")

local AmuseLabs = require("crossword_amuselabs")
local NYT = require("crossword_nyt")
local PuzParser = require("crossword_puz_parser")

local Sources = {}

Sources.TIMEOUT_CONNECT = 10
Sources.TIMEOUT_READ = 30

local USER_AGENT = "Mozilla/5.0 (KOReader-CrosswordPlugin/0.1)"

local function httpRequest(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "https"
    if scheme == "https" then
        return https.request(options)
    end
    return http.request(options)
end

local function formatDate(date)
    local yy = date.year - 2000
    local mm = string.format("%02d", date.month)
    local dd = string.format("%02d", date.day)
    return yy, mm, dd
end

local function getTodayDate()
    local now = os.date("*t")
    return {year = now.year, month = now.month, day = now.day}
end

-- Generic .puz file downloader from Martin Herbach mirror
local function fetchPuzFromHerbach(path, source_name)
    local endpoint = "https://herbach.dnsalias.com/" .. path
    local sink = {}
    socketutil:set_timeout(Sources.TIMEOUT_CONNECT, Sources.TIMEOUT_READ)
    local ok, code, headers = httpRequest{
        url = endpoint,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"] = "KOReader-CrosswordPlugin/0.1",
            ["Accept"] = "application/octet-stream, */*",
        },
    }
    socketutil:reset_timeout()
    if not ok then
        logger.warn(source_name .. ": request failed", code)
        return nil, tostring(code or "network error")
    end
    if type(code) == "number" and code ~= 200 then
        return nil, string.format("HTTP %d", code)
    end
    local body = table.concat(sink)
    if #body < 60 then
        return nil, "Empty or too-small response"
    end
    if body:sub(3, 13) ~= "ACROSS&DOWN" then
        return nil, "Response was not a .puz file"
    end
    return body
end

-- USA Today (same as Universal - they share the same puzzle)
function Sources.fetchUSAToday(date)
    date = date or getTodayDate()
    local yy, mm, dd = formatDate(date)
    -- Note: USA Today and Universal are the same puzzle
    local path = string.format("uc/uc%s%s%s.puz", yy, mm, dd)
    return fetchPuzFromHerbach(path, "USA Today")
end

-- Universal Crossword (daily Mon-Sat)
function Sources.fetchUniversal(date)
    date = date or getTodayDate()
    local yy, mm, dd = formatDate(date)
    local path = string.format("uc/uc%s%s%s.puz", yy, mm, dd)
    return fetchPuzFromHerbach(path, "Universal")
end

-- Universal Sunday
function Sources.fetchUniversalSunday(date)
    date = date or getTodayDate()
    local yy, mm, dd = formatDate(date)
    local path = string.format("uc/ucs%s%s%s.puz", yy, mm, dd)
    return fetchPuzFromHerbach(path, "Universal Sunday")
end

-- Wall Street Journal
function Sources.fetchWSJ(date)
    date = date or getTodayDate()
    local yy, mm, dd = formatDate(date)
    local path = string.format("wsj/wsj%s%s%s.puz", yy, mm, dd)
    return fetchPuzFromHerbach(path, "Wall Street Journal")
end

-- Washington Post (Sunday only)
function Sources.fetchWashingtonPost(date)
    date = date or getTodayDate()
    
    -- WaPo only publishes on Sundays (day 0)
    -- If not Sunday, find the most recent Sunday
    local t = os.time(date)
    local dt = os.date("*t", t)
    local day_of_week = dt.wday - 1  -- 0=Sunday, 1=Monday, etc.
    
    if day_of_week ~= 0 then
        -- Go back to last Sunday
        local days_back = day_of_week
        t = t - (days_back * 86400)
        dt = os.date("*t", t)
        date = {year = dt.year, month = dt.month, day = dt.day}
    end
    
    local yy, mm, dd = formatDate(date)
    local path = string.format("WaPo/wp%s%s%s.puz", yy, mm, dd)
    local bytes, err = fetchPuzFromHerbach(path, "Washington Post")
    
    if not bytes and err then
        return nil, "Washington Post Sunday puzzle not available. The Herbach mirror may be down or this puzzle may not be archived."
    end
    
    return bytes, err
end

-- Jonesin' (Thursday puzzle, published Tuesday)
function Sources.fetchJonesin(date)
    date = date or getTodayDate()
    
    -- Jonesin is a Thursday puzzle published on Tuesday
    -- Calculate the Thursday of the current week
    local t = os.time(date)
    local dt = os.date("*t", t)
    local day_of_week = dt.wday - 1  -- 0=Sunday, 1=Monday, ..., 4=Thursday
    
    -- Find this week's Thursday (day 4)
    local days_to_thursday
    if day_of_week < 4 then
        -- Before Thursday this week, use last week's Thursday
        days_to_thursday = day_of_week + 7 - 4
    else
        -- Thursday or after, use this week's Thursday
        days_to_thursday = day_of_week - 4
    end
    
    t = t - (days_to_thursday * 86400)
    dt = os.date("*t", t)
    date = {year = dt.year, month = dt.month, day = dt.day}
    
    local yy, mm, dd = formatDate(date)
    local path = string.format("Jonesin/jz%s%s%s.puz", yy, mm, dd)
    return fetchPuzFromHerbach(path, "Jonesin'")
end

-- HTML entity decoder
local function htmlDecode(s)
    s = s:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&#(%d+);", function(n) return string.char(tonumber(n) or 32) end)
    s = s:gsub("&#[xX](%x+);", function(h) return string.char(tonumber(h, 16) or 32) end)
    s = s:gsub("&apos;", "'")
    return s
end

local function fetchHtml(url)
    local sink = {}
    socketutil:set_timeout(Sources.TIMEOUT_CONNECT, Sources.TIMEOUT_READ)
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

-- The Atlantic (uses AmuseLabs embed)
function Sources.fetchAtlantic(date)
    date = date or getTodayDate()
    local yyyy = date.year
    local mm = string.format("%02d", date.month)
    local dd = string.format("%02d", date.day)
    
    local url = string.format(
        "https://www.theatlantic.com/free-daily-crossword-puzzle/%s/%s/%s/",
        yyyy, mm, dd
    )
    
    local html, err = fetchHtml(url)
    if not html then return nil, err end
    
    -- Atlantic embeds AmuseLabs crossword. Look for the embed URL.
    local embed_url = html:match('https://amuselabs%.com/pmm/crossword%?[^"<>]+')
    if not embed_url then
        return nil, "Could not find AmuseLabs embed in Atlantic page"
    end
    
    -- Extract the puzzle ID from the embed URL
    local puzzle_id = embed_url:match('id=([^&"<>]+)')
    if not puzzle_id then
        return nil, "Could not extract puzzle ID from Atlantic embed"
    end
    
    -- Fetch the puzzle data from AmuseLabs API
    local api_url = "https://amuselabs.com/pmm/puzzle?id=" .. puzzle_id
    local puzzle_json, perr = fetchHtml(api_url)
    if not puzzle_json then return nil, perr end
    
    local ok, puzzle_data = pcall(function() return json.decode(puzzle_json) end)
    if not ok or type(puzzle_data) ~= "table" then
        return nil, "Failed to parse Atlantic puzzle JSON"
    end
    
    -- Convert AmuseLabs JSON to puzzle data (returns data table, not .puz bytes)
    local data, cerr = AmuseLabs.jsonToPuzzleData(puzzle_data)
    if not data then
        return nil, cerr or "Failed to convert Atlantic puzzle"
    end
    
    -- Return as special marker: {_amuselabs_data = data}
    -- Caller will detect this and use Puzzle.new directly instead of PuzParser
    return {_amuselabs_data = data}
end

-- Los Angeles Times
function Sources.fetchLATimes(date)
    date = date or getTodayDate()
    local yyyy = date.year
    local mm = string.format("%02d", date.month)
    local dd = string.format("%02d", date.day)
    
    -- LA Times uses AmuseLabs embed
    local url = string.format(
        "https://www.latimes.com/games/daily-crossword/%s-%s-%s",
        yyyy, mm, dd
    )
    
    local html, err = fetchHtml(url)
    if not html then return nil, err end
    
    -- Look for AmuseLabs embed
    local embed_url = html:match('https://amuselabs%.com/pmm/crossword%?[^"<>]+')
    if not embed_url then
        return nil, "Could not find AmuseLabs embed in LA Times page"
    end
    
    local puzzle_id = embed_url:match('id=([^&"<>]+)')
    if not puzzle_id then
        return nil, "Could not extract puzzle ID from LA Times embed"
    end
    
    local api_url = "https://amuselabs.com/pmm/puzzle?id=" .. puzzle_id
    local puzzle_json, perr = fetchHtml(api_url)
    if not puzzle_json then return nil, perr end
    
    local ok, puzzle_data = pcall(function() return json.decode(puzzle_json) end)
    if not ok or type(puzzle_data) ~= "table" then
        return nil, "Failed to parse LA Times puzzle JSON"
    end
    
    local data, cerr = AmuseLabs.jsonToPuzzleData(puzzle_data)
    if not data then
        return nil, cerr or "Failed to convert LA Times puzzle"
    end
    
    return {_amuselabs_data = data}
end

-- Newsday (try multiple possible URLs)
function Sources.fetchNewsday(date)
    date = date or getTodayDate()
    local yyyy = date.year
    local mm = string.format("%02d", date.month)
    local dd = string.format("%02d", date.day)
    local yy, _, _ = formatDate(date)
    
    -- Try Herbach mirror first (most reliable)
    local herbach_path = string.format("nd/nd%s%s%s.puz", yy, mm, dd)
    local bytes, err = fetchPuzFromHerbach(herbach_path, "Newsday")
    if bytes then return bytes end
    
    -- Fallback: try direct Newsday CDN (URL pattern may change)
    local cdn_urls = {
        string.format("https://cdn.newsday.com/ace/generic/crossword/Creators_%s%s%s.puz", yyyy, mm, dd),
        string.format("https://cdn3.newsday.com/crossword/Creators_%s%s%s.puz", yyyy, mm, dd),
    }
    
    for _, url in ipairs(cdn_urls) do
        local sink = {}
        socketutil:set_timeout(Sources.TIMEOUT_CONNECT, Sources.TIMEOUT_READ)
        local ok, code = httpRequest{
            url = url,
            method = "GET",
            sink = ltn12.sink.table(sink),
            headers = {
                ["User-Agent"] = USER_AGENT,
                ["Accept"] = "application/octet-stream, */*",
            },
        }
        socketutil:reset_timeout()
        if ok and type(code) == "number" and code == 200 then
            local body = table.concat(sink)
            if #body >= 60 and body:sub(3, 13) == "ACROSS&DOWN" then
                return body
            end
        end
    end
    
    return nil, err or "All Newsday download attempts failed"
end

-- BEQ (Brendan Emmett Quigley) - Monday & Thursday
function Sources.fetchBEQ(date)
    -- BEQ publishes on Monday and Thursday
    -- We'll fetch the latest puzzle from the homepage
    -- Note: Date parameter is ignored for now (always gets latest)
    
    local html, err = fetchHtml("https://brendanemmettquigley.com/")
    if not html then return nil, err end
    
    -- Look for .puz file link in the latest post
    -- Pattern: /files/XXXX.puz or brendanemmettquigley.com/files/XXXX.puz
    local puz_path = html:match('href="([^"]+%.puz)"')
    if not puz_path then
        return nil, "Could not find .puz file link on BEQ homepage"
    end
    
    -- Make sure it's a full URL
    local puz_url
    if puz_path:match("^https?://") then
        puz_url = puz_path
    elseif puz_path:match("^/") then
        puz_url = "https://brendanemmettquigley.com" .. puz_path
    else
        puz_url = "https://brendanemmettquigley.com/" .. puz_path
    end
    
    -- Download the .puz file
    local sink = {}
    socketutil:set_timeout(Sources.TIMEOUT_CONNECT, Sources.TIMEOUT_READ)
    local ok, code = httpRequest{
        url = puz_url,
        method = "GET",
        sink = ltn12.sink.table(sink),
        headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept"] = "application/octet-stream, */*",
        },
    }
    socketutil:reset_timeout()
    if not ok then
        return nil, tostring(code or "network error")
    end
    if type(code) == "number" and code ~= 200 then
        return nil, string.format("HTTP %d", code)
    end
    
    local body = table.concat(sink)
    if #body < 60 then
        return nil, "Empty or too-small response"
    end
    if body:sub(3, 13) ~= "ACROSS&DOWN" then
        return nil, "Response was not a .puz file"
    end
    
    return body
end

-- New York Times (from GitHub archive, 1977-present)
function Sources.fetchNYT(date)
    date = date or getTodayDate()
    return NYT.fetchPuzzle(date)
end

-- New Yorker (Monday only, free)
function Sources.fetchNewYorker(date)
    date = date or getTodayDate()
    local yyyy = date.year
    local mm = string.format("%02d", date.month)
    local dd = string.format("%02d", date.day)
    
    -- New Yorker Monday crossword is free, uses AmuseLabs
    local url = string.format(
        "https://www.newyorker.com/puzzles-and-games-dept/crossword/%s/%s/%s",
        yyyy, mm, dd
    )
    
    local html, err = fetchHtml(url)
    if not html then return nil, err end
    
    -- Look for AmuseLabs embed
    local embed_url = html:match('https://amuselabs%.com/pmm/crossword%?[^"<>]+')
    if not embed_url then
        return nil, "Could not find AmuseLabs embed in New Yorker page"
    end
    
    local puzzle_id = embed_url:match('id=([^&"<>]+)')
    if not puzzle_id then
        return nil, "Could not extract puzzle ID from New Yorker embed"
    end
    
    local api_url = "https://amuselabs.com/pmm/puzzle?id=" .. puzzle_id
    local puzzle_json, perr = fetchHtml(api_url)
    if not puzzle_json then return nil, perr end
    
    local ok, puzzle_data = pcall(function() return json.decode(puzzle_json) end)
    if not ok or type(puzzle_data) ~= "table" then
        return nil, "Failed to parse New Yorker puzzle JSON"
    end
    
    local data, cerr = AmuseLabs.jsonToPuzzleData(puzzle_data)
    if not data then
        return nil, cerr or "Failed to convert New Yorker puzzle"
    end
    
    return {_amuselabs_data = data}
end

-- Source definitions for menu building
Sources.SOURCES = {
    {
        id = "usatoday",
        label = "USA Today",
        fetch = Sources.fetchUSAToday,
        supports_date = true,
        free = true,
    },
    {
        id = "universal",
        label = "Universal Crossword",
        fetch = Sources.fetchUniversal,
        supports_date = true,
        free = true,
    },
    {
        id = "universal_sunday",
        label = "Universal Sunday",
        fetch = Sources.fetchUniversalSunday,
        supports_date = true,
        free = true,
        day_of_week = 0, -- Sunday only
    },
    {
        id = "wsj",
        label = "Wall Street Journal",
        fetch = Sources.fetchWSJ,
        supports_date = true,
        free = true,
    },
    {
        id = "wapo",
        label = "Washington Post Sunday",
        fetch = Sources.fetchWashingtonPost,
        supports_date = true,
        free = true,
        day_of_week = 0, -- Sunday only
    },
    {
        id = "jonesin",
        label = "Jonesin' (Thursday)",
        fetch = Sources.fetchJonesin,
        supports_date = true,
        free = true,
        day_of_week = 4, -- Thursday
    },
    {
        id = "newsday",
        label = "Newsday",
        fetch = Sources.fetchNewsday,
        supports_date = true,
        free = true,
    },
    {
        id = "beq",
        label = "BEQ (Latest)",
        fetch = Sources.fetchBEQ,
        supports_date = false, -- Always fetches latest puzzle
        free = true,
        note = "Monday & Thursday puzzles",
    },
    -- Disabled: HTML parsing sources are unreliable due to website changes
    -- {
    --     id = "atlantic",
    --     label = "The Atlantic",
    --     fetch = Sources.fetchAtlantic,
    --     supports_date = true,
    --     free = true,
    -- },
    -- {
    --     id = "latimes",
    --     label = "Los Angeles Times",
    --     fetch = Sources.fetchLATimes,
    --     supports_date = true,
    --     free = true,
    -- },
    -- {
    --     id = "newyorker",
    --     label = "The New Yorker (Monday)",
    --     fetch = Sources.fetchNewYorker,
    --     supports_date = true,
    --     free = true,
    --     day_of_week = 1, -- Monday only
    -- },
    {
        id = "nyt",
        label = "New York Times (Archive 1977+)",
        fetch = Sources.fetchNYT,
        supports_date = true,
        free = true,
        archive_note = "Latest puzzles may have 1-2 day delay",
    },
}

return Sources
