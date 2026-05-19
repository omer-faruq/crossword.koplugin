--[[
Vocabulary Builder source for crossword generation.

Extracts words from Vocabulary Builder database, optionally filtered by book.
]]

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local VocabSource = {}
VocabSource.__index = VocabSource

local VOCAB_DB_PATH = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"

function VocabSource.create(dict_reader, title_id)
    local db_conn = SQ3.open(VOCAB_DB_PATH)
    if not db_conn then
        return nil, "Could not open vocabulary_builder.sqlite3"
    end
    
    local sql
    if title_id then
        sql = string.format([[
            SELECT word FROM vocabulary 
            WHERE title_id = %d 
            ORDER BY review_count DESC, create_time DESC
        ]], title_id)
    else
        sql = [[
            SELECT word FROM vocabulary 
            ORDER BY review_count DESC, create_time DESC
        ]]
    end
    
    local words = {}
    local word_set = {}
    
    local stmt = db_conn:prepare(sql)
    if stmt then
        for row in stmt:rows() do
            local word = row[1]
            if word and #word >= 3 and not word_set[word] then
                word_set[word] = true
                words[#words + 1] = word
            end
        end
        stmt:close()
    end
    
    db_conn:close()
    
    if #words == 0 then
        return nil, "No words found in vocabulary builder"
    end
    
    logger.info("VocabSource: found", #words, "words, looking up in dictionary...")
    
    local entries = {}
    if dict_reader then
        local count = 0
        for i, word in ipairs(words) do
            local def, found_word = dict_reader:lookup(word)
            if def and def ~= "" then
                entries[#entries + 1] = {
                    word = found_word or word,
                    clue = def,
                }
            end
            count = count + 1
            if count % 20 == 0 then
                logger.info("VocabSource: processed", count, "/", #words, "words,", #entries, "valid")
            end
        end
    end
    
    if #entries == 0 then
        return nil, "No valid words found in dictionary"
    end
    
    logger.info("VocabSource: extracted", #entries, "words with definitions")
    
    return setmetatable({
        entries = entries,
    }, VocabSource)
end

function VocabSource:getLanguage()
    return "unknown"
end

function VocabSource:randomSample(count, filter)
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

function VocabSource.listBooks()
    local db_conn = SQ3.open(VOCAB_DB_PATH)
    if not db_conn then
        return {}
    end
    
    local books = {}
    local sql = [[
        SELECT t.id, t.name, COUNT(v.word) as word_count
        FROM title t
        LEFT JOIN vocabulary v ON v.title_id = t.id
        WHERE t.filter = 1
        GROUP BY t.id, t.name
        HAVING word_count > 0
        ORDER BY t.name
    ]]
    
    local stmt = db_conn:prepare(sql)
    if stmt then
        for row in stmt:rows() do
            books[#books + 1] = {
                id = row[1],
                name = row[2],
                word_count = row[3],
            }
        end
        stmt:close()
    end
    
    db_conn:close()
    return books
end

return VocabSource
