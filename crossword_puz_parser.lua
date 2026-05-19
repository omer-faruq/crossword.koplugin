--[[
Across Lite .puz binary parser.

The .puz format:
  Offset  Size   Field
  0x00    2      Overall checksum (ignored here)
  0x02    12     File magic "ACROSS&DOWN\0"
  0x0E    2      CIB checksum
  0x10    4      Masked low checksum
  0x14    4      Masked high checksum
  0x18    4      Version string, e.g. "1.3\0"
  0x1C    2      Reserved1C
  0x1E    2      Scrambled checksum
  0x20    12     Reserved20 (all zero)
  0x2C    1      Width
  0x2D    1      Height
  0x2E    2      Number of clues (little-endian)
  0x30    2      Unknown bitmask
  0x32    2      Scrambled tag

  Then:
    width*height bytes: solution (letters A-Z, '.' for black, ':' for unfilled in some puzzles)
    width*height bytes: player state ('-' for empty white, letter for filled, '.' for black)
    NUL-terminated strings: title, author, copyright
    NUL-terminated strings: clues in numbered order (ALL across+down interleaved by number)
    NUL-terminated string: notes
    Optional extra sections: GEXT, LTIM, GRBS, RTBL, RUSR (we skip them).

Rebus and scrambled puzzles are not supported by this parser; plain text-only
puzzles parse fine.
]]--

local PuzParser = {}

local MAGIC = "ACROSS&DOWN\0"
local BLACK_CHAR = "."

local function readU8(data, pos)
    return data:byte(pos), pos + 1
end

local function readU16LE(data, pos)
    local lo = data:byte(pos) or 0
    local hi = data:byte(pos + 1) or 0
    return lo + hi * 256, pos + 2
end

local function readCString(data, pos)
    local nul = data:find("\0", pos, true)
    if not nul then
        return data:sub(pos), #data + 1
    end
    return data:sub(pos, nul - 1), nul + 1
end

local function decodeLatin1(s)
    -- .puz strings are ISO-8859-1. Convert to UTF-8.
    local out = {}
    for i = 1, #s do
        local byte = s:byte(i)
        if byte < 0x80 then
            out[#out + 1] = string.char(byte)
        else
            out[#out + 1] = string.char(0xC0 + math.floor(byte / 64), 0x80 + (byte % 64))
        end
    end
    return table.concat(out)
end

-- Read the full file contents from a path.
local function readFile(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*all")
    f:close()
    return data
end

function PuzParser.parse(path_or_data, from_data)
    local data
    if from_data then
        data = path_or_data
    else
        local err
        data, err = readFile(path_or_data)
        if not data then return nil, err end
    end

    if #data < 0x34 then
        return nil, "File too short to be a .puz"
    end
    if data:sub(0x03, 0x0E) ~= MAGIC then
        return nil, "Missing .puz magic (ACROSS&DOWN)"
    end

    local width = data:byte(0x2D)
    local height = data:byte(0x2E)
    local n_clues = data:byte(0x2F) + data:byte(0x30) * 256

    if not width or not height or width == 0 or height == 0 then
        return nil, "Invalid .puz dimensions"
    end

    local pos = 0x35
    local cells = width * height
    if #data < pos + 2 * cells - 1 then
        return nil, "File too short for solution/state"
    end

    local solution_raw = data:sub(pos, pos + cells - 1)
    pos = pos + cells
    local state_raw = data:sub(pos, pos + cells - 1)
    pos = pos + cells

    local title
    title, pos = readCString(data, pos)
    local author
    author, pos = readCString(data, pos)
    local copyright
    copyright, pos = readCString(data, pos)

    -- Clues in numbered order: across/down interleaved.
    local clues = {}
    for _ = 1, n_clues do
        local s
        s, pos = readCString(data, pos)
        clues[#clues + 1] = decodeLatin1(s)
    end

    local notes
    notes, pos = readCString(data, pos)

    -- Build solution grid and user grid. .puz cells are single ISO-8859-1 bytes;
    -- convert bytes >= 0x80 to UTF-8 so languages like Spanish (Ñ) or German (Ä)
    -- render correctly on screen.
    local function decodeCell(ch)
        if ch == "" or ch == "\0" then return "" end
        return decodeLatin1(ch):upper()
    end
    local solution = {}
    local user = {}
    for r = 1, height do
        solution[r] = {}
        user[r] = {}
        for c = 1, width do
            local idx = (r - 1) * width + c
            local sol_ch = solution_raw:sub(idx, idx)
            if sol_ch == BLACK_CHAR then
                solution[r][c] = false
                user[r][c] = ""
            else
                solution[r][c] = decodeCell(sol_ch)
                local state_ch = state_raw:sub(idx, idx)
                if state_ch == "-" or state_ch == "\0" or state_ch == "" then
                    user[r][c] = ""
                else
                    user[r][c] = decodeCell(state_ch)
                end
            end
        end
    end

    -- Assign across/down clues by numbering order.
    local across_clues = {}
    local down_clues = {}
    local clue_idx = 1
    local num = 0
    local function isBlack(r, c)
        if r < 1 or r > height or c < 1 or c > width then return true end
        return solution[r][c] == false
    end
    for r = 1, height do
        for c = 1, width do
            if not isBlack(r, c) then
                local starts_across = (c == 1 or isBlack(r, c - 1))
                    and (c < width and not isBlack(r, c + 1))
                local starts_down = (r == 1 or isBlack(r - 1, c))
                    and (r < height and not isBlack(r + 1, c))
                if starts_across or starts_down then
                    num = num + 1
                    if starts_across then
                        across_clues[num] = clues[clue_idx] or ""
                        clue_idx = clue_idx + 1
                    end
                    if starts_down then
                        down_clues[num] = clues[clue_idx] or ""
                        clue_idx = clue_idx + 1
                    end
                end
            end
        end
    end

    return {
        title = decodeLatin1(title),
        author = decodeLatin1(author),
        copyright = decodeLatin1(copyright),
        notes = decodeLatin1(notes),
        width = width,
        height = height,
        solution = solution,
        user = user,
        across_clues = across_clues,
        down_clues = down_clues,
    }
end

return PuzParser
