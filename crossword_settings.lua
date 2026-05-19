--[[
Settings sub-menu for the crossword plugin.

Exposes:
  - default generator grid size
  - default target word count
  - preferred dictionary path (ifo) for the generator
  - auto-reveal on wrong letter (opt-in)

The returned table is meant to be used as a sub_item_table under the plugin's
main menu entry.
]]--

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local StarDict = require("crossword_stardict")

local Settings = {}

Settings.DEFAULTS = {
    generator_width = 11,
    generator_height = 11,
    generator_target_words = 22,
    generator_min_len = 3,
    preferred_dictionary = "",
    auto_check_on_commit = false,
}

function Settings.get(db, key)
    return db:getSetting(key, Settings.DEFAULTS[key])
end

function Settings.set(db, key, value)
    db:setSetting(key, value)
end

local function showIntegerInput(title, current, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(current or ""),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local val = tonumber(dialog:getInputText())
                    if val then on_save(val) end
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function listDictionaries()
    local data_dir = DataStorage:getDataDir() .. "/data/dict"
    return StarDict.listAvailable(data_dir)
end

function Settings.buildSubMenu(db, on_change)
    local function refresh() if on_change then on_change() end end

    return {
        {
            text_func = function()
                return T(_("Generator grid: %1 × %2"),
                    Settings.get(db, "generator_width"),
                    Settings.get(db, "generator_height"))
            end,
            sub_item_table_func = function()
                local items = {}
                for _idx, n in ipairs({ 5, 7, 9, 11, 13, 15 }) do
                    local captured = n
                    items[#items + 1] = {
                        text = T(_("%1 × %1"), captured),
                        checked_func = function()
                            return Settings.get(db, "generator_width") == captured
                        end,
                        callback = function()
                            Settings.set(db, "generator_width", captured)
                            Settings.set(db, "generator_height", captured)
                            refresh()
                        end,
                    }
                end
                return items
            end,
        },
        {
            text_func = function()
                return T(_("Target words: %1"), Settings.get(db, "generator_target_words"))
            end,
            keep_menu_open = true,
            callback = function()
                showIntegerInput(
                    _("Target number of words"),
                    Settings.get(db, "generator_target_words"),
                    function(val)
                        val = math.max(4, math.min(200, val))
                        Settings.set(db, "generator_target_words", val)
                        refresh()
                    end)
            end,
        },
        {
            text_func = function()
                return T(_("Minimum word length: %1"), Settings.get(db, "generator_min_len"))
            end,
            keep_menu_open = true,
            callback = function()
                showIntegerInput(
                    _("Minimum word length"),
                    Settings.get(db, "generator_min_len"),
                    function(val)
                        val = math.max(2, math.min(10, val))
                        Settings.set(db, "generator_min_len", val)
                        refresh()
                    end)
            end,
        },
        {
            text_func = function()
                local path = Settings.get(db, "preferred_dictionary") or ""
                if path == "" then
                    return _("Preferred dictionary: (none)")
                end
                return T(_("Preferred dictionary: %1"), path:match("([^/\\]+)%.ifo$") or path)
            end,
            sub_item_table_func = function()
                local items = {}
                items[#items + 1] = {
                    text = _("(none — choose at generation time)"),
                    checked_func = function()
                        local cur = Settings.get(db, "preferred_dictionary") or ""
                        return cur == ""
                    end,
                    callback = function()
                        Settings.set(db, "preferred_dictionary", "")
                        refresh()
                    end,
                }
                for _idx, ifo in ipairs(listDictionaries()) do
                    local captured = ifo
                    local display = ifo:match("([^/\\]+)%.ifo$") or ifo
                    items[#items + 1] = {
                        text = display,
                        checked_func = function()
                            return Settings.get(db, "preferred_dictionary") == captured
                        end,
                        callback = function()
                            Settings.set(db, "preferred_dictionary", captured)
                            refresh()
                        end,
                    }
                end
                if #items == 1 then
                    items[#items + 1] = {
                        text = _("No StarDict dictionaries found under data/dict/"),
                        enabled = false,
                    }
                end
                return items
            end,
        },
        {
            text = _("Clear current puzzle"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Discard the in-progress puzzle? This cannot be undone."),
                    ok_text = _("Discard"),
                    ok_callback = function()
                        db:clearCurrent()
                        refresh()
                        UIManager:show(InfoMessage:new{
                            text = _("Current puzzle cleared."), timeout = 2,
                        })
                    end,
                })
            end,
        },
    }
end

return Settings
