--[[
Book-based word source for crossword generation.

Extracts words from the currently open book (up to current reading position)
and uses a dictionary to provide clues.
]]--

local util = require("util")
local logger = require("logger")

local BookSource = {}
BookSource.__index = BookSource

local function extractBookText(ui, max_words)
    local book_text = nil
    if not ui.document.info.has_pages then
        local current_xp = ui.document:getXPointer()
        ui.document:gotoPos(0)
        local start_xp = ui.document:getXPointer()
        ui.document:gotoXPointer(current_xp)
        book_text = ui.document:getTextFromXPointers(start_xp, current_xp) or ""
        local max_text_length = max_words * 10
        if #book_text > max_text_length then
            book_text = book_text:sub(-max_text_length)
            book_text = book_text:gsub("^[\128-\191]+", "")
            book_text = util.fixUtf8(book_text, "_")
        end
    else
        local current_page = ui.view.state.page
        local max_pages = math.min(current_page, math.ceil(max_words / 100))
        local start_page = math.max(1, current_page - max_pages)
        book_text = ""
        for page = start_page, current_page do
            local page_text = ui.document:getPageText(page) or ""
            if type(page_text) == "table" then
                local texts = {}
                for _, block in ipairs(page_text) do
                    if type(block) == "table" then
                        for i = 1, #block do
                            local span = block[i]
                            if type(span) == "table" and span.word then
                                table.insert(texts, span.word)
                            end
                        end
                    end
                end
                page_text = table.concat(texts, " ")
            end
            book_text = book_text .. page_text .. "\n"
        end
    end
    return book_text
end

local function extractWords(text, dict_reader)
    local word_freq = {}
    
    for word in text:gmatch("%a+") do
        local lower = word:lower()
        if #lower >= 3 then
            word_freq[lower] = (word_freq[lower] or 0) + 1
        end
    end
    
    local entries = {}
    for word, freq in pairs(word_freq) do
        if dict_reader then
            local def, found_word = dict_reader:lookup(word)
            if def and def ~= "" then
                entries[#entries + 1] = {
                    word = found_word or word,
                    clue = def,
                    freq = freq,
                }
            end
        else
            entries[#entries + 1] = {
                word = word,
                clue = "Word from book (freq: " .. freq .. ")",
                freq = freq,
            }
        end
    end
    
    table.sort(entries, function(a, b)
        if a.freq == b.freq then
            return a.word < b.word
        end
        return a.freq > b.freq
    end)
    
    return entries
end

function BookSource.create(ui, dict_reader, max_words)
    max_words = max_words or 2000
    
    local text = extractBookText(ui, max_words)
    if not text or text == "" then
        return nil, "Could not extract text from book"
    end
    
    local entries = extractWords(text, dict_reader)
    if #entries == 0 then
        return nil, "No valid words found in book"
    end
    
    logger.info("BookSource: extracted", #entries, "unique words from book")
    
    return setmetatable({
        entries = entries,
    }, BookSource)
end

function BookSource:getLanguage()
    return "unknown"
end

function BookSource:randomSample(count, filter)
    local kept = {}
    local considered = 0
    for _, entry in ipairs(self.entries) do
        if not filter or filter(entry.word) then
            considered = considered + 1
            if #kept < count then
                kept[#kept + 1] = entry
            else
                local j = math.random(considered)
                if j <= count then kept[j] = entry end
            end
        end
    end
    return kept
end

return BookSource
