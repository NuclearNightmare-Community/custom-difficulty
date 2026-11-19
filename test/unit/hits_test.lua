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
                ["Disable Reinforcement"] = true, GameMode = true, ClassifiedDynamicValue = true }
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
        TimesUsedReinforcements = 0, ["Classified Minium"] = opts.cm or 2, ["Disable Reinforcement"] = opts.disabled == true, GameMode = opts.gamemode or 0,
        ClassifiedDynamicValue = opts.classified or 0 })
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
    -- The players: the game state's PlayerArray of player states, each naming its pawn (PawnPrivate).
    T.ps = { actor("BP_NNPlayerState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PS_1", { PawnPrivate = T.me }),
             actor("BP_NNPlayerState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PS_2", { PawnPrivate = T.other }) }
    rawset(T.gs, "PlayerArray", { T.ps[1], T.ps[2] })
    rawset(T.me, "PlayerState", T.ps[1])
    rawset(T.other, "PlayerState", T.ps[2])
    -- story 5's recovery: the montage, PlayingMontage and the movement mode of each character
    for _, ch in ipairs({ T.me, T.other }) do
        rawset(ch, "montage", { IsValid = function() return true end })
        rawset(ch, "stops", 0)
        rawset(ch, "GetCurrentMontage", function(c) return rawget(c, "montage") end)
        rawset(ch, "StopAnimMontage", function(c) rawset(c, "stops", rawget(c, "stops") + 1) end)
        rawset(ch, "CharacterMovement", { SetMovementMode = function(m, mode) rawset(ch, "mode", mode) end })
        rawset(ch, "PlayingMontage", true)
    end
    -- story 5: core.net (a fake; nil without opts.net)
    T.net = opts.net
    -- core's weak handles: handle -> object; deref is nil once the object is gone.
    T.handles, T.freed = {}, 0
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
        ref = (not opts.noRef) and function(o) T.refs = (T.refs or 0) + 1 T.handles[T.refs] = o return T.refs end or nil,
        deref = (not opts.noRef) and function(h) local o = T.handles[h] if o and not rawget(o, "_gone") then return o end return nil end or nil,
        free = (not opts.noRef) and function(h) T.handles[h] = nil T.freed = T.freed + 1 end or nil,
        net = opts.net, modId = "nuclearnightmare-community.difficulty", version = opts.version or "0.1.0",
        netCompat = opts.netCompat, netMissing = opts.netMissing,
    }
    local okI, why = T.H:install()
    ok(okI, "install: the natives hook", why)
    -- The host poll: its loop is taken out of W.later (so runLater runs only the grab fallbacks); T.poll() is one tick.
    local okP = T.H:startPoll()
    ok(okP and #W.later == 1 and W.later[1].loop and W.later[1].ms == 250, "startPoll: one 250 ms game-thread loop")
    T.poll = table.remove(W.later, 1).fn
    ok(T.H:startPoll() and #W.later == 0, "startPoll: a second call adds no loop")
    for _, p in ipairs(opts.missing or {}) do W.missing[p] = true end
    T.H:onWorld(MATCH, T.host, true, opts.client == true)
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
-- CallFrostbiteDamageEvent, the same way. inner runs inside the native (a nested CallDamageEvent, another mod).
local function frostHit(victim, amount, inner, noSubtract)
    W.fire(N.frost, W.p(victim), W.p(amount))
    if inner then inner() end
    if not noSubtract then victim._hp = victim._hp - amount end
    W.firePost(N.frost, W.p(victim), W.p(amount))
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
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "flip: GRAB line", dump())
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
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=client spare=no%(core%)$"), 1, "remote: GRAB line", dump())
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
    ok(line("^GRAB enemy=stalker hp=80 E=50 game=e decision=s flip=101 victim=local spare=yes$"), "Stalker grab: GRAB line", dump())
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
do -- the poll's find: weak handles + PlayerArray; discovery on the first poll and every 8th, derefs between
    setup{ knobs = "cold=50;revives=4", diff = 0, cm = 3 }
    eq(T.refs, 1, "find: one weak handle on the game state at the match start")
    local finds, sfo, names, walks = 0, 0, 0, 0
    local realF, realS = FindAllOf, StaticFindObject
    FindAllOf = function(s) finds = finds + 1 return realF(s) end
    StaticFindObject = function(p) sfo = sfo + 1 return realS(p) end
    local realName = Actor.GetFullName
    Actor.GetFullName = function(a) names = names + 1 return realName(a) end
    local arr = T.gs.PlayerArray
    local function walked() walks = walks + 1 return arr end
    rawset(T.gs, "PlayerArray", setmetatable({}, { __len = function() walked() return #arr end, __index = function(_, i) return arr[i] end }))
    T.me._f.Temperature = 0.1 T.poll()           -- poll 1: discovery
    eq(T.refs, 3, "find: the first poll takes a handle per character")
    local walks1, names1 = walks, names
    T.me._f.Temperature = 0.14 T.poll()          -- poll 2: derefs only
    ok(math.abs(T.me._f.Temperature - 0.11) < 1e-9, "find: a character from its handle is scaled", T.me._f.Temperature)
    eq(walks, walks1, "find: no PlayerArray walk between discoveries")
    eq(names, names1, "find: no GetFullName between discoveries")
    for _ = 3, 8 do T.poll() end                 -- polls 3..8: derefs
    eq(walks, walks1, "find: still no walk through poll 8")
    T.poll()                                     -- poll 9: the next discovery
    eq(walks, walks1 + 1, "find: rediscovered on the 9th poll (every 8 polls)")
    eq(T.freed, 2, "find: the rediscovery freed the two old character handles")
    eq(finds, 0, "find: no FindAllOf at all")
    eq(sfo, 0, "find: no StaticFindObject at all (the fake alive; world.alive caches its own)")
    FindAllOf, StaticFindObject, Actor.GetFullName = realF, realS, realName
    -- A deref that returns nil drops that entry until the next discovery (its handle freed).
    local otherH
    for h, o in pairs(T.handles) do if o == T.other then otherH = h end end
    T.handles[otherH] = nil
    local freed = T.freed
    T.other._f.Temperature = 0.5 T.poll()
    T.other._f.Temperature = 0.6 T.poll()
    eq(T.other._f.Temperature, 0.6, "find: a nil deref is skipped")
    eq(T.freed, freed + 1, "find: the dropped entry's handle is freed")
    eq(#T.H.st.charRefs, 1, "find: the dropped entry is gone until the next discovery")
    -- A spectator (no pawn), a pawn of another class and one reachable only through GetPawn(): seen at a discovery.
    local odd = actor("BP_ThirdPersonCharacter_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.Monster_1", { Temperature = 0.1 })
    local viaGet = actor("BP_FirstPersonCharacter_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_3", { Temperature = 0.1 })
    local spect = actor("BP_NNPlayerState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PS_3", {})
    local psOdd = actor("BP_NNPlayerState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PS_4", { PawnPrivate = odd })
    local psGet = actor("BP_NNPlayerState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PS_5", {})
    rawset(psGet, "GetPawn", function() return viaGet end)
    rawset(T.gs, "PlayerArray", { T.ps[1], spect, psOdd, psGet })
    T.H.st.sinceDiscovery = hits.REDISCOVER_EVERY - 1 -- the next poll discovers
    T.poll()
    odd._f.Temperature, viaGet._f.Temperature = 0.2, 0.2
    T.poll()
    eq(odd._f.Temperature, 0.2, "find: a pawn of another class is skipped")
    ok(math.abs(viaGet._f.Temperature - 0.125) < 1e-9, "find: GetPawn() when PawnPrivate is empty", viaGet._f.Temperature)
    -- The game state gone (its handle derefs to nil): the tick does nothing.
    rawset(T.gs, "_gone", true)
    viaGet._f.Temperature = 0.3
    T.poll()
    eq(viaGet._f.Temperature, 0.3, "find: game state gone -> the tick is skipped")
    rawset(T.gs, "_gone", nil)
    -- A new match frees every handle (the game state's and the characters').
    local live = #T.H.st.charRefs
    freed = T.freed
    T.H:onWorld(MATCH, true, true)
    eq(T.freed, freed + 1 + live, "find: a fresh world frees the game state's and the characters' handles")
    local refs = T.refs
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    eq(T.refs, refs + 1, "find: the next match takes a new game-state handle")
    eq(T.H.st.charRefs, nil, "find: the next match discovers on its first poll")
end
do -- without core's handles: the old FindAllOf of the game states still finds it
    setup{ knobs = "cold=50", diff = 0, noRef = true }
    T.me._f.Temperature = 0.1 T.poll()
    T.me._f.Temperature = 0.14 T.poll()
    ok(math.abs(T.me._f.Temperature - 0.11) < 1e-9, "no handles: scaled through the fallback", T.me._f.Temperature)
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
    ok(line("^COLD .* avg_ms=0%.%d%d%d clock=core$"), "cold: the cost from core's clock", dump())
    ok(line("^DEBUG COLD timing discover_ms=0%.%d+ %(n=1%) deref_ms=0%.%d+ %(n=4%) read_ms=0%.%d+ write_ms=0%.%d+ reads=%d+$"), "cold: the DEBUG timing line per part", dump())
end
do -- cold zero: no rise outdoors
    setup{ knobs = "cold=0", diff = 0 }
    T.me._f.Temperature = 0.3 T.poll()
    for i = 1, 5 do T.me._f.Temperature = T.me._f.Temperature + 0.002 T.poll() end
    eq(T.me._f.Temperature, 0.3, "cold zero: Temperature stays at its start")
end
do -- the per-path state is reset per match; a character gone is forgotten (discovery every poll: no handles)
    setup{ knobs = "cold=50", diff = 0, noRef = true }
    T.me._f.Temperature = 0.1 T.poll()
    ok(T.H.st.cold.last[T.me._path] == 0.1, "cold: the path is remembered")
    rawset(T.gs, "PlayerArray", { T.ps[2] })
    T.poll()
    eq(T.H.st.cold.last[T.me._path], nil, "cold: a character not found is forgotten")
    rawset(T.gs, "PlayerArray", { T.ps[1], T.ps[2] })
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

-- ---------------------------------------------------------------- frostbite (V8.2: CallFrostbiteDamageEvent)
do
    setup{ knobs = "frostbite=3" }
    eq(W.count(N.frost), 1, "frostbite: the native is hooked")
    frostHit(T.me, 1)
    eq(T.me._hp, 97, "tick: amount 1 at frostbite 3 -> 3 (no temperature gate)")
    eq(count("^HIT enemy=frostbite via=frostbite stock=1 scaled=3 rolled=3 applied=3 hp=100 kind=hit$"), 1, "tick: one HIT line", dump())
    frostHit(T.me, 2)
    eq(T.me._hp, 91, "perk tick: amount 2 -> 6")
    eq(count("WARN"), 0, "tick: the guard is satisfied")
    eq(#T.H.st.frost, 0, "tick: the stack is empty")
    -- Other amounts stay stock.
    T.me._hp, T.me.writes = 100, 0
    frostHit(T.me, 7)
    ok(T.me._hp == 93 and T.me.writes == 0, "other amount: 7 at frostbite 3 untouched", T.me._hp)
    frostHit(T.me, 100)
    ok(T.me._hp == -7 and T.me.writes == 0, "finisher other: 100 at frostbite 3 untouched", T.me._hp)
    eq(count("^HIT "), 2, "other amounts: no HIT line")
end
do -- the old route: CallDamageEvent on a frozen player is no longer frostbite
    setup{ knobs = "frostbite=3" }
    frozen(T.me)
    cde(T.me, 1)
    cde(T.me, 2)
    ok(T.me._hp == 97 and T.me.writes == 0, "old route: 1 and 2 HP on a frozen player untouched", T.me._hp)
    eq(count("^HIT "), 0, "old route: no frostbite line")
    setup{ knobs = "frostbite=0" }
    frozen(T.me) T.me._hp = 0.5
    T.me.writes = 0
    cde(T.me, 100)
    ok(T.me._hp < 0 and T.me.writes == 0 and count("finisher") == 0, "old route: no finisher through CallDamageEvent", T.me._hp)
end
do -- a CallDamageEvent nested in the native: no second plan, no bat attribution, depth restored
    setup{ knobs = "frostbite=3;enemyDamage=50", diff = 0 }
    local bat = actor("BP_BatEnemy_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_BatEnemy_C_1", { loc = { X = 140, Y = 0, Z = 0 } })
    rawset(bat, "_phase", 3)
    W.all.BP_BatEnemy_C = { bat }
    frostHit(T.me, 1, function() W.fire(N.cde, W.p(T.me), W.p(1)) W.firePost(N.cde, W.p(T.me), W.p(1)) end)
    eq(T.me._hp, 97, "nested: compensated once")
    eq(count("^HIT "), 1, "nested: one plan only")
    eq(count("^HIT enemy=bat"), 0, "nested: no bat attribution")
    eq(#T.H.st.frost + #T.H.st.cde, 0, "nested: the stacks are balanced")
    T.me._hp = 100
    cde(T.me, 100)
    eq(T.me._hp, 50, "nested: the depth is restored, the next bat hit is scaled")
    -- Also while Frostbite is Default: the depth still rises.
    setup{ knobs = "enemyDamage=50", diff = 0 }
    bat = actor("BP_BatEnemy_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_BatEnemy_C_1", { loc = { X = 140, Y = 0, Z = 0 } })
    rawset(bat, "_phase", 3)
    W.all.BP_BatEnemy_C = { bat }
    frostHit(T.me, 100, function() W.fire(N.cde, W.p(T.me), W.p(100)) W.firePost(N.cde, W.p(T.me), W.p(100)) end)
    eq(count("^HIT enemy=bat"), 0, "nested, frostbite Default: no bat attribution")
end
do -- frostbite zero: Health unchanged
    setup{ knobs = "frostbite=0" }
    for _ = 1, 5 do frostHit(T.me, 1) end
    eq(T.me._hp, 100, "zero: Health unchanged")
    eq(count("^HIT enemy=frostbite via=frostbite stock=1 scaled=0 rolled=0 applied=0 hp=100 kind=hit$"), 5, "zero: applied 0", dump())
end
do -- frostbite Default, before start, client, another world, backed off: nothing acts
    setup{ knobs = "enemyDamage=17" }
    frostHit(T.me, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "Default: stock 1, no write")
    eq(count("^HIT "), 0, "Default: no HIT line")
    setup{ knobs = "frostbite=3", start = false }
    frostHit(T.me, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "before start: stock")
    setup{ knobs = "frostbite=3", host = false }
    frostHit(T.me, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "client: stock")
    setup{ knobs = "frostbite=3" }
    T.world = "World /Game/Maps/NewMainMenu.NewMainMenu"
    frostHit(T.me, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "another world: stock")
    setup{ knobs = "frostbite=3" }
    frostHit(T.me, 1, function() T.me._hp = T.me._hp + 5 end) -- a clash
    T.me._hp, T.me.writes = 100, 0
    frostHit(T.me, 1)
    ok(T.me._hp == 99 and T.me.writes == 0, "backed off: stock")
end
do -- the guard: a clash backs off once; the native applied nothing; a lowering floors at 0.01
    setup{ knobs = "frostbite=3" }
    frostHit(T.me, 1, function() T.me._hp = T.me._hp + 5 end)
    eq(count("^WARN clash: after the hit enemy=frostbite via=frostbite Health is 102, planned 97 %(another mod changed it%); every knob off until the next match$"), 1, "clash: one WARN", dump())
    T.H:onWorld(MATCH, true, true)
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    T.me._hp = 100
    frostHit(T.me, 1)
    eq(T.me._hp, 97, "clash: resets next match")
    setup{ knobs = "frostbite=3" }
    frostHit(T.me, 1, nil, true)
    eq(T.me._hp, 100, "native applied nothing: compensation undone")
    eq(count("WARN"), 0, "native applied nothing: no clash")
    eq(T.H.st.backedOff, false, "native applied nothing: not backed off")
    setup{ knobs = "frostbite=20" }
    T.me._hp = 5
    frostHit(T.me, 1)
    ok(math.abs(T.me._hp + 0.99) < 1e-9, "frostbite 20 at 5 HP: Health 0.01 before the native's 1 (the tick kills)", T.me._hp)
    eq(count("WARN"), 0, "floor: the guard is satisfied")
end
do -- a grab's temporary Health in place: restored before the frostbite plan
    setup{ knobs = "frostbite=3;enemyDamage=25", diff = 0 }
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 101, "pending: temporary value")
    frostHit(T.me, 1)
    eq(T.me._hp, 97, "tick while pending: planned from 100")
    eq(count("WARN"), 0, "tick while pending: no false clash")
end
do -- the finisher: absorbed only at Frostbite 0 and 0 < Health < 1
    setup{ knobs = "frostbite=0" }
    T.me._hp = 0.5
    frostHit(T.me, 100)
    eq(T.me._hp, 0.5, "finisher zero: Health unchanged")
    eq(count("^HIT enemy=frostbite via=frostbite%-finisher stock=100 scaled=0 rolled=0 applied=0 hp=0%.5 kind=hit$"), 1, "finisher: HIT line", dump())
    eq(count("WARN"), 0, "finisher: the guard is satisfied")
    T.me._hp = 0.5
    frostHit(T.me, 100, function() T.me._hp = T.me._hp + 5 end)
    eq(count("^WARN clash: after the hit enemy=frostbite via=frostbite%-finisher "), 1, "finisher: checked by the guard", dump())
    setup{ knobs = "frostbite=0" }
    T.me._hp, T.me.writes = 50, 0
    frostHit(T.me, 100)
    ok(T.me._hp == -50 and T.me.writes == 0, "finisher other: Health 50 -> the game's", T.me._hp)
    eq(count("finisher"), 0, "finisher other: no finisher line")
    -- A grab's temporary 0.01 is not a Health between 0 and 1: it is restored first.
    setup{ knobs = "frostbite=0;enemyDamage=100", diff = 1 }
    T.me._hp = 60
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 0.01, "finisher, pending: the execution's temporary value")
    frostHit(T.me, 100)
    eq(T.me._hp, -40, "finisher, pending: restored, then the game's 100")
    eq(count("via=frostbite%-finisher"), 0, "finisher, pending: not absorbed")
end
do -- the native couldn't be hooked: install reports it, nothing acts
    W = F.new() F.install(W)
    W.missing[N.frost] = true
    local h2 = hits.new{ say = function() end, warnOnce = function() end, isHost = function() return true end,
        world = function() return MATCH end, knobs = function() return "frostbite=3" end, alive = function() return true end }
    local okI, why = h2:install()
    eq(okI, false, "hook missing: install fails")
    eq(h2.installFailed, true, "hook missing: no grab flips or compensation")
    ok(why and why:find("CallFrostbiteDamageEvent", 1, true), "hook missing: named in the problem", why)
end

-- ---------------------------------------------------------------- tokens
do -- a back-off puts the token count back to stock, once; nothing more with tokens that match
    setup{ knobs = "revives=4;enemyDamage=17", cm = 0 }
    radio("ReinforceSpecficPlayer")
    eq(T.gs._f.TimesUsedReinforcements, -1, "release: offset count before")
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50, { inner = function() T.me._hp = T.me._hp + 5 end }) -- a clash
    eq(T.gs._f.TimesUsedReinforcements, 1, "release: the count back to used at the back-off")
    eq(count("^TOKENS released at back%-off used=1 count=%-1 %-> 1$"), 1, "release: one line", dump())
    radio("ReinforceSpecficPlayer") T.poll()
    eq(count("^TOKENS"), 3, "release: no TOKENS line after it (start, used=1, released)", dump())
    eq(T.gs._w["Disable Reinforcement"], nil, "release: Disable never written")
    -- A failing hook body backs off the same way.
    setup{ knobs = "revives=4;cold=50", cm = 0, diff = 0 }
    T.me._f.Temperature = 0.1 T.poll()
    T.me._ro.Temperature = true
    T.me._f.Temperature = 0.2 T.poll()
    eq(T.gs._f.TimesUsedReinforcements, 0, "release: a poll fault puts the count back too")
end
do -- the radio callbacks use the match's handle (no FindAllOf); a failed class read isn't cached
    setup{ knobs = "revives=2;cold=50", cm = 3, diff = 0 }
    local finds, real = 0, FindAllOf
    FindAllOf = function(s) finds = finds + 1 return real(s) end
    radio("ReinforceSpecficPlayer")
    FindAllOf = real
    eq(finds, 0, "radio: no FindAllOf with the match's handle")
    eq(count("^TOKENS used=1 "), 1, "radio: still re-checked")
    local realClass = Actor.GetClass
    Actor.GetClass = function(a) if a == T.me then error("class read failed") end return realClass(a) end
    T.poll()
    eq(T.H.st.isFP[T.me._path], nil, "class: a failed read isn't cached")
    Actor.GetClass = realClass
    T.H.st.sinceDiscovery = hits.REDISCOVER_EVERY - 1
    T.me._f.Temperature = 0.1 T.poll()
    T.me._f.Temperature = 0.14 T.poll()
    ok(math.abs(T.me._f.Temperature - 0.11) < 1e-9, "class: read again at the next discovery and scaled", T.me._f.Temperature)
end
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

-- ---------------------------------------------------------------- story 12: tokens per classified objective
-- The game's UpdateClassifieds on the host: the value + 1, then (unless noHook) its callback.
local function classified(opts)
    opts = opts or {}
    T.gs._f.ClassifiedDynamicValue = T.gs._f.ClassifiedDynamicValue + (opts.by or 1)
    if not opts.noHook then return W.fire(GSC .. ":UpdateClassifieds", W.p(T.gs), W.p(T.gs._f.ClassifiedDynamicValue)) end
end
do -- the hook is registered with the game state's; Default and 0 do nothing
    setup{ knobs = "enemyDamage=17", cm = 3 }
    eq(W.count(GSC .. ":UpdateClassifieds"), 1, "classified: UpdateClassifieds registered on a host world")
    classified() T.poll()
    eq(next(T.gs._w), nil, "classified Default: nothing written")
    eq(count("^TOKENS"), 0, "classified Default: no TOKENS line")
    setup{ knobs = "classifiedTokens=0;classifiedTokensMax=3", cm = 3 }
    classified() T.poll()
    eq(next(T.gs._w), nil, "classified 0: nothing written")
    eq(count("^TOKENS"), 0, "classified 0: no TOKENS line (the cap alone does nothing)")
    eq(T.H.st.tok, nil, "classified 0: no token state")
    -- revives alone: the story 4 lines, byte for byte, and no bonus.
    setup{ knobs = "revives=2", cm = 3 }
    classified() T.poll()
    eq(table.concat(T.lines, "|"):match("TOKENS[^|]*"), "TOKENS start limit=8 N=2 count=6", "revives only: the start line unchanged")
    eq(count("^TOKENS"), 1, "revives only: no new TOKENS line", dump())
    eq(T.gs._f.TimesUsedReinforcements, 6, "revives only: the objective changes nothing")
end
do -- stock tokens through the adapter: revives Default, CM 3, k 2, used 3, one objective
    setup{ knobs = "classifiedTokens=2", cm = 3, start = false }
    T.gs._f.TimesUsedReinforcements = 3
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    ok(T.H.st.tok ~= nil and T.H.st.gsRef ~= nil, "stock: token state and the game state's handle without revives")
    eq(T.gs._w.TimesUsedReinforcements, nil, "stock: no write at the start")
    eq(classified(), 1, "stock: the UpdateClassifieds callback ran")
    eq(T.gs._f.TimesUsedReinforcements, 1, "stock: count 3 -> 1 (the computer shows 7)")
    eq(count("^TOKENS bonus classified=1 %+2 count=1 left=stock via=UpdateClassifieds$"), 1, "stock: the bonus line", dump())
    T.poll()
    eq(count("^TOKENS bonus "), 1, "stock: the poll after the hook awards nothing more")
    eq(T.gs._w["Disable Reinforcement"], nil, "stock: Disable never written")
end
do -- the poll alone (no callback from UE4SS): awarded within one poll; two objectives in one poll, one line
    setup{ knobs = "revives=2;classifiedTokens=2", cm = 3 }
    classified{ noHook = true, by = 2 }
    T.poll()
    eq(T.gs._f.TimesUsedReinforcements, 2, "poll: 6 -> 2 (+4)")
    eq(count("^TOKENS bonus classified=2 %+4 count=2 left=6 via=poll$"), 1, "poll: one line +4", dump())
    T.poll()
    eq(count("^TOKENS bonus "), 1, "poll: not awarded again")
end
do -- the scenario's path: N 2, k 2, cap 3: both tokens used -> Disable; +2 reopens; +1 capped; closes at used 5
    setup{ knobs = "revives=2;classifiedTokens=2;classifiedTokensMax=3", cm = 3 }
    eq(count("^TOKENS classified k=2 cap=3 baseline=0$"), 1, "scenario: the classified line", dump())
    radio("ReinforceSpecficPlayer") radio("ReinforceSpecficPlayer")
    eq(T.gs._f["Disable Reinforcement"], true, "scenario: Disable at used 2")
    classified()
    eq(T.gs._f["Disable Reinforcement"], false, "scenario: Disable cleared by the bonus")
    eq(8 - T.gs._f.TimesUsedReinforcements, 2, "scenario: the computer shows 2")
    classified()
    eq(8 - T.gs._f.TimesUsedReinforcements, 3, "scenario: the computer shows 3 (capped)")
    eq(count("^TOKENS bonus classified=2 %+1 .* capped at 3$"), 1, "scenario: +1 capped", dump())
    for i = 1, 3 do radio("ReinforceSpecficPlayer") end
    eq(count("^TOKENS disabled at used=5 N=5 via=ReinforceSpecficPlayer$"), 1, "scenario: closes at used 5", dump())
end
do -- client, before start, imposter, lobby Disable: nothing acts
    setup{ knobs = "classifiedTokens=2", cm = 3, host = false }
    classified() T.poll()
    eq(next(T.gs._w), nil, "classified, client: nothing written")
    eq(W.count(GSC .. ":UpdateClassifieds"), 0, "classified, client: no hook")
    setup{ knobs = "classifiedTokens=2", cm = 3, start = false }
    classified() T.poll()
    eq(next(T.gs._w), nil, "classified, before start: nothing written")
    setup{ knobs = "classifiedTokens=2", cm = 3, gamemode = 1 }
    classified() T.poll()
    eq(next(T.gs._w), nil, "classified, imposter: nothing written")
    eq(count("^TOKENS imposter mode"), 1, "classified, imposter: one info line")
    setup{ knobs = "classifiedTokens=2", cm = 3, disabled = true }
    classified() T.poll()
    eq(next(T.gs._w), nil, "classified, lobby Disable: nothing written")
    eq(count("^TOKENS the lobby disabled reinforcements: untouched$"), 1, "classified, lobby Disable: one info line")
end
do -- a back-off stops awarding and puts the count back to stock
    setup{ knobs = "revives=2;classifiedTokens=2;enemyDamage=17", cm = 3 }
    classified()
    eq(T.gs._f.TimesUsedReinforcements, 4, "back-off: 6 -> 4 before")
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50, { inner = function() T.me._hp = T.me._hp + 5 end }) -- a clash
    eq(T.gs._f.TimesUsedReinforcements, 0, "back-off: the count back to stock (used 0)")
    classified() T.poll()
    eq(T.gs._f.TimesUsedReinforcements, 0, "back-off: no award after it")
    eq(count("^TOKENS bonus "), 1, "back-off: no bonus line after it")
end
do -- a failed award write: one ERROR, every knob off
    setup{ knobs = "classifiedTokens=2;enemyDamage=17", cm = 3 }
    T.gs._ro.TimesUsedReinforcements = true
    classified()
    eq(count("^ERROR UpdateClassifieds hook failed: .*could not write TimesUsedReinforcements.*; every knob off until the next match$"), 1, "award write fault: one ERROR", dump())
end

-- ---------------------------------------------------------------- story 5: survivable grabs on modded clients
local NETID = "nuclearnightmare-community.difficulty."
local PRESENT = hits.PRESENT
local function hv(t) local v = {} for k, x in pairs(t) do v[NETID .. k] = x end return v end
local function present(victim, attacker) return W.fire(PRESENT, W.p(T.ctx), W.p(attacker), W.p(victim)) end
-- Runs only the delayed callbacks of ms (the recovery: 6000), keeping the others.
local function runDelayed(ms)
    local keep, run = {}, {}
    for _, e in ipairs(W.later) do if e.ms == ms then run[#run + 1] = e else keep[#keep + 1] = e end end
    W.later = keep
    for _, e in ipairs(run) do e.fn() end
    return #run
end
local function clientSetup(values, o)
    o = o or {}
    local net = F.net{ role = "client", values = values, status = o.status }
    setup{ host = false, client = true, diff = o.diff or 0, net = net, version = o.version, netCompat = o.netCompat,
           netMissing = o.netMissing, missing = o.missing, noRef = o.noRef }
    return net
end

-- The host publishes at the match start (I/O matrix: what a modded client reads).
do
    local net = F.net()
    setup{ knobs = "enemyDamage=25;dmg.meek=50;spread=20;cold=50;revives=8", net = net }
    local t = {}
    for _, kv in ipairs(net.published) do t[#t + 1] = kv[1]:sub(#NETID + 1) .. "=" .. tostring(kv[2]) end
    eq(table.concat(t, ","), "enemyDamage=25,dmg_meek=50,ver=1000,compat=1000", "publish: the set grab knobs only, then ver and compat last")
    for _, kv in ipairs(net.published) do ok(kv[1]:sub(1, #NETID) == NETID, "publish: under the mod's own id: " .. kv[1]) end
    eq(count("^NET published enemyDamage=25 dmg_meek=50 ver=1000 compat=1000$"), 1, "publish: one NET line", dump())
    -- A second UpdateFriendlyFire in the same world (a client can call it again): nothing published again.
    W.fire(GSC .. ":UpdateFriendlyFire", W.p(T.gs))
    eq(#net.published, 4, "publish: once per match")
end
do -- all Default: ver and compat only, so a client tells Default apart from no Difficulty
    local net = F.net()
    setup{ knobs = nil, net = net }
    eq(#net.published, 2, "publish all Default: ver and compat")
end
do -- solo: core answers standalone; nothing published, no WARN, the match goes on
    local net = F.net{ role = "standalone" }
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    eq(#net.published, 0, "publish standalone: nothing")
    eq(count("WARN"), 0, "publish standalone: no WARN")
    meekGrab(T.me)
    eq(count("decision=s flip=101 victim=local spare=yes$"), 1, "standalone: the host's own player still spared")
end
do -- a raising publish: one WARN, the host's own grabs unaffected
    local net = F.net()
    net.publish = function() error("nucleus.net.publish: cap reached", 0) end
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    eq(count("^WARN NET publish failed: nucleus%.net%.publish: cap reached; modded clients keep the game's grab decisions this match$"), 1, "publish raises: one WARN", dump())
    eq(count("^MATCH start "), 1, "publish raises: the match started")
    meekGrab(T.me)
    eq(T.me._hp, 100, "publish raises: the host's own flip and restore still run")
    eq(count("decision=s flip=101 victim=local spare=yes$"), 1, "publish raises: GRAB line")
end
do -- core without Net: no publish, the host spares only its own player
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net, netMissing = "net.compatible" }
    eq(#net.published, 0, "core without Net: nothing published")
    meekGrab(T.me)
    eq(count("decision=s flip=101 victim=local spare=yes$"), 1, "core without Net: the host spares itself")
    T.now = T.now + 30
    meekGrab(T.other)
    eq(T.other.writes, 0, "core without Net: a client victim keeps the game's decision")
    eq(count("victim=client spare=no%(core%)$"), 1, "core without Net: spare=no(core)", dump())
    eq(#net.compatCalls, 0, "core without Net: compatible never called")
end

do -- a publish failing partway: no ver (the knobs go first), and the host spares no client
    local net = F.net()
    local real, n = net.publish, 0
    net.publish = function(k, v) n = n + 1 if n == 2 then return false, "no-world" end return real(k, v) end
    setup{ knobs = "enemyDamage=25;dmg.meek=50", diff = 0, net = net }
    eq(net.values[NETID .. "ver"], nil, "partial publish: ver not published")
    eq(net.values[NETID .. "enemyDamage"], 25, "partial publish: the first knob went out")
    net.compat[T.ps[2]] = true
    eq(meekGrab(T.other), "e", "partial publish: a compatible client keeps the game's decision")
    eq(count("victim=client spare=no%(unpublished%)$"), 1, "partial publish: spare=no(unpublished)", dump())
    T.now = T.now + 30
    meekGrab(T.me)
    eq(count("victim=local spare=yes$"), 1, "partial publish: the host still spares itself")
end
do -- the host backs off mid-match: compat republished as VER_MAX, so a client reading that state stops flipping
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 100, { inner = function() T.me._hp = T.me._hp + 5 end }) -- a clash: backed off
    eq(net.values[NETID .. "compat"], 999999999, "back-off: compat republished as VER_MAX")
    eq(count("^NET compat=999999999 republished at the back%-off"), 1, "back-off: one NET line", dump())
    lockedHit(T.meek, 100, { inner = function() T.me._hp = T.me._hp + 5 end })
    eq(#net.published, 4, "back-off: republished once")
    local state = {}
    for k, v in pairs(net.values) do state[k] = v end
    clientSetup(state)
    eq(meekGrab(T.me), "e", "back-off: the client keeps the game's decision")
    eq(T.me.writes, 0, "back-off: the client writes nothing")
    eq(count("^host has no Difficulty, inactive %(incompatible%)$"), 1, "back-off: the client is inactive (incompatible)", dump())
end
do -- a guarded hook body raises mid-match: guard's back-off also republishes compat as VER_MAX
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    eq(net.values[NETID .. "compat"], 1000, "guard fault: compat published at the start")
    T.locked[T.meek._path] = T.me
    T.H.plan = function() error("boom") end
    lockedHit(T.meek, 100)
    T.H.plan = nil
    eq(count("^ERROR ApplyLockedDamage hook failed: .*boom; every knob off until the next match$"), 1, "guard fault: one ERROR", dump())
    eq(net.values[NETID .. "compat"], 999999999, "guard fault: compat republished as VER_MAX")
    eq(count("^NET compat=999999999 republished at the back%-off"), 1, "guard fault: one NET line", dump())
end

-- The host's decision for a client victim (presence).
do -- a compatible client: spared; the host applies at most 99 (here 25)
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    net.compat[T.ps[2]] = true
    local picked = meekGrab(T.other)
    eq(picked, "s", "modded client: the host's own test picks survivable")
    eq(T.other._hp, 100, "modded client: restored in the multicast hook")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes$"), 1, "modded client: GRAB line", dump())
    eq(net.compatCalls[1], "nuclearnightmare-community.difficulty", "modded client: compatible asked with the mod's own id")
    lockedHit(T.meek, 100)
    eq(T.other._hp, 75, "modded client: the survivable hit (<= 99)")
    eq(count("kind=survivable$"), 1, "modded client: kind=survivable")
end
for _, why in ipairs({ "absent", "incompatible", "no-world" }) do
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    net.compat[T.ps[2]] = why
    eq(meekGrab(T.other), "e", why .. " client: the game's execution")
    eq(T.other.writes, 0, why .. " client: no temporary Health")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=client spare=no%(" .. why:gsub("%-", "%%-") .. "%)$"), 1, why .. " client: spare=no(" .. why .. ")", dump())
    lockedHit(T.meek, 100)
    ok(T.other._hp <= 0, why .. " client: the execution floor still applies", T.other._hp)
end
do -- compatible raises: no(error), one WARN; the victim's player state gone: no(no-player-state)
    local net = F.net()
    net.compatible = function() error("nucleus.net.compatible: player is not a live object", 0) end
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    meekGrab(T.other)
    eq(count("victim=client spare=no%(error%)$"), 1, "compatible raises: spare=no(error)")
    T.now = T.now + 30
    meekGrab(T.other)
    eq(count("^WARN core%.net%.compatible failed"), 1, "compatible raises: one WARN", dump())
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    rawset(T.other, "PlayerState", nil)
    meekGrab(T.other)
    eq(count("victim=client spare=no%(no%-player%-state%)$"), 1, "no player state: spare=no(no-player-state)", dump())
end
do -- the Stalker presentation hook does nothing on the host
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    eq(present(T.me, T.stalker), 1, "host: the presentation hook is registered")
    eq(T.me.writes, 0, "host: the presentation hook writes nothing")
    eq(count("^GRAB "), 0, "host: no GRAB from the presentation hook")
end

-- A modded client: its own player only, from the host's values, read at every grab.
do -- values in range: flip, restore, no damage of its own
    local net = clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    eq(W.count(HASPERK), 1, "client: HasPerk hooked")
    eq(W.count(MEEK_ATTACK), 1, "client: the grab multicast hooked")
    eq(W.count(GSC .. ":UpdateFriendlyFire"), 0, "client: no match-start hook")
    eq(meekGrab(T.me), "s", "client: the game's test picks survivable")
    eq(T.me._hp, 100, "client: restored in the multicast hook")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "client: GRAB line", dump())
    eq(count("^RESTORE enemy=meek hp=101 %-> 100 via=multicast$"), 1, "client: RESTORE line")
    local reads = net.reads
    ok(reads >= 2, "client: the host's values read at the grab", reads)
    lockedHit(T.meek, 100) -- the host's damage replicated: the client's damage hooks do nothing
    eq(count("^HIT "), 0, "client: damage stays the host's")
    eq(#net.published, 0, "client: publishes nothing")
    -- Never cached: the host's value changes, the next grab follows it.
    T.me._hp = 100
    net.values[NETID .. "enemyDamage"] = nil
    T.now = T.now + 30
    eq(meekGrab(T.me), "e", "client: Default now -> the game's decision")
    ok(net.reads > reads, "client: read again at the next grab")
    eq(count("^GRAB "), 1, "client: no GRAB for a Default grab")
    -- A remote player's grab on this client: never flipped.
    T.now = T.now + 30
    local w0 = T.other.writes
    net.values[NETID .. "enemyDamage"] = 25
    meekGrab(T.other)
    eq(T.other.writes, w0, "client: a remote victim is never flipped")
    eq(count("^GRAB "), 1, "client: no GRAB for a remote victim")
end
do -- the client's next-tick fallback when the multicast hook didn't come
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    meekGrab(T.me, { noMulticast = true })
    eq(T.me._hp, 101, "client fallback: temporary value in place")
    runDelayed(hits.RESTORE_DELAY)
    eq(T.me._hp, 100, "client fallback: restored on the next tick")
    eq(count("via=next tick$"), 1, "client fallback: RESTORE via=next tick")
end
for _, case in ipairs({ { nil, nil, "absent" }, { "no-state", nil, "no-state" }, { "version", nil, "version" },
                        { nil, { ver = 1000 }, "absent" } }) do
    -- no usable host values (unmodded host, no state yet, core version mismatch, compat missing): nothing changes
    local net = clientSetup(case[2] and hv(case[2]) or {}, { status = case[1] })
    eq(meekGrab(T.me), "e", "client, " .. case[3] .. ": the game's decision")
    eq(T.me.writes, 0, "client, " .. case[3] .. ": no write")
    T.now = T.now + 30
    meekGrab(T.me)
    eq(count("^host has no Difficulty, inactive %(" .. (case[3]:gsub("%-", "%%-")) .. "%)$"), 1, "client, " .. case[3] .. ": one inactive line for two grabs", dump())
    eq(count("^GRAB "), 0, "client, " .. case[3] .. ": no GRAB")
    eq(count("^RESTORE "), 0, "client, " .. case[3] .. ": no RESTORE")
    -- A new world: the line again (once per world).
    T.H:onWorld(MATCH .. "2", false, true, true)
    T.world = MATCH .. "2"
    T.now = T.now + 30
    meekGrab(T.me)
    eq(count("inactive"), 2, "client, " .. case[3] .. ": once more in a new world")
end
do -- incompatible host version: no change, inactive (incompatible)
    clientSetup(hv{ ver = 2000, compat = 2000, enemyDamage = 25 })
    eq(meekGrab(T.me), "e", "incompatible host: the game's decision")
    eq(T.me.writes, 0, "incompatible host: no write")
    eq(count("^host has no Difficulty, inactive %(incompatible%)$"), 1, "incompatible host: one inactive line", dump())
    -- A newer patch with an older netCompat on either side is compatible.
    clientSetup(hv{ ver = 1005, compat = 1000, enemyDamage = 25 })
    eq(meekGrab(T.me), "s", "host 0.1.5: compatible")
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 }, { version = "0.2.0", netCompat = "0.1.0" })
    eq(meekGrab(T.me), "s", "client 0.2.0 with netCompat 0.1.0: compatible with host 0.1.0")
    clientSetup(hv{ ver = 1000, compat = 2000, enemyDamage = 25 })
    eq(meekGrab(T.me), "e", "host compat above its version (broken): no change")
    eq(count("inactive %(incompatible%)$"), 1, "host compat above its version: inactive (incompatible)")
end
do -- an out-of-bounds value: no change for that grab, one line per key per match
    local net = clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25, dmg_meek = 9999 })
    eq(meekGrab(T.me), "e", "out-of-bounds: the game's decision")
    eq(T.me.writes, 0, "out-of-bounds: no write")
    T.now = T.now + 30
    meekGrab(T.me)
    eq(count("^WARN the host's dmg_meek is outside this mod's bounds"), 1, "out-of-bounds: one line for two grabs", dump())
    eq(count("inactive"), 0, "out-of-bounds: not the inactive line")
    net.values[NETID .. "enemyDamage"] = 201
    T.now = T.now + 30
    meekGrab(T.me)
    eq(count("^WARN the host's enemyDamage is outside"), 1, "out-of-bounds: a second key gets its own line")
    T.now = T.now + 30
    meekGrab(T.me)
    eq(count("^WARN the host's "), 2, "out-of-bounds: still one line per key")
    eq(T.me.writes, 0, "out-of-bounds: never a write")
end
do -- the client's attacker: GetLockedVictim unset -> the nearest grab-class AI within 10 m; none -> enemy % 100
    clientSetup(hv{ ver = 1000, compat = 1000, dmg_meek = 50 })
    T.locked = {}
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "client attacker: the nearest Meek's row (E 50 < 100: survivable)")
    ok(line("^GRAB enemy=meek "), "client attacker: row from the nearest grab-class AI", dump())
    clientSetup(hv{ ver = 1000, compat = 1000, dmg_meek = 200, enemyDamage = 25 })
    T.locked = {}
    T.meek._loc = { X = 5000, Y = 0, Z = 0 }
    W.fire(HASPERK, W.p(T.me), W.p(39))
    ok(line("^GRAB enemy=unknown%(none%) hp=100 E=25 .* why=no%-grab%-ai%-near$"), "client attacker: none within 10 m -> no row (enemy % 100), named unknown", dump())
    eq(count("enemy=%?"), 0, "client attacker: never enemy=?")
end
do -- the client's Stalker grab: the presentation pre-hook flips; PlayDamageEvent's hook restores
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    eq(present(T.me, T.stalker), 1, "client Stalker: the presentation hook is registered")
    eq(T.me._hp, 101, "client Stalker: flipped before the body's Health test")
    W.fire(FPC .. ":PlayDamageEvent", W.p(T.me), W.p(T.stalker), W.p(false))
    eq(T.me._hp, 100, "client Stalker: restored in PlayDamageEvent")
    ok(line("^GRAB enemy=stalker hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), "client Stalker: GRAB line", dump())
    -- the next-tick fallback
    T.now = T.now + 30
    present(T.me, T.stalker)
    eq(T.me._hp, 101, "client Stalker fallback: temporary value")
    present(T.me, T.stalker) -- a repeated callback while pending: skipped
    eq(count("^GRAB enemy=stalker"), 2, "client Stalker: pending victim skipped")
    runDelayed(hits.RESTORE_DELAY)
    eq(T.me._hp, 100, "client Stalker fallback: restored next tick")
    -- a remote victim's presentation on this client: nothing
    local w0 = T.other.writes
    present(T.other, T.stalker)
    eq(T.other.writes, w0, "client Stalker: a remote victim is never flipped")
end
do -- no client hook acts before ver has arrived (and nothing in the menu or a standalone world)
    clientSetup({})
    present(T.me, T.stalker)
    meekGrab(T.me)
    eq(T.me.writes, 0, "before ver: no write from any client hook")
    setup{ host = false, client = false, diff = 0, net = F.net{ role = "standalone", values = hv{ ver = 1000, compat = 1000, enemyDamage = 25 } } }
    meekGrab(T.me)
    present(T.me, T.stalker)
    eq(T.me.writes, 0, "not a client world: no flip")
    eq(count("inactive"), 0, "not a client world: no inactive line")
end
do -- a client on a core without Net: no reads, no flip, no inactive line (connect's one line said why)
    local net = clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 }, { netMissing = "net.read" })
    meekGrab(T.me)
    eq(T.me.writes, 0, "client without Net: no write")
    eq(net.reads, 0, "client without Net: nothing read")
    eq(count("inactive"), 0, "client without Net: no inactive line")
end
do -- the client's grab hooks when the character class wasn't loaded at the world's evaluation
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 }, { missing = { HASPERK, FPC .. ":PlayDamageEvent" } })
    eq(W.count(HASPERK), 0, "client late class: not hooked at first")
    for _ = 1, hits.REDISCOVER_EVERY do T.poll() end
    eq(W.count(HASPERK), 0, "client late class: still missing")
    W.missing = {}
    for _ = 1, hits.REDISCOVER_EVERY do T.poll() end
    eq(W.count(HASPERK), 1, "client late class: hooked on a later poll")
    for _ = 1, hits.REDISCOVER_EVERY * 2 do T.poll() end
    eq(W.count(HASPERK), 1, "client late class: once")
    eq(meekGrab(T.me), "s", "client late class: the grab is flipped")
    -- never loaded: one line after the last try, then no more tries
    clientSetup(hv{ ver = 1000, compat = 1000 }, { missing = { HASPERK } })
    for _ = 1, hits.REDISCOVER_EVERY * (hits.CLIENT_HOOK_TRIES + 3) do T.poll() end
    eq(count("^WARN the character class never loaded on this client"), 1, "client class never loaded: one line", dump())
end

-- The recovery: every machine with the mod, its own player only.
do -- after an execution began here, the player alive at 6 s, no newer grab: RECOVER
    setup{ knobs = nil, diff = 0 }
    eq(meekGrab(T.me), "e", "recovery: the game's execution (Default knobs)")
    T.me._hp = 40 -- alive (the hit reduced, as by another mod)
    eq(runDelayed(hits.RECOVER_DELAY), 1, "recovery: one check 6 s later")
    eq(count("^RECOVER hp=40 montage=yes stop=true playing=true movement=true$"), 1, "recovery: RECOVER line", dump())
    eq(T.me.stops, 1, "recovery: StopAnimMontage")
    eq(rawget(T.me, "PlayingMontage"), false, "recovery: PlayingMontage = false")
    eq(T.me.mode, 1, "recovery: SetMovementMode(1)")
    eq(T.freed > 0, true, "recovery: the weak handle freed")
end
do -- not fired if a newer grab began (even a survivable one), nor when dead, nor for a survivable grab
    setup{ knobs = nil, diff = 1 }
    T.me._hp = 40
    eq(meekGrab(T.me), "e", "newer grab: first an execution")
    T.me._hp = 100
    T.now = T.now + 2
    eq(meekGrab(T.me), "s", "newer grab: then a survivable grab")
    runDelayed(hits.RECOVER_DELAY)
    eq(count("^RECOVER"), 0, "newer grab: no RECOVER", dump())
    setup{ knobs = nil, diff = 0 }
    meekGrab(T.me)
    T.me._hp = 0
    runDelayed(hits.RECOVER_DELAY)
    eq(count("^RECOVER"), 0, "dead: no RECOVER")
    setup{ knobs = nil, diff = 0, noRef = true }
    meekGrab(T.me)
    rawset(T.me, "_gone", true)
    runDelayed(hits.RECOVER_DELAY)
    eq(count("^RECOVER"), 0, "pawn gone (path lookup): no RECOVER")
    setup{ knobs = "enemyDamage=25", diff = 0 }
    meekGrab(T.me)
    eq(runDelayed(hits.RECOVER_DELAY), 0, "survivable: no recovery scheduled")
    setup{ knobs = nil, diff = 0 }
    meekGrab(T.other)
    eq(runDelayed(hits.RECOVER_DELAY), 0, "a remote victim: no recovery on this machine")
end
do -- after a back-off the recovery still runs; on a client too (an unmodded host's execution that didn't kill)
    setup{ knobs = "enemyDamage=17", diff = 0 }
    T.locked[T.meek._path] = T.me
    lockedHit(T.meek, 50, { inner = function() T.me._hp = T.me._hp + 5 end }) -- a clash: backed off
    T.me._hp = 100
    meekGrab(T.me)
    T.me._hp = 30
    runDelayed(hits.RECOVER_DELAY)
    eq(count("^RECOVER hp=30 "), 1, "backed off: the recovery still runs", dump())
    clientSetup({})
    meekGrab(T.me)
    T.me._hp = 30
    runDelayed(hits.RECOVER_DELAY)
    eq(count("^RECOVER hp=30 "), 1, "client of an unmodded host: the recovery backstop")
    clientSetup({})
    meekGrab(T.me)
    T.world = "World /Game/Maps/Other.Other"
    runDelayed(hits.RECOVER_DELAY)
    eq(count("^RECOVER"), 0, "another world by then: no RECOVER")
end
do -- a modded client's execution decision from the host's values (low Health): recovery scheduled
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    T.me._hp = 20
    eq(meekGrab(T.me), "e", "client low Health: execution (20 - 25 <= 0)")
    eq(count("^GRAB enemy=meek hp=20 E=25 game=e decision=e flip=none victim=local spare=yes$"), 1, "client low Health: GRAB line", dump())
    eq(runDelayed(hits.RECOVER_DELAY), 1, "client low Health: recovery check scheduled")
end

-- ---------------------------------------------------------------- story 11: the Watcher's grab, the attacker named
local WATCHER_ATTACK = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C:AttackMulti"
-- A Watcher in W.all (near both players unless loc is given).
local function addWatcher(loc)
    T.watcher = actor("EyeMonster_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.EyeMonster_AI_C_1", { loc = loc or { X = 150, Y = 0, Z = 0 } })
    W.all.EyeMonster_AI_C = { T.watcher }
    return T.watcher
end
-- A Watcher grab as EyeMonster_AI_C:AttackMulti runs it: AttackedPlayer = the grabbed character, HasPerk(0x27) on the
-- chase Target, the decision from AttackedPlayer's Health, then the multicast hook (after the body). opts.noLock: no
-- locked victim (a client); opts.noMulticast: the hook doesn't come.
local function watcherGrab(target, attacked, opts)
    opts = opts or {}
    local w = T.watcher
    rawset(w, "Target", target)
    rawset(w, "AttackedPlayer", attacked)
    if not opts.noLock then T.locked[w._path] = attacked end
    W.fire(HASPERK, W.p(target), W.p(39))
    local picked = (attacked._hp - ({ [0] = 100, 50, 25, 17 })[T.gs.Diffculty] <= 0) and "e" or "s"
    if not opts.noMulticast then W.fire(WATCHER_ATTACK, W.p(w), W.p(0), W.p(attacked)) end
    return picked
end
do -- the host, solo shape (Target == AttackedPlayer == its own player): enemy=watcher, both fields local
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    addWatcher()
    eq(watcherGrab(T.me, T.me), "s", "watcher solo: survivable")
    eq(T.me._hp, 100, "watcher solo: restored in the multicast hook")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "watcher solo: GRAB line", dump())
    eq(count("^WATCHER target=local attacked=local$"), 1, "watcher solo: WATCHER line", dump())
end
do -- the host: the Watcher's Target is B, its locked victim the host: the attacker is still named (no enemy=?)
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    net.compat[T.ps[2]] = true
    addWatcher()
    rawset(T.watcher, "Target", T.other)
    rawset(T.watcher, "AttackedPlayer", T.me)
    T.locked[T.watcher._path] = T.me
    W.fire(HASPERK, W.p(T.other), W.p(39))
    ok(line("^GRAB enemy=watcher hp=100 E=25 "), "watcher Target only: attacker named from the Watcher's Target", dump())
    eq(count("^WATCHER target=client attacked=local$"), 1, "watcher Target only: target=client attacked=local", dump())
    eq(count("enemy=%?"), 0, "watcher Target only: never enemy=?")
end
do -- a modded client, its own player both Target and attacked: enemy=watcher, WATCHER line from its own read
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    addWatcher()
    eq(watcherGrab(T.me, T.me, { noLock = true }), "s", "client watcher: survivable")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "client watcher: GRAB line", dump())
    eq(count("^WATCHER target=local attacked=local$"), 1, "client watcher: WATCHER line", dump())
end
do -- no attacker found on the host: enemy=unknown(<class>) with the reason, never enemy=?
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    W.all.Stalker_AI_C = {}
    W.fire(HASPERK, W.p(T.me), W.p(39))
    ok(line("^GRAB enemy=unknown%(SCP_AI_C%) hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes why=no%-locked%-victim$"), "unknown: the nearest grab AI's class and the reason", dump())
    eq(count("^WATCHER "), 0, "unknown: no WATCHER line")
    runDelayed(hits.RESTORE_DELAY)
    T.now = T.now + 30
    T.meek._loc = { X = 5000, Y = 0, Z = 0 }
    T.me._hp = 100
    W.fire(HASPERK, W.p(T.me), W.p(39))
    ok(line("^GRAB enemy=unknown%(none%) .* why=no%-grab%-ai%-near$"), "unknown: none near", dump())
    eq(count("enemy=%?"), 0, "unknown: never enemy=?")
    runDelayed(hits.RESTORE_DELAY)
    ok(line("^RESTORE enemy=unknown%(none%) "), "unknown: the RESTORE label names it too", dump())
end

-- ---------------------------------------------------------------- story 14: the Insta-kill box
do -- ticked, game executes: Nightmare, ED 25, kill.meek, 100 HP: no flip, kill=yes, the execution kills
    setup{ knobs = "enemyDamage=25;kill.meek=1", diff = 0 }
    eq(meekGrab(T.me), "e", "ticked, game e: the game's execution")
    eq(T.me.writes, 0, "ticked, game e: no temporary Health")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=local spare=yes kill=yes$"), 1, "ticked, game e: GRAB line", dump())
    lockedHit(T.meek, 100)
    ok(T.me._hp <= 0, "ticked, game e: dead", T.me._hp)
    eq(count("^HIT enemy=meek via=ApplyLockedDamage stock=100 scaled=25 rolled=25 applied=100 hp=100 kind=execution$"), 1, "ticked, game e: HIT kind=execution applied>=100", dump())
    eq(count("WARN"), 0, "ticked, game e: no WARN")
end
do -- ticked, game spares: Normal, ED Default, kill.meek, 100 HP: flip 0.01, the execution kills
    setup{ knobs = "kill.meek=1", diff = 2 }
    eq(meekGrab(T.me), "e", "ticked, game s: the flipped test picks the execution")
    eq(T.me._hp, 100, "ticked, game s: restored in the multicast hook")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=s decision=e flip=0.01 victim=local spare=yes kill=yes$"), 1, "ticked, game s: GRAB line", dump())
    eq(count("^RESTORE enemy=meek hp=0.01 %-> 100 via=multicast$"), 1, "ticked, game s: RESTORE line", dump())
    lockedHit(T.meek, 100)
    ok(T.me._hp <= 0, "ticked, game s: dead", T.me._hp)
    eq(count("^HIT enemy=meek via=ApplyLockedDamage stock=100 scaled=100 rolled=100 applied=100 hp=100 kind=execution$"), 1, "ticked, game s: HIT", dump())
end
do -- ticked, ED 0 and the row at 0 %: still the execution, at least Health
    setup{ knobs = "enemyDamage=0;dmg.meek=0;kill.meek=1", diff = 2 }
    eq(meekGrab(T.me), "e", "ED 0 / row 0, ticked: execution")
    eq(count("game=s decision=e flip=0.01 victim=local spare=yes kill=yes$"), 1, "ED 0 / row 0: GRAB line", dump())
    lockedHit(T.meek, 100)
    ok(T.me._hp <= 0, "ED 0 / row 0: dead", T.me._hp)
    eq(count("applied=100 hp=100 kind=execution$"), 1, "ED 0 / row 0: applied 100", dump())
    -- Outside a grab the same Meek's hit follows ED 0: nothing.
    T.me._hp = 100
    T.now = T.now + 30
    lockedHit(T.meek, 25)
    eq(T.me._hp, 100, "ED 0 / row 0: a hit outside a grab applies 0")
end
do -- ticked, an unspared client: the game's survivable, capped (4a)
    local net = F.net()
    setup{ knobs = "kill.meek=1", diff = 2, net = net }
    eq(meekGrab(T.other), "s", "unspared client: the game's survivable")
    eq(T.other.writes, 0, "unspared client: no temporary Health")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=s decision=s flip=none victim=client spare=no%(absent%) kill=yes$"), 1, "unspared client: GRAB line", dump())
    lockedHit(T.meek, 25)
    eq(T.other._hp, 75, "unspared client: alive")
    eq(count("kind=survivable$"), 1, "unspared client: kind=survivable")
end
do -- ticked, a compatible modded client: the host decides the execution for it too
    local net = F.net()
    setup{ knobs = "enemyDamage=25;kill.meek=1", diff = 0, net = net }
    net.compat[T.ps[2]] = true
    eq(meekGrab(T.other), "e", "modded client, ticked: execution")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=client spare=yes kill=yes$"), 1, "modded client, ticked: GRAB line", dump())
    lockedHit(T.meek, 100)
    ok(T.other._hp <= 0, "modded client, ticked: dead", T.other._hp)
end
do -- the host publishes the kills bitmask (grab boxes only)
    local net = F.net()
    setup{ knobs = "enemyDamage=25;kill.meek=1;kill.stalker=1;kill.apex=1", net = net }
    local t = {}
    for _, kv in ipairs(net.published) do t[#t + 1] = kv[1]:sub(#NETID + 1) .. "=" .. tostring(kv[2]) end
    eq(table.concat(t, ","), "enemyDamage=25,kills=33,ver=1000,compat=1000", "publish: kills=33 (meek + stalker), no boss bit")
    net = F.net()
    setup{ knobs = "kill.apex=1", net = net }
    eq(#net.published, 2, "publish: only a boss ticked -> ver and compat only")
end
do -- the modded client: its own player from the host's kills bit
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25, kills = 1 })
    eq(meekGrab(T.me), "e", "client, kills bit 0: execution")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=local spare=yes kill=yes$"), 1, "client, kills bit 0: GRAB line", dump())
    clientSetup(hv{ ver = 1000, compat = 1000, kills = 1 }, { diff = 2 })
    eq(meekGrab(T.me), "e", "client on Normal, kills bit 0: flipped to the execution")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=s decision=e flip=0.01 victim=local spare=yes kill=yes$"), 1, "client on Normal: GRAB line", dump())
    eq(T.me._hp, 100, "client on Normal: restored")
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25, kills = 2 })
    eq(meekGrab(T.me), "s", "client, only the Mimic's bit: the Meek is spared")
    eq(count("kill=yes"), 0, "client, only the Mimic's bit: no kill=yes")
    for _, bad in ipairs({ 64, -1 }) do
        clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25, kills = bad })
        eq(meekGrab(T.me), "e", "client, kills=" .. bad .. ": the game's decision")
        eq(T.me.writes, 0, "client, kills=" .. bad .. ": no write")
        eq(count("^WARN the host's kills is outside this mod's bounds"), 1, "client, kills=" .. bad .. ": one WARN", dump())
        eq(count("^GRAB "), 0, "client, kills=" .. bad .. ": no GRAB")
    end
end
do -- a boss ticked: the finisher applies at least Health (kind=execution); unticked unchanged (story 13)
    setup{ knobs = "enemyDamage=25;kill.apex=1", diff = 0 }
    bossHit(T.apex, T.me, 100)
    ok(T.me._hp <= 0, "boss ticked: dead", T.me._hp)
    eq(count("^HIT enemy=apex via=CommitLethalDamage stock=100 scaled=25 rolled=25 applied=100 hp=100 kind=execution$"), 1, "boss ticked: HIT line", dump())
    eq(count("WARN"), 0, "boss ticked: the guard is satisfied")
    local queen = actor("SlugQueen_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.SlugQueen_AI_C_1")
    T.me._hp = 100
    bossHit(queen, T.me, 100)
    eq(T.me._hp, 75, "boss unticked (the Queen, kill.apex only): 75 HP")
    eq(count("^HIT enemy=slugQueen via=CommitLethalDamage stock=100 scaled=25 rolled=25 applied=25 hp=100 kind=hit$"), 1, "boss unticked: HIT line unchanged", dump())
    setup{ knobs = "kill.slugQueen=1", diff = 2 }
    queen = actor("SlugQueen_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.SlugQueen_AI_C_1")
    T.me._hp = 150
    bossHit(queen, T.me, 100)
    ok(T.me._hp <= 0, "boss ticked, Health above the stock hit: still dead", T.me._hp)
    eq(count("applied=150 hp=150 kind=execution$"), 1, "boss ticked: applied = Health", dump())
    -- A boss ticked but the hit outside CommitLethalDamage (no context): untouched.
    T.me._hp = 100
    cde(T.me, 30)
    eq(T.me._hp, 70, "boss ticked: a hit with no context stays stock")
end
do -- only a box ticked: acts for that enemy only; its non-grab hits plan to the stock
    setup{ knobs = "kill.husk=1", diff = 2 }
    local husk = actor("FastLearner_AI_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.FastLearner_AI_C_1")
    T.locked[husk._path] = T.me
    lockedHit(husk, 25)
    eq(T.me._hp, 75, "only a box: the Husk's hit unchanged")
    eq(count("^HIT enemy=husk via=ApplyLockedDamage stock=25 scaled=25 rolled=25 applied=25 hp=100 kind=hit$"), 1, "only a box: HIT plans the stock", dump())
    T.me._hp, T.me.writes = 100, 0
    T.locked[T.meek._path] = T.me
    meekGrab(T.me)
    lockedHit(T.meek, 25)
    eq(T.me._hp, 75, "only a box: the Meek's hit stock")
    eq(T.me.writes, 0, "only a box: no write for the Meek")
    eq(count("enemy=meek"), 0, "only a box: no line for the Meek")
end
do -- unticked = identical: the same grabs and hits with and without other enemies' boxes give the same lines
    local function run(knobs)
        setup{ knobs = knobs, diff = 0, net = F.net() }
        T.H.rng = function() return 0.25 end
        meekGrab(T.me)
        lockedHit(T.meek, 100)
        T.now = T.now + 30
        T.me._hp = 100
        bossHit(T.apex, T.me, 100)
        T.me._hp = 30
        T.now = T.now + 30
        meekGrab(T.me)
        lockedHit(T.meek, 100)
        local out = {}
        for _, l in ipairs(T.lines) do if not l:find("^MATCH ") and not l:find("^NET ") then out[#out + 1] = l end end
        return table.concat(out, " | "), T.me._hp
    end
    local a, hpA = run("enemyDamage=25;spread=20")
    local b, hpB = run("enemyDamage=25;spread=20;kill.mimic=1;kill.slugQueen=1")
    eq(b, a, "unticked = identical lines")
    eq(hpB, hpA, "unticked = identical Health")
    ok(not a:find("kill=", 1, true), "unticked: no kill= anywhere")
-- ---------------------------------------------------------------- story 11: the Watcher's victim (I/O matrix)
do -- host: B is the Watcher's Target, the host is attacked: the host is flipped and restored, B untouched
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    net.compat[T.ps[2]] = true
    addWatcher()
    eq(watcherGrab(T.other, T.me), "s", "host attacked, B Target: the game's test on the host picks survivable")
    eq(T.me._hp, 100, "host attacked, B Target: the host restored in the multicast hook")
    eq(T.me.writes, 2, "host attacked, B Target: the host flipped (101) and restored")
    eq(T.other.writes, 0, "host attacked, B Target: B untouched")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "host attacked, B Target: GRAB line", dump())
    eq(count("^GRAB "), 1, "host attacked, B Target: one GRAB")
    eq(count("^WATCHER target=client attacked=local$"), 1, "host attacked, B Target: WATCHER line", dump())
    eq(count("^RESTORE enemy=watcher hp=101 %-> 100 via=multicast$"), 1, "host attacked, B Target: restored via the multicast", dump())
    eq(#net.compatCalls, 0, "host attacked, B Target: no presence asked for B")
end
do -- host: the host is the Target, B (compatible) is attacked: B flipped, the host untouched
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    net.compat[T.ps[2]] = true
    addWatcher()
    eq(watcherGrab(T.me, T.other), "s", "B attacked, host Target: survivable for B")
    eq(T.other._hp, 100, "B attacked, host Target: B restored in the multicast hook")
    eq(T.other.writes, 2, "B attacked, host Target: B flipped and restored")
    eq(T.me.writes, 0, "B attacked, host Target: the host untouched")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes$"), 1, "B attacked, host Target: GRAB line", dump())
    eq(count("^WATCHER target=local attacked=client$"), 1, "B attacked, host Target: WATCHER line", dump())
    eq(runDelayed(hits.RECOVER_DELAY), 0, "B attacked, host Target: no recovery on the host for B's grab")
end
do -- host: B absent (unmodded) is attacked: spare=no(absent), no write anywhere
    local net = F.net()
    setup{ knobs = "enemyDamage=25", diff = 0, net = net }
    addWatcher()
    eq(watcherGrab(T.me, T.other), "e", "B absent attacked: the game's execution")
    eq(T.other.writes + T.me.writes, 0, "B absent attacked: no write")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=e flip=none victim=client spare=no%(absent%)$"), 1, "B absent attacked: spare=no(absent)", dump())
end
do -- client: the local player is only the Target, the host is attacked: nothing written, logged or noted
    local net = clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    addWatcher()
    eq(watcherGrab(T.me, T.other, { noLock = true }), "e", "client Target only: the host's own grab")
    eq(T.me.writes + T.other.writes, 0, "client Target only: no write")
    eq(count("^GRAB "), 0, "client Target only: no GRAB", dump())
    eq(count("^WATCHER "), 0, "client Target only: no WATCHER line")
    eq(T.H.recover.seq, 0, "client Target only: no recovery note")
    eq(runDelayed(hits.RECOVER_DELAY), 0, "client Target only: no recovery check")
    eq(net.reads, 0, "client Target only: the host's values not even read")
end
do -- client: the host is the Target, the local player is attacked: flipped from the host's values
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    addWatcher()
    eq(watcherGrab(T.other, T.me, { noLock = true }), "s", "client attacked: survivable")
    eq(T.me._hp, 100, "client attacked: restored in the multicast hook")
    eq(T.me.writes, 2, "client attacked: flipped and restored")
    eq(T.other.writes, 0, "client attacked: the remote host never written")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "client attacked: GRAB line", dump())
    eq(count("^WATCHER target=client attacked=local$"), 1, "client attacked: WATCHER line", dump())
    eq(T.H.recover.seq, 1, "client attacked: the grab noted for the recovery")
    -- next tick fallback when the multicast hook doesn't come
    T.now = T.now + 30
    watcherGrab(T.other, T.me, { noLock = true, noMulticast = true })
    eq(T.me._hp, 101, "client attacked fallback: temporary value")
    runDelayed(hits.RESTORE_DELAY)
    eq(T.me._hp, 100, "client attacked fallback: restored next tick")
end
do -- client attacked with no usable host values: the inactive line, as today
    clientSetup({})
    addWatcher()
    eq(watcherGrab(T.other, T.me, { noLock = true }), "e", "client attacked, no host values: the game's decision")
    eq(T.me.writes, 0, "client attacked, no host values: no write")
    eq(count("^host has no Difficulty, inactive %(absent%)$"), 1, "client attacked, no host values: one inactive line", dump())
    eq(count("^GRAB "), 0, "client attacked, no host values: no GRAB")
end
do -- another AI's grab on v: a Meek has v locked, the Watcher's stale AttackedPlayer is the other player: decided for v
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    addWatcher()
    rawset(T.watcher, "Target", T.me)
    rawset(T.watcher, "AttackedPlayer", T.other)
    T.locked[T.meek._path] = T.me
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "Meek's grab on v: v flipped")
    eq(T.other.writes, 0, "Meek's grab on v: the stale AttackedPlayer untouched")
    W.fire(MEEK_ATTACK, W.p(T.meek), W.p(0), W.p(T.me))
    eq(T.me._hp, 100, "Meek's grab on v: restored")
    eq(count("^GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "Meek's grab on v: GRAB line", dump())
end
do -- the Watcher's AttackedPlayer more than 10 m from it: decided for v
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    addWatcher()
    T.other._loc = { X = 5000, Y = 0, Z = 0 }
    rawset(T.watcher, "Target", T.me)
    rawset(T.watcher, "AttackedPlayer", T.other)
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "Watcher far: v flipped")
    eq(T.other.writes, 0, "Watcher far: the far AttackedPlayer untouched")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "Watcher far: decided for v", dump())
    eq(count("^WATCHER target=local attacked=client$"), 1, "Watcher far: WATCHER line", dump())
end
do -- a dead or non-player AttackedPlayer: decided for v
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    addWatcher()
    rawset(T.other, "_garbage", true)
    rawset(T.watcher, "Target", T.me)
    rawset(T.watcher, "AttackedPlayer", T.other)
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "AttackedPlayer not live: decided for v")
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    addWatcher()
    rawset(T.watcher, "Target", T.me)
    rawset(T.watcher, "AttackedPlayer", T.meek)
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "AttackedPlayer not a player: decided for v")
end
do -- solo / the same player (Target == AttackedPlayer) on a client: unchanged
    clientSetup(hv{ ver = 1000, compat = 1000, enemyDamage = 25 })
    addWatcher()
    eq(watcherGrab(T.me, T.me, { noLock = true }), "s", "client same player: survivable")
    eq(count("^GRAB enemy=watcher hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes$"), 1, "client same player: GRAB line", dump())
end
do -- a raising AttackedPlayer read: v stays the victim, no fault escapes
    setup{ knobs = "enemyDamage=25", diff = 0, net = F.net() }
    addWatcher()
    setmetatable(T.watcher, { __index = function(a, k)
        if k == "AttackedPlayer" or k == "Target" then error("read failed") end
        return Actor.__index(a, k)
    end, __newindex = Actor.__newindex })
    W.fire(HASPERK, W.p(T.me), W.p(39))
    eq(T.me._hp, 101, "raising Watcher reads: decided for v")
    eq(count("^ERROR "), 0, "raising Watcher reads: no ERROR", dump())
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
