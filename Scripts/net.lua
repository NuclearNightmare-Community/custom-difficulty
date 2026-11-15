-- Difficulty: what the host publishes for modded clients and how a client reads it back (spec-difficulty-v1 story 5,
-- knob-mechanics.md "Survivable grabs"). Pure Lua, no UE4SS: unit-tested without the game. The values travel only
-- through core's host replicated state (core.net, core story 22); presence and the version rule are core's (story 23).
--
-- Keys (the name part of "<mod id>.<name>"): ver and compat (Difficulty's own version and effective netCompat, as
-- major*1000000 + minor*1000 + patch), then the grab-relevant knobs that are set (an absent knob key means Default):
-- enemyDamage and the six grab rows (dmg_<row>; core's names allow no dot). All integers, as mod.json steps them.
local knobs = require("knobs")
local M = {}

M.VER_MAX = 999999999 -- 999.999.999
M.MAX_PART = 999
M.MAX_MANIFEST = 65536 -- bytes of mod.json read at most

-- The grab-relevant knobs (mod.json scope "all"): net key -> knob key.
M.KNOBS = {
    { net = "enemyDamage", knob = "enemyDamage" },
    { net = "dmg_meek", knob = "dmg.meek" },
    { net = "dmg_mimic", knob = "dmg.mimic" },
    { net = "dmg_psycho", knob = "dmg.psycho" },
    { net = "dmg_husk", knob = "dmg.husk" },
    { net = "dmg_watcher", knob = "dmg.watcher" },
    { net = "dmg_stalker", knob = "dmg.stalker" },
}
M.KEYS = { "ver", "compat" }
for _, k in ipairs(M.KNOBS) do M.KEYS[#M.KEYS + 1] = k.net end

-- The features core must have for client grabs and the host's spare decision (core.has names).
M.FEATURES = { "net.publish", "net.read", "net.presence", "net.compatible", "net.versionsCompatible" }

-- missing(has) -> the first feature core.has doesn't report (a failing or absent has counts as missing), or nil.
function M.missing(has)
    for _, f in ipairs(M.FEATURES) do
        if type(has) ~= "function" then return f end
        local ok, r = pcall(has, f)
        if not ok or r ~= true then return f end
    end
    return nil
end

-- parse(v) -> major, minor, patch for a strict "x.y.z" (each part 0..999, no leading zero), or nil.
function M.parse(v)
    if type(v) ~= "string" or #v > 11 then return nil end
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    for _, p in ipairs({ a, b, c }) do
        if #p > 1 and p:sub(1, 1) == "0" then return nil end
        if tonumber(p) > M.MAX_PART then return nil end
    end
    return tonumber(a), tonumber(b), tonumber(c)
end

-- verCode("0.1.0") -> 1000; nil for anything that isn't strict x.y.z.
function M.verCode(v)
    local a, b, c = M.parse(v)
    if not a then return nil end
    return a * 1000000 + b * 1000 + c
end

-- verString(1000) -> "0.1.0"; nil for anything but an integer in 0..VER_MAX.
function M.verString(code)
    if type(code) ~= "number" then return nil end
    local i = math.tointeger(code)
    if i == nil or i < 0 or i > M.VER_MAX then return nil end
    return string.format("%d.%d.%d", i // 1000000, (i // 1000) % 1000, i % 1000)
end

-- defaultNetCompat(version): core's default (net-contract.md): "0.<minor>.0" for 0.x, "<major>.0.0" from 1.0.
function M.defaultNetCompat(version)
    local a, b = M.parse(version)
    if not a then return nil end
    if a == 0 then return string.format("0.%d.0", b) end
    return string.format("%d.0.0", a)
end

-- encode(values, version, netCompat) -> pairs, problems. pairs is a list of { name, int } to publish: each grab knob
-- that is set, then ver and compat last (netCompat nil: the default), so a client never sees ver with only some knobs. A knob that isn't an integer is left out (Default for
-- clients) with a problem line; a version that isn't strict x.y.z gives no pairs at all.
function M.encode(values, version, netCompat)
    local problems = {}
    local ver = M.verCode(version)
    local compat = M.verCode(netCompat or M.defaultNetCompat(version))
    if not ver or not compat then
        problems[1] = ("version %s / netCompat %s is not strict x.y.z; nothing published"):format(tostring(version), tostring(netCompat))
        return {}, problems
    end
    local pairs_ = {}
    for _, k in ipairs(M.KNOBS) do
        local v = values and values[k.knob]
        if v ~= nil then
            local i = type(v) == "number" and math.tointeger(v) or nil
            if i == nil then problems[#problems + 1] = ("%s=%s is not an integer; not published (Default for clients)"):format(k.knob, tostring(v))
            else pairs_[#pairs_ + 1] = { k.net, i } end
        end
    end
    pairs_[#pairs_ + 1] = { "ver", ver }
    pairs_[#pairs_ + 1] = { "compat", compat }
    return pairs_, problems
end

-- decode(read) -> values, hostVer, hostCompat | nil, reason, key.
-- read(name, min, max) -> value | nil, reason (core.net.read on "<mod id>.<name>"). ver and compat come first: either
-- one not usable stops there (reason "absent", "no-state", "version" or "out-of-bounds"). Then each grab knob with
-- knobs.BY_KEY's bounds: absent is Default; anything else not usable ("out-of-bounds", or the state going away
-- between reads) gives nil, reason, key. A raising read is reason "error".
function M.decode(read)
    local function get(name, lo, hi)
        local ok, v, why = pcall(read, name, lo, hi)
        if not ok then return nil, "error" end
        if v == nil then return nil, why or "absent" end
        if type(v) ~= "number" or math.tointeger(v) == nil or v < lo or v > hi then return nil, "out-of-bounds" end
        return math.tointeger(v)
    end
    local ver, why = get("ver", 0, M.VER_MAX)
    if not ver then return nil, why, "ver" end
    local compat, whyC = get("compat", 0, M.VER_MAX)
    if not compat then return nil, whyC, "compat" end
    local values = {}
    for _, k in ipairs(M.KNOBS) do
        local b = knobs.BY_KEY[k.knob]
        local v, whyK = get(k.net, b.min, b.max)
        if v ~= nil then values[k.knob] = v
        elseif whyK ~= "absent" then return nil, whyK, k.net end
    end
    return values, M.verString(ver), M.verString(compat)
end

-- manifest(text) -> { id, version, netCompat } (strings or nil) from mod.json's top-level fields. A small scan,
-- not a full JSON parser: only top-level "key": "string" pairs are taken; nested objects and arrays are skipped.
function M.manifest(text)
    local out = {}
    if type(text) ~= "string" or #text > M.MAX_MANIFEST then return out end
    local i, n, depth = 1, #text, 0
    local function str(at) -- at: index of the opening quote -> content, index after the closing quote
        local j, buf = at + 1, {}
        while j <= n do
            local c = text:sub(j, j)
            if c == "\\" then
                buf[#buf + 1] = text:sub(j + 1, j + 1)
                j = j + 2
            elseif c == '"' then
                return table.concat(buf), j + 1
            else
                buf[#buf + 1] = c
                j = j + 1
            end
        end
        return nil, n + 1
    end
    while i <= n do
        local c = text:sub(i, i)
        if c == '"' then
            local s, j = str(i)
            if s == nil then break end
            i = j
            if depth == 1 then
                local k = text:find("%S", i)
                if k and text:sub(k, k) == ":" then
                    local q = text:find("%S", k + 1)
                    if q and text:sub(q, q) == '"' then
                        local v, j2 = str(q)
                        if v ~= nil and (s == "id" or s == "version" or s == "netCompat") and out[s] == nil then out[s] = v end
                        i = j2
                    else
                        i = k + 1
                    end
                end
            end
        elseif c == "{" or c == "[" then
            depth = depth + 1
            i = i + 1
        elseif c == "}" or c == "]" then
            depth = depth - 1
            i = i + 1
        else
            i = i + 1
        end
    end
    return out
end

return M
