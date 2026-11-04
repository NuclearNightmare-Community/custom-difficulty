-- Unit tests for Scripts/tokens.lua: the limit / offset / used math and the adapter on a fake game state (story 4's
-- matrix rows: tokens more, tokens fewer, tokens zero and the lobby's own Disable, minimum changes, imposter), plus
-- unreadable values and failed writes.
-- Run from the repo root:  texlua test/unit/tokens_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("tokens_test")
local ok, eq = H.ok, H.eq
local tokens = require("tokens")

-- ---------------------------------------------------------------- the math
eq(tokens.limit(0), 2, "limit: Classified Minium 0 -> 2")
eq(tokens.limit(1), 4, "limit: 1 -> 4")
eq(tokens.limit(2), 6, "limit: 2 -> 6")
eq(tokens.limit(3), 8, "limit: 3 -> 8")
eq(tokens.limit(4), nil, "limit: 4 -> nil")
eq(tokens.limit(1.5), nil, "limit: 1.5 -> nil")
eq(tokens.limit(nil), nil, "limit: nil -> nil")
eq(tokens.count(2, 4, 0), -2, "count: limit 2, N 4 -> -2 (the computer shows 4)")
eq(tokens.count(8, 2, 0), 6, "count: limit 8, N 2 -> 6")
eq(tokens.used(-2 + 3, 2, 4), 3, "used: three reinforcements on the offset count")
eq(tokens.count(6, 2, 1), 5, "minimum changes: limit 6, N 2, used 1 -> 5")

-- ---------------------------------------------------------------- the adapter
local lines
local function o()
    lines = {}
    local once = {}
    return {
        say = function(level, fmt, ...) lines[#lines + 1] = (level == "info" and "" or level:upper() .. " ") .. string.format(fmt, ...) end,
        warnOnce = function(key, fmt, ...) if once[key] then return end once[key] = true lines[#lines + 1] = "WARN " .. string.format(fmt, ...) end,
    }
end
local function count(pat) local n = 0 for _, l in ipairs(lines) do if l:find(pat) then n = n + 1 end end return n end
local function dump() return table.concat(lines, " | ") end
-- A fake game state counting writes per key.
local function gs(fields)
    local f = { TimesUsedReinforcements = 0, ["Classified Minium"] = 2, ["Disable Reinforcement"] = false, GameMode = 0 }
    for k, v in pairs(fields or {}) do f[k] = v end
    local w = {}
    return setmetatable({}, {
        __index = function(_, k) if k == "_f" then return f elseif k == "_w" then return w end return f[k] end,
        __newindex = function(_, k, v)
            if f._readonly then error("read-only") end
            w[k] = (w[k] or 0) + 1
            f[k] = v
        end,
    }), f, w
end
-- The game's own +1 (a radio server event), then the re-check.
local function reinforce(t, g, f, op, how) f.TimesUsedReinforcements = f.TimesUsedReinforcements + 1 tokens.check(t, g, how or "ReinforceSpecficPlayer", op) end

do -- tokens more: Classified Minium 0 (limit 2), N 4
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 0 }
    local t = tokens.start(g, 4, op)
    eq(f.TimesUsedReinforcements, -2, "more: count written -2")
    eq(2 - f.TimesUsedReinforcements, 4, "more: the computer's text (limit - count) shows 4")
    eq(count("^TOKENS start limit=2 N=4 count=%-2$"), 1, "more: TOKENS start line", dump())
    for i = 1, 3 do reinforce(t, g, f, op) end
    eq(f["Disable Reinforcement"], false, "more: not disabled after 3")
    eq(count("^TOKENS used=%d left=%d count=%-?%d via=ReinforceSpecficPlayer$"), 3, "more: one TOKENS used line each", dump())
    reinforce(t, g, f, op, "poll")
    eq(f["Disable Reinforcement"], true, "more: Disable after the 4th")
    eq(count("^TOKENS disabled at used=4 N=4 via=poll$"), 1, "more: TOKENS disabled line", dump())
    tokens.check(t, g, "poll", op)
    eq(w["Disable Reinforcement"], 1, "more: Disable written once")
    eq(count("^TOKENS used="), 4, "more: no repeated used line without a change")
end
do -- tokens fewer: Classified Minium 3 (limit 8), N 2
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3 }
    local t = tokens.start(g, 2, op)
    eq(f.TimesUsedReinforcements, 6, "fewer: count 6")
    reinforce(t, g, f, op)
    eq(f["Disable Reinforcement"], false, "fewer: not disabled after 1")
    reinforce(t, g, f, op)
    eq(f["Disable Reinforcement"], true, "fewer: Disable after the 2nd")
    eq(8 - f.TimesUsedReinforcements, 0, "fewer: the text shows 0")
    -- A request past N still counts (the host never refuses): logged, Disable not written again.
    reinforce(t, g, f, op)
    eq(count("^TOKENS used=3 left=%-1 "), 1, "fewer: a third (from an open panel) is still counted", dump())
    eq(w["Disable Reinforcement"], 1, "fewer: Disable written once")
end
do -- two reinforcements between re-checks: one line with both
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 3 }
    local t = tokens.start(g, 5, op)
    f.TimesUsedReinforcements = f.TimesUsedReinforcements + 2
    tokens.check(t, g, "poll", op)
    eq(count("^TOKENS used=2 left=3 count=5 via=poll$"), 1, "two at once: one used=2 line", dump())
end
do -- tokens zero: Disable at the match start
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 1 }
    tokens.start(g, 0, op)
    eq(f["Disable Reinforcement"], true, "zero: Disable at the match start")
    eq(f.TimesUsedReinforcements, 4, "zero: count = limit (the computer shows 0)")
    eq(count("^TOKENS disabled at used=0 N=0 via=start$"), 1, "zero: TOKENS disabled line", dump())
end
do -- the lobby already disabled reinforcements: untouched
    local op = o()
    local g, f, w = gs{ ["Disable Reinforcement"] = true }
    eq(tokens.start(g, 0, op), nil, "lobby disabled: no token state")
    eq(next(w), nil, "lobby disabled: nothing written", next(w))
    eq(count("^TOKENS the lobby disabled reinforcements: untouched$"), 1, "lobby disabled: one line", dump())
end
do -- Disable set by someone else after the start: not written again
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3 }
    local t = tokens.start(g, 1, op)
    f["Disable Reinforcement"] = true
    reinforce(t, g, f, op)
    eq(w["Disable Reinforcement"], nil, "already set: Disable not written")
    eq(count("Disable Reinforcement was already set"), 1, "already set: one line", dump())
end
do -- the minimum changes mid-match: 3 -> 2
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 3 }
    local t = tokens.start(g, 2, op)
    reinforce(t, g, f, op)
    eq(f.TimesUsedReinforcements, 7, "minimum: count 7 after one")
    f["Classified Minium"] = 2
    tokens.check(t, g, "poll", op)
    eq(f.TimesUsedReinforcements, 5, "minimum: re-written to limit' - N + used = 6 - 2 + 1")
    eq(6 - f.TimesUsedReinforcements, 1, "minimum: the computer still shows N - used = 1")
    eq(count("^TOKENS minimum changed limit=8 %-> 6 used=1 count=5$"), 1, "minimum: one line", dump())
    reinforce(t, g, f, op)
    eq(f["Disable Reinforcement"], true, "minimum: Disable still at N")
end
do -- imposter: GameMode 1
    local op = o()
    local g, f, w = gs{ GameMode = 1 }
    eq(tokens.start(g, 4, op), nil, "imposter: no token state")
    eq(next(w), nil, "imposter: nothing written")
    eq(count("^TOKENS imposter mode"), 1, "imposter: one line", dump())
    -- The decompile's spelling as a fallback.
    local g2, f2, w2 = gs{ GameMode = "x", Gamemode = 1 }
    eq(tokens.start(g2, 4, op), nil, "imposter (Gamemode): no token state")
end
do -- Default and bad values
    local op = o()
    local g, f, w = gs()
    eq(tokens.start(g, nil, op), nil, "Default: nil")
    eq(next(w), nil, "Default: nothing written")
    eq(#lines, 0, "Default: no line")
    local g2, _, w2 = gs{ ["Classified Minium"] = 9 }
    eq(tokens.start(g2, 4, op), nil, "Classified Minium 9: stock")
    eq(next(w2), nil, "Classified Minium 9: nothing written")
    eq(count("^WARN TOKENS Classified Minium reads 9"), 1, "Classified Minium 9: one WARN")
    local g3, _, w3 = gs{ TimesUsedReinforcements = "?" }
    eq(tokens.start(g3, 4, op), nil, "unreadable count: stock")
    eq(next(w3), nil, "unreadable count: nothing written")
    eq(tokens.start(gs(), 2.5, op), nil, "N 2.5: stock")
    eq(count("^WARN TOKENS N=2%.5 is not a whole number"), 1, "N 2.5: the WARN names the value given", dump())
    -- A count already above 0 at the start (reinforcements before the knob's start): kept as used.
    local g4, f4 = gs{ ["Classified Minium"] = 3, TimesUsedReinforcements = 1 }
    local t4 = tokens.start(g4, 2, op)
    eq(f4.TimesUsedReinforcements, 7, "start with count 1: limit - N + 1")
    eq(t4.used, 1, "start with count 1: used 1")
    -- An unreadable value at a re-check: skipped, one WARN.
    f4["Classified Minium"] = 7
    tokens.check(t4, g4, "poll", op)
    tokens.check(t4, g4, "poll", op)
    eq(count("^WARN TOKENS Classified Minium 7 or the count unreadable"), 1, "re-check unreadable: one WARN", dump())
    eq(f4.TimesUsedReinforcements, 7, "re-check unreadable: nothing written")
    -- A failed write raises (the guard backs off).
    local g5, f5 = gs{ ["Classified Minium"] = 3 }
    f5._readonly = true
    ok(not pcall(tokens.start, g5, 2, op), "a failed count write raises")
    eq(tokens.check(nil, g, "poll", op), nil, "check with no state: nothing")
end

do -- release at a back-off: the count back to stock (used), once
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 0 }
    local t = tokens.start(g, 4, op)
    reinforce(t, g, f, op)
    eq(f.TimesUsedReinforcements, -1, "release: count -1 before")
    tokens.release(t, g, op)
    eq(f.TimesUsedReinforcements, 1, "release: the count back to used (1)")
    eq(count("^TOKENS released at back%-off used=1 count=%-1 %-> 1$"), 1, "release: one line", dump())
    tokens.release(t, g, op)
    eq(count("^TOKENS released"), 1, "release: only once")
    eq(tokens.release(nil, g, op), nil, "release with no state: nothing")
end

-- ---------------------------------------------------------------- the source
do
    local f = assert(io.open(ROOT .. "/Scripts/tokens.lua", "r"))
    local src = f:read("a"):gsub("%-%-[^\r\n]*", "")
    f:close()
    ok(not src:find("ExecuteInGameThread") and not src:find("LoopAsync") and not src:find("StaticFindObject"), "tokens.lua: no ExecuteInGameThread, LoopAsync or StaticFindObject")
    ok(not src:find("Diffculty", 1, true), "tokens.lua: never touches Diffculty")
end

H.done()
