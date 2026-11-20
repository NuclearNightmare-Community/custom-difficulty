-- CustomDifficulty: the world-preset sidecar file (spec-difficulty-v1 story 6, presets-and-ui.md "The sidecar"). Pure Lua,
-- no UE4SS: name encoding, the bounded parse of format 2, serialize, and reconcile against the game's presets.
-- presets.lua does the file IO and the hooks.
--
--   # <ModName> world presets, format 2
--   <index>\t<name>\t<values>
--
-- <index> is the preset's 0-based position in the game's Presets; <name> is percent-encoded ('%', tab, CR, LF and
-- every byte below 0x20); <values> is the knob syntax (knobs.lua: only non-Default keys, empty for all Default).
-- The file is data: parsed with string patterns only, never load/dofile. A bad line, an unknown key or a value out of
-- range counts as Default, and every problem is listed for the caller's one WARN per read.
local knobs = require("knobs")

local M = {}
M.FORMAT = 2
M.MAX_BYTES = 256 * 1024 -- read at most this much of the file
M.MAX_ENTRIES = 256      -- entries read (and written)
M.MAX_LINE = 1024        -- bytes per line
M.MAX_NAME = 128         -- bytes of an encoded name

function M.header(mod) return ("# %s world presets, format %d"):format(tostring(mod), M.FORMAT) end

function M.encodeName(s)
    return (tostring(s):gsub("[%%\0-\31]", function(c) return ("%%%02X"):format(c:byte()) end))
end
function M.decodeName(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function clip(s)
    local r = (#s > 40 and (s:sub(1, 40) .. "...") or s):gsub("[%c]", "?")
    return r
end

-- parse(text) -> entries, problems. entries: { index = <int>, name = <string>, values = <knobs table> } in file order;
-- problems: short strings (the caller logs their count and the first). nil or "" is no file: no entries, no problem.
function M.parse(text)
    local entries, problems = {}, {}
    if text == nil or text == "" then return entries, problems end
    if type(text) ~= "string" then problems[1] = "not text (" .. type(text) .. "); every entry Default" return entries, problems end
    if #text > M.MAX_BYTES then
        problems[#problems + 1] = ("the file is over %d bytes; read up to it"):format(M.MAX_BYTES)
        text = text:sub(1, M.MAX_BYTES)
        local cut = text:match("^.*()\n") -- drop the partial last line
        text = cut and text:sub(1, cut) or ""
    end
    local pos, lineNo, headerSeen = 1, 0, false
    while pos <= #text do
        local nl = text:find("\n", pos, true)
        local line = text:sub(pos, (nl or (#text + 1)) - 1)
        pos = (nl or #text) + 1
        lineNo = lineNo + 1
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if #line > M.MAX_LINE then
            problems[#problems + 1] = ("line %d is over %d bytes; Default"):format(lineNo, M.MAX_LINE)
        elseif line == "" then
            -- blank lines are allowed
        elseif not headerSeen and lineNo == 1 and line:sub(1, 1) == "#" then
            headerSeen = true
            local f = line:match("^# .- world presets, format (%d+)%s*$")
            if f ~= tostring(M.FORMAT) then
                problems[#problems + 1] = ("header '%s' is not format %d; every entry Default"):format(clip(line), M.FORMAT)
                return {}, problems
            end
        else
            local idx, name, vals = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if not idx then
                problems[#problems + 1] = ("line %d is not <index>\\t<name>\\t<values>; Default"):format(lineNo)
            elseif not idx:match("^%d%d?%d?%d?%d?%d?$") then
                problems[#problems + 1] = ("line %d: index '%s' is not a number; Default"):format(lineNo, clip(idx))
            elseif #name > M.MAX_NAME then
                problems[#problems + 1] = ("line %d: the name is over %d bytes; Default"):format(lineNo, M.MAX_NAME)
            elseif #entries >= M.MAX_ENTRIES then
                problems[#problems + 1] = ("more than %d entries; the rest Default"):format(M.MAX_ENTRIES)
                break
            else
                local values, vp = knobs.parse(vals)
                for _, p in ipairs(vp) do problems[#problems + 1] = ("line %d: %s"):format(lineNo, p) end
                entries[#entries + 1] = { index = tonumber(idx), name = M.decodeName(name), values = values }
            end
        end
    end
    if not headerSeen then table.insert(problems, 1, ("no format %d header"):format(M.FORMAT)) end
    return entries, problems
end

local function copy(t) local r = {} for k, v in pairs(t or {}) do r[k] = v end return r end
M.copy = copy

-- serialize(entries, mod) -> text, skipped. Entries in the given order, at most MAX_ENTRIES; an entry whose encoded
-- name is over MAX_NAME bytes is left out (Default on the next read) and listed in skipped.
function M.serialize(entries, mod)
    local t, skipped = { M.header(mod) }, {}
    for i, e in ipairs(entries or {}) do
        if i > M.MAX_ENTRIES then break end
        local name = M.encodeName(e.name)
        if #name > M.MAX_NAME then skipped[#skipped + 1] = e
        else t[#t + 1] = ("%d\t%s\t%s"):format(e.index, name, knobs.encode(e.values)) end
    end
    return table.concat(t, "\n") .. "\n", skipped
end

-- reconcile(names, entries, mod) -> entries, text. names: the game's preset names in order (names[i] is preset i-1).
-- For preset i: the entry with the same index and name, else the first unused entry with that name, else Default.
-- The result is in the game's order with fresh indices; text is its serialization.
function M.reconcile(names, entries, mod)
    local used, out = {}, {}
    entries = entries or {}
    for i, name in ipairs(names or {}) do
        if i > M.MAX_ENTRIES then break end
        local hit
        for j, e in ipairs(entries) do
            if not used[j] and e.index == i - 1 and e.name == name then hit = j break end
        end
        if not hit then
            for j, e in ipairs(entries) do
                if not used[j] and e.name == name then hit = j break end
            end
        end
        if hit then used[hit] = true end
        out[i] = { index = i - 1, name = name, values = copy(hit and entries[hit].values) }
    end
    return out, (M.serialize(out, mod))
end

return M
