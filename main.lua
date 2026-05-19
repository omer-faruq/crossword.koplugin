--[[
Crossword plugin for KOReader.

Main entry point. Registers menu items, coordinates loading puzzles from
local files, Crosshare, or the generator, and manages the in-progress
puzzle state.
]]--

local ButtonDialog = require("ui/widget/buttondialog")
local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local BookSource = require("crossword_book_source")
local Crosshare = require("crossword_crosshare")
local DB = require("crossword_db")
local GameScreen = require("crossword_game_screen")
local Generator = require("crossword_generator")
local Guardian = require("crossword_guardian")
local Library = require("crossword_library")
local Puzzle = require("crossword_puzzle")
local PuzParser = require("crossword_puz_parser")
local Settings = require("crossword_settings")
local Sources = require("crossword_sources")
local StarDict = require("crossword_stardict")
local VocabSource = require("crossword_vocab_source")

local Screen = Device.screen

local Crossword = WidgetContainer:extend{
    name = "crossword",
    is_doc_only = false,
}

function Crossword:init()
    self.db = DB.open()
    self.ui.menu:registerToMainMenu(self)
end

function Crossword:addToMainMenu(menu_items)
    menu_items.crossword = {
        text = _("Crossword"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:buildMenu()
        end,
    }
end

function Crossword:buildMenu()
    local items = {}

    items[#items + 1] = {
        text_func = function()
            local current = self.db:getCurrent()
            if current and current.title and current.title ~= "" then
                return T(_("Continue: %1"), current.title)
            end
            return _("Continue")
        end,
        enabled_func = function()
            return self.db:getCurrent() ~= nil
        end,
        callback = function()
            self:continuePuzzle()
        end,
    }

    items[#items + 1] = {
        text = _("Library (local files)"),
        callback = function() self:openLibrary() end,
    }

    items[#items + 1] = {
        text = _("Recently played"),
        enabled_func = function() return #self.db:getRecents() > 0 end,
        callback = function() self:openRecents() end,
    }

    items[#items + 1] = {
        text = _("Download from sources"),
        sub_item_table_func = function() return self:buildSourcesMenu() end,
    }

    items[#items + 1] = {
        text = _("Guardian crosswords"),
        sub_item_table_func = function() return self:buildGuardianMenu() end,
    }

    items[#items + 1] = {
        text = _("Get from Crosshare"),
        sub_item_table_func = function() return self:buildCrosshareMenu() end,
    }

    items[#items + 1] = {
        text = _("Generate puzzle"),
        callback = function() self:openGenerateMenu() end,
    }

    items[#items + 1] = {
        text = _("Settings"),
        sub_item_table_func = function()
            return Settings.buildSubMenu(self.db, function() end)
        end,
    }

    return items
end

-- --------------------------------------------------------------------------
-- Persistence helpers
-- --------------------------------------------------------------------------

function Crossword:saveCurrent(puzzle)
    if not puzzle then return end
    local state = puzzle:serialize()
    self.db:setCurrent(state)
    local filled, total = puzzle:progress()
    local progress_pct = 0
    if total > 0 then progress_pct = math.floor(100 * filled / total) end
    self.db:updateRecent{
        source_type = puzzle.source and puzzle.source.type or "unknown",
        source_ref = puzzle.source and puzzle.source.ref or "",
        title = puzzle.title or "",
        progress_pct = progress_pct,
        completed = puzzle:isSolved(),
        cached_state = (puzzle.source and puzzle.source.type ~= "file") and state or nil,
    }
end

function Crossword:onPuzzleSolved(puzzle)
    self:saveCurrent(puzzle)
end

function Crossword:onScreenClosed()
    self.screen = nil
end

function Crossword:showGame(puzzle)
    if self.screen then return end
    self.screen = GameScreen:new{
        puzzle = puzzle,
        plugin = self,
    }
    self:saveCurrent(puzzle)
    UIManager:show(self.screen)
end

-- --------------------------------------------------------------------------
-- Continue / Recents
-- --------------------------------------------------------------------------

function Crossword:continuePuzzle()
    local state = self.db:getCurrent()
    if not state then
        UIManager:show(InfoMessage:new{ text = _("No puzzle in progress."), timeout = 2 })
        return
    end
    local ok, puzzle = pcall(Puzzle.deserialize, state)
    if not ok or not puzzle then
        UIManager:show(InfoMessage:new{
            text = _("Could not restore saved puzzle."), timeout = 3,
        })
        return
    end
    self:showGame(puzzle)
end

local SOURCE_TAGS = {
    file = "FILE",
    crosshare = "CH",
    guardian = "GRD",
    source = "SRC",
    generated = "GEN",
    unknown = "?",
}

function Crossword:openRecents()
    local recents = self.db:getRecents()
    local items = {}
    for _idx, entry in ipairs(recents) do
        local captured = entry
        local progress = entry.progress_pct or 0
        local title = (entry.title and entry.title ~= "") and entry.title or _("Untitled")
        -- Keep the mandatory column short so it never starves the text column
        -- (KOReader's Menu crashes if the remaining text width becomes <= 0).
        local tag = SOURCE_TAGS[entry.source_type] or "?"
        local status = entry.completed and "✓" or (tostring(progress) .. "%")
        local mandatory = tag .. " " .. status
        items[#items + 1] = {
            text = title,
            mandatory = mandatory,
            callback = function()
                self:openRecentEntry(captured)
            end,
            hold_callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = _("Remove this entry from recents?"),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        self.db:removeRecent(captured.source_type, captured.source_ref)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }
    end
    if #items == 0 then
        items[#items + 1] = { text = _("No recent puzzles yet."), enabled = false }
    end
    local menu
    menu = Menu:new{
        title = _("Recent puzzles"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

function Crossword:openRecentEntry(entry)
    -- If we cached the full state (crosshare/generator), restore it directly.
    if entry.cached_state then
        local ok, puzzle = pcall(Puzzle.deserialize, entry.cached_state)
        if ok and puzzle then
            self:showGame(puzzle)
            return
        end
    end
    if entry.source_type == "file" then
        local puzzle, err = Library.loadFromFile(entry.source_ref)
        if not puzzle then
            UIManager:show(InfoMessage:new{ text = err or _("Failed to load file."), timeout = 3 })
            return
        end
        self:showGame(puzzle)
        return
    end
    if entry.source_type == "crosshare" then
        self:fetchFromCrosshare(entry.source_ref)
        return
    end
    if entry.source_type == "guardian" then
        local series, number = Guardian.parseRef(entry.source_ref or "")
        if series and number then
            self:fetchFromGuardian(series, number)
            return
        end
    end
    if entry.source_type == "source" then
        -- For multi-source puzzles, try to restore from cache
        local cached = self.db:getCachedPuzzle("source", entry.source_ref)
        if cached then
            local ok, puzzle = pcall(Puzzle.deserialize, cached)
            if ok and puzzle then
                self:showGame(puzzle)
                return
            end
        end
    end
    UIManager:show(InfoMessage:new{
        text = _("This puzzle source cannot be reopened."), timeout = 3,
    })
end

-- --------------------------------------------------------------------------
-- Library
-- --------------------------------------------------------------------------

function Crossword:openLibrary()
    Library.ensurePuzzlesDir()
    local files = Library.listFiles()
    local items = {}
    for _idx, entry in ipairs(files) do
        local captured = entry
        items[#items + 1] = {
            text = entry.title,
            mandatory = string.upper(entry.format),
            callback = function()
                local puzzle, err = Library.loadFromFile(captured.path)
                if not puzzle then
                    UIManager:show(InfoMessage:new{ text = err or _("Load failed."), timeout = 3 })
                    return
                end
                self:showGame(puzzle)
            end,
        }
    end
    if #items == 0 then
        items[#items + 1] = {
            text = T(_("No puzzles found under %1"), Library.PUZZLES_DIR),
            enabled = false,
        }
        items[#items + 1] = {
            text = _("(drop .puz or .ipuz files there)"),
            enabled = false,
        }
    end
    local menu
    menu = Menu:new{
        title = _("Crossword library"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

-- --------------------------------------------------------------------------
-- Multi-source downloads
-- --------------------------------------------------------------------------

function Crossword:buildSourcesMenu()
    local items = {}
    for _idx, source in ipairs(Sources.SOURCES) do
        local captured = source
        items[#items + 1] = {
            text = T(_("Today's %1"), captured.label),
            keep_menu_open = false,
            callback = function()
                self:fetchFromSource(captured, nil)
            end,
        }
    end
    items[#items + 1] = {
        text = _("By date…"),
        keep_menu_open = true,
        sub_item_table_func = function() return self:buildSourcesByDateMenu() end,
    }
    return items
end

function Crossword:buildSourcesByDateMenu()
    local items = {}
    for _idx, source in ipairs(Sources.SOURCES) do
        -- Only show sources that support date selection
        if source.supports_date ~= false then
            local captured = source
            items[#items + 1] = {
                text = captured.label,
                keep_menu_open = true,
                callback = function()
                    self:promptDateForSource(captured)
                end,
            }
        end
    end
    return items
end

function Crossword:promptDateForSource(source)
    local dialog
    dialog = InputDialog:new{
        title = T(_("%1 - Select date"), source.label),
        description = _("Examples:\n• 2020-05-15 or 05/15/2020\n• yesterday, 3 days ago, 7 days ago"),
        input = self.db:getSetting("last_source_date", "") or "",
        buttons = {
            {
                { text = _("Yesterday"), callback = function()
                    UIManager:close(dialog)
                    local now = os.date("*t")
                    local yesterday_time = os.time(now) - 86400
                    local yesterday = os.date("*t", yesterday_time)
                    self:fetchFromSource(source, {year = yesterday.year, month = yesterday.month, day = yesterday.day})
                end },
                { text = _("3 days ago"), callback = function()
                    UIManager:close(dialog)
                    local now = os.date("*t")
                    local past_time = os.time(now) - (3 * 86400)
                    local past = os.date("*t", past_time)
                    self:fetchFromSource(source, {year = past.year, month = past.month, day = past.day})
                end },
                { text = _("1 week ago"), callback = function()
                    UIManager:close(dialog)
                    local now = os.date("*t")
                    local past_time = os.time(now) - (7 * 86400)
                    local past = os.date("*t", past_time)
                    self:fetchFromSource(source, {year = past.year, month = past.month, day = past.day})
                end },
            },
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text = _("Download"),
                    is_enter_default = true,
                    callback = function()
                        local raw = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        local date = self:parseDate(raw)
                        if not date then
                            UIManager:show(InfoMessage:new{
                                text = _("Could not parse date. Try YYYY-MM-DD format."),
                                timeout = 3,
                            })
                            return
                        end
                        self.db:setSetting("last_source_date", raw)
                        self:fetchFromSource(source, date)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Crossword:parseDate(input)
    if type(input) ~= "string" or input == "" then return nil end
    local s = input:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- Try YYYY-MM-DD
    local y, m, d = s:match("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)$")
    if y and m and d then
        return {year = tonumber(y), month = tonumber(m), day = tonumber(d)}
    end
    
    -- Try MM/DD/YYYY
    m, d, y = s:match("^(%d%d?)%/(%d%d?)%/(%d%d%d%d)$")
    if y and m and d then
        return {year = tonumber(y), month = tonumber(m), day = tonumber(d)}
    end
    
    -- Try relative dates
    local now = os.date("*t")
    local lower = s:lower()
    if lower == "today" then
        return {year = now.year, month = now.month, day = now.day}
    elseif lower == "yesterday" then
        local now_time = os.time(now)
        local yesterday_time = now_time - 86400
        local yesterday = os.date("*t", yesterday_time)
        return {year = yesterday.year, month = yesterday.month, day = yesterday.day}
    else
        -- Try "N days ago"
        local n = lower:match("^(%d+)%s+days?%s+ago$")
        if n then
            local now_time = os.time(now)
            local past_time = now_time - (tonumber(n) * 86400)
            local past = os.date("*t", past_time)
            return {year = past.year, month = past.month, day = past.day}
        end
    end
    
    return nil
end

function Crossword:fetchFromSource(source, date)
    local source_id = source.id
    local source_label = source.label
    
    -- Use provided date or today
    if not date then
        local now = os.date("*t")
        date = {year = now.year, month = now.month, day = now.day}
    end
    
    local ref = string.format("%s/%04d-%02d-%02d", source_id, date.year, date.month, date.day)
    
    for _, entry in ipairs(self.db:getRecents()) do
        if entry.source_type == "source" and entry.source_ref == ref
            and entry.cached_state and not entry.completed then
            local ok, puzzle = pcall(Puzzle.deserialize, entry.cached_state)
            if ok and puzzle then
                puzzle.source = { type = "source", ref = ref, source_id = source_id }
                self:showGame(puzzle)
                return
            end
        end
    end
    
    -- Check pristine cache
    local cached = self.db:getCachedPuzzle("source", ref)
    if cached then
        local ok, puzzle = pcall(Puzzle.deserialize, cached)
        if ok and puzzle then
            puzzle.source = { type = "source", ref = ref, source_id = source_id }
            self:showGame(puzzle)
            return
        end
    end
    
    local date_str
    local now = os.date("*t")
    if date.year == now.year and date.month == now.month and date.day == now.day then
        date_str = _("today's")
    else
        date_str = string.format("%04d-%02d-%02d", date.year, date.month, date.day)
    end
    
    local info = InfoMessage:new{
        text = T(_("Downloading %1 %2..."), date_str, source_label),
    }
    UIManager:show(info)
    UIManager:forceRePaint()
    
    Trapper:wrap(function()
        local result, err = source.fetch(date)
        UIManager:close(info)
        if not result then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"), tostring(err or "unknown")),
                timeout = 4,
            })
            return
        end
        
        local data
        -- Check if result is AmuseLabs data (table with _amuselabs_data marker)
        if type(result) == "table" and result._amuselabs_data then
            data = result._amuselabs_data
        -- Check if result is NYT data (table with _nyt_data marker)
        elseif type(result) == "table" and result._nyt_data then
            data = result._nyt_data
        else
            -- Regular .puz bytes
            local perr
            data, perr = PuzParser.parse(result, true)
            if not data then
                UIManager:show(InfoMessage:new{
                    text = T(_("Parse failed: %1"), tostring(perr or "unknown")),
                    timeout = 4,
                })
                return
            end
        end
        
        data.source = { type = "source", ref = ref, source_id = source_id }
        local puzzle = Puzzle.new(data)
        self.db:setCachedPuzzle("source", ref, puzzle:serialize())
        self:showGame(puzzle)
    end)
end

-- --------------------------------------------------------------------------
-- Guardian
-- --------------------------------------------------------------------------

function Crossword:buildGuardianMenu()
    local items = {}
    for _idx, series in ipairs(Guardian.SERIES) do
        local captured = series
        items[#items + 1] = {
            text = T(_("Today's %1"), captured.label),
            keep_menu_open = false,
            callback = function()
                self:fetchFromGuardian(captured.id, nil)
            end,
        }
    end
    items[#items + 1] = {
        text = _("By number…"),
        keep_menu_open = true,
        callback = function() self:promptGuardianByNumber() end,
    }
    items[#items + 1] = {
        text = _("From Guardian URL…"),
        keep_menu_open = true,
        callback = function() self:promptGuardianByUrl() end,
    }
    return items
end

function Crossword:promptGuardianByNumber()
    local dialog
    dialog = InputDialog:new{
        title = _("Guardian puzzle by number"),
        description = _("Enter series and number, e.g. 'quick 16155' or 'cryptic 29123'."),
        input = self.db:getSetting("last_guardian_ref", "") or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Fetch"),
                is_enter_default = true,
                callback = function()
                    local raw = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    local series, number = Guardian.parseRef(raw)
                    if not series or not number then
                        UIManager:show(InfoMessage:new{
                            text = _("Could not parse Guardian reference."), timeout = 3,
                        })
                        return
                    end
                    self.db:setSetting("last_guardian_ref", series .. "/" .. number)
                    self:fetchFromGuardian(series, number)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Crossword:promptGuardianByUrl()
    local dialog
    dialog = InputDialog:new{
        title = _("Guardian URL"),
        description = _("Paste a https://www.theguardian.com/crosswords/... URL."),
        input = self.db:getSetting("last_guardian_url", "") or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Fetch"),
                is_enter_default = true,
                callback = function()
                    local raw = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    local series, number = Guardian.parseRef(raw)
                    if not series or not number then
                        UIManager:show(InfoMessage:new{
                            text = _("Could not parse Guardian URL."), timeout = 3,
                        })
                        return
                    end
                    self.db:setSetting("last_guardian_url", raw)
                    self:fetchFromGuardian(series, number)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Crossword:fetchFromGuardian(series, number)
    -- If we're requesting "today" (number == nil) we must hit the network to
    -- learn the current number; otherwise check progress cache first.
    if number then
        local ref = series .. "/" .. tostring(number)
        for _, entry in ipairs(self.db:getRecents()) do
            if entry.source_type == "guardian" and entry.source_ref == ref
                and entry.cached_state and not entry.completed then
                local ok, puzzle = pcall(Puzzle.deserialize, entry.cached_state)
                if ok and puzzle then
                    puzzle.source = { type = "guardian", ref = ref,
                                      series = series, number = number }
                    self:showGame(puzzle)
                    return
                end
            end
        end
    end

    local info = InfoMessage:new{
        text = number
            and T(_("Downloading Guardian %1 #%2..."), series, tostring(number))
            or T(_("Downloading today's Guardian %1..."), series),
    }
    UIManager:show(info)
    UIManager:forceRePaint()

    Trapper:wrap(function()
        local data, err
        if number then
            data, err = Guardian.fetchPuzzle(series, number)
        else
            data, err = Guardian.fetchLatest(series)
        end
        UIManager:close(info)
        if not data then
            UIManager:show(InfoMessage:new{
                text = T(_("Guardian download failed: %1"), tostring(err or "unknown")),
                timeout = 4,
            })
            return
        end
        local puzzle = Puzzle.new(data)
        self.db:setCachedPuzzle("guardian", puzzle.source.ref, puzzle:serialize())
        self:showGame(puzzle)
    end)
end

-- --------------------------------------------------------------------------
-- Crosshare
-- --------------------------------------------------------------------------

function Crossword:buildCrosshareMenu()
    return {
        {
            text = _("Paste Crosshare URL or ID…"),
            keep_menu_open = true,
            callback = function() self:promptCrosshareId() end,
        },
        {
            text = _("Open in browser: crosshare.org"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _(
                        "Crosshare does not expose a public search API.\n\n" ..
                        "Browse https://crosshare.org on any device, open a puzzle, then copy its URL " ..
                        "(or ID) and paste it here via 'Paste Crosshare URL or ID'."
                    ),
                    timeout = 10,
                })
            end,
        },
    }
end

function Crossword:promptCrosshareId()
    local last = self.db:getSetting("last_crosshare_id", "") or ""
    local dialog
    dialog = InputDialog:new{
        title = _("Crosshare puzzle"),
        description = _("Paste a Crosshare URL or puzzle ID."),
        input = last,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Fetch"),
                is_enter_default = true,
                callback = function()
                    local raw = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    local id = Crosshare.parseId(raw)
                    if not id then
                        UIManager:show(InfoMessage:new{
                            text = _("Could not find a Crosshare puzzle ID in that input."),
                            timeout = 3,
                        })
                        return
                    end
                    self.db:setSetting("last_crosshare_id", id)
                    self:fetchFromCrosshare(id)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Crossword:fetchFromCrosshare(puzzle_id)
    -- If the user already has this puzzle with progress, resume it.
    for _, entry in ipairs(self.db:getRecents()) do
        if entry.source_type == "crosshare" and entry.source_ref == puzzle_id
            and entry.cached_state and not entry.completed then
            local ok, puzzle = pcall(Puzzle.deserialize, entry.cached_state)
            if ok and puzzle then
                puzzle.source = { type = "crosshare", ref = puzzle_id }
                self:showGame(puzzle)
                return
            end
        end
    end

    -- Otherwise check the pristine cache to avoid re-downloading.
    local cached = self.db:getCachedPuzzle("crosshare", puzzle_id)
    if cached then
        local ok, puzzle = pcall(Puzzle.deserialize, cached)
        if ok and puzzle then
            puzzle.source = { type = "crosshare", ref = puzzle_id }
            self:showGame(puzzle)
            return
        end
    end

    local info = InfoMessage:new{
        text = T(_("Downloading %1 from Crosshare..."), puzzle_id),
    }
    UIManager:show(info)
    UIManager:forceRePaint()

    Trapper:wrap(function()
        local bytes, err = Crosshare.fetchPuz(puzzle_id)
        UIManager:close(info)
        if not bytes then
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed: %1"), tostring(err or "unknown")),
                timeout = 4,
            })
            return
        end
        local data, perr = PuzParser.parse(bytes, true)
        if not data then
            UIManager:show(InfoMessage:new{
                text = T(_("Parse failed: %1"), tostring(perr or "unknown")),
                timeout = 4,
            })
            return
        end
        data.source = { type = "crosshare", ref = puzzle_id }
        local puzzle = Puzzle.new(data)
        self.db:setCachedPuzzle("crosshare", puzzle_id, puzzle:serialize())
        self:showGame(puzzle)
    end)
end

-- --------------------------------------------------------------------------
-- Generator
-- --------------------------------------------------------------------------

function Crossword:openGenerateMenu()
    local dialog
    local function close() UIManager:close(dialog) end
    local has_document = self.ui and self.ui.document
    dialog = ButtonDialog:new{
        title = _("Generate puzzle"),
        buttons = {
            {
                {
                    text = _("From current book"),
                    background = Blitbuffer.COLOR_WHITE,
                    enabled = has_document,
                    callback = function() close(); self:openBookGenerator() end,
                },
            },
            {
                {
                    text = _("From Vocabulary Builder"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() close(); self:openVocabGenerator() end,
                },
            },
            {
                {
                    text = _("From StarDict dictionary"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() close(); self:openStarDictGenerator() end,
                },
            },
            {
                {
                    text = _("From TSV word list"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = function() close(); self:openTsvGenerator() end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    background = Blitbuffer.COLOR_WHITE,
                    callback = close,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Crossword:openStarDictGenerator()
    local data_dir = DataStorage:getDataDir() .. "/data/dict"
    local ifos = StarDict.listAvailable(data_dir)
    local preferred = Settings.get(self.db, "preferred_dictionary")
    if preferred and preferred ~= "" then
        -- Move preferred entry to top.
        for i, ifo in ipairs(ifos) do
            if ifo == preferred then
                table.remove(ifos, i)
                table.insert(ifos, 1, preferred)
                break
            end
        end
    end
    if #ifos == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No StarDict dictionaries found under %1."), data_dir),
            timeout = 4,
        })
        return
    end
    local items = {}
    for _, ifo in ipairs(ifos) do
        local captured = ifo
        local display = ifo:match("([^/\\]+)%.ifo$") or ifo
        items[#items + 1] = {
            text = display,
            callback = function() self:runStarDictGenerator(captured) end,
        }
    end
    local menu
    menu = Menu:new{
        title = _("Pick a dictionary"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

function Crossword:runStarDictGenerator(ifo_path)
    local info = InfoMessage:new{ text = _("Generating puzzle...") }
    UIManager:show(info)
    UIManager:forceRePaint()

    Trapper:setPausedText(_("Puzzle generation in progress..."), _("Cancel"), _("Continue"))
    local completed = Trapper:wrap(function()
        local reader, err = StarDict.open(ifo_path)
        if not reader then
            UIManager:close(info)
            UIManager:show(InfoMessage:new{
                text = T(_("Cannot open dictionary: %1"), tostring(err or "unknown")),
                timeout = 4,
            })
            return
        end
        local source = Generator.StarDictSource.wrap(reader)
        local size = Settings.get(self.db, "generator_width") or 11
        local target = Settings.get(self.db, "generator_target_words") or 22
        local min_len = Settings.get(self.db, "generator_min_len") or 3
        local puzzle, perr = Generator.generate{
            source = source,
            width = size,
            height = size,
            target_words = target,
            min_word_len = min_len,
            title = reader:getName() or "Generated",
            source_ref = ifo_path,
        }
        reader:close()
        UIManager:close(info)
        if not puzzle then
            UIManager:show(InfoMessage:new{
                text = T(_("Generation failed: %1"), tostring(perr or "unknown")),
                timeout = 4,
            })
            return
        end
        self:showGame(puzzle)
    end)
    
    if not completed then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = _("Puzzle generation cancelled."),
            timeout = 2,
        })
    end
end

function Crossword:openTsvGenerator()
    local dialog
    dialog = InputDialog:new{
        title = _("TSV word list"),
        description = _("Enter absolute path to a TSV file (one word<TAB>clue per line)."),
        input = self.db:getSetting("last_tsv_path", "") or "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Generate"),
                is_enter_default = true,
                callback = function()
                    local path = dialog:getInputText() or ""
                    UIManager:close(dialog)
                    if path == "" then return end
                    self.db:setSetting("last_tsv_path", path)
                    self:runTsvGenerator(path)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Crossword:runTsvGenerator(path)
    local source, err = Generator.TsvSource.open(path)
    if not source then
        UIManager:show(InfoMessage:new{
            text = T(_("Cannot read TSV: %1"), tostring(err or "unknown")),
            timeout = 4,
        })
        return
    end
    local size = Settings.get(self.db, "generator_width") or 11
    local target = Settings.get(self.db, "generator_target_words") or 22
    local min_len = Settings.get(self.db, "generator_min_len") or 3
    local puzzle, perr = Generator.generate{
        source = source,
        width = size,
        height = size,
        target_words = target,
        min_word_len = min_len,
        title = path:match("([^/\\]+)$") or "Generated",
        source_ref = path,
    }
    if not puzzle then
        UIManager:show(InfoMessage:new{
            text = T(_("Generation failed: %1"), tostring(perr or "unknown")),
            timeout = 4,
        })
        return
    end
    self:showGame(puzzle)
end

function Crossword:openBookGenerator()
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book is currently open."),
            timeout = 3,
        })
        return
    end
    
    local data_dir = DataStorage:getDataDir() .. "/data/dict"
    local ifos = StarDict.listAvailable(data_dir)
    local preferred = Settings.get(self.db, "preferred_dictionary")
    if preferred and preferred ~= "" then
        for i, ifo in ipairs(ifos) do
            if ifo == preferred then
                table.remove(ifos, i)
                table.insert(ifos, 1, preferred)
                break
            end
        end
    end
    
    local menu
    local items = {}
    items[#items + 1] = {
        text = _("Without dictionary (frequency-based clues)"),
        callback = function()
            UIManager:close(menu)
            self:runBookGenerator(nil)
        end,
    }
    
    for _, ifo in ipairs(ifos) do
        local captured = ifo
        local display = ifo:match("([^/\\]+)%.ifo$") or ifo
        items[#items + 1] = {
            text = display,
            callback = function()
                UIManager:close(menu)
                self:runBookGenerator(captured)
            end,
        }
    end
    
    menu = Menu:new{
        title = _("Pick a dictionary (optional)"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

function Crossword:runBookGenerator(ifo_path)
    local info = InfoMessage:new{ text = _("Extracting words from book...") }
    UIManager:show(info)
    UIManager:forceRePaint()
    
    Trapper:setPausedText(_("Puzzle generation in progress..."), _("Cancel"), _("Continue"))
    local completed = Trapper:wrap(function()
        local dict_reader = nil
        if ifo_path then
            local reader, err = StarDict.open(ifo_path)
            if not reader then
                UIManager:close(info)
                UIManager:show(InfoMessage:new{
                    text = T(_("Cannot open dictionary: %1"), tostring(err or "unknown")),
                    timeout = 4,
                })
                return
            end
            dict_reader = reader
        end
        
        local source, err = BookSource.create(self.ui, dict_reader, 2000)
        if dict_reader then
            dict_reader:close()
        end
        
        if not source then
            UIManager:close(info)
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to extract words: %1"), tostring(err or "unknown")),
                timeout = 4,
            })
            return
        end
        
        UIManager:close(info)
        UIManager:forceRePaint()
        
        local info2 = InfoMessage:new{ text = _("Generating puzzle...") }
        UIManager:show(info2)
        UIManager:forceRePaint()
        
        local size = Settings.get(self.db, "generator_width") or 11
        local target = Settings.get(self.db, "generator_target_words") or 22
        local min_len = Settings.get(self.db, "generator_min_len") or 3
        
        local book_title = self.ui.document:getProps().title or "Book"
        local puzzle, perr = Generator.generate{
            source = source,
            width = size,
            height = size,
            target_words = target,
            min_word_len = min_len,
            title = book_title,
            source_ref = "book:" .. (self.ui.document.file or ""),
        }
        
        UIManager:close(info2)
        
        if not puzzle then
            UIManager:show(InfoMessage:new{
                text = T(_("Generation failed: %1"), tostring(perr or "unknown")),
                timeout = 4,
            })
            return
        end
        
        self:showGame(puzzle)
    end)
    
    if not completed then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = _("Puzzle generation cancelled."),
            timeout = 2,
        })
    end
end

function Crossword:openVocabGenerator()
    local books = VocabSource.listBooks()
    
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No words found in Vocabulary Builder."),
            timeout = 3,
        })
        return
    end
    
    local menu
    local items = {}
    
    items[#items + 1] = {
        text = _("All books"),
        callback = function()
            UIManager:close(menu)
            self:selectVocabDictionary(nil, "All books")
        end,
    }
    
    for _, book in ipairs(books) do
        local captured_id = book.id
        local captured_name = book.name
        items[#items + 1] = {
            text = string.format("%s (%d words)", book.name, book.word_count),
            callback = function()
                UIManager:close(menu)
                self:selectVocabDictionary(captured_id, captured_name)
            end,
        }
    end
    
    menu = Menu:new{
        title = _("Select book"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

function Crossword:selectVocabDictionary(title_id, book_name)
    local data_dir = DataStorage:getDataDir() .. "/data/dict"
    local ifos = StarDict.listAvailable(data_dir)
    
    if #ifos == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No dictionaries found. Please install a dictionary first."),
            timeout = 3,
        })
        return
    end
    
    local preferred = Settings.get(self.db, "preferred_dictionary")
    if preferred and preferred ~= "" then
        for i, ifo in ipairs(ifos) do
            if ifo == preferred then
                table.remove(ifos, i)
                table.insert(ifos, 1, preferred)
                break
            end
        end
    end
    
    local menu
    local items = {}
    
    for _, ifo in ipairs(ifos) do
        local captured = ifo
        local display = ifo:match("([^/\\]+)%.ifo$") or ifo
        items[#items + 1] = {
            text = display,
            callback = function()
                UIManager:close(menu)
                self:runVocabGenerator(captured, title_id, book_name)
            end,
        }
    end
    
    menu = Menu:new{
        title = _("Select dictionary"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.9),
    }
    UIManager:show(menu)
end

function Crossword:runVocabGenerator(ifo_path, title_id, book_name)
    local info = InfoMessage:new{ text = _("Loading words from Vocabulary Builder...") }
    UIManager:show(info)
    UIManager:forceRePaint()
    
    Trapper:setPausedText(_("Puzzle generation in progress..."), _("Cancel"), _("Continue"))
    local completed = Trapper:wrap(function()
        local reader, err = StarDict.open(ifo_path)
        if not reader then
            UIManager:close(info)
            UIManager:show(InfoMessage:new{
                text = T(_("Cannot open dictionary: %1"), tostring(err or "unknown")),
                timeout = 4,
            })
            return
        end
        
        local source, serr = VocabSource.create(reader, title_id)
        reader:close()
        
        if not source then
            UIManager:close(info)
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to load words: %1"), tostring(serr or "unknown")),
                timeout = 4,
            })
            return
        end
        
        UIManager:close(info)
        UIManager:forceRePaint()
        
        local info2 = InfoMessage:new{ text = _("Generating puzzle...") }
        UIManager:show(info2)
        UIManager:forceRePaint()
        
        local default_size = Settings.get(self.db, "generator_width") or 11
        local default_target = Settings.get(self.db, "generator_target_words") or 22
        local min_len = Settings.get(self.db, "generator_min_len") or 3
        
        local puzzle, perr = Generator.generate{
            source = source,
            width = default_size,
            height = default_size,
            target_words = default_target,
            min_word_len = min_len,
            title = book_name or "Vocabulary Builder",
            source_ref = "vocab:" .. (title_id or "all"),
        }
        
        if not puzzle then
            UIManager:close(info2)
            local info3 = InfoMessage:new{ text = _("Retrying with smaller puzzle...") }
            UIManager:show(info3)
            UIManager:forceRePaint()
            
            local small_size = 9
            local small_target = 12
            
            puzzle, perr = Generator.generate{
                source = source,
                width = small_size,
                height = small_size,
                target_words = small_target,
                min_word_len = min_len,
                title = book_name or "Vocabulary Builder",
                source_ref = "vocab:" .. (title_id or "all"),
            }
            
            UIManager:close(info3)
        else
            UIManager:close(info2)
        end
        
        if not puzzle then
            UIManager:show(InfoMessage:new{
                text = T(_("Generation failed: %1"), tostring(perr or "unknown")),
                timeout = 4,
            })
            return
        end
        
        self:showGame(puzzle)
    end)
    
    if not completed then
        UIManager:close(info)
        UIManager:show(InfoMessage:new{
            text = _("Puzzle generation cancelled."),
            timeout = 2,
        })
    end
end

return Crossword
