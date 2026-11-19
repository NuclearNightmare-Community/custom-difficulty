-- Unit tests for Scripts/knobs.lua: the knob table agrees with mod.json, and the parser's bounds (presets-and-ui.md
-- "The sidecar": known keys, numbers in range rounded to the step, 1024 bytes; a bad entry is Default with one problem).
-- Run from the repo root:  texlua test/unit/knobs_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local J = require("json")
local H = F.harness("knobs_test")
local ok, eq = H.ok, H.eq
local knobs = require("knobs")

-- ---------------------------------------------------------------- the table matches mod.json
do
    local f = assert(io.open(ROOT .. "/mod.json", "r"))
    local m = J.decode(f:read("a"))
    f:close()
    local n = 0
    for _, key in ipairs(m.settings.__keys) do
        local s = m.settings[key]
        n = n + 1
        local k = knobs.BY_KEY[key]
        ok(k ~= nil, "knobs.lua knows mod.json's " .. key)
        if k and s.type == "bool" then
            -- Story 14: an Insta-kill box is a bool setting (default false) and a 0..1 flag knob here.
            ok(k.flag == true and k.min == 0 and k.max == 1 and k.step == 1 and s.default == false, key .. ": a bool setting is a 0..1 flag knob")
        elseif k then ok(k.min == s.min and k.max == s.max and k.step == s.step, key .. ": same range and step as mod.json",
            ("%s..%s/%s vs %s..%s/%s"):format(k.min, k.max, k.step, s.min, s.max, s.step)) end
    end
    eq(#knobs.KNOBS, n, "knobs.lua has exactly mod.json's settings")
    eq(knobs.STANDARD[0] .. "/" .. knobs.STANDARD[1] .. "/" .. knobs.STANDARD[2] .. "/" .. knobs.STANDARD[3], "100/50/25/17", "STANDARD")
end

-- ---------------------------------------------------------------- parse
local function parse(t) local v, p = knobs.parse(t) return v, p end
do
    local v, p = parse(nil)
    ok(next(v) == nil and #p == 0, "nil: every knob Default, no problem")
    v, p = parse("")
    ok(next(v) == nil and #p == 0, "empty: every knob Default, no problem")
    v, p = parse("enemyDamage=17")
    eq(v.enemyDamage, 17, "enemyDamage=17")
    eq(#p, 0, "a good entry: no problem")
    v, p = parse(" enemyDamage = 25 ; dmg.stalker=200;spread=20; ")
    ok(v.enemyDamage == 25 and v["dmg.stalker"] == 200 and v.spread == 20 and #p == 0, "several entries, spaces and a trailing ;")
    v = parse("dmg.stalker=203")
    eq(v["dmg.stalker"], 205, "rounded to the step (5)")
    v = parse("dmg.stalker=202")
    eq(v["dmg.stalker"], 200, "rounded to the step (down)")
    v = parse("frostbite=2.3")
    eq(v.frostbite, 2.5, "rounded to the step 0.5")
    v = parse("enemyDamage=16.4")
    eq(v.enemyDamage, 16, "rounded to the step 1")
    v, p = parse("enemyDamage=default")
    ok(v.enemyDamage == nil and #p == 0, "'default' is Default, no problem")
    v, p = parse("enemyDamage=0;dmg.apex=0")
    ok(v.enemyDamage == 0 and v["dmg.apex"] == 0, "0 is a value, not Default")
end
do -- bad entries: that knob Default, one problem each
    local v, p = parse("bogus=5;enemyDamage=17")
    ok(v.bogus == nil and v.enemyDamage == 17, "unknown key ignored, the rest kept")
    eq(#p, 1, "unknown key: one problem")
    ok(p[1] and p[1]:find("unknown knob 'bogus'", 1, true), "the problem names the key", p[1])
    v, p = parse("enemyDamage=201")
    ok(v.enemyDamage == nil and #p == 1 and p[1]:find("outside 0..200", 1, true), "out of range (high): Default, one problem", p[1])
    v, p = parse("spread=-1")
    ok(v.spread == nil and #p == 1, "out of range (low): Default, one problem")
    v, p = parse("enemyDamage=abc;spread=1e3;cold=0x10;revives=inf;frostbite=nan")
    ok(next(v) == nil, "not decimal numbers: every one Default")
    eq(#p, 5, "not decimal numbers: one problem each")
    v, p = parse("enemyDamage")
    ok(next(v) == nil and #p == 1 and p[1]:find("not key=value", 1, true), "no '=': one problem")
    v, p = parse("infection=40")
    ok(next(v) == nil and #p == 1, "infection (v2) is not a v1 knob")
    v, p = parse("enemyDamage=17;" .. string.rep("x", 1100))
    ok(next(v) == nil and #p == 1 and p[1]:find("over 1024", 1, true), "oversized: every knob Default, one problem", p[1])
    v, p = parse(string.rep("a", 1024 - #"enemyDamage=17;") .. ";enemyDamage=17")
    eq(#p >= 1, true, "1024 bytes exactly: parsed (a junk entry is a problem)")
    eq(v.enemyDamage, 17, "1024 bytes exactly: the good entry kept")
    v, p = parse(17)
    ok(next(v) == nil and #p == 1 and p[1]:find("not a string", 1, true), "not a string: every knob Default, one problem")
    local many = {}
    for i = 1, 40 do many[#many + 1] = "enemyDamage=" .. i end
    v, p = parse(table.concat(many, ";"))
    eq(v.enemyDamage, 32, "at most 32 entries read")
    ok(#p == 1 and p[1]:find("more than 32", 1, true), "more than 32 entries: one problem")
    v, p = parse("enemyDamage=17\nspread=5")
    ok(v.enemyDamage == nil and #p >= 1, "a control character makes the entry bad")
end
do -- describe
    eq(knobs.describe({}), "all Default", "describe: all Default")
    eq(knobs.describe({ ["dmg.stalker"] = 200, enemyDamage = 17, frostbite = 2.5 }), "enemyDamage=17 frostbite=2.5 dmg.stalker=200", "describe: KNOBS order")
end

-- ---------------------------------------------------------------- encode (story 6): the inverse of parse
do
    eq(knobs.encode({}), "", "encode: all Default is empty")
    eq(knobs.encode({ ["dmg.stalker"] = 200, enemyDamage = 17, frostbite = 2.5 }), "enemyDamage=17;frostbite=2.5;dmg.stalker=200", "encode: KNOBS order")
    local v = { cold = 50, spread = 20, revives = 0, frostbite = 0.5, ["dmg.apex"] = 0 }
    eq(knobs.describe((knobs.parse(knobs.encode(v)))), knobs.describe(v), "encode then parse round-trips")
end
do -- story 12: Tokens per Classified (0..4) and Max Classified Tokens (0..40), right after revives
    local v, p = knobs.parse("classifiedTokensMax=3;classifiedTokens=2;revives=2;cold=50")
    ok(v.classifiedTokens == 2 and v.classifiedTokensMax == 3 and #p == 0, "the two keys parse")
    eq(knobs.encode(v), "revives=2;classifiedTokens=2;classifiedTokensMax=3;cold=50", "encode: right after revives, in KNOBS order")
    v, p = knobs.parse("classifiedTokens=5;classifiedTokensMax=41")
    ok(v.classifiedTokens == nil and v.classifiedTokensMax == nil and #p == 2, "out of range: Default, one problem each")
    v = knobs.parse("classifiedTokens=1.4;classifiedTokensMax=0")
    ok(v.classifiedTokens == 1 and v.classifiedTokensMax == 0, "rounded to the step; 0 kept")
    local all = {}
    for _, k in ipairs(knobs.KNOBS) do all[k.key] = k.max end
    ok(#knobs.KNOBS == 29 and #knobs.KNOBS <= knobs.MAX_ENTRIES, "29 knobs (21 + 8 Insta-kill boxes) fit MAX_ENTRIES")
    ok(#knobs.encode(all) + 128 * 3 + 8 <= knobs.MAX_TEXT, "every knob at its max and a 128-byte encoded name fit a sidecar line", #knobs.encode(all))
end
do -- story 14: the Insta-kill boxes, "kill.<row>" = 1 or Default
    eq(table.concat(knobs.GRAB_ROWS, ","), "meek,mimic,psycho,husk,watcher,stalker", "GRAB_ROWS: the six grabs, bitmask order")
    eq(table.concat(knobs.KILL_ROWS, ","), "meek,mimic,psycho,husk,watcher,stalker,slugQueen,apex", "KILL_ROWS: the six grabs and the two bosses")
    for _, r in ipairs({ "worm", "leech", "bat", "infectedDog", "infectedPlayer", "monster" }) do
        eq(knobs.BY_KEY["kill." .. r], nil, "no box on " .. r)
        local v, p = knobs.parse("kill." .. r .. "=1")
        ok(next(v) == nil and #p == 1 and p[1]:find("unknown knob", 1, true), "kill." .. r .. ": unknown knob, one problem")
    end
    local v, p = knobs.parse("kill.meek=1;kill.apex=1")
    ok(v["kill.meek"] == 1 and v["kill.apex"] == 1 and #p == 0, "kill.meek=1 and kill.apex=1 parse")
    eq(knobs.encode(v), "kill.meek=1;kill.apex=1", "encode: after the dmg rows, KILL_ROWS order")
    eq(knobs.describe(v), "kill.meek=1 kill.apex=1", "describe names them")
    v, p = knobs.parse("kill.meek=0")
    ok(next(v) == nil and #p == 0, "kill.meek=0: unticked is Default, no problem")
    eq(knobs.encode(v), "", "kill.meek=0: nothing encoded")
    v, p = knobs.parse("kill.meek=default")
    ok(next(v) == nil and #p == 0, "kill.meek=default: Default, no problem")
    for _, bad in ipairs({ "2", "yes", "-1", "0.5", "1.5", "true" }) do
        v, p = knobs.parse("kill.meek=" .. bad .. ";enemyDamage=17")
        ok(v["kill.meek"] == nil and v.enemyDamage == 17 and #p == 1, "kill.meek=" .. bad .. ": Default, one problem, the rest kept", p[1])
    end
    v, p = knobs.parse("kill.meek=1.0")
    ok(v["kill.meek"] == 1 and #p == 0, "kill.meek=1.0: ticked")
    -- A sidecar round trip with a box ticked.
    v = knobs.parse("enemyDamage=25;dmg.meek=0;kill.meek=1")
    eq(knobs.encode((knobs.parse(knobs.encode(v)))), "enemyDamage=25;dmg.meek=0;kill.meek=1", "encode then parse round-trips a ticked box")
end

H.done()
