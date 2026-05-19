--[[
StarDict dictionary reader for the crossword generator.

StarDict format (partial spec):
  <basename>.ifo  : INI-style header with metadata (wordcount, idxfilesize, ...)
  <basename>.idx  : concatenated records:
                      <headword NUL-terminated string><offset u32 BE><length u32 BE>
                    When ifo's idxoffsetbits=64 the offset is 8 bytes (rare).
  <basename>.dict : concatenated bytes of definitions at (offset, length).
  <basename>.dict.dz : same as .dict but gzipped (dictzip is gzip-compatible).

We deliberately don't depend on sdcv here; we iterate entries ourselves and
extract (word, first-sentence-of-definition) pairs. For .dict.dz we
decompress the full file via zlib with gzip window bits (windowBits = 31).

The caller can either:
  - call reader:iterate(callback) to walk every entry, or
  - call reader:randomSample(n, filter) to pull n random entries.

Decompression is done lazily on first access; for a ~10 MB compressed .dict.dz
this takes a second or two and then stays cached in memory for the reader's
lifetime. Callers that only need a few samples should call close() when done.
]]--

local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- Extend zlib cdef locally (the stock ffi/zlib_h only declares the simple
-- compress/uncompress entry points; we need inflate* for gzip mode).
ffi.cdef[[
typedef struct z_stream_s {
    const unsigned char *next_in;
    unsigned int     avail_in;
    unsigned long    total_in;
    unsigned char   *next_out;
    unsigned int     avail_out;
    unsigned long    total_out;
    const char      *msg;
    void            *state;
    void            *zalloc;
    void            *zfree;
    void            *opaque;
    int              data_type;
    unsigned long    adler;
    unsigned long    reserved;
} z_stream;

int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
const char *zlibVersion(void);
]]

local libz = ffi.loadlib("z", 1)

local Z_OK = 0
local Z_STREAM_END = 1
local Z_NO_FLUSH = 0
local GZIP_WINDOW_BITS = 31 -- 15 + 16: auto-detect gzip/zlib; 31 forces gzip.

local function gzipInflate(data)
    local stream = ffi.new("z_stream[1]")
    -- zlib requires inflateInit2 to be invoked via the macro-equivalent
    -- inflateInit2_ with the zlib version string and sizeof(z_stream).
    local ver = libz.zlibVersion()
    local stream_size = ffi.sizeof("z_stream")
    local rc = libz.inflateInit2_(stream, GZIP_WINDOW_BITS, ver, stream_size)
    if rc ~= Z_OK then
        return nil, string.format("inflateInit2 failed (%d)", rc)
    end

    local in_buf = ffi.cast("const unsigned char *", data)
    stream[0].next_in = in_buf
    stream[0].avail_in = #data

    local out_chunks = {}
    local chunk_size = math.max(65536, #data * 4)
    local out_buf = ffi.new("unsigned char[?]", chunk_size)

    while true do
        stream[0].next_out = out_buf
        stream[0].avail_out = chunk_size
        rc = libz.inflate(stream, Z_NO_FLUSH)
        if rc == Z_OK or rc == Z_STREAM_END then
            local produced = chunk_size - stream[0].avail_out
            if produced > 0 then
                out_chunks[#out_chunks + 1] = ffi.string(out_buf, produced)
            end
            if rc == Z_STREAM_END then break end
        else
            libz.inflateEnd(stream)
            return nil, string.format("inflate error %d (%s)", rc,
                stream[0].msg ~= nil and ffi.string(stream[0].msg) or "unknown")
        end
    end

    libz.inflateEnd(stream)
    return table.concat(out_chunks)
end

local function readFileBytes(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*all")
    f:close()
    return data
end

local function parseIfo(path)
    local data, err = readFileBytes(path)
    if not data then return nil, err end
    local info = {}
    for line in data:gmatch("[^\r\n]+") do
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and value then
            info[key:gsub("%s+$", "")] = value
        end
    end
    return info
end

local function baseNameFromIfo(ifo_path)
    return (ifo_path:gsub("%.ifo$", ""))
end

local function readU32BE(s, pos)
    local b1 = s:byte(pos)     or 0
    local b2 = s:byte(pos + 1) or 0
    local b3 = s:byte(pos + 2) or 0
    local b4 = s:byte(pos + 3) or 0
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

local function parseIdx(idx_bytes, is64)
    -- Walk the .idx buffer and return a list of {word = ..., offset = ..., length = ...}.
    local entries = {}
    local pos = 1
    local total = #idx_bytes
    local width = is64 and 8 or 4
    while pos <= total do
        local nul = idx_bytes:find("\0", pos, true)
        if not nul then break end
        local word = idx_bytes:sub(pos, nul - 1)
        local after = nul + 1
        if after + width + 4 - 1 > total then break end
        local offset
        if is64 then
            -- 64-bit offset: read high u32 then low u32.
            local hi = readU32BE(idx_bytes, after)
            local lo = readU32BE(idx_bytes, after + 4)
            offset = hi * 4294967296 + lo
        else
            offset = readU32BE(idx_bytes, after)
        end
        local length = readU32BE(idx_bytes, after + width)
        entries[#entries + 1] = { word = word, offset = offset, length = length }
        pos = after + width + 4
    end
    return entries
end

local Reader = {}
Reader.__index = Reader

local function listIfosInDir(dir)
    local out = {}
    if not dir or not lfs.attributes(dir, "mode") then return out end
    for name in lfs.dir(dir) do
        if name:match("%.ifo$") then
            out[#out + 1] = ffiUtil.joinPath(dir, name)
        end
    end
    return out
end

-- Recursively walk a base dir for .ifo files (one-level subdirectories only,
-- mirroring KOReader's own dictionary loader behavior).
function Reader.listAvailable(data_dir)
    local ifos = {}
    if not data_dir or not lfs.attributes(data_dir, "mode") then return ifos end
    for name in lfs.dir(data_dir) do
        if name ~= "." and name ~= ".." then
            local full = ffiUtil.joinPath(data_dir, name)
            local attr = lfs.attributes(full)
            if attr and attr.mode == "directory" then
                for _, ifo in ipairs(listIfosInDir(full)) do
                    ifos[#ifos + 1] = ifo
                end
            elseif name:match("%.ifo$") then
                ifos[#ifos + 1] = full
            end
        end
    end
    table.sort(ifos)
    return ifos
end

function Reader.open(ifo_path)
    local self = setmetatable({}, Reader)
    self.ifo_path = ifo_path
    self.base = baseNameFromIfo(ifo_path)
    self.info = parseIfo(ifo_path) or {}
    self.is64 = (self.info.idxoffsetbits == "64")
    self.idx_path = self.base .. ".idx"
    local idx_gz = self.base .. ".idx.gz"
    if not lfs.attributes(self.idx_path, "mode") and lfs.attributes(idx_gz, "mode") then
        -- Decompress .idx.gz into memory.
        local gz_data, err = readFileBytes(idx_gz)
        if not gz_data then return nil, err end
        local plain
        plain, err = gzipInflate(gz_data)
        if not plain then return nil, err end
        self.idx_bytes = plain
    else
        local data, err = readFileBytes(self.idx_path)
        if not data then return nil, err end
        self.idx_bytes = data
    end
    self.dict_path = self.base .. ".dict"
    self.dict_dz_path = self.base .. ".dict.dz"
    return self
end

function Reader:getName()
    return self.info.bookname or self.info.sametypesequence or self.base:match("([^/\\]+)$")
end

function Reader:getWordCount()
    return tonumber(self.info.wordcount) or 0
end

function Reader:loadDict()
    if self.dict_bytes then return self.dict_bytes end
    if lfs.attributes(self.dict_path, "mode") then
        local data, err = readFileBytes(self.dict_path)
        if not data then return nil, err end
        self.dict_bytes = data
        return data
    end
    if lfs.attributes(self.dict_dz_path, "mode") then
        local gz, err = readFileBytes(self.dict_dz_path)
        if not gz then return nil, err end
        local plain
        plain, err = gzipInflate(gz)
        if not plain then
            logger.warn("crossword: failed to decompress", self.dict_dz_path, err)
            return nil, err
        end
        self.dict_bytes = plain
        return plain
    end
    return nil, "Neither .dict nor .dict.dz found for " .. self.base
end

function Reader:getEntries()
    if not self.entries then
        self.entries = parseIdx(self.idx_bytes, self.is64)
    end
    return self.entries
end

-- Read the raw definition text for a given index entry.
function Reader:readDefinition(entry)
    local dict, err = self:loadDict()
    if not dict then return nil, err end
    local text = dict:sub(entry.offset + 1, entry.offset + entry.length)
    return text
end

-- Clean an HTML/XDXF-like definition into a plain first-sentence clue.
local function cleanDefinition(text)
    if not text then return "" end
    -- Drop XML tags (xdxf/html dictionaries). Keep inner text.
    text = text:gsub("<[^>]+>", " ")
    -- Collapse whitespace.
    text = text:gsub("[\r\n\t]+", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip leading part-of-speech markers like "n.", "v.", "adj.".
    text = text:gsub("^[nvadjAV]+%.%s*", "")
    -- Keep only the first sentence, capped to a reasonable length.
    local sentence = text:match("^(.-[%.!%?])%s")
    if sentence and #sentence > 8 then
        text = sentence
    end
    if #text > 160 then
        text = text:sub(1, 157) .. "..."
    end
    return text
end

Reader.cleanDefinition = cleanDefinition

function Reader:lookup(search_word)
    if not search_word or search_word == "" then return nil end
    
    if not self.lookup_cache then
        self.lookup_cache = {}
        local entries = self:getEntries()
        for _, entry in ipairs(entries) do
            local key = entry.word:lower()
            if not self.lookup_cache[key] then
                self.lookup_cache[key] = entry
            end
        end
    end
    
    local lower_search = search_word:lower()
    local entry = self.lookup_cache[lower_search]
    if entry then
        local raw = self:readDefinition(entry)
        return cleanDefinition(raw or ""), entry.word
    end
    return nil
end

-- Iterate entries (optionally a random subset). The callback receives
-- (word, clue_text) for each entry that passes the filter.
--
-- filter(word, entry) -> true to keep, false to skip (optional).
function Reader:iterate(callback, filter)
    local entries = self:getEntries()
    for _, entry in ipairs(entries) do
        local word = entry.word
        local keep = true
        if filter then keep = filter(word, entry) end
        if keep then
            local raw = self:readDefinition(entry)
            local clue = cleanDefinition(raw or "")
            if clue ~= "" then
                local stop = callback(word, clue, entry)
                if stop == false then break end
            end
        end
    end
end

-- Return at most `count` random (word, clue) pairs matching the filter.
-- Uses reservoir sampling so we don't need to materialize everything.
function Reader:randomSample(count, filter)
    assert(count and count > 0, "count must be positive")
    local entries = self:getEntries()
    if #entries == 0 then return {} end
    local kept = {}
    local considered = 0
    for _, entry in ipairs(entries) do
        local word = entry.word
        if not filter or filter(word, entry) then
            considered = considered + 1
            if #kept < count then
                kept[#kept + 1] = entry
            else
                local j = math.random(considered)
                if j <= count then kept[j] = entry end
            end
        end
    end
    local results = {}
    for _, entry in ipairs(kept) do
        local raw = self:readDefinition(entry)
        local clue = cleanDefinition(raw or "")
        if clue ~= "" then
            results[#results + 1] = { word = entry.word, clue = clue }
        end
    end
    return results
end

function Reader:close()
    self.idx_bytes = nil
    self.dict_bytes = nil
    self.entries = nil
    self.lookup_cache = nil
end

return Reader
