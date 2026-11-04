-- Unit tests for Scripts/hits.lua, the game adapter, against fake hooks and fake game objects: the story 3 matrix
-- rows that need the adapter (default writes nothing, scaled, Apex, per-enemy, zero, frostbite and environmental
-- damage untouched, before start, non-host, clash back-off and its reset, flip with the restore only if still
-- temporary, the next-tick fallback, remote victims, bad knobs) plus the depth counter, attribution, faults and the
-- per-world Blueprint hooks. The natives are simulated the way the game runs them: pre-hook, the nested
-- CallDamageEvent (its pre-hook, Health - amount, its post-hook), post-hook.
-- Run from the repo root:  texlua test/unit/hits_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("hits_test")
local ok, eq = H.ok, H.eq
local hits = require("hits")

local FPC = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
local GSC = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C"
local N = hits.NATIVES
local MATCH = "World /Game/Maps/SmallLoweIsland/SmallMap.SmallMap"

-- ---------------------------------------------------------------- fake game objects
local W, T -- the fake UE4SS and the test state
local Actor = {}
-- Story 4's properties: kept in a._f, every write counted in a._w[key] (a._ro[key]: the write fails).
local PROPS = { Temperature = true, CanTakeTemperature = true, InsideEnoughToStopFreezing = true, Infected = true,
                ["IsMimic?"] = true, TimesUsedReinforcements = true, ["Classified Minium"] = true,
                ["Disable Reinforcement"] = true, GameMode = true }
local function actor(class, path, fields)
    local a = { _class = class, _path = path, _hp = fields and fields.hp, _loc = fields and fields.loc or { X = 0, Y = 0, Z = 0 }, writes = 0,
                _f = {}, _w = {}, _ro = {} }
    for k, v in pairs(fields or {}) do
        if PROPS[k] then a._f[k] = v elseif k ~= "hp" and k ~= "loc" then a[k] = v end
    end
    W.byPath[path] = a
    return setmetatable(a, Actor)
end
Actor.__index = function(a, k)
    if k == "Health" then return rawget(a, "_hp") end
    if PROPS[k] then return rawget(a, "_f")[k] end
    return Actor[k]
end
Actor.__newindex = function(a, k, v)
    if k == "Health" then
        rawset(a, "writes", rawget(a, "writes") + 1)
        if rawget(a, "_readonly") then error("Health is read-only here") end
        rawset(a, "_hp", v)
        return
    end
    if PROPS[k] then
        local w = rawget(a, "_w")
        w[k] = (w[k] or 0) + 1
        if rawget(a, "_ro")[k] then error(k .. " is read-only here") end
        rawget(a, "_f")[k] = v
        return
    end
    if k == "Diffculty" then rawset(a, "dwrites", (rawget(a, "dwrites") or 0) + 1) end
    rawset(a, k, v)
end
function Actor:IsValid() return not rawget(self, "_gone") end
function Actor:GetFullName() return self._class .. " " .. self._path end
function Actor:GetClass() local c = self._class return { GetFName = function() return { ToString = function() return c end } end } end
function Actor:K2_GetActorLocation() return self._loc end
function Actor:GetBatPhase() return self._phase end

local function setup(opts)
    opts = opts or {}
    W = F.new()
    F.install(W)
    T = { lines = {}, host = opts.host ~= false, world = MATCH, knobs = opts.knobs, now = 100, rolls = opts.rolls }
    -- Characters and enemies.
    local warm = { CanTakeTemperature = true, InsideEnoughToStopFreezing = false, Infected = false, ["IsMimic?"] = false }
    local function pc(n) local f = { hp = 100, Temperature = 0 } for k, v in pairs(warm) do f[k] = v end return f end
    T.me = actor("BP_FirstPersonCharacter_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_1", pc())
    T.other = actor("BP_FirstPersonCharacter_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_2", pc())
    T.meek = actor("SCP_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.SCP_AI_C_1")
    T.stalker = actor("Stalker_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.Stalker_AI_C_1", { loc = { X = 200, Y = 0, Z = 0 } })
    T.apex = actor("ApexPredatorAI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.ApexPredatorAI_C_1")
    T.gs = actor("BP_FirstPersonGameState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonGameState_C_1", { Diffculty = opts.diff or 1,
        TimesUsedReinforcements = 0, ["Classified Minium"] = opts.cm or 2, ["Disable Reinforcement"] = opts.disabled == true, GameMode = opts.gamemode or 0 })
    T.radio = actor("BP_Radio_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_Radio_C_1")
    T.locked = {} -- attacker path -> victim
    local ctx = actor("NNEnemyAttackContext", "/Script/NuclearNightmare.Default__NNEnemyAttackContext")
    rawset(ctx, "GetLockedVictim", function(_, a) return T.locked[a._path] end)
    rawset(ctx, "GetStalkerPresentationSource", function(_, v) return T.presenting end)
    T.ctx = ctx
    local gsl = actor("GameplayStatics", "/Script/Engine.Default__GameplayStatics")
    rawset(gsl, "GetGameState", function() return T.gs end)
    rawset(gsl, "GetPlayerController", function() return { K2_GetPawn = function() return T.me end } end)
    local dog = actor("NNInfectedDogSupport", "/Script/NuclearNightmare.Default__NNInfectedDogSupport")
    rawset(dog, "IsAttackActive", function(_, d) return d._active == true end)
    rawset(dog, "GetAttackVictim", function(_, d) return d._victim end)
    W.all = { SCP_AI_C = { T.meek }, Stalker_AI_C = { T.stalker }, BP_FirstPersonGameState_C = { T.gs }, BP_FirstPersonCharacter_C = { T.me, T.other } }
    T.H = hits.new{
        say = function(level, fmt, ...) T.lines[#T.lines + 1] = (level == "info" and "" or level:upper() .. " ") .. string.format(fmt, ...) end,
        warnOnce = function(key, fmt, ...)
            T.once = T.once or {}
            if T.once[key] then return end
            T.once[key] = true
            T.lines[#T.lines + 1] = "WARN " .. string.format(fmt, ...)
        end,
        isHost = function() return T.host end,
        world = function() return T.world end,
        knobs = function() return T.knobs end,
        alive = function(o) return o ~= nil and not rawget(o, "_garbage") end,
        clock = function() return T.now end,
        rng = function() return 0.5 end,
        seed = function(n) T.seeded = (T.seeded or 0) + 1 end,
    }
    local okI, why = T.H:install()
    ok(okI, "install: the natives hook", why)
    -- The host poll: its loop is taken out of W.later (so runLater runs only the grab fallbacks); T.poll() is one tick.
    local okP = T.H:startPoll()
    ok(okP and #W.later == 1 and W.later[1].loop and W.later[1].ms == 250, "startPoll: one 250 ms game-thread loop")
    T.poll = table.remove(W.later, 1).fn
    ok(T.H:startPoll() and #W.later == 0, "startPoll: a second call adds no loop")
    T.H:onWorld(MATCH, T.host, true)
    if opts.start ~= false then W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs)) end
end
local function count(pat) local n = 0 for _, l in ipairs(T.lines) do if l:find(pat) then n = n + 1 end end return n end
local function line(pat) for _, l in ipairs(T.lines) do if l:find(pat) then return l end end return nil end
local function dump() return table.concat(T.lines, " | ") end

-- The natives, as the game runs them.
-- noSubtract: the native runs its hooks but applies nothing.
local function cde(victim, amount, inner, noSubtract)
    W.fire(N.cde, W.p(victim), W.p(amount))
    if inner then inner() end
    if not noSubtract then victim._hp = victim._hp - amount end
    W.firePost(N.cde, W.p(victim), W.p(amount))
end
local function lockedHit(attacker, amount, opts)
    opts = opts or {}
    W.fire(N.locked, W.p(T.ctx), W.p(attacker), W.p(amount))
    local v = T.locked[attacker._path]
    if not opts.noDelivery then cde(v, amount, opts.inner, opts.noSubtract) end
    W.firePost(N.locked, W.p(T.ctx), W.p(attacker), W.p(amount))
end
local function stalkerHit(victim, amount)
    W.fire(N.stalker, W.p(T.ctx), W.p(victim), W.p(amount))
    cde(victim, amount)
    W.firePost(N.stalker, W.p(T.ctx), W.p(victim), W.p(amount))
end
local function bossHit(boss, victim, amount, noSubtract)
    W.fire(N.boss, W.p(T.ctx), W.p(boss), W.p(victim))
    cde(victim, amount, nil, noSubtract)
    W.firePost(N.boss, W.p(T.ctx), W.p(boss), W.p(victim))
end
local HASPERK = FPC .. ":HasPerk"
local MEEK_ATTACK = "/Game/AI/SCP_AI.SCP_AI_C:Attack"
-- A Meek grab on victim: HasPerk(0x27) inside the body, the body's own test, then the multicast hook (after the body).
local function meekGrab(victim, opts)
    opts = opts or {}
    T.locked[T.meek._path] = victim
    W.fire(HASPERK, W.p(victim), W.p(39))
    local picked = (victim._hp - ({ [0] = 100, 50, 25, 17 })[T.gs.Diffculty] <= 0) and "e" or "s"
    if opts.between then opts.between() end
    if not opts.noMulticast then W.fire(MEEK_ATTACK, W.p(T.meek), W.p(0), W.p(victim)) end
    return picked
end

-- ---------------------------------------------------------------- default: every knob Default -> no write, no line
do
    setup{ knobs = nil }
    T.locked[T.meek._path] = T.me
    meekGrab(T.me)
    lockedHit(T.meek, 50)
    eq(T.me._hp, 50, "default: the game's 50")
    eq(T.me.writes, 0, "default: no Health write at all")
    eq(count("^HIT "), 0, "default: no HIT line")
    eq(count("^GRAB "), 0, "default: no GRAB line")
    eq(count("^MATCH start knobs=all Default$"), 1, "default: MATCH line says all Default")
    eq(count("WARN"), 0, "default: no WARN")
end

-- ---------------------------------------------------------------- scaled hit, the depth counter
do
    setup{ knobs = "enemyDamage=17" }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50)
    eq(T.me._hp, 83, "scaled: Hard, base 17, Meek 50 at 100 HP -> 83")
    eq(count("^HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=17 rolled=17 applied=17 hp=100 kind=hit$"), 1, "scaled: one HIT line", dump())
    eq(count("^HIT "), 1, "depth counter: the nested CallDamageEvent isn't scaled again")
    eq(count("WARN"), 0, "scaled: the guard is satisfied")
    eq(#T.H.st.apply + #T.H.st.cde, 0, "stacks empty after the hit")
    -- Apex through CommitLethalDamage.
    T.me._hp = 100
    bossHit(T.apex, T.me, 100)
    eq(T.me._hp, 66, "Apex: Hard, base 17, 100 -> 34")
    eq(count("^HIT enemy=apex via=CommitLethalDamage stock=100 scaled=34 rolled=34 applied=34 hp=100 kind=hit$"), 1, "Apex: HIT line", dump())
end

-- ---------------------------------------------------------------- per-enemy, zero
do
    setup{ knobs = "dmg.stalker=200", diff = 2 }
    T.presenting = T.stalker
    stalkerHit(T.me, 25)
    eq(T.me._hp, 50, "per-enemy: Normal, Stalker 200% -> 50")
    T.me._hp, T.me.writes = 100, 0
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 25)
    eq(T.me._hp, 75, "per-enemy: the Meek's 25 untouched")
    eq(T.me.writes, 0, "per-enemy: no write for the Meek (its knobs are Default)")
    eq(count("^HIT enemy=meek"), 0, "per-enemy: no HIT for the Meek")
    eq(count("^HIT enemy=stalker via=ApplyStalkerDamage stock=25 scaled=50 rolled=50 applied=50 hp=100 kind=hit$"), 1, "per-enemy: Stalker HIT", dump())

    setup{ knobs = "dmg.apex=0" }
    bossHit(T.apex, T.me, 100)
    eq(T.me._hp, 100, "zero: Apex 0% -> Health unchanged")
    eq(count("applied=0 hp=100"), 1, "zero: applied 0")
end

-- ---------------------------------------------------------------- frostbite, environmental, unattributed
do
    setup{ knobs = "enemyDamage=17;spread=20" }
    cde(T.me, 1)
    cde(T.me, 2)
    eq(T.me._hp, 97, "frostbite 1 and 2 with no context: untouched")
    cde(T.me, 30)
    eq(T.me._hp, 67, "a fall (no context, no bat or dog): untouched")
    eq(T.me.writes, 0, "frostbite and environmental damage: no write")
    eq(count("^HIT "), 0, "no HIT for them")
    -- An enemy context whose attacker class is unknown: base ratio only.
    local odd = actor("SomeNewEnemy_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.SomeNewEnemy_C_1")
    T.me._hp = 100
    T.locked[odd._path] = T.me
    lockedHit(odd, 50)
    ok(line("^HIT enemy=%? via=ApplyLockedDamage stock=50 scaled=17 "), "unattributed: base ratio, enemy=?", dump())
end

-- ---------------------------------------------------------------- Bat and Infected Dog rules
do
    setup{ knobs = "enemyDamage=50", diff = 0 }
    local bat = actor("BP_BatEnemy_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_BatEnemy_C_1", { loc = { X = 140, Y = 0, Z = 0 } })
    rawset(bat, "_phase", 3)
    W.all.BP_BatEnemy_C = { bat }
    cde(T.me, 100)
    eq(T.me._hp, 50, "bat within 3 m in phase 3: scaled (Nightmare, base 50)")
    ok(line("^HIT enemy=bat via=bat "), "bat: HIT line", dump())
    rawset(bat, "_phase", 2)
    T.me._hp = 100
    cde(T.me, 100)
    eq(T.me._hp, 0, "bat in phase 2: untouched")
    rawset(bat, "_phase", 3)
    bat._loc = { X = 400, Y = 0, Z = 0 }
    T.me._hp = 100
    cde(T.me, 100)
    eq(T.me._hp, 0, "bat 4 m away: untouched")
    local dog = actor("Dog_Infected_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.Dog_Infected_AI_C_1")
    rawset(dog, "_active", true) rawset(dog, "_victim", T.me)
    W.all.Dog_Infected_AI_C = { dog }
    T.me._hp = 100
    cde(T.me, 100)
    eq(T.me._hp, 50, "dog attacking this victim: scaled")
    ok(line("^HIT enemy=infectedDog via=dog "), "dog: HIT line", dump())
    rawset(dog, "_victim", T.other)
    T.me._hp = 100
    cde(T.me, 100)
    eq(T.me._hp, 0, "dog attacking someone else: untouched")
end

-- ---------------------------------------------------------------- Blueprint-wrapper enemies stay stock (v1)
do
    setup{ knobs = "enemyDamage=50;dmg.worm=50;dmg.leech=300", diff = 0 }
    eq(W.count(FPC .. ":ExplosionDamage") + W.count("/Game/Horror_worm/Mesh/BabyWorm_AI.BabyWorm_AI_C:AttackAll")
        + W.count(FPC .. ":AttackPInfectedAll"), 0, "no wrapper hooks registered")
    local leech = actor("BabyWorm_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BabyWorm_AI_C_1", { loc = { X = 50, Y = 0, Z = 0 } })
    W.all.BabyWorm_AI_C = { leech }
    cde(T.me, 25)
    eq(T.me._hp, 75, "Leech hit (no context): stock")
    cde(T.me, 30)
    eq(T.me._hp, 45, "a later fall: stock")
    eq(T.me.writes, 0, "wrapper enemies: no Health write")
end

-- ---------------------------------------------------------------- before start, non-host, other world
do
    setup{ knobs = "enemyDamage=17", start = false }
    T.locked[T.meek._path] = T.me
    meekGrab(T.me)
    lockedHit(T.meek, 50)
    ok(T.me._hp == 50 and T.me.writes == 0 and count("^HIT ") == 0 and count("^GRAB ") == 0, "before start: untouched", dump())
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    T.me._hp = 100
    lockedHit(T.meek, 50)
    eq(T.me._hp, 83, "after UpdateFriendlyFire: scaled")

    setup{ knobs = "enemyDamage=17", host = false }
    T.locked[T.meek._path] = T.me
    meekGrab(T.me)
    lockedHit(T.meek, 50)
    ok(T.me._hp == 50 and T.me.writes == 0 and count("^HIT ") == 0 and count("^MATCH") == 0, "client: no hook acts", dump())
    eq(W.count(HASPERK), 0, "client world: no Blueprint hooks registered")

    setup{ knobs = "enemyDamage=17" }
    T.world = "World /Game/Maps/NewMainMenu.NewMainMenu" -- the current world isn't the match's
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50)
    eq(T.me._hp, 50, "another world than the match's: untouched")
    -- A fresh world resets the match state.
    T.world = MATCH
    T.H:onWorld(MATCH, true, true)
    T.me._hp = 100
    lockedHit(T.meek, 50)
    eq(T.me._hp, 50, "a fresh world: not started until UpdateFriendlyFire")
end

-- ---------------------------------------------------------------- the grab flip, restore, fallback
do
    setup{ knobs = "enemyDamage=25", diff = 0 }
    local seen = 0
    local picked = meekGrab(T.me, { between = function() seen = T.me._hp end })
    eq(seen, 101, "flip: the temporary Health in the body (standard + 1)")
    eq(picked, "s", "flip: the game's test picks survivable")
    eq(T.me._hp, 100, "flip: restored in the multicast hook")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101$"), 1, "flip: GRAB line", dump())
    eq(count("^RESTORE enemy=meek hp=101 %-> 100 via=multicast$"), 1, "flip: RESTORE line", dump())
    eq(W.runLater(), 1, "flip: the fallback was scheduled")
    eq(count("^RESTORE "), 1, "flip: the fallback finds nothing to do")
    lockedHit(T.meek, 100)
    eq(T.me._hp, 75, "flip: survivable hit 25, about 75 HP")
    eq(count("kind=survivable$"), 1, "flip: the hit is the survivable grab's")
    -- The same grab registered twice (a hook left over): one decision, no double flip.
    T.me._hp = 100
    T.H.st.grabs = {}
    W.hooks[HASPERK][2] = W.hooks[HASPERK][1]
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "two HasPerk callbacks: still the temporary value")
    eq(count("^GRAB "), 2, "two HasPerk callbacks: one more GRAB line only")
    W.fire(MEEK_ATTACK, W.p(T.meek), W.p(0), W.p(T.me))
    eq(T.me._hp, 100, "two HasPerk callbacks: restored")
    table.remove(W.hooks[HASPERK], 2)
    -- Another perk: nothing.
    W.fire(HASPERK, W.p(T.me), W.p(12))
    eq(count("^GRAB "), 2, "HasPerk(other perk): nothing")
end
do -- next-tick fallback: the multicast hook never comes
    setup{ knobs = "enemyDamage=25", diff = 0 }
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 101, "no multicast: still the temporary value")
    W.runLater()
    eq(T.me._hp, 100, "next tick: restored")
    eq(count("^RESTORE enemy=meek hp=101 %-> 100 via=next tick$"), 1, "next tick: RESTORE line", dump())
end
do -- restore only if Health still holds the temporary value
    setup{ knobs = "enemyDamage=25", diff = 0 }
    meekGrab(T.me, { between = function() T.me._hp = 60 end })
    eq(T.me._hp, 60, "changed meanwhile: left as it is")
    eq(count("^WARN clash: at the grab's restore %(enemy=meek%) Health is 60, not the temporary 101; left as it is; every knob off until the next match$"), 1, "changed meanwhile: one WARN", dump())
    T.me._hp = 100
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 100)
    eq(T.me._hp, 0, "backed off: stock hits")
    W.runLater()
    eq(count("^WARN "), 1, "backed off: still one WARN")
end
do -- remote victim: the game's decision; the execution floor still applies
    setup{ knobs = "enemyDamage=25", diff = 0 }
    local picked = meekGrab(T.other)
    eq(picked, "e", "remote: the game's execution")
    eq(T.other.writes, 0, "remote: no temporary Health")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none$"), 1, "remote: GRAB line", dump())
    lockedHit(T.meek, 100)
    ok(T.other._hp <= 0, "remote execution: applied at least Health (dies)", T.other._hp)
    eq(count("kind=execution$"), 1, "remote: kind=execution")
    -- A later hit after the grab window: a plain hit.
    T.other._hp = 100
    T.now = T.now + 30
    lockedHit(T.meek, 100)
    eq(T.other._hp, 75, "after the grab window: a plain scaled hit")
end
do -- the survivable cap through the adapter: 26 HP, Spread 50 (the roll at mean + 2 sigma = 50)
    setup{ knobs = "enemyDamage=25;spread=50", diff = 0 }
    T.H.rng = (function() local i = 0 return function() i = i + 1 return i % 2 == 1 and 0.9999999 or 0 end end)()
    T.me._hp = 26
    meekGrab(T.me)
    lockedHit(T.meek, 100)
    eq(T.me._hp, 1, "survivable cap: a 50 roll at 26 HP leaves 1")
end
do -- the Stalker's grab: HasPerk on the victim, no AI locked; restored in PlayDamageEvent
    setup{ knobs = "dmg.stalker=50", diff = 0 }
    T.locked = {}
    T.me._hp = 80
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "Stalker grab: the nearest Stalker names the row (E 50 < 80: survivable)")
    W.fire(FPC .. ":PlayDamageEvent", W.p(T.me), W.p(T.stalker), W.p(false))
    eq(T.me._hp, 80, "Stalker grab: restored in PlayDamageEvent")
    ok(line("^GRAB enemy=stalker hp=80 E=50 game=e decision=s flip=101$"), "Stalker grab: GRAB line", dump())
end

-- ---------------------------------------------------------------- clash back-off and its reset
do
    setup{ knobs = "enemyDamage=17" }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50, { inner = function() T.me._hp = T.me._hp + 5 end })
    eq(T.me._hp, 88, "clash: another mod's +5 stays")
    eq(count("^WARN clash: after the hit enemy=meek via=ApplyLockedDamage Health is 88, planned 83 %(another mod changed it%); every knob off until the next match$"), 1, "clash: one WARN", dump())
    T.me._hp = 100
    lockedHit(T.meek, 50, { inner = function() T.me._hp = T.me._hp + 5 end })
    eq(T.me._hp, 55, "clash: then stock hits")
    eq(count("^HIT "), 1, "clash: no HIT after the WARN")
    eq(count("^WARN "), 1, "clash: one WARN only")
    -- A repeated UpdateFriendlyFire in the same world (a client can call the RPC): the back-off stays.
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    T.me._hp = 100
    lockedHit(T.meek, 50)
    eq(T.me._hp, 50, "repeated UpdateFriendlyFire: still backed off")
    eq(count("^MATCH start"), 1, "repeated UpdateFriendlyFire: no second match start")
    eq(T.seeded, 1, "repeated UpdateFriendlyFire: not reseeded")
    -- The next match (a fresh world): acts again.
    T.H:onWorld(MATCH, true, true)
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    T.me._hp = 100
    lockedHit(T.meek, 50)
    eq(T.me._hp, 83, "next match: the back-off is reset")
    eq(T.seeded, 2, "seeded once per match")
end
do -- the native applied nothing: the compensation is undone, no clash
    setup{ knobs = "enemyDamage=17" }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50, { noDelivery = true })
    eq(T.me._hp, 100, "no CallDamageEvent inside: compensation undone")
    eq(count("^WARN "), 0, "no CallDamageEvent inside: no clash")
    -- CallDamageEvent ran but subtracted nothing (Health still the compensated value).
    lockedHit(T.meek, 50, { noSubtract = true })
    eq(T.me._hp, 100, "Locked, native applied nothing: Health back to before")
    bossHit(T.apex, T.me, 100, true)
    eq(T.me._hp, 100, "boss, native applied nothing: Health back to before")
    eq(count("^WARN clash"), 0, "native applied nothing: no clash")
    eq(T.H.st.backedOff, false, "native applied nothing: not backed off")
    lockedHit(T.meek, 50)
    eq(T.me._hp, 83, "native applied nothing: the next hit still scaled")
end
do -- a hit while the victim still holds a grab's temporary Health: restored first, planned from the real Health
    setup{ knobs = "enemyDamage=25", diff = 0 }
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 101, "pending: temporary value")
    lockedHit(T.meek, 100)
    eq(T.me._hp, 75, "hit while pending: planned from 100")
    eq(count("^RESTORE enemy=meek hp=101 %-> 100 via=hit$"), 1, "hit while pending: restored by the hit", dump())
    W.runLater()
    eq(count("^WARN"), 0, "hit while pending: no false clash")
end
do -- the natives couldn't be hooked: nothing acts, no flip
    setup{ knobs = "enemyDamage=25", diff = 0 }
    T.H.installFailed = true
    meekGrab(T.me)
    eq(T.me.writes, 0, "install failed: no flip")
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 100)
    eq(T.me._hp, 0, "install failed: stock hit")
    eq(count("^GRAB ") + count("^HIT "), 0, "install failed: no GRAB or HIT")
    -- install() failing for real sets it.
    W = F.new() F.install(W)
    W.missing[N.cde] = true
    local h2 = hits.new{ say = function() end, warnOnce = function() end, isHost = function() return true end,
        world = function() return MATCH end, knobs = function() return "" end, alive = function() return true end }
    eq(h2:install(), false, "install: a missing native fails")
    eq(h2.installFailed, true, "install: failure recorded")
end
do -- the grab's Stalker from the nearest-Stalker fallback, the hit's from the presentation source: same row, still the grab's
    setup{ knobs = "enemyDamage=25;spread=50", diff = 0 }
    T.locked = {}
    T.me._hp = 30
    W.fire(HASPERK, W.p(T.me), W.p(39)) -- nearest Stalker (T.stalker)
    W.fire(FPC .. ":PlayDamageEvent", W.p(T.me), W.p(T.stalker), W.p(false))
    T.presenting = actor("Stalker_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.Stalker_AI_C_2")
    T.H.rng = (function() local i = 0 return function() i = i + 1 return i % 2 == 1 and 0.9999999 or 0 end end)()
    stalkerHit(T.me, 100)
    eq(T.me._hp, 1, "same row, another path: survivable cap applies")
    eq(count("kind=survivable$"), 1, "same row, another path: kind=survivable")
end

-- ---------------------------------------------------------------- bad knobs, faults, Diffculty
do
    setup{ knobs = "enemyDamage=999;bogus=1;spread=10" }
    eq(count("^WARN knobs: enemyDamage=999 is outside 0..200; enemyDamage Default$"), 1, "bad knobs: one WARN for the range", dump())
    eq(count("^WARN knobs: unknown knob 'bogus'; ignored$"), 1, "bad knobs: one WARN for the unknown key")
    eq(count("^MATCH start knobs=spread=10$"), 1, "bad knobs: the good one kept")
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    eq(count("^WARN knobs:"), 2, "bad knobs: not repeated next match")
end
do -- a failing hook body: one ERROR, back off, a pending temporary Health is still restored
    setup{ knobs = "enemyDamage=25", diff = 0 }
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 101, "fault: temporary value set")
    local real = T.ctx.GetLockedVictim
    rawset(T.ctx, "GetLockedVictim", nil)
    T.H.plan = function() error("boom") end
    W.fire(N.locked, W.p(T.ctx), W.p(T.meek), W.p(100))
    W.firePost(N.locked, W.p(T.ctx), W.p(T.meek), W.p(100))
    rawset(T.ctx, "GetLockedVictim", real)
    eq(count("^ERROR ApplyLockedDamage hook failed: .*boom; every knob off until the next match$"), 1, "fault: one ERROR", dump())
    W.runLater()
    eq(T.me._hp, 100, "fault: the temporary Health is still restored")
    T.H.plan = nil
    lockedHit(T.meek, 50)
    eq(count("^HIT "), 0, "fault: backed off for the match")
end
do -- Diffculty outside 0..3: stock, one WARN
    setup{ knobs = "enemyDamage=17", diff = 9 }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50)
    lockedHit(T.meek, 20)
    eq(T.me._hp, 30, "Diffculty 9: stock")
    eq(count("^WARN GameState.Diffculty reads 9"), 1, "Diffculty 9: one WARN")
    -- Diffculty is read live at each hit.
    rawset(T.gs, "Diffculty", 1)
    T.me._hp = 100
    lockedHit(T.meek, 50)
    eq(T.me._hp, 83, "Diffculty read live: now Hard")
    eq(rawget(T.gs, "dwrites"), nil, "Diffculty is never written")
end

-- ---------------------------------------------------------------- Blueprint hooks per world
do
    setup{ knobs = "enemyDamage=17", start = false }
    eq(W.count(HASPERK), 1, "host world: HasPerk registered once")
    eq(W.count(GSC .. ":UpdateFriendlyFire"), 1, "host world: UpdateFriendlyFire registered")
    eq(W.count(MEEK_ATTACK), 1, "host world: a loaded grab class's multicast registered")
    T.H:onWorld(MATCH, true, false)
    eq(W.count(HASPERK), 1, "the same world again: unregistered and registered again (still once)")
    T.H:onWorld("World /Game/Maps/NewMainMenu.NewMainMenu", false, true)
    eq(W.count(HASPERK), 0, "a menu world: the Blueprint hooks are gone")
    eq(W.count(N.cde), 1, "the natives stay")
    -- A class that isn't loaded stays pending until an attacker of it is seen.
    W.missing[MEEK_ATTACK] = true
    T.world = MATCH
    T.H:onWorld(MATCH, true, true)
    eq(W.count(MEEK_ATTACK), 0, "unloaded class: not registered")
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    W.missing[MEEK_ATTACK] = nil
    T.locked[T.meek._path] = T.me
    W.fire(HASPERK, W.p(T.me), W.p(39))
    W.runLater()
    eq(W.count(MEEK_ATTACK), 1, "an attacker of the class was seen: registered on the next tick")
    -- Per class: two classes seen before the next tick are both queued.
    local mimicFn = "/Game/AI/Mimic_AI.Mimic_AI_C:AttackMulti"
    T.H:onWorld(MATCH, true, true)
    T.H.bpHooks[MEEK_ATTACK], T.H.bpHooks[mimicFn] = nil, nil
    W.hooks[MEEK_ATTACK], W.hooks[mimicFn] = {}, {}
    T.H:needClassHooks("SCP_AI_C")
    T.H:needClassHooks("Mimic_AI_C")
    W.runLater()
    ok(W.count(MEEK_ATTACK) >= 1 and W.count(mimicFn) >= 1, "two classes queued: both registered")
    -- A class loaded after LoadMap but before the match start: hooked at UpdateFriendlyFire.
    W.missing[MEEK_ATTACK] = true
    T.H:onWorld(MATCH, true, true)
    eq(W.count(MEEK_ATTACK), 0, "loaded later: not at LoadMap")
    W.missing[MEEK_ATTACK] = nil
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    eq(W.count(MEEK_ATTACK), 1, "loaded by the match start: hooked at UpdateFriendlyFire")
end

-- ================================================================ story 4: cold, frostbite, tokens through the adapter
local RADIO = hits.RADIO
local function tw(a) return a._w.Temperature or 0 end
local function frozen(a) a._f.Temperature = 1 end
-- A radio server event on the host: the game's +1 in the body, then UE4SS's callback (after the body).
local function radio(ev, opts)
    opts = opts or {}
    if not opts.noCount then T.gs._f.TimesUsedReinforcements = T.gs._f.TimesUsedReinforcements + 1 end
    return W.fire(RADIO .. ":" .. ev, W.p(T.radio), W.p(T.me))
end

-- ---------------------------------------------------------------- cold
do -- cold Default: no poll work, no write
    setup{ knobs = "enemyDamage=17", diff = 0 }
    local finds = 0
    local real = FindAllOf
    FindAllOf = function(s) if s == "BP_FirstPersonCharacter_C" then finds = finds + 1 end return real(s) end
    T.me._f.Temperature = 0.1 T.poll()
    T.me._f.Temperature = 0.2 T.poll()
    FindAllOf = real
    eq(finds, 0, "cold default: the poll finds no characters")
    eq(tw(T.me), 0, "cold default: no Temperature write")
    eq(T.me._f.Temperature, 0.2, "cold default: the stock rise")
    eq(count("^COLD "), 0, "cold default: no COLD line")
end
do -- cold scaled: Nightmare, cold 50, rise 0.04 -> 0.01
    setup{ knobs = "cold=50", diff = 0 }
    T.me._f.Temperature, T.other._f.Temperature = 0.10, 0.60
    T.poll()
    eq(tw(T.me) + tw(T.other), 0, "cold: first poll writes nothing")
    T.me._f.Temperature, T.other._f.Temperature = 0.14, 0.55
    T.poll()
    ok(math.abs(T.me._f.Temperature - 0.11) < 1e-9, "cold scaled: rise 0.04 written as 0.01", T.me._f.Temperature)
    eq(T.other._f.Temperature, 0.55, "warming: untouched (stock rate)")
    eq(tw(T.other), 0, "warming: no write")
    -- The summary every 10 s.
    T.now = T.now + 11
    T.poll()
    local l = line("^COLD ")
    ok(l and l:find("^COLD raw=0%.0400 applied=0%.0100 factor=0%.25 polls=3 writes=1 players=2 avg_ms=%S+ clock=os$"), "cold: the COLD summary line", l)
    -- Diffculty is read live: on Normal the same knob is half Normal's rate.
    rawset(T.gs, "Diffculty", 2)
    T.me._f.Temperature = 0.21
    T.poll()
    ok(math.abs(T.me._f.Temperature - 0.16) < 1e-9, "cold: Diffculty read live (Normal, cold 50 -> factor 0.5)", T.me._f.Temperature)
    eq(rawget(T.gs, "dwrites"), nil, "cold: Diffculty never written")
end
do -- cold faster: Normal, cold 200, rise 0.01 -> 0.02, clamped at 1; core's clock when present
    setup{ knobs = "cold=200", diff = 2 }
    local us = 1000
    T.H.micros = function() us = us + 30 return us end
    T.me._f.Temperature = 0.50 T.poll()
    T.me._f.Temperature = 0.51 T.poll()
    ok(math.abs(T.me._f.Temperature - 0.52) < 1e-9, "cold faster: rise 0.02", T.me._f.Temperature)
    T.me._f.Temperature = 0.995 T.poll()
    T.me._f.Temperature = 1.0 T.poll()
    eq(T.me._f.Temperature, 1, "cold faster: clamped at 1")
    T.now = T.now + 11 T.poll()
    ok(line("^COLD .* avg_ms=0%.030 clock=core$"), "cold: the cost from core's clock", dump())
end
do -- cold zero: no rise outdoors
    setup{ knobs = "cold=0", diff = 0 }
    T.me._f.Temperature = 0.3 T.poll()
    for i = 1, 5 do T.me._f.Temperature = T.me._f.Temperature + 0.002 T.poll() end
    eq(T.me._f.Temperature, 0.3, "cold zero: Temperature stays at its start")
end
do -- the per-path state is reset per match; a character gone is forgotten
    setup{ knobs = "cold=50", diff = 0 }
    T.me._f.Temperature = 0.1 T.poll()
    ok(T.H.st.cold.last[T.me._path] == 0.1, "cold: the path is remembered")
    W.all.BP_FirstPersonCharacter_C = { T.other }
    T.poll()
    eq(T.H.st.cold.last[T.me._path], nil, "cold: a character not found is forgotten")
    W.all.BP_FirstPersonCharacter_C = { T.me, T.other }
    T.me._f.Temperature = 0.2 T.poll()
    eq(tw(T.me), 0, "cold: seen again is a first sight")
    -- A dead (garbage) character is skipped.
    rawset(T.me, "_garbage", true)
    T.me._f.Temperature = 0.3 T.poll()
    eq(tw(T.me), 0, "cold: a destroyed character (KSL IsValid false) is skipped")
    rawset(T.me, "_garbage", nil)
    T.poll()
    -- A fresh world and its match start: nothing carried over.
    T.H:onWorld(MATCH, true, true)
    eq(next(T.H.st.cold.last), nil, "cold: a fresh world has no per-path state")
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    T.me._f.Temperature = 0.9 T.poll()
    eq(tw(T.me), 0, "cold: a new match starts from a first sight")
end
do -- not host, before start, another world, backed off: nothing acts
    setup{ knobs = "cold=0", diff = 0, host = false }
    T.me._f.Temperature = 0.1 T.poll() T.me._f.Temperature = 0.2 T.poll()
    eq(tw(T.me), 0, "cold, client: no write")
    setup{ knobs = "cold=0", diff = 0, start = false }
    T.me._f.Temperature = 0.1 T.poll() T.me._f.Temperature = 0.2 T.poll()
    eq(tw(T.me), 0, "cold, before start: no write")
    setup{ knobs = "cold=0", diff = 0 }
    T.world = "World /Game/Maps/NewMainMenu.NewMainMenu"
    T.me._f.Temperature = 0.1 T.poll() T.me._f.Temperature = 0.2 T.poll()
    eq(tw(T.me), 0, "cold, another world: no write")
    setup{ knobs = "cold=0;enemyDamage=17", diff = 0 }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 100, { inner = function() T.me._hp = T.me._hp + 5 end }) -- a clash
    eq(count("^WARN clash: after the hit .*; every knob off until the next match$"), 1, "clash: the WARN says every knob", dump())
    T.me._f.Temperature = 0.1 T.poll() T.me._f.Temperature = 0.2 T.poll()
    eq(tw(T.me), 0, "cold, backed off: no write")
end
do -- a fault in the poll: one ERROR, every knob off
    setup{ knobs = "cold=0;enemyDamage=17", diff = 0 }
    T.me._f.Temperature = 0.1 T.poll()
    T.me._ro.Temperature = true
    T.me._f.Temperature = 0.2 T.poll()
    eq(count("^ERROR poll failed: .*could not write Temperature.*; every knob off until the next match$"), 1, "poll fault: one ERROR", dump())
    T.poll()
    eq(count("^ERROR "), 1, "poll fault: no second ERROR (the poll stops acting)")
    T.locked[T.meek._path] = T.me
    T.me._hp = 100
    lockedHit(T.meek, 100)
    eq(T.me._hp, 0, "poll fault: enemy damage backed off too")
end

-- ---------------------------------------------------------------- frostbite
do
    setup{ knobs = "frostbite=3" }
    frozen(T.me)
    cde(T.me, 1)
    eq(T.me._hp, 97, "frostbite: amount 1 at frostbite 3 -> 3")
    eq(count("^HIT enemy=frostbite via=frostbite stock=1 scaled=3 rolled=3 applied=3 hp=100 kind=hit$"), 1, "frostbite: HIT line", dump())
    cde(T.me, 2)
    eq(T.me._hp, 91, "perk tick: amount 2 -> 6")
    eq(count("WARN"), 0, "frostbite: the guard is satisfied")
    eq(#T.H.st.cde, 0, "frostbite: the stack is empty")
    -- Not frostbite: each gate.
    local function untouched(what, prep)
        T.me._hp, T.me.writes = 100, 0
        T.me._f.Temperature, T.me._f.CanTakeTemperature, T.me._f.InsideEnoughToStopFreezing, T.me._f.Infected, T.me._f["IsMimic?"] = 1, true, false, false, false
        prep()
        cde(T.me, 1)
        ok(T.me._hp == 99 and T.me.writes == 0, "not frostbite: " .. what, T.me._hp)
    end
    untouched("Temperature < 1", function() T.me._f.Temperature = 0.99 end)
    untouched("inside", function() T.me._f.InsideEnoughToStopFreezing = true end)
    untouched("in a vehicle (CanTakeTemperature false)", function() T.me._f.CanTakeTemperature = false end)
    untouched("infected", function() T.me._f.Infected = true end)
    untouched("the imposter", function() T.me._f["IsMimic?"] = true end)
    -- An enemy context: never frostbite (here the enemy knobs are Default, so the hit is stock).
    T.me._hp, T.me.writes = 100, 0
    frozen(T.me)
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "not frostbite: inside ApplyLockedDamage", T.me._hp)
    bossHit(T.apex, T.me, 1)
    ok(T.me._hp == 98 and T.me.writes == 0, "not frostbite: inside CommitLethalDamage", T.me._hp)
    eq(count("^HIT enemy=frostbite"), 2, "not frostbite: no other HIT line")
end
do -- frostbite zero: Health unchanged while frozen
    setup{ knobs = "frostbite=0" }
    frozen(T.me)
    for _ = 1, 5 do cde(T.me, 1) end
    eq(T.me._hp, 100, "frostbite zero: Health unchanged")
    eq(count("^HIT enemy=frostbite via=frostbite stock=1 scaled=0 rolled=0 applied=0 hp=100 kind=hit$"), 5, "frostbite zero: applied 0", dump())
end
do -- frostbite Default, before start, client, backed off: untouched
    setup{ knobs = "enemyDamage=17" }
    frozen(T.me) cde(T.me, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "frostbite Default: stock 1, no write")
    setup{ knobs = "frostbite=3", start = false }
    frozen(T.me) cde(T.me, 1)
    eq(T.me._hp, 99, "frostbite before start: stock")
    setup{ knobs = "frostbite=3", host = false }
    frozen(T.me) cde(T.me, 1)
    eq(T.me._hp, 99, "frostbite on a client: stock")
end
do -- frostbite through the guard: a clash backs off; a lowering floors at 0.01
    setup{ knobs = "frostbite=3" }
    frozen(T.me)
    cde(T.me, 1, function() T.me._hp = T.me._hp + 5 end)
    eq(count("^WARN clash: after the hit enemy=frostbite via=frostbite Health is 102, planned 97 %(another mod changed it%); every knob off until the next match$"), 1, "frostbite clash: one WARN", dump())
    T.me._hp = 100
    cde(T.me, 1)
    eq(T.me._hp, 99, "frostbite clash: then stock")
    setup{ knobs = "frostbite=20" }
    frozen(T.me)
    T.me._hp = 5
    cde(T.me, 1)
    ok(math.abs(T.me._hp + 0.99) < 1e-9, "frostbite 20 at 5 HP: Health 0.01 before the native's 1 (the tick kills)", T.me._hp)
    eq(count("WARN"), 0, "frostbite floor: the guard is satisfied")
end
do -- a grab's temporary Health in place: restored before the frostbite plan
    setup{ knobs = "frostbite=3;enemyDamage=25", diff = 0 }
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 101, "pending: temporary value")
    frozen(T.me)
    cde(T.me, 1)
    eq(T.me._hp, 97, "frostbite while pending: planned from 100")
    eq(count("WARN"), 0, "frostbite while pending: no false clash")
end

-- ---------------------------------------------------------------- tokens
do -- tokens more: Classified Minium 0 (limit 2), N 4
    setup{ knobs = "revives=4", cm = 0 }
    eq(T.gs._f.TimesUsedReinforcements, -2, "tokens more: count written -2 at the match start")
    eq(count("^TOKENS start limit=2 N=4 count=%-2$"), 1, "tokens more: TOKENS start", dump())
    for _, ev in ipairs(hits.RADIO_EVENTS) do eq(W.count(RADIO .. ":" .. ev), 1, "radio hook registered: " .. ev) end
    eq(radio("ReinforceSpecficPlayer"), 1, "tokens: the callback ran")
    radio("SpawnReinforcementMethod2")
    radio("SpawnReinforcmentSpectator")
    eq(T.gs._f["Disable Reinforcement"], false, "tokens more: not disabled after 3")
    eq(count("^TOKENS used="), 3, "tokens more: one used line each", dump())
    -- The 4th through a path with no callback (RPCReinforcementMethod2's multicast): the poll catches it.
    T.gs._f.TimesUsedReinforcements = T.gs._f.TimesUsedReinforcements + 1
    T.poll()
    eq(T.gs._f["Disable Reinforcement"], true, "tokens more: Disable after the 4th (poll)")
    eq(count("^TOKENS disabled at used=4 N=4 via=poll$"), 1, "tokens more: TOKENS disabled", dump())
    T.poll()
    eq(T.gs._w["Disable Reinforcement"], 1, "tokens: Disable written once")
    eq(tw(T.me), 0, "tokens only: the poll writes no Temperature")
end
do -- tokens fewer: limit 8, N 2
    setup{ knobs = "revives=2", cm = 3 }
    eq(T.gs._f.TimesUsedReinforcements, 6, "tokens fewer: count 6")
    radio("ReinforceSpecficPlayer")
    eq(T.gs._f["Disable Reinforcement"], false, "tokens fewer: not after 1")
    radio("ReinforceSpecficPlayer")
    eq(T.gs._f["Disable Reinforcement"], true, "tokens fewer: Disable after the 2nd")
    eq(count("^TOKENS disabled at used=2 N=2 via=ReinforceSpecficPlayer$"), 1, "tokens fewer: TOKENS disabled", dump())
end
do -- tokens zero, lobby disabled, imposter, Default
    setup{ knobs = "revives=0", cm = 1 }
    eq(T.gs._f["Disable Reinforcement"], true, "tokens zero: Disable at the match start")
    setup{ knobs = "revives=0", disabled = true }
    eq(next(T.gs._w), nil, "tokens, lobby already disabled: nothing written")
    eq(count("^TOKENS the lobby disabled reinforcements: untouched$"), 1, "tokens, lobby disabled: one line")
    setup{ knobs = "revives=4", gamemode = 1 }
    eq(next(T.gs._w), nil, "tokens, imposter: nothing written")
    radio("ReinforceSpecficPlayer") T.poll()
    eq(T.gs._w.TimesUsedReinforcements, nil, "tokens, imposter: still nothing after a reinforcement")
    setup{ knobs = "enemyDamage=17" }
    radio("ReinforceSpecficPlayer") T.poll()
    eq(next(T.gs._w), nil, "tokens Default: nothing written")
    eq(count("^TOKENS"), 0, "tokens Default: no TOKENS line")
end
do -- minimum changes mid-match
    setup{ knobs = "revives=2", cm = 3 }
    radio("ReinforceSpecficPlayer")
    T.gs._f["Classified Minium"] = 2
    T.poll()
    eq(T.gs._f.TimesUsedReinforcements, 5, "minimum changes: count re-written to keep N - used (6 - 2 + 1)")
    eq(count("^TOKENS minimum changed limit=8 %-> 6 used=1 count=5$"), 1, "minimum changes: one line", dump())
end
do -- not host, before start, backed off: nothing acts
    setup{ knobs = "revives=2", cm = 3, host = false }
    radio("ReinforceSpecficPlayer") T.poll()
    eq(next(T.gs._w), nil, "tokens, client: nothing written")
    eq(W.count(RADIO .. ":ReinforceSpecficPlayer"), 0, "tokens, client: no radio hook")
    setup{ knobs = "revives=2", cm = 3, start = false }
    radio("ReinforceSpecficPlayer") T.poll()
    eq(next(T.gs._w), nil, "tokens, before start: nothing written")
    setup{ knobs = "revives=2;enemyDamage=17", cm = 3 }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50, { inner = function() T.me._hp = T.me._hp + 5 end }) -- a clash
    radio("ReinforceSpecficPlayer") radio("ReinforceSpecficPlayer") T.poll()
    eq(T.gs._w["Disable Reinforcement"], nil, "tokens, backed off: Disable not written")
    eq(count("^TOKENS used="), 0, "tokens, backed off: no re-check")
end
do -- a failed token write: one ERROR, every knob off
    setup{ knobs = "revives=2;enemyDamage=17", cm = 3, start = false }
    T.gs._ro.TimesUsedReinforcements = true
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    eq(count("^ERROR UpdateFriendlyFire hook failed: .*could not write TimesUsedReinforcements.*; every knob off until the next match$"), 1, "token write fault: one ERROR", dump())
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50)
    eq(T.me._hp, 50, "token write fault: enemy damage backed off too")
end

-- ---------------------------------------------------------------- the source: rules from AGENTS.md
do
    local f = assert(io.open(ROOT .. "/Scripts/hits.lua", "r"))
    local src = f:read("a"):gsub("%-%-[^\r\n]*", "")
    f:close()
    ok(not src:find("ExecuteInGameThread%(") and not src:find("LoopAsync"), "hits.lua: no ExecuteInGameThread / LoopAsync")
    ok(not src:find("HasAuthority", 1, true), "hits.lua: never HasAuthority")
    ok(not src:find("Diffculty%s*=[^=]"), "hits.lua: never writes Diffculty")
end

H.done()
