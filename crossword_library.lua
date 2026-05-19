--[[
Crossword local library.

Scans the plugin's `puzzles/` folder for .puz and .ipuz files, optionally
merges recently-opened entries (which may live anywhere on the filesystem),
and loads the selected puzzle into a Puzzle instance via the right parser.
]]--

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local IpuzParser = require("crossword_ipuz_parser")
local Puzzle = require("crossword_puzzle")
local PuzParser = require("crossword_puz_parser")

local Library = {}

local function getPluginPath()
    local info = debug.getinfo(1, "S").source
    if info:sub(1, 1) == "@" then
        local src = info:sub(2):gsub("\\", "/")
        local dir = src:match("^(.*)/[^/]+$")
        if dir then return dir end
    end
    return DataStorage:getDataDir() .. "/plugins/crossword.koplugin"
end

Library.PLUGIN_PATH = getPluginPath()
Library.PUZZLES_DIR = ffiUtil.joinPath(Library.PLUGIN_PATH, "puzzles")

local function fileExists(path)
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file"
end

local function ensureDir(path)
    local attr = lfs.attributes(path)
    if not attr then
        lfs.mkdir(path)
    end
end

function Library.ensurePuzzlesDir()
    ensureDir(Library.PUZZLES_DIR)
end

function Library.detectFormat(path)
    local lower = path:lower()
    if lower:sub(-4) == ".puz" then return "puz" end
    if lower:sub(-5) == ".ipuz" then return "ipuz" end
    return nil
end

function Library.loadFromFile(path)
    local format = Library.detectFormat(path)
    if not format then
        return nil, _("Unsupported file extension (need .puz or .ipuz).")
    end
    if not fileExists(path) then
        return nil, _("File not found.")
    end
    local parser = (format == "puz") and PuzParser or IpuzParser
    local data, err = parser.parse(path)
    if not data then return nil, err end
    data.source = {
        type = "file",
        ref = path,
        format = format,
    }
    return Puzzle.new(data)
end

-- Returns a list of {title, author, path, format, size} entries for files
-- inside the puzzles/ directory.
function Library.listFiles()
    Library.ensurePuzzlesDir()
    local out = {}
    for name in lfs.dir(Library.PUZZLES_DIR) do
        local full = ffiUtil.joinPath(Library.PUZZLES_DIR, name)
        local attr = lfs.attributes(full)
        if attr and attr.mode == "file" then
            local format = Library.detectFormat(name)
            if format then
                out[#out + 1] = {
                    title = name,
                    path = full,
                    format = format,
                    size = attr.size,
                    modified = attr.modification,
                }
            end
        end
    end
    table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    return out
end

-- Very lightweight header-only peek to show title/author in the list without
-- fully parsing every file. Best-effort; returns nil on failure.
function Library.peek(entry)
    local ok, data = pcall(function()
        local parser = (entry.format == "puz") and PuzParser or IpuzParser
        return parser.parse(entry.path)
    end)
    if not ok or not data then return nil end
    return {
        title = (data.title and data.title ~= "") and data.title or entry.title,
        author = data.author or "",
        copyright = data.copyright or "",
        width = data.width,
        height = data.height,
    }
end

return Library
