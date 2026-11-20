-- Unit tests for mod.json: the manifest fields (AGENTS.md conventions, the spec's constraints) and the settings:
-- the five v1 knobs and the 14 per-enemy rows of presets-and-ui.md, each with its range, step, scope and the shape
-- { type number, min, max, step, default null, label, scope, changeable menu, source presets }; story 14's eight
-- Insta-kill boxes, each right after its enemy's row, with { type bool, default false, label, scope, changeable menu,
-- source presets } (core's schema type "bool"). No Infection Chance (v2).
-- Run from the repo root:  texlua test/unit/modjson_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. package.path
local F = require("fakeue")
local J = require("json")
local H = F.harness("modjson_test")
local ok, eq = H.ok, H.eq

local f = assert(io.open(ROOT .. "/mod.json", "r"))
local text = f:read("a")
f:close()
local okJ, m = pcall(J.decode, text)
ok(okJ, "mod.json parses", m)
if not okJ then H.done() end

eq(m.id, "nuclearnightmare-community.custom-difficulty", "id")
eq(m.name, "CustomDifficulty", "name")
eq(m.version, "0.2.0", "version")
ok(tostring(m.version):match("^%d+%.%d+%.%d+$"), "version is semver")
eq(m.scope, "all", "scope all")
eq(m.game and m.game.version, "V8.2.3", "game.version")
eq(m.game and m.game.build, "26601774", "game.build")
eq(m.ue4ss, "v3.0.1-1181-g83330635", "ue4ss pinned")
ok(type(m.dependsOn) == "table" and #m.dependsOn == 1, "one dependency")
eq(m.dependsOn[1].id, "nuclearnightmare-community.nucleus", "dependsOn nuclearnightmare-community.nucleus")
eq(m.dependsOn[1].version, "^0.15.0", "dependsOn ^0.15.0 (core story 33: game-style rows for story 7)")
ok(not text:lower():find("infection", 1, true), "no Infection Chance anywhere in mod.json (v2)")

-- key, label, min, max, step, scope (presets-and-ui.md; Decisions: 'all' for the survivable-grab inputs)
local ROWS = {
    { "enemyDamage", "Enemy Damage", 0, 200, 1, "all" },
    { "spread", "Damage Spread", 0, 50, 1, "host" },
    { "revives", "Reinforcement Tokens", 0, 20, 1, "host" },
    { "classifiedTokens", "Tokens per Classified", 0, 4, 1, "host" },
    { "classifiedTokensMax", "Max Classified Tokens", 0, 40, 1, "host" },
    { "cold", "Cold Exposure", 0, 400, 1, "host" },
    { "frostbite", "Frostbite Damage", 0, 20, 0.5, "host" },
    { "dmg.meek", "Damage: Meek", 0, 500, 5, "all" },
    { "kill.meek", "Insta-kill: Meek", "bool", "all" },
    { "dmg.mimic", "Damage: Mimic", 0, 500, 5, "all" },
    { "kill.mimic", "Insta-kill: Mimic", "bool", "all" },
    { "dmg.psycho", "Damage: Psycho", 0, 500, 5, "all" },
    { "kill.psycho", "Insta-kill: Psycho", "bool", "all" },
    { "dmg.husk", "Damage: Husk", 0, 500, 5, "all" },
    { "kill.husk", "Insta-kill: Husk", "bool", "all" },
    { "dmg.watcher", "Damage: Watcher", 0, 500, 5, "all" },
    { "kill.watcher", "Insta-kill: Watcher", "bool", "all" },
    { "dmg.stalker", "Damage: Stalker", 0, 500, 5, "all" },
    { "kill.stalker", "Insta-kill: Stalker", "bool", "all" },
    { "dmg.slugQueen", "Damage: Slug Queen", 0, 500, 5, "host" },
    { "kill.slugQueen", "Insta-kill: Slug Queen", "bool", "host" },
    { "dmg.apex", "Damage: Apex Predator", 0, 500, 5, "host" },
    { "kill.apex", "Insta-kill: Apex Predator", "bool", "host" },
    { "dmg.worm", "Damage: Worm", 0, 500, 5, "host" },
    { "dmg.leech", "Damage: Leech", 0, 500, 5, "host" },
    { "dmg.bat", "Damage: Bat", 0, 500, 5, "host" },
    { "dmg.infectedDog", "Damage: Infected Dog", 0, 500, 5, "host" },
    { "dmg.infectedPlayer", "Damage: Infected Player", 0, 500, 5, "host" },
    { "dmg.monster", "Damage: Playable Monster", 0, 500, 5, "host" },
}
local S = m.settings
ok(type(S) == "table" and S.__keys, "settings is an object")
eq(#S.__keys, 29, "29 settings (21 rows, 8 Insta-kill boxes)")
eq(#ROWS, 29, "(the expected table has 29 rows)")
local ALLOWED = { type = 1, min = 1, max = 1, step = 1, default = 1, label = 1, scope = 1, changeable = 1, source = 1, __keys = 1 }
local BOOL = { type = 1, default = 1, label = 1, scope = 1, changeable = 1, source = 1, __keys = 1 }
for i, r in ipairs(ROWS) do
    local key, label, min, max, step, scope = r[1], r[2], r[3], r[4], r[5], r[6]
    eq(S.__keys[i], key, "setting " .. i .. " is " .. key .. " (row order)")
    local s = S[key]
    ok(type(s) == "table", key .. ": declared")
    if type(s) == "table" and min == "bool" then
        scope = max
        eq(s.type, "bool", key .. ": type bool (core's schema name)")
        eq(s.default, false, key .. ": default false (unticked)")
        eq(s.label, label, key .. ": label")
        eq(s.scope, scope, key .. ": scope")
        eq(s.changeable, "menu", key .. ": changeable menu")
        eq(s.source, "presets", key .. ": source presets")
        for k in pairs(s) do ok(BOOL[k], key .. ": no unknown field " .. tostring(k)) end
        ok(key:match("^kill%.[%a][%w]*$"), key .. ": a kill.<row> key")
        eq(S.__keys[i - 1], key:gsub("^kill", "dmg"), key .. ": right after its enemy's row")
    elseif type(s) == "table" then
        eq(s.type, "number", key .. ": type number")
        eq(s.min, min, key .. ": min")
        eq(s.max, max, key .. ": max")
        eq(s.step, step, key .. ": step")
        ok(s.min < s.max, key .. ": min < max")
        ok(s.step > 0 and ((s.max - s.min) / s.step) % 1 == 0, key .. ": the range is a whole number of steps")
        eq(s.default, J.null, key .. ": default null (Default: the row's own default)")
        eq(s.label, label, key .. ": label")
        eq(s.scope, scope, key .. ": scope")
        eq(s.changeable, "menu", key .. ": changeable menu")
        eq(s.source, "presets", key .. ": source presets")
        for k in pairs(s) do ok(ALLOWED[k], key .. ": no unknown field " .. tostring(k)) end
        ok(key:match("^[%a][%w]*$") or key:match("^dmg%.[%a][%w]*$"), key .. ": a plain key")
    end
end
for _, k in ipairs(S.__keys) do ok(not k:lower():find("infection", 1, true), "no infection key: " .. k) end

-- The settings the grab decision reads (Decisions: enemyDamage and the six grabbing enemies, with their Insta-kill
-- boxes) are 'all'; every other is 'host' (the bosses' boxes too: CommitLethalDamage runs on the host).
local all = {}
for _, k in ipairs(S.__keys) do if S[k].scope == "all" then all[#all + 1] = k end end
eq(table.concat(all, ","), "enemyDamage,dmg.meek,kill.meek,dmg.mimic,kill.mimic,dmg.psycho,kill.psycho,dmg.husk,kill.husk,dmg.watcher,kill.watcher,dmg.stalker,kill.stalker", "scope all = the survivable-grab inputs")
local boxes = {}
for _, k in ipairs(S.__keys) do if k:match("^kill%.") then boxes[#boxes + 1] = k end end
eq(#boxes, 8, "eight Insta-kill boxes")
for _, r in ipairs({ "worm", "leech", "bat", "infectedDog", "infectedPlayer", "monster" }) do eq(S["kill." .. r], nil, "no box for " .. r) end

H.done()
