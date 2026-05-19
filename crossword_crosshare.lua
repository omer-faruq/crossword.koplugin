--[[
Crosshare API client.

Crosshare (https://crosshare.org) exposes each user-submitted puzzle at:
    https://crosshare.org/api/puz/<puzzleId>
which returns the puzzle as an Across Lite .puz binary download.

Puzzle pages have URLs of the form:
    https://crosshare.org/crosswords/<puzzleId>/<slug>

This module extracts the ID from either a bare ID or a full URL and fetches
the .puz binary. Callers are expected to hand the bytes to the .puz parser.
]]--

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local url = require("socket.url")
local logger = require("logger")

local Crosshare = {}

Crosshare.BASE_URL = "https://crosshare.org"
Crosshare.API_BASE = "https://crosshare.org/api/puz"
Crosshare.TIMEOUT_CONNECT = 10
Crosshare.TIMEOUT_READ = 30

-- Extract the Crosshare puzzle ID from various inputs.
--   "abc123"                                 -> "abc123"
--   "https://crosshare.org/crosswords/abc123/some-slug" -> "abc123"
--   "https://crosshare.org/api/puz/abc123"   -> "abc123"
--   "crosshare.org/crosswords/abc123"        -> "abc123"
function Crosshare.parseId(input)
    if type(input) ~= "string" then return nil end
    local trimmed = input:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then return nil end
    local id = trimmed:match("/crosswords/([%w%-]+)")
        or trimmed:match("/api/puz/([%w%-]+)")
    if id then return id end
    -- If it looks like a bare ID (alnum + hyphens), accept it.
    if trimmed:match("^[%w%-]+$") then
        return trimmed
    end
    return nil
end

local function httpRequest(options)
    local parsed = url.parse(options.url)
    local scheme = parsed and parsed.scheme or "https"
    if scheme == "https" then
        return https.request(options)
    end
    return http.request(options)
end

-- Fetch raw .puz bytes from Crosshare by ID.
-- Returns (puz_bytes, err).
function Crosshare.fetchPuz(puzzle_id)
    if type(puzzle_id) ~= "string" or puzzle_id == "" then
        return nil, "Missing Crosshare puzzle ID"
    end
    local endpoint = Crosshare.API_BASE .. "/" .. puzzle_id
    local sink = {}
    socketutil:set_timeout(Crosshare.TIMEOUT_CONNECT, Crosshare.TIMEOUT_READ)
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
        logger.warn("Crosshare: request failed", code)
        return nil, tostring(code or "network error")
    end
    if type(code) == "number" and code ~= 200 then
        return nil, string.format("HTTP %d from Crosshare", code)
    end
    local body = table.concat(sink)
    if #body < 60 then
        return nil, "Empty or too-small response from Crosshare"
    end
    -- A .puz has the magic "ACROSS&DOWN" at byte offset 2.
    if body:sub(3, 13) ~= "ACROSS&DOWN" then
        -- Some content-type hosts serve HTML for invalid IDs; detect that.
        if body:sub(1, 15):lower():find("<!doctype html") or body:sub(1, 15):lower():find("<html") then
            return nil, "Puzzle not found on Crosshare"
        end
        logger.warn("Crosshare: unexpected response", headers and headers["content-type"])
        return nil, "Response was not a .puz file"
    end
    return body
end

return Crosshare
