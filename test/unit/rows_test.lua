-- Unit tests for Scripts/rows.lua (story 7): the pure data (labels and ranges against mod.json and knobs.lua, the
-- tooltips' line and byte limits, the defaults per difficulty and an unknown index), and every row of the story's I/O
-- matrix on a fake core.ui wired to the real presets.lua over a fake CreateServer_C (open, drag or type, clear,
-- Difficulty and Classified changes, preset select, None, reopen, a missing anchor, a throwing callback), plus core
-- calls that fail.
-- Run from the repo root:  texlua test/unit/rows_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local J = require("json")
local H = F.harness("rows_test")
local ok, eq = H.ok, H.eq
local rows = require("rows")
local knobs = require("knobs")
local presets = require("presets")
local HDR = "# Difficulty world presets, format 2\n"
local FILE = "C:/nn/copy/_userdir/Saved/SaveGames/Difficulty_WorldPresets.txt"
local ENEMY = {}
for _, r in ipairs(knobs.ROWS) do ENEMY[#ENEMY + 1] = "dmg." .. r end

-- ---------------------------------------------------------------- pure data
do
    eq(#rows.ORDER, 21, "21 rows")
    eq(table.concat(rows.ORDER, ",", 1, 7), "enemyDamage,spread,revives,classifiedTokens,classifiedTokensMax,cold,frostbite", "the knob rows first, in the screen's order (story 12's two right after Reinforcement Tokens)")
    eq(table.concat(rows.ORDER, ",", 8), table.concat(ENEMY, ","), "then the per-enemy rows in knobs.ROWS order")
    local f = assert(io.open(ROOT .. "/mod.json", "r"))
    local m = J.decode(f:read("a"))
    f:close()
    eq(table.concat(m.settings.__keys, ","), table.concat(rows.ORDER, ","), "the rows' order is mod.json's settings order")
    for _, key in ipairs(rows.ORDER) do
        local s, k = m.settings[key], knobs.BY_KEY[key]
        eq(rows.LABELS[key], s.label, key .. ": label = mod.json's")
        ok(k and k.min == s.min and k.max == s.max and k.step == s.step, key .. ": knobs.lua's range and step = mod.json's")
        local help = rows.HELP[key]
        ok(type(help) == "string" and #help >= 1 and #help <= rows.MAX_HELP_BYTES, key .. ": help 1..512 bytes", #help)
        local _, nl = help:gsub("\n", "")
        ok(nl + 1 <= rows.MAX_HELP_LINES, key .. ": help at most 8 lines", nl + 1)
        ok(not help:find("[\0-\9\11-\31]"), key .. ": help is plain text (newline the only control byte)")
        ok(#rows.LABELS[key] <= rows.MAX_LABEL, key .. ": label at most 64 bytes")
        local range = ("Range %s-%s"):format(rows.num(k.min), rows.num(k.max))
        ok(help:find(range, 1, true), key .. ": help names the range " .. range, help)
        if key:match("^dmg%.") then
            ok(help:find("Empty = 100.", 1, true), key .. ": help says Empty = 100")
        elseif key == "classifiedTokens" then
            ok(help:find("Default: 0 on every difficulty.", 1, true) and help:find("Empty = 0 (the game gives none).", 1, true), key .. ": help says Default 0 and Empty = 0", help)
        elseif key == "classifiedTokensMax" then
            ok(help:find("Default: no cap.", 1, true) and help:find("Empty = no cap.", 1, true), key .. ": help says Default no cap and Empty = no cap", help)
        elseif key == "revives" then
            ok(help:find("Empty = follow Classified Minimum.", 1, true) and not help:find("follow Difficulty", 1, true), key .. ": help says Empty = follow Classified Minimum")
        else
            ok(help:find("Empty = follow Difficulty.", 1, true), key .. ": help says Empty = follow Difficulty")
        end
    end
    ok(rows.HELP.frostbite:find("in steps of 0.5", 1, true), "frostbite: the 0.5 step named")
    ok(rows.HELP.enemyDamage:find("Nightmare 100, Hard 50, Normal 25, Easy 17", 1, true), "enemyDamage: defaults per difficulty")
    ok(rows.HELP.cold:find("Nightmare 200, Hard 133, Normal 100, Easy 50", 1, true), "cold: defaults per difficulty")
    ok(rows.HELP.revives:find("Nightmare 2, Hard 4, Normal 6, Easy 8", 1, true), "revives: defaults per Classified Minimum")
    ok(rows.HELP["dmg.meek"]:find("execution 100", 1, true) and rows.HELP["dmg.stalker"]:find("execution 100", 1, true), "Meek and Stalker: execution 100")
    ok(rows.HELP["dmg.leech"]:find("25 on every", 1, true) and rows.HELP["dmg.monster"]:find("45 on every", 1, true), "Leech 25, Playable Monster 45")
    for _, key in ipairs(rows.ORDER) do ok(not key:lower():find("infection"), "no Infection Chance row: " .. key) end
end
do -- the defaults per difficulty (EDiffculty 0..3 = Nightmare, Hard, Normal, Easy)
    local WANT = { [0] = { 100, 200, 2 }, [1] = { 50, 133, 4 }, [2] = { 25, 100, 6 }, [3] = { 17, 50, 8 } }
    for i = 0, 3 do
        local d, problems = rows.defaults(i, i)
        eq(#problems, 0, "index " .. i .. ": no problem")
        eq(d.enemyDamage, WANT[i][1], "index " .. i .. ": enemyDamage")
        eq(d.cold, WANT[i][2], "index " .. i .. ": cold = round(200 / divisor)")
        eq(d.revives, WANT[i][3], "index " .. i .. ": revives by Classified Minimum")
        eq(d.spread, 0, "index " .. i .. ": spread 0")
        eq(d.frostbite, 1, "index " .. i .. ": frostbite 1")
        eq(d.classifiedTokens, 0, "index " .. i .. ": classifiedTokens 0")
        eq(d.classifiedTokensMax, 40, "index " .. i .. ": classifiedTokensMax sits at 40 (no cap)")
        for _, k in ipairs(ENEMY) do eq(d[k], 100, "index " .. i .. ": " .. k .. " 100") end
    end
    local d = rows.defaults(0, 3)
    ok(d.enemyDamage == 100 and d.revives == 8, "Difficulty and Classified Minimum are independent")
    for _, bad in ipairs({ 4, -1, 1.5, "2", nil }) do
        local u, problems = rows.defaults(bad, 2)
        ok(u.enemyDamage == 25 and u.cold == 100 and #problems == 1, "unknown Difficulty " .. tostring(bad) .. ": Normal, one problem")
        u, problems = rows.defaults(2, bad)
        ok(u.revives == 6 and #problems == 1, "unknown Classified " .. tostring(bad) .. ": Normal, one problem")
    end
end

-- ---------------------------------------------------------------- the adapter on presets.lua and a fake screen
local W, D, U, P, R, logs
local function setup(o)
    o = o or {}
    W = F.new()
    F.install(W)
    D = F.fs()
    U = F.ui()
    logs = {}
    local function say(level, fmt, ...) logs[#logs + 1] = (level == "info" and "" or (level:upper() .. " ")) .. string.format(fmt, ...) end
    local said = {}
    local function warnOnce(k, fmt, ...) if not said[k] then said[k] = true say("warn", fmt, ...) end end
    P = presets.new{ say = say, warnOnce = warnOnce, name = "Difficulty", fs = D,
                     onRows = function(d, cm) if R then R:sync(d, cm) end end }
    R = rows.new{ ui = U, model = P, say = say, warnOnce = warnOnce, levels = presets.levels, hasAnchor = o.hasAnchor }
    ok(R:watch(), "watch registers")
    P:onLoadMap()
    return R
end
local function count(pat) local n = 0 for _, l in ipairs(logs) do if l:find(pat) then n = n + 1 end end return n end
local function last(pat) local r for _, l in ipairs(logs) do if l:find(pat) then r = l end end return r end
local function sl(key) return U.sliders["s-" .. key] end
local function hints()
    local t = {}
    for _, key in ipairs(rows.ORDER) do t[#t + 1] = tostring(sl(key).hint) end
    return table.concat(t, " ")
end
local function values()
    local t = {}
    for _, key in ipairs(rows.ORDER) do t[#t + 1] = tostring(sl(key).value) end
    return table.concat(t, " ")
end
local ALL_NIL = ("nil "):rep(21):sub(1, -2)
local NORMAL_HINTS = "25 0 6 0 no cap 100 1" .. (" 100"):rep(14)
local function writes() local n = 0 for _, l in ipairs(D.log) do if l:find("^write ") then n = n + 1 end end return n end

do -- declare: 21 rows with sliders, once
    setup()
    ok(R:declare(), "declare returns true")
    eq(#U.order, 21, "21 rows declared")
    for i, key in ipairs(rows.ORDER) do
        local rh = U.rows["r-" .. key]
        eq(U.order[i], "r-" .. key, "row " .. i .. " is " .. key .. " (creation order = screen order)")
        local o = rh.opts
        eq(o.like, "Overlay_28", key .. ": like the Difficulty row")
        eq(o.label, rows.LABELS[key], key .. ": label")
        eq(o.help, rows.HELP[key], key .. ": help")
        eq(o.place.container, "VerticalBox_202", key .. ": in the settings list")
        eq(o.place.after, key:match("^dmg%.") and "Overlay_738" or "Overlay_28", key .. ": anchor")
        local s, k = sl(key), knobs.BY_KEY[key]
        ok(s and s.row == rh, key .. ": its slider sits in its row")
        ok(s.min == k.min and s.max == k.max and s.step == k.step, key .. ": the slider's range and step are knobs.lua's")
        eq(s.value, nil, key .. ": Default at declare")
    end
    eq(hints(), NORMAL_HINTS, "declare: the hints are Normal's")
    eq(count("^ROWS declared 21$"), 1, "one ROWS declared line")
    eq(U.shown("s-classifiedTokens"), 0, "Tokens per Classified: Default sits at 0")
    eq(U.shown("s-classifiedTokensMax"), 40, "Max Classified Tokens: Default sits at the max (40)")
    eq(sl("classifiedTokensMax").hint, "no cap", "Max Classified Tokens: the hint says no cap")
    local n = #U.calls
    ok(R:declare(), "declare again: true")
    eq(#U.calls, n, "declare again: no core call")
end

do -- the matrix: open, drag or type, clear, Difficulty, Classified, preset select, None, reopen
    setup()
    R:declare()
    D.files[FILE] = HDR .. "0\tA\tenemyDamage=17\n"
    local S = F.screen(W, { "A" })
    S.levels[1] = { 1, 1 } -- preset A was saved on Hard, Classified Hard
    S:open()
    U.open(F.tree({ "Overlay_10", "Overlay_28", "Overlay_738", "Overlay_33" }))
    eq(values(), ALL_NIL, "open: every box empty")
    eq(hints(), NORMAL_HINTS, "open on Normal: hints 25 / 0 / 6 / 100 / 1 / 100 x14")
    ok(count("^WARN") == 0, "open: no WARN", table.concat(logs, " | "))
    local w0 = writes()

    U.input("s-enemyDamage", 61.6) -- a drag
    eq(P.rows.enemyDamage, 62, "drag: the model at the dragged value")
    U.input("s-enemyDamage", 57) -- typed 57 + Enter
    eq(P.rows.enemyDamage, 57, "type 57: P.rows.enemyDamage = 57")
    eq(last("^ROWS change"), "ROWS change enemyDamage=57 rows=enemyDamage=57", "type 57: the log line names the model")
    S:capture()
    eq(P:sessionText(), "enemyDamage=57", "a capture now encodes enemyDamage=57")
    U.input("s-enemyDamage", 999)
    eq(P.rows.enemyDamage, 200, "type 999: clamped to 200")
    U.input("s-enemyDamage", nil)
    eq(P.rows.enemyDamage, nil, "clear: Default")
    eq(last("^ROWS change"), "ROWS change enemyDamage=default rows=", "clear: logged as default")
    eq(writes(), w0, "slider changes never write the sidecar")

    U.input("s-cold", 150)
    S:pick(0) -- Nightmare
    eq(sl("enemyDamage").hint, "100", "Nightmare: Default Enemy Damage hint 100")
    eq(U.shown("s-enemyDamage"), 100, "Nightmare: its slider sits at 100")
    eq(sl("cold").hint, "200", "Nightmare: Cold's hint 200")
    eq(sl("cold").value, 150, "Nightmare: the custom Cold keeps its value")
    eq(P.rows.cold, 150, "Nightmare: the model keeps cold=150")
    eq(sl("revives").hint, "6", "Nightmare: tokens still follow Classified Minimum (Normal)")
    eq(last("^ROWS follow"), "ROWS follow difficulty=0 classified=2 enemyDamage=100 cold=200 revives=6", "the follow line")
    S:pickClassified(3)
    eq(sl("revives").hint, "8", "Classified Easy: Default tokens hint 8")
    eq(sl("enemyDamage").hint, "100", "Classified change: Enemy Damage still Nightmare's")

    S:select(1) -- preset A: enemyDamage=17, saved on Hard
    eq(sl("enemyDamage").value, 17, "select A: the slider shows 17")
    eq(sl("cold").value, nil, "select A: Cold back to Default (the preset's value)")
    eq(sl("cold").hint, "133", "select A: the Default rows follow the preset's Difficulty (Hard)")
    eq(U.shown("s-cold"), 133, "select A: Cold sits at Hard's 133")
    eq(sl("revives").hint, "4", "select A: tokens follow the preset's Classified Minimum")
    local before = values()
    S:select(0)
    eq(values(), before, "select None: the rows unchanged")
    eq(P.rows.enemyDamage, 17, "select None: the model unchanged")

    S:open() -- Back, then open again
    eq(values(), ALL_NIL, "reopen: every row Default")
    eq(hints(), NORMAL_HINTS, "reopen: Normal's hints (the class defaults)")
    U.open(F.tree({ "Overlay_28", "Overlay_738" }))
    eq(hints(), NORMAL_HINTS, "reopen opened: still Normal's")
    eq(count("^WARN"), 0, "the matrix: no WARN")
    eq(count("^ERROR"), 0, "the matrix: no ERROR")
    eq(#U.placed, 0, "the anchor was there: nothing re-placed")
end

do -- a missing anchor: one WARN, the per-enemy rows after the knob rows; back when it returns
    setup()
    R:declare()
    U.open(F.tree({ "Overlay_28", "Overlay_33" }))
    eq(count("^WARN ROWS Overlay_738 is missing"), 1, "anchor gone: one WARN")
    eq(#U.placed, 14, "anchor gone: the fourteen per-enemy rows re-placed")
    for _, k in ipairs(ENEMY) do eq(U.rows["r-" .. k].place.after, "Overlay_28", k .. ": after Overlay_28 now") end
    for _, k in ipairs(rows.KNOB_KEYS) do eq(U.rows["r-" .. k].place.after, "Overlay_28", k .. ": knob row unchanged") end
    local ki, ei = 0, 0
    for i, id in ipairs(U.order) do if id == "r-frostbite" then ki = i end if id == "r-dmg.meek" then ei = i end end
    ok(ki < ei, "the knob rows were declared first (core keeps creation order at one position)")
    U.open(F.tree({ "Overlay_28" }))
    eq(count("^WARN ROWS Overlay_738"), 1, "a second open without it: still one WARN")
    eq(#U.placed, 14, "a second open: no re-place")
    U.open(F.tree({ "Overlay_28", "Overlay_738" }))
    eq(#U.placed, 28, "the anchor back: re-placed after it")
    eq(U.rows["r-dmg.meek"].place.after, "Overlay_738", "the anchor back: after Overlay_738")
    eq(count("^ERROR"), 0, "anchor: no ERROR")
end
do -- the walk: a tree that can't be read changes nothing; the real walk finds a deep name
    setup()
    R:declare()
    U.open({ Diffculty = 2, ["Minium Classified"] = 2 }) -- no WidgetTree
    eq(#U.placed, 0, "no tree: nothing re-placed")
    eq(count("^WARN"), 0, "no tree: no WARN")
    eq(rows.hasNamed(F.tree({ "a", "Overlay_738" }), "Overlay_738"), true, "the walk finds a child of a child of the root")
    U.open(F.tree({ "Overlay_738" }, 0, 3)) -- opened covers the initial state: the screen on Nightmare, Classified Easy
    eq(sl("enemyDamage").hint, "100", "opened on Nightmare: Enemy Damage hint 100")
    eq(sl("revives").hint, "8", "opened on Classified Easy: tokens hint 8")
    eq(rows.hasNamed(F.tree({ "a" }), "Overlay_738"), false, "the walk: a miss")
    eq(rows.hasNamed({}, "Overlay_738"), nil, "the walk: no root -> nil")
    local many = {}
    for i = 1, rows.WALK_MAX + 10 do many[i] = "w" .. i end
    many[#many + 1] = "Overlay_738"
    eq(rows.hasNamed(F.tree(many), "Overlay_738"), nil, "the walk out of budget with widgets left: nil (unknown), not a miss")
    local placed = #U.placed
    U.open(F.tree(many))
    eq(#U.placed, placed, "a truncated walk: the per-enemy rows stay where they are")
    eq(count("^WARN ROWS Overlay_738"), 0, "a truncated walk: no missing-anchor WARN")
    setup{ hasAnchor = function() error("boom") end }
    R:declare()
    U.open({})
    eq(count("^WARN ROWS the screen's tree could not be read"), 1, "a throwing walk: one WARN")
    eq(hints(), NORMAL_HINTS, "a throwing walk: the rows still follow (Normal)")
end

do -- a callback that throws: value not written, one log line
    setup()
    R:declare()
    local S = F.screen(W, {})
    S:open()
    P.rows = setmetatable({}, { __newindex = function() error("rows locked") end })
    U.input("s-enemyDamage", 57)
    eq(rawget(P.rows, "enemyDamage"), nil, "throwing body: the value is not written")
    eq(count("^ERROR ROWS enemyDamage change failed: .*rows locked; not written$"), 1, "throwing body: one ERROR line")
    eq(count("^ROWS change"), 0, "throwing body: no change line")
    P.rows = {}
    R:onChange("enemyDamage", 999)
    eq(P.rows.enemyDamage, nil, "out of range from core: not written")
    R:onChange("enemyDamage", "x")
    eq(count("^ERROR ROWS enemyDamage change failed"), 3, "each bad call: one line")
end

do -- unknown difficulty index on the screen: Normal, one WARN
    setup()
    R:declare()
    local S = F.screen(W, {})
    S:open()
    S:pick(7)
    eq(sl("enemyDamage").hint, "25", "Diffculty 7: Normal's hint")
    S:pick(9)
    S.Diffculty = "garbage"
    S:pickClassified(1)
    eq(count("^WARN ROWS Difficulty"), 1, "unknown index: one WARN per Lua state")
    S:pick(2)
    S:pickClassified(7)
    eq(sl("revives").hint, "6", "Minium Classified 7: Normal's tokens hint")
    S:pickClassified(9)
    eq(count("^WARN ROWS Classified Minimum"), 1, "unknown Classified index: its own WARN, once")
end

do -- core calls that fail: logged, never thrown
    setup()
    U.fails["slider.create"] = true
    eq(R:declare(), false, "slider.create fails: declare false")
    eq(count("^ERROR ROWS enemyDamage could not be declared"), 1, "slider.create fails: one ERROR")
    setup()
    R:declare()
    U.fails["slider.setDefault"], U.fails["slider.set"], U.fails["place"] = true, true, true
    local S = F.screen(W, {})
    S:open()
    S:pick(0)
    U.open(F.tree({ "Overlay_28" }))
    eq(count("^WARN ROWS enemyDamage default could not be set"), 1, "setDefault fails: one WARN per row")
    eq(count("^WARN ROWS enemyDamage could not be set"), 1, "set fails: one WARN per row")
    eq(count("^WARN ROWS the per%-enemy rows could not be moved"), 1, "place fails: one WARN")
    eq(count("^ERROR"), 0, "no ERROR (the hooks never see a throw)")
    setup()
    -- onRows itself throwing: presets logs one line per hook call
    P.o.onRows = function() error("rows broke") end
    local S2 = F.screen(W, {})
    S2:open()
    eq(count("^ERROR PRESETS rows update failed: .*rows broke"), 1, "onRows throws: one ERROR from presets")
    -- watch: once per Lua state; a failing watch is one ERROR; a closed or lost event is ignored
    setup()
    ok(R:watch(), "watch again: true")
    eq(#U.watchers, 1, "watch again: still one watcher")
    R:declare()
    S2 = F.screen(W, {})
    S2:open()
    S2:pick(0)
    U.open(nil, "closed")
    eq(sl("enemyDamage").hint, "100", "closed: nothing follows")
    U.opened = nil
    local U2 = F.ui()
    U2.fails["game.watch"] = true
    local R2 = rows.new{ ui = U2, model = P, say = function(l, f, ...) logs[#logs + 1] = l:upper() .. " " .. string.format(f, ...) end,
                         warnOnce = function() end, levels = presets.levels }
    eq(R2:watch(), false, "watch fails: false")
    eq(count("^ERROR ROWS could not watch the create%-world screen"), 1, "watch fails: one ERROR")
    local R3 = rows.new{ ui = {}, model = P, say = function(l, f, ...) logs[#logs + 1] = l:upper() .. " " .. string.format(f, ...) end,
                         warnOnce = function() end, levels = presets.levels }
    eq(R3:watch(), false, "no ui.game: false, no throw")
    -- opened itself throwing (levels broken): one ERROR from the watcher
    setup()
    R.o.levels = function() error("levels broke") end
    U.open(F.tree({ "Overlay_738" }))
    eq(count("^ERROR ROWS opened failed: .*levels broke"), 1, "opened throws: one ERROR")
end

H.done()
