-- Difficulty: the knob table and the parser for knob values (spec-difficulty-v1, presets-and-ui.md "Our rows" and
-- "The sidecar"). Pure Lua, no UE4SS: unit-tested without the game.
-- The values use the sidecar's syntax: "key=value;key=value", a value being "default" or a decimal number. Story 3
-- reads them from dev.lua (deploy.ps1 -Test -Knobs); story 6 adds the sidecar (sidecar.lua) and the text captured at
-- CreateSteamSession (presets.lua), both written with encode and read back with this parser. A value is
-- Default (nil) unless it is a known key with a number within the knob's range; it is then rounded to the knob's step.
-- Anything else is Default, with one problem line per bad entry for the caller to log.
local M = {}

-- EDiffculty 0..3 = Nightmare, Hard, Normal, Easy: the standard enemy hit (knob-mechanics.md "Enemy damage").
M.STANDARD = { [0] = 100, [1] = 50, [2] = 25, [3] = 17 }
M.MAX_TEXT = 1024 -- bytes (the sidecar's line bound)
M.MAX_ENTRIES = 32

-- The per-enemy rows, in the screen's order (presets-and-ui.md). Keys are "dmg.<row>".
M.ROWS = { "meek", "mimic", "psycho", "husk", "watcher", "stalker", "slugQueen", "apex", "worm", "leech", "bat",
           "infectedDog", "infectedPlayer", "monster" }
-- Story 14: the six enemies whose grab picks an execution or a survivable animation (knob-mechanics.md "Survivable
-- grabs"), in the order of the published bitmask (net.lua "kills": bit 0 = meek ... bit 5 = stalker).
M.GRAB_ROWS = { "meek", "mimic", "psycho", "husk", "watcher", "stalker" }
-- Story 14: the enemies with an Insta-kill box ("kill.<row>"): the six grabs and the two bosses' finisher grabs
-- (CommitLethalDamage). No box on the Worm, Leech, Bat, Infected Dog, Infected Player or Playable Monster.
M.KILL_ROWS = { "meek", "mimic", "psycho", "husk", "watcher", "stalker", "slugQueen", "apex" }
M.IS_KILL_ROW = {}
for _, r in ipairs(M.KILL_ROWS) do M.IS_KILL_ROW[r] = true end

-- Every knob mod.json declares under settings, with the same range and step (test/unit/knobs_test.lua checks they
-- agree).
M.KNOBS = {
    { key = "enemyDamage", min = 0, max = 200, step = 1 },
    { key = "spread", min = 0, max = 50, step = 1 },
    { key = "revives", min = 0, max = 20, step = 1 },
    { key = "classifiedTokens", min = 0, max = 4, step = 1 },     -- story 12: tokens per classified objective
    { key = "classifiedTokensMax", min = 0, max = 40, step = 1 }, -- story 12: the most classified bonus per match
    { key = "cold", min = 0, max = 400, step = 1 },
    { key = "frostbite", min = 0, max = 20, step = 0.5 },
}
for _, r in ipairs(M.ROWS) do M.KNOBS[#M.KNOBS + 1] = { key = "dmg." .. r, min = 0, max = 500, step = 5 } end
-- Story 14: the Insta-kill boxes, flags: 1 = ticked; 0 and Default both mean unticked (parse keeps neither).
for _, r in ipairs(M.KILL_ROWS) do M.KNOBS[#M.KNOBS + 1] = { key = "kill." .. r, min = 0, max = 1, step = 1, flag = true } end
M.BY_KEY = {}
for _, k in ipairs(M.KNOBS) do M.BY_KEY[k.key] = k end

local function clip(s)
    s = tostring(s)
    local r = (#s > 40 and (s:sub(1, 40) .. "...") or s):gsub("[%c]", "?")
    return r
end

-- round(v, step): to the nearest multiple of step (halves away from zero).
function M.round(v, step)
    local q = v / step
    q = q >= 0 and math.floor(q + 0.5) or math.ceil(q - 0.5)
    local r = q * step
    -- step 0.5 or 1 keeps this exact; drop any float noise from other steps.
    return tonumber(string.format("%.6f", r))
end

-- parse(text) -> values, problems. values maps a key to its number (Default keys are absent); problems is a list of
-- short strings, one per bad entry (or one for the whole text when it isn't a string or is over MAX_TEXT bytes).
function M.parse(text)
    local values, problems = {}, {}
    if text == nil or text == "" then return values, problems end
    if type(text) ~= "string" then problems[1] = "knobs is not a string (" .. type(text) .. "); every knob Default" return values, problems end
    if #text > M.MAX_TEXT then
        problems[1] = ("knobs is %d bytes, over %d; every knob Default"):format(#text, M.MAX_TEXT)
        return values, problems
    end
    local n = 0
    for entry in (text .. ";"):gmatch("([^;]*);") do
        local e = entry:match("^%s*(.-)%s*$")
        if e ~= "" then
            n = n + 1
            if n > M.MAX_ENTRIES then problems[#problems + 1] = ("more than %d entries; the rest Default"):format(M.MAX_ENTRIES) break end
            local key, val = e:match("^([%w%.]+)%s*=%s*(.-)$")
            local k = key and M.BY_KEY[key]
            if not key then
                problems[#problems + 1] = ("entry '%s' is not key=value; ignored"):format(clip(e))
            elseif not k then
                problems[#problems + 1] = ("unknown knob '%s'; ignored"):format(clip(key))
            elseif val == "default" then
                values[key] = nil
            elseif not (val:match("^%-?%d+$") or val:match("^%-?%d+%.%d+$") or val:match("^%-?%.%d+$")) then
                problems[#problems + 1] = ("%s=%s is not a number; %s Default"):format(key, clip(val), key)
                values[key] = nil
            else
                local v = tonumber(val)
                if k.flag and v ~= nil and v >= k.min and v <= k.max and v ~= math.floor(v) then
                    -- A flag is 0 or 1 only (story 14): 0.5 is no box state.
                    problems[#problems + 1] = ("%s=%s is not 0 or 1; %s Default"):format(key, clip(val), key)
                    values[key] = nil
                elseif k.flag and v == 0 then
                    values[key] = nil -- unticked is Default: nothing kept, nothing encoded
                elseif v == nil or v ~= v or v < k.min or v > k.max then
                    problems[#problems + 1] = ("%s=%s is outside %s..%s; %s Default"):format(key, clip(val), tostring(k.min), tostring(k.max), key)
                    values[key] = nil
                else
                    values[key] = M.round(v, k.step)
                end
            end
        end
    end
    return values, problems
end

-- A value as text: at most two decimals, no trailing zeros ("17", "0.5").
local function num(v) return (string.format("%.2f", v):gsub("%.?0+$", "")) end

-- Only known keys with a number, in KNOBS order (anything else in values is skipped).
local function pairsOf(values, sep)
    local t = {}
    for _, k in ipairs(M.KNOBS) do
        local v = values and values[k.key]
        if type(v) == "number" and v == v then t[#t + 1] = ("%s=%s"):format(k.key, num(v)) end
    end
    return table.concat(t, sep)
end

-- describe(values) -> "enemyDamage=17 dmg.stalker=200" in KNOBS order, or "all Default".
function M.describe(values)
    local s = pairsOf(values, " ")
    return s ~= "" and s or "all Default"
end

-- encode(values) -> "enemyDamage=17;dmg.stalker=200" in KNOBS order, "" when every knob is Default: the inverse of
-- parse (story 6: the sidecar's values field and the text captured at CreateSteamSession).
function M.encode(values) return pairsOf(values, ";") end

return M
