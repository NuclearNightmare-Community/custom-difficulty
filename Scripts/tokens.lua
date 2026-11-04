-- Difficulty: reinforcement tokens on the host (spec-difficulty-v1 story 4; knob-mechanics.md "Reinforcement
-- tokens"). Two parts: the math (pure) and the adapter on the game state (start, re-check, Disable, minimum change,
-- imposter). hits.lua owns the match state and calls them only on the host, once the match started.
-- The offset rule: the game counts reinforcements itself in the host's TimesUsedReinforcements (the radio's three
-- server events add 1; Reinformant() only routes to them), and its computer shows limit - count and closes at
-- count >= limit, with limit = 2 / 4 / 6 / 8 for Classified Minium 0..3. So at the match start the host writes
-- count = limit - N; from then on used = count - (limit - N), and the computer shows N - used. At used >= N the host
-- sets Disable Reinforcement once (never when the lobby already set it), which closes every computer, modded or not.
-- The pinned UE4SS never runs post callbacks on these Blueprint events, so the re-check runs in their callbacks
-- (after the body) and in the host poll.
local M = {}

M.LIMIT = { [0] = 2, [1] = 4, [2] = 6, [3] = 8 } -- NukeComputer_UI_C's literals per Classified Minium
M.IMPOSTER = 1 -- GameMode 1: no reinforcements; the knob does nothing

local function num(v) if type(v) == "number" then return v end return tonumber(tostring(v)) end
local function int(v) v = num(v) if v == nil or v ~= math.floor(v) then return nil end return math.tointeger and math.tointeger(v) or v end

-- limit(cm) -> the game's token limit for Classified Minium cm (0..3), or nil.
function M.limit(cm)
    cm = int(cm)
    return cm and M.LIMIT[cm] or nil
end
-- used(count, limit, n): reinforcements used, from the offset count.
function M.used(count, limit, n) return count - (limit - n) end
-- count(limit, n, used): the count that makes the computer show n - used and close at n.
function M.count(limit, n, used) return limit - n + used end

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

-- start(gs, n, o) -> the match's token state, or nil when the knob does nothing this match (Default, imposter, the
-- lobby disabled reinforcements, or an unreadable value: one line each). o.say(level, fmt, ...), o.warnOnce(key, ...).
function M.start(gs, n, o)
    if n == nil then return nil end
    local given = n
    n = int(n)
    if not n or n < 0 then o.warnOnce("tokens:n", "TOKENS N=%s is not a whole number >= 0; tokens stay stock", tostring(given)) return nil end
    if gameMode(gs) == M.IMPOSTER then o.say("info", "TOKENS imposter mode (GameMode 1): reinforcement tokens untouched") return nil end
    if read(gs, "Disable Reinforcement") == true then o.say("info", "TOKENS the lobby disabled reinforcements: untouched") return nil end
    local cm = read(gs, "Classified Minium")
    local limit = M.limit(cm)
    if not limit then o.warnOnce("tokens:cm", "TOKENS Classified Minium reads %s, not 0..3; tokens stay stock", tostring(cm)) return nil end
    local count = int(read(gs, "TimesUsedReinforcements"))
    if not count then o.warnOnce("tokens:count", "TOKENS TimesUsedReinforcements is unreadable; tokens stay stock") return nil end
    -- The game's count so far is the reinforcements used so far (0 at a match start).
    local t = { n = n, limit = limit, used = count, disabled = false }
    local c = M.count(limit, n, count)
    write(gs, "TimesUsedReinforcements", c)
    o.say("info", "TOKENS start limit=%d N=%d count=%d", limit, n, c)
    M.check(t, gs, "start", o)
    return t
end

-- check(t, gs, how, o): the re-check (radio callbacks, poll). A Classified Minium change re-writes the count as
-- limit' - N + used; a new used is logged; at used >= N, Disable Reinforcement is set once.
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
        local used = M.used(count, t.limit, t.n)
        local c = M.count(limit, t.n, used)
        write(gs, "TimesUsedReinforcements", c)
        o.say("info", "TOKENS minimum changed limit=%d -> %d used=%d count=%d", t.limit, limit, used, c)
        t.limit, count = limit, c
    end
    local used = M.used(count, t.limit, t.n)
    if used ~= t.used then
        t.used = used
        o.say("info", "TOKENS used=%d left=%d count=%d via=%s", used, t.n - used, count, how)
    end
    if used >= t.n and not t.disabled then
        t.disabled = true
        if read(gs, "Disable Reinforcement") == true then
            o.say("info", "TOKENS used=%d reached N=%d; Disable Reinforcement was already set", used, t.n)
        else
            write(gs, "Disable Reinforcement", true)
            o.say("info", "TOKENS disabled at used=%d N=%d via=%s", used, t.n, how)
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
    local used = M.used(count, t.limit, t.n)
    write(gs, "TimesUsedReinforcements", used)
    o.say("info", "TOKENS released at back-off used=%d count=%d -> %d", used, count, used)
end

return M
