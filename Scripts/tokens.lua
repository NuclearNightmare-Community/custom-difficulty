-- CustomDifficulty: reinforcement tokens on the host (spec-difficulty-v1 story 4; knob-mechanics.md "Reinforcement
-- tokens"). Two parts: the math (pure) and the adapter on the game state (start, re-check, Disable, minimum change,
-- imposter, classified bonus). hits.lua owns the match state and calls them only on the host, once the match started.
-- The offset rule: the game counts reinforcements itself in the host's TimesUsedReinforcements (the radio's three
-- server events add 1; Reinformant() only routes to them), and its computer shows limit - count and closes at
-- count >= limit, with limit = 2 / 4 / 6 / 8 for Classified Minium 0..3. So at the match start the host writes
-- count = limit - N; from then on used = count - (limit - N), and the computer shows N - used. At used >= N the host
-- sets Disable Reinforcement once (never when the lobby already set it), which closes every computer, modded or not.
-- The pinned UE4SS never runs post callbacks on these Blueprint events, so the re-check runs in their callbacks
-- (after the body) and in the host poll.
-- Story 12 (Tokens per Classified, classifiedTokens = k; Max Classified Tokens, classifiedTokensMax = cap): every rise
-- of the game state's ClassifiedDynamicValue (set once per completed classified objective by the host's own
-- UpdateClassifieds) lowers the count by k per objective, up to cap in total per match (the bonus). The bonus raises
-- the effective N to n + bonus (with revives Default: the stock limit + bonus), so the computer shows
-- n + bonus - used. With revives set, a bonus that reopens tokens clears the Disable Reinforcement CustomDifficulty itself
-- wrote (never one another writer set); with revives Default CustomDifficulty never writes Disable and the game's own gate
-- (count >= limit) closes the computer.
local M = {}

M.LIMIT = { [0] = 2, [1] = 4, [2] = 6, [3] = 8 } -- NukeComputer_UI_C's literals per Classified Minium
M.IMPOSTER = 1 -- GameMode 1: no reinforcements; the knob does nothing

local function num(v) if type(v) == "number" then return v end return tonumber(tostring(v)) end
local function int(v) v = num(v) if v == nil or v ~= v or v ~= math.floor(v) then return nil end return math.tointeger and math.tointeger(v) or v end

-- limit(cm) -> the game's token limit for Classified Minium cm (0..3), or nil.
function M.limit(cm)
    cm = int(cm)
    return cm and M.LIMIT[cm] or nil
end
-- used(count, limit, n): reinforcements used, from the offset count.
function M.used(count, limit, n) return count - (limit - n) end
-- count(limit, n, used): the count that makes the computer show n - used and close at n.
function M.count(limit, n, used) return limit - n + used end

-- award(last, value, k, given, cap) -> add, baseline, capped: the bonus for one reading of ClassifiedDynamicValue.
-- last is the value seen last (nil: none yet; this reading becomes the baseline, no award), k the tokens per
-- objective, given the bonus awarded so far this match, cap the most it may reach (nil: no cap). A rise awards
-- (value - last) * k, clamped to what the cap leaves (capped = true when the clamp cut it); a lower value only resets
-- the baseline.
function M.award(last, value, k, given, cap)
    if last == nil or value <= last then return 0, value, false end
    local want = (value - last) * k
    local add = want
    if cap ~= nil then
        local room = cap - given
        if room < 0 then room = 0 end
        if add > room then add = room end
    end
    return add, value, add < want
end

-- nEff(t): the effective N, n (revives Default: the stock limit) plus the classified bonus.
local function nEff(t) return (t.n or t.limit) + t.bonus end
M.nEff = nEff

-- ---------------------------------------------------------------- the adapter (gs: the live game state)
local function read(gs, key)
    local ok, v = pcall(function() return gs[key] end)
    if ok then return v end
    return nil
end
local function write(gs, key, v)
    local ok, err = pcall(function() gs[key] = v end)
    if not ok then error(("could not write %s: %s"):format(key, tostring(err))) end
end
local function gameMode(gs)
    local m = num(read(gs, "GameMode")) -- the reflected spelling (the decompile says Gamemode)
    if m == nil then m = num(read(gs, "Gamemode")) end
    return m
end
-- classifiedValue(gs, o) -> ClassifiedDynamicValue as a whole number, or nil (one WARN).
local function classifiedValue(gs, o)
    local raw = read(gs, "ClassifiedDynamicValue")
    local v = int(raw)
    if v == nil then o.warnOnce("tokens:classified", "TOKENS ClassifiedDynamicValue reads %s, not a whole number; no classified bonus for it", tostring(raw)) end
    return v
end

-- start(gs, n, o, cls) -> the match's token state, or nil when the knobs do nothing this match (Default, imposter,
-- the lobby disabled reinforcements, or an unreadable value: one line each). o.say(level, fmt, ...),
-- o.warnOnce(key, ...). cls (story 12): nil, or { k = tokens per classified objective (> 0), cap = the most bonus per
-- match, nil for no cap }; with n nil and cls set the count stays stock and only the bonus lowers it.
function M.start(gs, n, o, cls)
    if n == nil and cls == nil then return nil end
    if n ~= nil then
        local given = n
        n = int(n)
        if not n or n < 0 then o.warnOnce("tokens:n", "TOKENS N=%s is not a whole number >= 0; tokens stay stock", tostring(given)) return nil end
    end
    local k, cap
    if cls ~= nil then
        -- Whole numbers (knobs.parse hands floats such as 2.0): the counts and the lines stay integers.
        k, cap = int(cls.k), cls.cap ~= nil and int(cls.cap) or nil
        if not k or k <= 0 or (cls.cap ~= nil and (not cap or cap < 0)) then
            o.warnOnce("tokens:k", "TOKENS classified k=%s cap=%s are not whole numbers (k > 0, cap >= 0); no classified bonus", tostring(cls.k), tostring(cls.cap))
            k, cap = nil, nil
            if n == nil then return nil end
        end
    end
    if gameMode(gs) == M.IMPOSTER then o.say("info", "TOKENS imposter mode (GameMode 1): reinforcement tokens untouched") return nil end
    if read(gs, "Disable Reinforcement") == true then o.say("info", "TOKENS the lobby disabled reinforcements: untouched") return nil end
    local cm = read(gs, "Classified Minium")
    local limit = M.limit(cm)
    if not limit then o.warnOnce("tokens:cm", "TOKENS Classified Minium reads %s, not 0..3; tokens stay stock", tostring(cm)) return nil end
    local count = int(read(gs, "TimesUsedReinforcements"))
    if not count then o.warnOnce("tokens:count", "TOKENS TimesUsedReinforcements is unreadable; tokens stay stock") return nil end
    -- The game's count so far is the reinforcements used so far (0 at a match start). disabled: Disable is set (by
    -- anyone) since used reached the effective N; wrote: CustomDifficulty wrote it (the only Disable it ever clears).
    local t = { n = n, limit = limit, used = count, disabled = false, wrote = false, bonus = 0 }
    if n ~= nil then
        local c = M.count(limit, n, count)
        write(gs, "TimesUsedReinforcements", c)
        o.say("info", "TOKENS start limit=%d N=%d count=%d", limit, n, c)
    else
        o.say("info", "TOKENS start limit=%d N=stock count=%d", limit, count)
    end
    if k then
        t.k, t.cap = k, cap
        t.last = classifiedValue(gs, o) -- the baseline: no award for objectives done before the start
        o.say("info", "TOKENS classified k=%d cap=%s baseline=%s", t.k, t.cap ~= nil and tostring(t.cap) or "none", tostring(t.last))
    end
    M.check(t, gs, "start", o)
    return t
end

-- check(t, gs, how, o): the re-check (radio callbacks, poll). A Classified Minium change re-writes the count as
-- limit' - N + used; a new used is logged; at used >= N, Disable Reinforcement is set once (N: the effective N; with
-- revives Default, never).
function M.check(t, gs, how, o)
    if not t then return end
    local cm = read(gs, "Classified Minium")
    local limit = M.limit(cm)
    local count = int(read(gs, "TimesUsedReinforcements"))
    if not limit or not count then
        o.warnOnce("tokens:check", "TOKENS Classified Minium %s or the count unreadable at a re-check; skipped", tostring(cm))
        return
    end
    if limit ~= t.limit then
        if t.n == nil then
            -- Revives Default: the count isn't offset by the limit (count = used - bonus); nothing to re-write.
            o.say("info", "TOKENS minimum changed limit=%d -> %d count=%d (stock)", t.limit, limit, count)
            t.limit = limit
        else
            local used = M.used(count, t.limit, nEff(t))
            local c = M.count(limit, nEff(t), used)
            write(gs, "TimesUsedReinforcements", c)
            o.say("info", "TOKENS minimum changed limit=%d -> %d used=%d count=%d", t.limit, limit, used, c)
            t.limit, count = limit, c
        end
    end
    local used = M.used(count, t.limit, nEff(t))
    if used ~= t.used then
        t.used = used
        o.say("info", "TOKENS used=%d left=%d count=%d via=%s", used, nEff(t) - used, count, how)
    end
    if t.n ~= nil and used >= nEff(t) and not t.disabled then
        t.disabled = true
        if read(gs, "Disable Reinforcement") == true then
            o.say("info", "TOKENS used=%d reached N=%d; Disable Reinforcement was already set", used, nEff(t))
        else
            write(gs, "Disable Reinforcement", true)
            t.wrote = true
            o.say("info", "TOKENS disabled at used=%d N=%d via=%s", used, nEff(t), how)
        end
    end
end

-- classified(t, gs, how, o): the classified bonus (story 12). The UpdateClassifieds callback and the poll both call
-- it; the last value seen makes it idempotent. A rise lowers the count by the award (the effective N rises with it,
-- used is unchanged); one line per rise. With revives set, a Disable CustomDifficulty wrote is cleared once tokens are left
-- again; one another writer set stays.
function M.classified(t, gs, how, o)
    if not t or not t.k then return end
    local v = classifiedValue(gs, o)
    if v == nil then return end
    local rose = t.last ~= nil and v > t.last
    local add, baseline, capped = M.award(t.last, v, t.k, t.bonus, t.cap)
    if not rose then t.last = baseline return end
    local count = int(read(gs, "TimesUsedReinforcements"))
    if not count then
        -- t.last stays: the award is tried again at the next reading.
        o.warnOnce("tokens:bonus", "TOKENS the count is unreadable at a classified bonus; tried again next time")
        return
    end
    t.last = baseline
    if add == 0 then
        o.say("info", "TOKENS bonus classified=%d +0 capped at %d", v, t.cap)
        return
    end
    local c = count - add
    write(gs, "TimesUsedReinforcements", c)
    t.bonus = t.bonus + add
    local used = M.used(c, t.limit, nEff(t))
    o.say("info", "TOKENS bonus classified=%d +%d count=%d left=%s via=%s%s", v, add, c,
        t.n ~= nil and tostring(nEff(t) - used) or "stock", how, capped and (" capped at " .. tostring(t.cap)) or "")
    if t.n ~= nil and t.disabled and used < nEff(t) then
        if t.wrote then
            t.disabled, t.wrote = false, false
            write(gs, "Disable Reinforcement", false)
            o.say("info", "TOKENS reopened at used=%d N=%d: Disable Reinforcement cleared via=%s", used, nEff(t), how)
        else
            o.say("info", "TOKENS bonus counted; Disable Reinforcement was set by someone else and stays set")
        end
    end
end

-- release(t, gs, o): at a back-off, put the count back to stock (used) once, so the tokens are never left half
-- applied (an offset count without Disable). Nothing more is done with tokens that match.
function M.release(t, gs, o)
    if not t or t.released then return end
    t.released = true
    local count = int(read(gs, "TimesUsedReinforcements"))
    if not count then o.say("info", "TOKENS released at back-off used=? (the count is unreadable; left as it is)") return end
    local used = M.used(count, t.limit, nEff(t))
    write(gs, "TimesUsedReinforcements", used)
    o.say("info", "TOKENS released at back-off used=%d count=%d -> %d", used, count, used)
end

return M
