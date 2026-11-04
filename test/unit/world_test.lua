-- Unit tests for Scripts/world.lua: the isHost cache (pure) and the game adapter over a fake KismetSystemLibrary.
-- Run from the repo root:  texlua test/unit/world_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("world_test")
local ok, eq = H.ok, H.eq
local world = require("world")

local MENU = "World /Game/Maps/NewMainMenu.NewMainMenu"
local MATCH = "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap"

-- ---------------------------------------------------------------- short names
eq(world.short(MENU), "NewMainMenu", "short: menu")
eq(world.short(MATCH), "SmallMap", "short: match")
eq(world.short("World /Game/Maps/A b<c>.Odd$Name"), "OddName", "short: only word characters")
eq(world.short(""), "?", "short: empty")
eq(world.short(nil), "?", "short: nil")
eq(#world.short("World /Game/X." .. string.rep("a", 300)), 64, "short: at most 64 characters")

-- ---------------------------------------------------------------- the cache
do
    local W = world.new()
    local e, fresh = W:onLoadMap(MENU, true, true)
    ok(e and fresh, "menu: a new entry")
    eq(e.host, false, "menu (server, standalone): not host")
    eq(e.map, "NewMainMenu", "menu: map")
    eq(W:isHost(MENU), false, "isHost(menu) false")
    local _, again = W:onLoadMap(MENU, true, true)
    eq(again, false, "the same world with the same answer: not fresh (one WORLD line)")
    e, fresh = W:onLoadMap(MATCH, true, false)
    ok(fresh and e.host == true, "hosted match: host")
    eq(W:isHost(MATCH), true, "isHost(match) true")
    eq(W:isHost(MENU), false, "menu still not host")
    _, fresh = W:onLoadMap(MENU, true, true)
    eq(fresh, true, "back to the menu: a new world, logged again")
    e = W:onLoadMap(MATCH, false, false)
    eq(e.host, false, "client of a match: not host")
    eq(W:isHost(MATCH), false, "the newer evaluation of a world replaces the older")
    eq(W:isHost("World /Game/Maps/Unknown.Unknown"), false, "an unknown world: not host")
    eq(W:isHost(nil), false, "isHost(nil): false")
    eq(W:isHost(42), false, "isHost(number): false")
end
do -- failed calls: host is false
    local W = world.new()
    local e = W:onLoadMap(MATCH, nil, false)
    ok(e.host == false and e.server == nil, "IsServer failed: host false")
    e = W:onLoadMap(MATCH, true, nil)
    ok(e.host == false and e.standalone == nil, "IsStandalone failed: host false")
    e = W:onLoadMap(MATCH, "yes", 0)
    ok(e.host == false and e.server == nil and e.standalone == nil, "non-boolean answers are not answers")
    local n = W:onLoadMap("", true, false)
    eq(n, nil, "an empty name is refused")
    n = W:onLoadMap(nil, true, false)
    eq(n, nil, "a nil name is refused")
end
do -- bounded
    local W = world.new()
    for i = 1, world.MAX_WORLDS + 5 do W:onLoadMap("World /Game/Maps/M" .. i .. ".M" .. i, true, false) end
    local n = 0
    for _ in pairs(W.worlds) do n = n + 1 end
    eq(n, world.MAX_WORLDS, "the cache keeps at most MAX_WORLDS worlds")
    eq(W:isHost("World /Game/Maps/M1.M1"), false, "the oldest world was dropped")
    eq(W:isHost("World /Game/Maps/M" .. (world.MAX_WORLDS + 5) .. ".M" .. (world.MAX_WORLDS + 5)), true, "the newest is kept")
    local long = "World /Game/Maps/" .. string.rep("x", 2000)
    W:onLoadMap(long, true, false)
    eq(#W:entry(long).name, world.MAX_NAME, "a long name is cut")
    eq(W:isHost(long), true, "and still found by its full name")
end

-- ---------------------------------------------------------------- the game adapter
do
    local FW = F.new()
    F.install(FW)
    local name, server, standalone, problem = world.read(FW.menu)
    ok(name == MENU and server == true and standalone == true and problem == nil, "read(menu)", tostring(problem))
    name, server, standalone, problem = world.read(FW.match)
    ok(name == MATCH and server == true and standalone == false and problem == nil, "read(hosted match)")
    local client = FW.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "client")
    _, server, standalone = world.read(client)
    ok(server == false and standalone == false, "read(client)")
    FW.serverFails = true
    name, server, standalone, problem = world.read(FW.match)
    ok(name == MATCH and server == nil and standalone == nil and tostring(problem):find("IsServer failed", 1, true), "IsServer throws: nil and a problem", tostring(problem))
    FW.serverFails = false; FW.standaloneFails = true
    name, server, standalone, problem = world.read(FW.match)
    ok(server == true and standalone == nil and tostring(problem):find("IsStandalone failed", 1, true), "IsStandalone throws: nil and a problem")
    FW.standaloneFails = false
    FW.match._badName = true
    name, _, _, problem = world.read(FW.match)
    ok(name == nil and problem, "a world without a name: nil and a problem")
    FW.match._badName = false
    FW.byPath["/Script/Engine.Default__KismetSystemLibrary"] = nil
    name, server, _, problem = world.read(FW.match)
    ok(name == MATCH and server == nil and problem, "no KSL: a problem, no answer")
    FW.byPath["/Script/Engine.Default__KismetSystemLibrary"] = FW.ksl

    eq(world.unwrap(FW.param(FW.menu)), FW.menu, "unwrap: the RemoteUnrealParam's world")
    eq(world.unwrap(FW.menu), FW.menu, "unwrap: a plain world stays")
    eq(world.unwrap(nil), nil, "unwrap(nil)")

    eq(world.currentWorld(), FW.menu, "currentWorld: the player controller's world")
    FW.pc._garbage = true
    eq(world.currentWorld(), nil, "currentWorld: a garbage controller (UE IsValid false) gives nothing")
    FW.pc._garbage = nil
    FindFirstOf = function() return nil end
    eq(world.currentWorld(), nil, "currentWorld: no controller")
    FindFirstOf = function() error("boom") end
    eq(world.currentWorld(), nil, "currentWorld: FindFirstOf throws")
    eq(world.alive(nil), false, "alive(nil)")
    -- The IsValid UFunction and KSL's CDO are looked up once, then cached until forget() or a failed call.
    world.forget()
    local finds, real = 0, StaticFindObject
    StaticFindObject = function(p) finds = finds + 1 return real(p) end
    local obj = FW.match
    for _ = 1, 5 do world.alive(obj) end
    eq(finds, 2, "alive: two lookups for five calls (cached)")
    eq(world.alive(obj), true, "alive: a live object")
    obj._garbage = true
    eq(world.alive(obj), false, "alive: the cached UFunction still sees the garbage flag")
    obj._garbage = nil
    world.forget()
    world.alive(obj)
    eq(finds, 4, "alive: forget() looks them up again")
    local fn = FW.byPath["/Script/Engine.KismetSystemLibrary:IsValid"]
    FW.byPath["/Script/Engine.KismetSystemLibrary:IsValid"] = nil
    world.forget()
    eq(world.alive(obj), false, "alive: no IsValid UFunction -> false")
    FW.byPath["/Script/Engine.KismetSystemLibrary:IsValid"] = fn
    eq(world.alive(obj), true, "alive: found again after a failed lookup")
    StaticFindObject = real
end

H.done()
