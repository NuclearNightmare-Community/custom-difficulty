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

-- ---------------------------------------------------------------- story 12: the classified bonus
do -- award: the pure function
    local add, base, capped = tokens.award(nil, 3, 2, 0, nil)
    ok(add == 0 and base == 3 and not capped, "award: no baseline yet -> the reading is the baseline, nothing awarded")
    add, base = tokens.award(0, 2, 2, 0, nil)
    ok(add == 4 and base == 2, "award: 0 -> 2 with k 2 -> +4 (two objectives in one reading)")
    add, base = tokens.award(2, 2, 2, 4, nil)
    ok(add == 0 and base == 2, "award: no rise -> nothing")
    add, base = tokens.award(5, 1, 2, 4, nil)
    ok(add == 0 and base == 1, "award: a lower value resets the baseline, nothing awarded")
    add, base, capped = tokens.award(0, 1, 2, 2, 3)
    ok(add == 1 and base == 1 and capped, "award: a rise past the cap awards only the rest")
    add, base, capped = tokens.award(1, 2, 2, 3, 3)
    ok(add == 0 and base == 2 and capped, "award: at the cap -> 0, capped")
    add, base, capped = tokens.award(0, 1, 2, 0, 2)
    ok(add == 2 and not capped, "award: exactly reaching the cap is not capped")
end
local function cls(k, cap) return { k = k, cap = cap } end
-- The game's own UpdateClassifieds (value + 1), then the award and the re-check (as the hook does).
local function objective(t, g, f, op, how, by)
    f.ClassifiedDynamicValue = f.ClassifiedDynamicValue + (by or 1)
    tokens.classified(t, g, how or "UpdateClassifieds", op)
    tokens.check(t, g, how or "UpdateClassifieds", op)
end
do -- Default: no classified state, no write, no new line (tokens.start without cls is story 4's)
    local op = o()
    local g, f, w = gs{ ClassifiedDynamicValue = 0 }
    eq(tokens.start(g, nil, op, nil), nil, "classified Default: no token state")
    eq(next(w), nil, "classified Default: nothing written")
    eq(#lines, 0, "classified Default: no line")
    local t = tokens.start(g, 2, op)
    f.ClassifiedDynamicValue = 1
    tokens.classified(t, g, "poll", op)
    eq(count("bonus"), 0, "revives only: an objective awards nothing, no bonus line", dump())
    eq(f.TimesUsedReinforcements, 4, "revives only: the count untouched by the objective")
end
do -- Stock tokens: revives Default, CM 3 (limit 8), k=2, used 3, one objective
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3, TimesUsedReinforcements = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, nil, op, cls(2))
    ok(t ~= nil, "stock: a token state")
    eq(w.TimesUsedReinforcements, nil, "stock: the count is not written at the start")
    eq(count("^TOKENS start limit=8 N=stock count=3$"), 1, "stock: the start line", dump())
    eq(count("^TOKENS classified k=2 cap=none baseline=0$"), 1, "stock: the classified line", dump())
    objective(t, g, f, op)
    eq(f.TimesUsedReinforcements, 1, "stock: count 3 -> 1")
    eq(8 - f.TimesUsedReinforcements, 7, "stock: the computer shows 7")
    eq(count("^TOKENS bonus classified=1 %+2 count=1 left=stock via=UpdateClassifieds$"), 1, "stock: one bonus line", dump())
    eq(w["Disable Reinforcement"], nil, "stock: Disable never written")
    -- The game's own gate closes it: 7 more reinforcements reach count 8 = limit; Difficulty writes no Disable.
    for i = 1, 7 do reinforce(t, g, f, op, "poll") end
    eq(f.TimesUsedReinforcements, 8, "stock: count at the limit after 7 more")
    eq(w["Disable Reinforcement"], nil, "stock: still no Disable (the game's gate closes)")
    eq(count("^TOKENS disabled"), 0, "stock: no disabled line")
    -- A minimum change leaves the stock count alone.
    f["Classified Minium"] = 2
    tokens.check(t, g, "poll", op)
    eq(f.TimesUsedReinforcements, 8, "stock: a minimum change doesn't re-write the count")
    -- Release: the count back to stock (used = count + bonus).
    tokens.release(t, g, op)
    eq(f.TimesUsedReinforcements, 10, "stock release: back to used (10)")
end
do -- With N, disabled: N=2, k=2, used 2 (Difficulty set Disable), one objective
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2, op, cls(2))
    reinforce(t, g, f, op) reinforce(t, g, f, op)
    eq(f["Disable Reinforcement"], true, "N disabled: Disable at used 2")
    objective(t, g, f, op)
    eq(f.TimesUsedReinforcements, 6, "N disabled: count lowered by 2 (8 -> 6)")
    eq(f["Disable Reinforcement"], false, "N disabled: Disable cleared")
    eq(8 - f.TimesUsedReinforcements, 2, "N disabled: the computer shows 2")
    eq(count("^TOKENS bonus classified=1 %+2 count=6 left=2 via=UpdateClassifieds$"), 1, "N disabled: the bonus line", dump())
    eq(count("^TOKENS reopened at used=2 N=4: Disable Reinforcement cleared via=UpdateClassifieds$"), 1, "N disabled: the reopened line", dump())
    reinforce(t, g, f, op)
    eq(f["Disable Reinforcement"], false, "N disabled: still open at used 3")
    reinforce(t, g, f, op, "poll")
    eq(f["Disable Reinforcement"], true, "N disabled: closes again at used 4")
    eq(count("^TOKENS disabled at used=4 N=4 via=poll$"), 1, "N disabled: the second disabled line", dump())
    eq(w["Disable Reinforcement"], 3, "N disabled: Disable written set, cleared, set")
    -- Release keeps used: count 8 = limit - (2 + 2) + 4 -> 4.
    tokens.release(t, g, op)
    eq(f.TimesUsedReinforcements, 4, "N release: the count back to used 4")
end
do -- Lobby/other Disable: set by someone else mid-match; the bonus is counted, Disable stays set
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 1, op, cls(2))
    f["Disable Reinforcement"] = true
    reinforce(t, g, f, op)
    eq(count("Disable Reinforcement was already set"), 1, "other Disable: the already-set line", dump())
    objective(t, g, f, op)
    eq(t.bonus, 2, "other Disable: the bonus counted")
    eq(f["Disable Reinforcement"], true, "other Disable: left set")
    eq(w["Disable Reinforcement"], nil, "other Disable: never written by Difficulty")
    eq(count("set by someone else and stays set"), 1, "other Disable: one line", dump())
end
do -- Two objectives in one poll: value 0 -> 2, +2k once, one line
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2, op, cls(2))
    objective(t, g, f, op, "poll", 2)
    eq(f.TimesUsedReinforcements, 2, "two at once: count 6 -> 2 (+4)")
    eq(count("^TOKENS bonus "), 1, "two at once: one line", dump())
    eq(count("^TOKENS bonus classified=2 %+4 count=2 left=6 via=poll$"), 1, "two at once: +4", dump())
end
do -- Hook and poll both see it: awarded once
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2, op, cls(2))
    objective(t, g, f, op, "UpdateClassifieds")
    tokens.classified(t, g, "poll", op)
    tokens.classified(t, g, "UpdateClassifieds", op)
    eq(f.TimesUsedReinforcements, 4, "dedup: count lowered once (6 -> 4)")
    eq(count("^TOKENS bonus "), 1, "dedup: one bonus line", dump())
    eq(w.TimesUsedReinforcements, 2, "dedup: two count writes (start and the award)")
end
do -- CM changes mid-match: the rewrite uses N + bonus
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2, op, cls(2))
    reinforce(t, g, f, op)
    objective(t, g, f, op)
    eq(8 - f.TimesUsedReinforcements, 3, "minimum + bonus: shows 3 (N 2 + 2 - 1)")
    f["Classified Minium"] = 1
    tokens.check(t, g, "poll", op)
    eq(f.TimesUsedReinforcements, 1, "minimum + bonus: re-written to 4 - (2 + 2) + 1 = 1")
    eq(4 - f.TimesUsedReinforcements, 3, "minimum + bonus: the computer still shows 3")
end
do -- Unreadable value: no award, one WARN; a later good reading becomes the baseline
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 1.5 }
    local t = tokens.start(g, 2, op, cls(2))
    eq(count("^TOKENS classified k=2 cap=none baseline=nil$"), 1, "unreadable at start: no baseline", dump())
    tokens.classified(t, g, "poll", op)
    eq(count("^WARN TOKENS ClassifiedDynamicValue reads 1%.5"), 1, "unreadable: one WARN", dump())
    f.ClassifiedDynamicValue = "x"
    tokens.classified(t, g, "poll", op)
    eq(count("^WARN TOKENS ClassifiedDynamicValue"), 1, "unreadable: still one WARN")
    f.ClassifiedDynamicValue = 3
    tokens.classified(t, g, "poll", op)
    eq(count("^TOKENS bonus"), 0, "first good reading: the baseline, no award")
    eq(w.TimesUsedReinforcements, 1, "unreadable: only the start wrote the count")
    f.ClassifiedDynamicValue = 4
    tokens.classified(t, g, "poll", op)
    eq(count("^TOKENS bonus classified=4 %+2 "), 1, "after the baseline: a rise awards", dump())
end
do -- Imposter / lobby Disable at the start: the knob does nothing, one info line as today
    local op = o()
    local g, _, w = gs{ GameMode = 1, ClassifiedDynamicValue = 0 }
    eq(tokens.start(g, nil, op, cls(2)), nil, "imposter: no state for the classified knob")
    eq(next(w), nil, "imposter: nothing written")
    eq(count("^TOKENS imposter mode"), 1, "imposter: one line")
    local g2, _, w2 = gs{ ["Disable Reinforcement"] = true, ClassifiedDynamicValue = 0 }
    eq(tokens.start(g2, nil, op, cls(2)), nil, "lobby Disable: no state for the classified knob")
    eq(next(w2), nil, "lobby Disable: nothing written")
    eq(count("^TOKENS the lobby disabled reinforcements: untouched$"), 1, "lobby Disable: one line")
end
do -- The cap (the approved change): k=2, cap 3: +2, then +1 capped, then +0 capped at 3
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 0, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2, op, cls(2, 3))
    eq(count("^TOKENS classified k=2 cap=3 baseline=0$"), 1, "cap: the classified line names the cap", dump())
    reinforce(t, g, f, op) reinforce(t, g, f, op)
    eq(f["Disable Reinforcement"], true, "cap: Disable at used 2")
    objective(t, g, f, op)
    eq(2 - f.TimesUsedReinforcements, 2, "cap: 2 left after the first objective")
    eq(f["Disable Reinforcement"], false, "cap: reopened")
    objective(t, g, f, op)
    eq(2 - f.TimesUsedReinforcements, 3, "cap: 3 left after the second (capped at +1)")
    eq(count("^TOKENS bonus classified=2 %+1 count=%-1 left=3 via=UpdateClassifieds capped at 3$"), 1, "cap: the second line +1 capped", dump())
    local before = w.TimesUsedReinforcements
    objective(t, g, f, op, "poll")
    eq(w.TimesUsedReinforcements, before, "cap: at the cap nothing is written")
    eq(count("^TOKENS bonus classified=3 %+0 capped at 3$"), 1, "cap: one +0 capped line", dump())
    tokens.classified(t, g, "poll", op)
    eq(count("capped at 3$"), 2, "cap: the +0 line once per rise, not per reading")
    for i = 1, 3 do reinforce(t, g, f, op, "poll") end
    eq(count("^TOKENS disabled at used=5 N=5 via=poll$"), 1, "cap: disabled at used 5", dump())
    -- Cap 0: every rise is +0 capped.
    local op2 = o()
    local g2, f2, w2 = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t2 = tokens.start(g2, nil, op2, cls(2, 0))
    objective(t2, g2, f2, op2)
    eq(w2.TimesUsedReinforcements, nil, "cap 0: nothing written")
    eq(count("^TOKENS bonus classified=1 %+0 capped at 0$"), 1, "cap 0: one +0 line", dump())
end
do -- floats from knobs.parse (2.0) log as integers; a k that isn't a whole number > 0 does nothing
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2.0, op, cls(2.0, 3.0))
    eq(count("^TOKENS classified k=2 cap=3 baseline=0$"), 1, "floats: integer line", dump())
    objective(t, g, f, op, "poll")
    eq(count("^TOKENS bonus classified=1 %+2 count=4 left=4 via=poll$"), 1, "floats: integer bonus line", dump())
    local op2 = o()
    local g2, _, w2 = gs{ ClassifiedDynamicValue = 0 }
    eq(tokens.start(g2, nil, op2, cls(2.5)), nil, "k 2.5 without revives: no state")
    eq(next(w2), nil, "k 2.5: nothing written")
    eq(count("^WARN TOKENS classified k=2%.5"), 1, "k 2.5: one WARN", dump())
    local t3 = tokens.start(g2, 2, op2, cls(-1))
    ok(t3 ~= nil and t3.k == nil, "k -1 with revives: revives still acts, no bonus")
end
do -- The count unreadable at award time: no write, one WARN, the value kept; the next readable reading awards once
    local op = o()
    local g, f, w = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, 2, op, cls(2))
    f.TimesUsedReinforcements = "?"
    f.ClassifiedDynamicValue = 1
    tokens.classified(t, g, "poll", op)
    tokens.classified(t, g, "poll", op)
    eq(w.TimesUsedReinforcements, 1, "unreadable count: no award write (only the start's)")
    eq(count("^WARN TOKENS the count is unreadable at a classified bonus"), 1, "unreadable count: one WARN", dump())
    eq(count("^TOKENS bonus"), 0, "unreadable count: no bonus line")
    f.TimesUsedReinforcements = 6
    tokens.classified(t, g, "poll", op)
    tokens.classified(t, g, "poll", op)
    eq(f.TimesUsedReinforcements, 4, "readable again: awarded once (6 -> 4)")
    eq(count("^TOKENS bonus classified=1 %+2 count=4 "), 1, "readable again: one bonus line", dump())
end
do -- A failed count write at an award raises (the guard backs off)
    local op = o()
    local g, f = gs{ ["Classified Minium"] = 3, ClassifiedDynamicValue = 0 }
    local t = tokens.start(g, nil, op, cls(2))
    f.ClassifiedDynamicValue = 1
    f._readonly = true
    ok(not pcall(tokens.classified, t, g, "poll", op), "a failed award write raises")
    eq(tokens.classified(nil, g, "poll", op), nil, "classified with no state: nothing")
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
