--[[
Crossword local library.

Scans the puzzle folders (the plugin's `puzzles/` and `koreader/data/crossword/`)
for .puz, .ipuz and NYT archive .json files, optionally merges recently-opened
entries (which may live anywhere on the filesystem), and loads the selected
puzzle into a Puzzle instance via the right parser.
]]--

local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local IpuzParser = require("crossword_ipuz_parser")
local NYT = require("crossword_nyt")
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
-- Outside the plugin folder, so puzzles survive a plugin reinstall
Library.DATA_PUZZLES_DIR = ffiUtil.joinPath(DataStorage:getDataDir(), "data/crossword")
Library.PUZZLE_DIRS = { Library.PUZZLES_DIR, Library.DATA_PUZZLES_DIR }

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
    if lower:sub(-5) == ".json" then return "json" end
    return nil
end

local function parseFile(format, path)
    if format == "puz" then return PuzParser.parse(path) end
    if format == "ipuz" then return IpuzParser.parse(path) end
    return NYT.parseFile(path)
end

function Library.loadFromFile(path)
    local format = Library.detectFormat(path)
    if not format then
        return nil, _("Unsupported file extension (need .puz, .ipuz or .json).")
    end
    if not fileExists(path) then
        return nil, _("File not found.")
    end
    local data, err = parseFile(format, path)
    if not data then return nil, err end
    data.source = {
        type = "file",
        ref = path,
        format = format,
    }
    return Puzzle.new(data)
end

-- Returns a list of {title, author, path, format, size} entries for files
-- directly inside the puzzle folders. Subfolders (e.g. a full copy of the NYT
-- archive) are not listed; the NYT source reads those by date.
function Library.listFiles()
    Library.ensurePuzzlesDir()
    local out = {}
    for _idx, dir in ipairs(Library.PUZZLE_DIRS) do
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            for name in lfs.dir(dir) do
                local full = ffiUtil.joinPath(dir, name)
                local fattr = lfs.attributes(full)
                if fattr and fattr.mode == "file" then
                    local format = Library.detectFormat(name)
                    if format then
                        out[#out + 1] = {
                            title = name,
                            path = full,
                            format = format,
                            size = fattr.size,
                            modified = fattr.modification,
                        }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    return out
end

-- Very lightweight header-only peek to show title/author in the list without
-- fully parsing every file. Best-effort; returns nil on failure.
function Library.peek(entry)
    local ok, data = pcall(parseFile, entry.format, entry.path)
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
