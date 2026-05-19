--[[
Persistence helper for the crossword plugin.

Stores:
  - current  : serialized puzzle in progress (Puzzle:serialize() output)
  - recents  : list of {source_type, source_ref, title, updated_at, progress_pct, completed}
               capped to the most-recent entries.
  - settings : misc plugin settings (generator defaults, last Crosshare id, etc.)

Uses LuaSettings to avoid an extra SQLite schema; the puzzle state is small
enough (<= a few hundred KB for very large 21x21 puzzles) to fit comfortably.
]]--

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local DB = {}
DB.__index = DB

local RECENTS_LIMIT = 30
local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/crossword.lua"

function DB.open()
    local self = setmetatable({}, DB)
    self.lua_settings = LuaSettings:open(SETTINGS_FILE)
    return self
end

function DB:flush()
    self.lua_settings:flush()
end

function DB:getCurrent()
    return self.lua_settings:readSetting("current")
end

function DB:setCurrent(state)
    self.lua_settings:saveSetting("current", state)
    self.lua_settings:flush()
end

function DB:clearCurrent()
    self.lua_settings:delSetting("current")
    self.lua_settings:flush()
end

function DB:getRecents()
    return self.lua_settings:readSetting("recents") or {}
end

local function recentKey(entry)
    -- A recent item is identified by (source_type, source_ref).
    return tostring(entry.source_type or "") .. "|" .. tostring(entry.source_ref or "")
end

function DB:updateRecent(entry)
    local recents = self:getRecents()
    local key = recentKey(entry)
    for i, existing in ipairs(recents) do
        if recentKey(existing) == key then
            table.remove(recents, i)
            break
        end
    end
    entry.updated_at = os.time()
    table.insert(recents, 1, entry)
    while #recents > RECENTS_LIMIT do
        table.remove(recents)
    end
    self.lua_settings:saveSetting("recents", recents)
    self.lua_settings:flush()
end

function DB:removeRecent(source_type, source_ref)
    local recents = self:getRecents()
    local key = tostring(source_type or "") .. "|" .. tostring(source_ref or "")
    for i, existing in ipairs(recents) do
        if recentKey(existing) == key then
            table.remove(recents, i)
            self.lua_settings:saveSetting("recents", recents)
            self.lua_settings:flush()
            return true
        end
    end
    return false
end

function DB:getSetting(key, default)
    local v = self.lua_settings:readSetting("settings_" .. key)
    if v == nil then return default end
    return v
end

function DB:setSetting(key, value)
    self.lua_settings:saveSetting("settings_" .. key, value)
    self.lua_settings:flush()
end

-- Cache: { source_type = "crosshare", source_ref = id, data = serialized_puzzle }
-- Avoid re-downloading the same puzzle.
function DB:getCachedPuzzle(source_type, source_ref)
    local cache = self.lua_settings:readSetting("puzzle_cache") or {}
    return cache[tostring(source_type) .. "|" .. tostring(source_ref)]
end

function DB:setCachedPuzzle(source_type, source_ref, data)
    local cache = self.lua_settings:readSetting("puzzle_cache") or {}
    cache[tostring(source_type) .. "|" .. tostring(source_ref)] = data
    -- Cap at 20 cached puzzles to avoid unbounded growth.
    local count = 0
    for _ in pairs(cache) do count = count + 1 end
    if count > 20 then
        -- Naively drop arbitrary entries; a real LRU would be nicer.
        local drop_needed = count - 20
        for k in pairs(cache) do
            if drop_needed <= 0 then break end
            cache[k] = nil
            drop_needed = drop_needed - 1
        end
    end
    self.lua_settings:saveSetting("puzzle_cache", cache)
    self.lua_settings:flush()
end

return DB
