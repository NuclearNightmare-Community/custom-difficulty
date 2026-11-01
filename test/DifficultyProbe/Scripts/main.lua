-- DifficultyProbe: story 2's solo checks (spec-difficulty-v1, knob-mechanics.md "To verify in game", items 1-3).
-- Test-only, never shipped; plain UE4SS Lua (no core). It enters a solo listen match on Nightmare, spawns one enemy at
-- a time in front of the player and logs every damage path it can hook, then forces the player cold for frostbite.
--
-- What it logs ([DifficultyProbe] lines, judged by hand and by run-probe.ps1's summary):
--   HOOK <fn> ok|FAIL            every hook it tried, so a missing one is visible.
--   DMG #<seq> <fn> amount=.. attacker=.. victim=.. hp=.. ctx=..   every damage call, in order, with the wrappers
--                                that were active (ctx) when it ran; post-hooks log "END #<seq> hp=..".
--   GRAB #<seq> <enemy> <fn> hp=.. flip=.. -> montage=..  each grab multicast and the montage it picked.
--   ATTR <enemy> ...             how a Bat or Infected Dog hit could be attributed (nearest bat, dog support state).
--   FROST #<seq> amount=.. rule=true|false (...)    each CallDamageEvent during the cold phase, with the rule's inputs.
--   RECOVER ...                  the enemy-died recovery run after an execution the probe kept the player alive in.
-- Damage is compensated the way the mod will (Health raised before the native call so the hit costs PROBE_HIT), which
-- also checks that compensation works; a guard refills Health below 30 so the player survives the whole run.
-- Never keeps a UObject across steps: paths and names only, re-found each step.
local ME = "DifficultyProbe"
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end
local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local MATCH_MAP = "/Game/Maps/SmallLoweIsland/SmallMap"
local FP = "BP_FirstPersonCharacter_C"
local FPC_PATH = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
local DIFF = 0                 -- Nightmare
local STANDARD = { [0] = 100, [1] = 50, [2] = 25, [3] = 17 }
local PROBE_HIT = 5            -- what each compensated hit costs
local SPAWN_DIST = 700         -- cm in front of the player

local S = { seq = 0, ctx = {}, checks = 0, failures = 0, case = nil, hooks = {}, frost = false, dead = false,
            nested = 0, grabAt = nil, grabExec = false }

local function valid(o)
    if o == nil or type(o) ~= "userdata" and type(o) ~= "table" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function nameOf(o) local ok, r = pcall(function() return o:GetFName():ToString() end) return ok and r or "?" end
local function classOf(o) local ok, r = pcall(function() return o:GetClass():GetFName():ToString() end) return ok and r or "?" end
local function pathOf(o) local ok, r = pcall(function() return (o:GetFullName():gsub("^%S+ ", "")) end) return ok and r or "?" end
local function check(cond, fmt, ...)
    S.checks = S.checks + 1
    if not cond then S.failures = S.failures + 1 end
    say("%s " .. fmt, cond and "OK" or "FAIL", ...)
    return cond
end
local function GS() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end
local function KSL() return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end
local function alive(a)
    if not valid(a) then return false end
    local f = StaticFindObject("/Script/Engine.KismetSystemLibrary:IsValid")
    local ok, r = pcall(function() return f(KSL(), a) end)
    return not ok or r == true
end

local function pc()
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) then
            local ok, l = pcall(function() return c:IsLocalPlayerController() end)
            if ok and l then return c end
        end
    end
    return nil
end
local function myPawn()
    local c = pc()
    if not c then return nil end
    local ok, p = pcall(function() return c:K2_GetPawn() end)
    return ok and valid(p) and p or nil
end
local function me() local p = myPawn() return p and classOf(p) == FP and p or nil end
local function worldName() local c = pc() return c and c:GetWorld():GetFullName() or "" end
local function gameState()
    for _, g in ipairs(FindAllOf("BP_FirstPersonGameState_C") or {}) do
        if valid(g) and not pathOf(g):find("Default__", 1, true) then return g end
    end
    return nil
end
local function num(v) return type(v) == "number" and v or tonumber(tostring(v)) end
local function hpOf(ch) local ok, h = pcall(function() return ch.Health end) return ok and num(h) or nil end
local function fmt1(v) return v and string.format("%.2f", v) or "?" end
local function montageOf(ch)
    local ok, m = pcall(function() return ch:GetCurrentMontage() end)
    return ok and valid(m) and nameOf(m) or "none"
end
local function get(p) if p == nil then return nil end local ok, v = pcall(function() return p:get() end) return ok and v or nil end
local function ctxText()
    local t = {}
    for _, c in ipairs(S.ctx) do t[#t + 1] = c end
    return #t > 0 and table.concat(t, ">") or "-"
end
local function caseHit(attacker)
    local c = S.case
    if not c then return end
    if attacker == nil or (valid(attacker) and pathOf(attacker) == c.actor) then c.hits = c.hits + 1
    else say("OTHER hit from %s during case %s (not counted)", enemyName(attacker), c.name) end
end
local function isMe(ch) local m = me() return m ~= nil and valid(ch) and pathOf(ch) == pathOf(m) end

-- ---------------------------------------------------------------- enemies
local CASES = {
    { name = "Meek", path = "/Game/AI/SCP_AI.SCP_AI_C", grab = true, flip = false },
    { name = "Meek", path = "/Game/AI/SCP_AI.SCP_AI_C", grab = true, flip = true },
    { name = "Mimic", path = "/Game/AI/Mimic_AI.Mimic_AI_C", grab = true, flip = true },
    { name = "Psycho", path = "/Game/AI/MadPatent_AI.MadPatent_AI_C", grab = true, flip = true },
    { name = "Husk", path = "/Game/AI/FastLearner_AI.FastLearner_AI_C", grab = true, flip = true },
    { name = "Watcher", path = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C", grab = true, flip = true },
    { name = "Stalker", path = "/Game/AI/Stalker_AI.Stalker_AI_C", grab = true, flip = true },
    { frost = true },
    { name = "Leech", path = "/Game/Horror_worm/Mesh/BabyWorm_AI.BabyWorm_AI_C" },
    { name = "Bat", path = "/Game/AI/Bat/BP_BatEnemy.BP_BatEnemy_C" },
    { name = "Infected Dog", path = "/Game/Dog_Husky/Husky/Dog_Infected_AI.Dog_Infected_AI_C" },
    { name = "Slug Queen", path = "/Game/AI/SlugQueen_AI.SlugQueen_AI_C" },
    { name = "Apex Predator", path = "/Game/AI/ApexPredator/ApexPredatorAI.ApexPredatorAI_C" },
    { name = "Worm", path = "/Game/AI/Worm_AI.Worm_AI_C", last = true },
}
local ENEMY_OF = {} -- class short name -> row name
for _, c in ipairs(CASES) do if c.path then ENEMY_OF[c.path:match("%.([^.]+)$")] = c.name end end
local function enemyName(o) return valid(o) and (ENEMY_OF[classOf(o)] or classOf(o)) or "none" end

-- The six grab multicasts (knob-mechanics.md "Survivable grabs"): function, victim parameter index, enemy row.
local GRABS = {
    { fn = "/Game/AI/SCP_AI.SCP_AI_C:Attack", victim = 2 },
    { fn = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C:AttackMulti", victim = 2 },
    { fn = "/Game/AI/Mimic_AI.Mimic_AI_C:AttackMulti", victim = 2 },
    { fn = "/Game/AI/MadPatent_AI.MadPatent_AI_C:AttackMulti", victim = 2 },
    { fn = "/Game/AI/FastLearner_AI.FastLearner_AI_C:AttackAll", victim = 2 },
    { fn = FPC_PATH .. ":PlayDamageEvent", victim = 0, attacker = 1 }, -- the Stalker's: on the victim, Stalker param
}
-- Synchronous wrappers that should bracket a CallDamageEvent (context attribution).
local WRAPPERS = {
    "/Game/AI/SlugQueen_AI.SlugQueen_AI_C:AttackMulti",
    "/Game/AI/ApexPredator/ApexPredatorAI.ApexPredatorAI_C:AttackMulti",
    "/Game/Horror_worm/Mesh/BabyWorm_AI.BabyWorm_AI_C:AttackAll",
    FPC_PATH .. ":AttackPInfectedAll",
    "/Game/ThirdPerson/Blueprints/BP_ThirdPersonCharacter.BP_ThirdPersonCharacter_C:AttackAll",
    FPC_PATH .. ":ExplosionDamage",
    FPC_PATH .. ":KillAll",
    "/Script/NuclearNightmare.NNInfectedDogSupport:TryAttack",
    "/Script/NuclearNightmare.NNInfectedDogSupport:TryAttackCurrentTarget",
    "/Script/NuclearNightmare.NNInfectedDogSupport:MulticastAttackPresentation",
    "/Script/NuclearNightmare.NNInfectedDogSupport:MulticastConfirmFinisher",
}

-- ---------------------------------------------------------------- damage compensation and attribution
local function compensate(victim, amount, why)
    if not isMe(victim) or not amount or (S.frost and (amount == 1 or amount == 2)) then return end
    local hp = hpOf(victim)
    if not hp then return end
    local new = hp + amount - PROBE_HIT
    pcall(function() victim.Health = new end)
    say("COMP %s hp %.2f -> %.2f (the native %.2f should leave %.2f)", why, hp, new, amount, new - amount)
end

-- Bat and Infected Dog have native damage paths: at each CallDamageEvent, look for one in the middle of an attack.
local function attribute(victim)
    local parts = {}
    local vloc
    pcall(function() vloc = victim:K2_GetActorLocation() end)
    for _, b in ipairs(FindAllOf("BP_BatEnemy_C") or {}) do
        if alive(b) and vloc then
            local okL, l = pcall(function() return b:K2_GetActorLocation() end)
            if okL then
                local d = math.sqrt((l.X - vloc.X) ^ 2 + (l.Y - vloc.Y) ^ 2 + (l.Z - vloc.Z) ^ 2) / 100
                local okP, phase = pcall(function() return b:GetBatPhase() end)
                parts[#parts + 1] = string.format("bat %s d=%.1fm phase=%s", nameOf(b), d, okP and tostring(phase) or "?")
            end
        end
    end
    local sup = StaticFindObject("/Script/NuclearNightmare.Default__NNInfectedDogSupport")
    for _, d in ipairs(FindAllOf("Dog_Infected_AI_C") or {}) do
        if alive(d) then
            local okA, act = pcall(function() return sup:IsAttackActive(d) end)
            local okV, v = pcall(function() return sup:GetAttackVictim(d) end)
            parts[#parts + 1] = string.format("dog %s active=%s victim=%s", nameOf(d), okA and tostring(act) or "err",
                okV and (valid(v) and nameOf(v) or "none") or "err")
        end
    end
    if #parts > 0 then say("ATTR %s", table.concat(parts, "; ")) end
end

-- The frostbite rule from knob-mechanics.md, with each input.
local function frostRule(victim, amount)
    local t, can, inside, inf, mim
    pcall(function() t = num(victim.Temperature) end)
    pcall(function() can = victim.CanTakeTemperature end)
    pcall(function() inside = victim.InsideEnoughToStopFreezing end)
    pcall(function() inf = victim.Infected end)
    pcall(function() mim = victim["IsMimic?"] end)
    local rule = (amount == 1 or amount == 2) and t ~= nil and t >= 1 and can == true and inside ~= true and inf ~= true
        and mim ~= true and #S.ctx == 0
    return rule, string.format("T=%s can=%s inside=%s infected=%s mimic=%s ctx=%s", fmt1(t), tostring(can), tostring(inside),
        tostring(inf), tostring(mim), ctxText())
end

-- ---------------------------------------------------------------- hooks
local function hook(fn, pre, post)
    if S.hooks[fn] then return true end
    local ok, err = pcall(RegisterHook, fn, pre, post or function() end)
    if ok then S.hooks[fn] = true end
    say("HOOK %s %s%s", fn, ok and "ok" or "FAIL", ok and "" or (" " .. tostring(err)))
    return ok
end

local function damagePre(fn, victim, attacker, amount)
    S.seq = S.seq + 1
    local id = S.seq
    local hp = hpOf(victim)
    say("DMG #%d %s amount=%s attacker=%s victim=%s hp=%s ctx=%s me=%s t=%.3f", id, fn, fmt1(amount), enemyName(attacker),
        valid(victim) and nameOf(victim) or "none", fmt1(hp), ctxText(), tostring(isMe(victim)), os.clock())
    return id, hp
end

-- StartInfectionProcess runs inside the Meek's Attack body right before its Health test (v8.1.3 decompile,
-- SCP_AI_C Label_7982): it shows whether the body runs inside the hooked call and is a second place to set Health.
local function installMarkers()
    hook(FPC_PATH .. ":StartInfectionProcess", function(self)
        local v = get(self)
        local pd = S.pending
        local want = STANDARD[DIFF] + 1
        local hp = hpOf(v)
        local set = false
        if S.case and S.case.flip and isMe(v) and hp and hp ~= want then
            pcall(function() v.Health = want end)
            set = true
            if pd and not pd.saved then pd.saved = hp end
        end
        say("MARK StartInfectionProcess victim=%s hp=%s pending=%s sinceGrab=%.3f set=%s", nameOf(v), fmt1(hp),
            tostring(pd ~= nil), S.grabAt and (os.clock() - S.grabAt) or -1, tostring(set))
    end)
end

local function installNatives()
    installMarkers()
    for _, w in ipairs(WRAPPERS) do
        if w:sub(1, 8) == "/Script/" then
            local short = w:match("([^.]+:[^:]+)$")
            hook(w, function(self) table.insert(S.ctx, short) say("CTX + %s", short) end,
                function() table.remove(S.ctx) say("CTX - %s", short) end)
        end
    end
    -- ApplyLockedDamage(Attacker, DamageAmount): the victim is the attacker's locked victim.
    local lockedId
    hook("/Script/NuclearNightmare.NNEnemyAttackContext:ApplyLockedDamage", function(self, attacker, amount)
        local a, n = get(attacker), num(get(amount))
        local victim
        pcall(function() victim = StaticFindObject("/Script/NuclearNightmare.Default__NNEnemyAttackContext"):GetLockedVictim(a) end)
        lockedId = damagePre("ApplyLockedDamage", victim, a, n)
        table.insert(S.ctx, "Locked:" .. enemyName(a))
        S.nested = S.nested + 1
        compensate(victim, n, "ApplyLockedDamage")
        caseHit(a)
    end, function(self, attacker)
        S.nested = S.nested - 1
        table.remove(S.ctx)
        local m = me()
        say("END #%s ApplyLockedDamage hp=%s", tostring(lockedId), fmt1(m and hpOf(m)))
    end)
    local stalkerId
    hook("/Script/NuclearNightmare.NNEnemyAttackContext:ApplyStalkerDamage", function(self, victim, amount)
        local v, n = get(victim), num(get(amount))
        local src
        pcall(function() src = StaticFindObject("/Script/NuclearNightmare.Default__NNEnemyAttackContext"):GetStalkerPresentationSource(v) end)
        stalkerId = damagePre("ApplyStalkerDamage", v, src, n)
        table.insert(S.ctx, "Stalker:" .. enemyName(src))
        S.nested = S.nested + 1
        compensate(v, n, "ApplyStalkerDamage")
        caseHit(src)
    end, function()
        S.nested = S.nested - 1
        table.remove(S.ctx)
        local m = me()
        say("END #%s ApplyStalkerDamage hp=%s", tostring(stalkerId), fmt1(m and hpOf(m)))
    end)
    local cdeIds = {}
    hook("/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent", function(self, amount)
        local v, n = get(self), num(get(amount))
        local id = damagePre("CallDamageEvent", v, nil, n)
        cdeIds[#cdeIds + 1] = id
        if S.frost then
            local rule, why = frostRule(v, n)
            say("FROST #%d amount=%s rule=%s (%s)", id, fmt1(n), tostring(rule), why)
            if n == 1 or n == 2 then
                S.frostN = (S.frostN or 0) + 1
                if rule then S.frostRule = (S.frostRule or 0) + 1 end
            elseif rule then
                S.frostFalse = (S.frostFalse or 0) + 1
            end
        else
            local rule, why = frostRule(v, n)
            if rule then say("FROSTLIKE #%d outside the cold phase: %s", id, why) end
        end
        attribute(v)
        if S.nested == 0 then
            compensate(v, n, "CallDamageEvent")
            if not frostRule(v, n) then caseHit(nil) end
        else
            say("NESTED #%d CallDamageEvent inside %s: not compensated again", id, ctxText())
        end
    end, function(self)
        local id = table.remove(cdeIds)
        say("END #%s CallDamageEvent hp=%s", tostring(id), fmt1(hpOf(get(self))))
    end)
end

local function installForClass(path)
    for _, g in ipairs(GRABS) do
        if g.fn:sub(1, #path) == path then
            hook(g.fn, function(self, a1, a2)
                local args = { [0] = get(self), get(a1), get(a2) }
                local victim, attacker = args[g.victim], args[g.attacker or 0]
                S.seq = S.seq + 1
                local hp = hpOf(victim)
                g.saved = nil
                local flip = S.case and S.case.flip and isMe(victim)
                if flip then
                    g.saved = hp
                    local want = STANDARD[DIFF] + 1
                    pcall(function() victim.Health = want end)
                end
                say("GRAB #%d %s %s hp=%s flip=%s (set %s) chance=%s", S.seq, enemyName(attacker), g.fn:match(":(.+)$"), fmt1(hp),
                    tostring(flip), flip and tostring(STANDARD[DIFF] + 1) or "-", tostring(g.victim == 0 and args[2] or args[1]))
                g.id, g.victimPath = S.seq, valid(victim) and pathOf(victim) or nil
                if S.case and valid(attacker) and pathOf(attacker) == S.case.actor then S.case.grabs = (S.case.grabs or 0) + 1 end
                S.grabAt, S.grabPath = os.clock(), g.victimPath
                -- The post-hook doesn't run for these multicasts (run 3, 2026-10-31): restore and read the montage on
                -- the runner's next tick instead (up to 250 ms later).
                S.pending = { id = S.seq, victim = g.victimPath, saved = g.saved, fn = g.fn:match(":(.+)$") }
                g.saved = nil
            end, function(self, a1, a2)
                say("GRAB post-hook ran (#%s)", tostring(g.id))
                local args = { [0] = get(self), get(a1), get(a2) }
                local victim = args[g.victim]
                if g.saved then pcall(function() victim.Health = g.saved end) end
                local m = valid(victim) and montageOf(victim) or "?"
                say("GRAB #%d post: hp=%s (restored %s) victim montage=%s", g.id or -1, fmt1(hpOf(victim)), tostring(g.saved ~= nil), m)
                g.saved = nil
                if S.case then S.case.grabs = (S.case.grabs or 0) + 1 end
                S.grabAt, S.grabPath = os.clock(), g.victimPath
            end)
        end
    end
    for _, w in ipairs(WRAPPERS) do
        if w:sub(1, #path) == path then
            local short = w:match("([^.]+:[^:]+)$")
            hook(w, function(self) table.insert(S.ctx, short) say("CTX + %s self=%s", short, nameOf(get(self))) end,
                function() table.remove(S.ctx) say("CTX - %s", short) end)
        end
    end
end

-- ---------------------------------------------------------------- spawning
local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path:gsub("%.[^.]+$", ""))
    c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(function()
        local ar = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        local pkg = path:match("^(.-)%.")
        local data = { PackageName = FName(pkg), AssetName = FName(pkg:match("[^/]+$")) }
        ar:GetAsset(data)
    end)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end

local function spawnerSpawn(cls)
    local sp
    for _, a in ipairs(FindAllOf("AISpawner_C") or {}) do if alive(a) and not pathOf(a):find("Default__", 1, true) then sp = a end end
    if not sp then return nil, "no AISpawner_C" end
    local ok, x = pcall(function() return sp:SpawnValidatedEnemy(cls, 0) end)
    if not (ok and valid(x)) then return nil, "SpawnValidatedEnemy " .. tostring(ok and "returned nothing" or x) end
    pcall(function() local arr = sp.EnemiesSpawned arr[#arr + 1] = x end)
    return x
end

local function spawnInFront(cls)
    local p = me()
    local loc, fwd = p:K2_GetActorLocation(), p:GetActorForwardVector()
    local at = { X = loc.X + fwd.X * SPAWN_DIST, Y = loc.Y + fwd.Y * SPAWN_DIST, Z = loc.Z + 50 }
    -- Facing the player (yaw only), so its sight cone covers them.
    local yaw = math.atan(-fwd.Y, -fwd.X)
    local xf = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local x, why = spawnerSpawn(cls)
    if x then
        local okT = pcall(function() x:K2_SetActorLocationAndRotation(at, { Pitch = 0, Yaw = math.deg(yaw), Roll = 0 }, false, {}, true) end)
        say("VIA SpawnValidatedEnemy, moved in front ok=%s", tostring(okT))
    else
        say("VIA deferred spawn (%s)", tostring(why))
        x = GS():BeginDeferredActorSpawnFromClass(p, cls, xf, 2, nil, 1) -- AdjustIfPossibleButAlwaysSpawn
        if not valid(x) then error("BeginDeferredActorSpawnFromClass returned no actor") end
        GS():FinishSpawningActor(x, xf, 1)
    end
    local okC, ctl = pcall(function() return x:GetController() end)
    if not (okC and valid(ctl)) then pcall(function() x:SpawnDefaultController() end) end
    okC, ctl = pcall(function() return x:GetController() end)
    -- Enemies the spawner didn't make may stay dormant: wake it the way the spawner's dormancy pass does.
    local okW, errW = pcall(function() x:ActivateDormancyServer(true) end)
    say("WAKE %s ActivateDormancyServer(true) ok=%s %s", nameOf(x), tostring(okW), okW and "" or tostring(errW))
    return x, okC and valid(ctl) and classOf(ctl) or "none"
end

-- ---------------------------------------------------------------- steps
local seq = 0
local function request(cmd)
    seq = seq + 1
    local f = io.open(REQ, "w"); f:write(seq .. " " .. cmd); f:close()
    local mine = seq
    return function()
        local d = io.open(DONE, "r"); if not d then return false end
        local s = d:read("*a"); d:close(); return tonumber(s) == mine
    end
end
local function after(sec) local t = os.clock() + sec return function() return os.clock() >= t end end
local steps = {}
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end

step("menu", function() return function() return worldName():find("NewMainMenu", 1, true) ~= nil end, 240, "menu world" end)
step("difficulty in the game instance", function()
    for _, gi in ipairs(FindAllOf("BP_GameInstance_C") or {}) do
        if valid(gi) and not pathOf(gi):find("Default__", 1, true) then
            local ok = pcall(function() gi.Diffculty = DIFF end)
            say("GI Diffculty=%d set=%s", DIFF, tostring(ok))
        end
    end
    return after(2), 5
end)
step("travel", function()
    say("TRAVEL OpenLevel %s?listen", MATCH_MAP)
    GS():OpenLevel(pc(), FName(MATCH_MAP), true, "listen")
    return after(3), 5
end)
step("match world", function() return function() return worldName():find("SmallMap", 1, true) ~= nil end, 150, "match world" end)
step("touchdown", function() say("TOUCHDOWN requesting Enter") return request("key ENTER"), 20, "touchdown key" end)
step("pawn", function()
    local t0
    return function()
        if not me() then t0 = nil return false end
        t0 = t0 or os.clock()
        return os.clock() - t0 > 20 -- past the landing showcase
    end, 120, "first-person pawn"
end)
step("difficulty in the match", function()
    local g = gameState()
    local okD, d = pcall(function() return g.Diffculty end)
    say("GS Diffculty=%s", okD and tostring(d) or "?")
    if not (okD and num(d) == DIFF) then
        local ok = pcall(function() g.Diffculty = DIFF end)
        say("GS Diffculty forced to %d ok=%s (test only)", DIFF, tostring(ok))
    end
    local p = me()
    say("PLAYER %s hp=%s T=%s", pathOf(p), fmt1(hpOf(p)), fmt1(num(p.Temperature)))
    installNatives()
    installForClass(FPC_PATH)
    return after(1), 3
end)

local function runCase(c)
    if c.frost then
        step("frostbite", function()
            S.frost, S.frostN, S.frostRule = true, 0, 0
            say("PHASE frostbite: Temperature held at 1.5 for 75 s")
            local t = os.clock()
            return function()
                local p = me()
                if p then
                    pcall(function() p.Temperature = 1.5 end)
                    for short in pairs(ENEMY_OF) do
                        for _, e in ipairs(FindAllOf(short) or {}) do
                            if alive(e) and not pathOf(e):find("Default__", 1, true) then
                                say("CLEAR natural %s %s", enemyName(e), nameOf(e))
                                pcall(function() e:K2_DestroyActor() end)
                            end
                        end
                    end
                    local hp = hpOf(p)
                    if hp and hp < 30 then pcall(function() p.Health = 100 end) say("REFILL hp %.2f -> 100", hp) end
                end
                if os.clock() - t < 75 then return false end
                S.frost = false
                pcall(function() p.Temperature = 0 end)
                check(S.frostN > 0, "FROST calls=%d matching the rule=%d", S.frostN, S.frostRule)
                check(S.frostN == S.frostRule and (S.frostFalse or 0) == 0, "FROST every 1-2 HP cold-phase call matched the rule (%d of %d), other amounts matching: %d", S.frostRule, S.frostN, S.frostFalse or 0)
                return true
            end, 90, "frostbite phase"
        end)
        return
    end
    local label = c.name .. (c.flip and " (flip)" or "")
    step("spawn " .. label, function()
        local p = me()
        if not p then S.dead = true return end
        pcall(function() p.Health = 100 end)
        local cls = loadClass(c.path)
        if not check(cls ~= nil, "CLASS %s %s", label, c.path) then return end
        installForClass(c.path:match("^[^:]+"))
        c.hits, c.grabs = 0, 0
        S.case = c
        local okS, x, ctl = pcall(spawnInFront, cls)
        if not check(okS and valid(x), "SPAWN %s %s controller=%s", label, okS and pathOf(x) or tostring(x), tostring(ctl)) then S.case = nil return end
        c.actor = pathOf(x)
        local t = os.clock()
        return function()
            local m = me()
            if not m then S.dead = true return true end
            if os.clock() - (c.clearAt or 0) >= 2 then
                c.clearAt = os.clock()
                for short in pairs(ENEMY_OF) do
                    for _, e in ipairs(FindAllOf(short) or {}) do
                        if alive(e) and pathOf(e) ~= c.actor and not pathOf(e):find("Default__", 1, true) then
                            say("CLEAR natural %s %s", enemyName(e), nameOf(e))
                            pcall(function() e:K2_DestroyActor() end)
                        end
                    end
                end
            end
            local hp = hpOf(m)
            if hp and hp < 30 and not S.grabAt then pcall(function() m.Health = 100 end) say("REFILL hp %.2f -> 100", hp) end
            -- After an execution the probe kept the player in, run the game's enemy-died recovery 6 s in.
            if S.grabAt and os.clock() - S.grabAt > 6 then
                S.grabAt = nil
                local playing = false
                pcall(function() playing = m.PlayingMontage end)
                local mode
                pcall(function() mode = m.CharacterMovement.MovementMode end)
                say("AFTERGRAB 6 s: montage=%s PlayingMontage=%s movement=%s hp=%s", montageOf(m), tostring(playing), tostring(mode), fmt1(hpOf(m)))
                if playing == true or tostring(mode) == "0" then
                    local okR, err = pcall(function()
                        local cur = m:GetCurrentMontage()
                        if valid(cur) then m:StopAnimMontage(cur) end
                        m.PlayingMontage = false
                        m.CharacterMovement:SetMovementMode(1, 0)
                    end)
                    pcall(function() mode = m.CharacterMovement.MovementMode end)
                    say("RECOVER ok=%s %s movement=%s", tostring(okR), okR and "" or tostring(err), tostring(mode))
                end
                if hp and hp < 30 then pcall(function() m.Health = 100 end) end
            end
            if os.clock() - (c.diagAt or 0) >= 10 then
                c.diagAt = os.clock()
                local x = c.actor and StaticFindObject(c.actor)
                -- Tell it about the player through its own sight event (the one its PawnSensing handler calls).
                if valid(x) and c.hits == 0 then
                    local tried = {}
                    for _, fn in ipairs({ "SeePlayerServer", "SeeCharacter", "SeePlayer" }) do
                        local okF, err = pcall(function() x[fn](x, m) end)
                        tried[#tried + 1] = fn .. "=" .. (okF and "ok" or "no")
                        if okF then break end
                    end
                    local okN = pcall(function() x:FindNewTarget() end)
                    tried[#tried + 1] = "FindNewTarget=" .. (okN and "ok" or "no")
                    local okE, el = pcall(function() return StaticFindObject("/Script/NuclearNightmare.Default__NNEnemyTargetEligibility"):IsEligibleStimulusSource(m) end)
                    say("SEE %s %s; player eligible=%s", label, table.concat(tried, " "), okE and tostring(el) or "err")
                end
                if valid(x) then
                    local d, dorm, v, ctl, brain = "?", "?", "?", "none", "?"
                    pcall(function() local a, b = x:K2_GetActorLocation(), m:K2_GetActorLocation()
                        d = string.format("%.1f m dz=%.1f", math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) / 100, (a.Z - b.Z) / 100) end)
                    pcall(function() dorm = tostring(x.DormancyState) end)
                    pcall(function() local vv = x:GetVelocity() v = string.format("%.0f", math.sqrt(vv.X ^ 2 + vv.Y ^ 2 + vv.Z ^ 2)) end)
                    pcall(function() local cc = x:GetController() if valid(cc) then ctl = classOf(cc) brain = valid(cc.BrainComponent) and classOf(cc.BrainComponent) or "none" end end)
                    say("DIAG %s dist=%s dormancy=%s speed=%s controller=%s brain=%s hp=%s", label, d, dorm, v, ctl, brain, fmt1(hpOf(m)))
                else
                    say("DIAG %s actor gone", label)
                end
            end
            local done = c.grab and c.grabs >= 1 and c.hits >= 1 or (not c.grab and c.hits >= 2)
            if done and not S.grabAt then return true end
            if os.clock() - t > 90 then say("TIMEOUT %s hits=%d grabs=%d", label, c.hits, c.grabs or 0) return true end
            return false
        end, 100, label
    end)
    step("despawn " .. label, function()
        if S.dead then return end
        say("CASE %s hits=%d grabs=%d", label, c.hits or 0, c.grabs or 0)
        S.case = nil
        local x = c.actor and StaticFindObject(c.actor)
        if valid(x) then pcall(function() x:K2_DestroyActor() end) end
        local p = me()
        if p then pcall(function() p.Health = 100 end) end
        return after(5), 8
    end)
end
for _, c in ipairs(CASES) do runCase(c) end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    say("END result=%s checks=%d failures=%d dead=%s", (S.failures == 0 and S.checks > 0) and "PASS" or "FAIL", S.checks, S.failures, tostring(S.dead))
end
local function tick()
    if busy or finished then return end
    busy = true
    local ok, err = pcall(function()
        if S.dead then say("DEATH the player died (case %s)", S.case and S.case.name or "-") finish() return end
        local pd = S.pending
        if pd then
            S.pending = nil
            local v = pd.victim and StaticFindObject(pd.victim)
            if valid(v) then
                local hpNow = hpOf(v)
                if pd.saved then pcall(function() v.Health = pd.saved end) end
                say("GRAB #%d next tick: hp was %s, restored to %s; victim montage=%s", pd.id, fmt1(hpNow), pd.saved and fmt1(pd.saved) or "-", montageOf(v))
            end
        end
        if waiting then
            if not waiting.pred() then
                if os.clock() <= waiting.deadline then return end
                check(false, "TIMEOUT %s", waiting.what)
            end
            waiting = nil
        end
        idx = idx + 1
        local s = steps[idx]
        if not s then finish() return end
        say("STEP %s", s.name)
        local pred, timeout, what = s.fn()
        if pred then waiting = { pred = pred, deadline = os.clock() + (timeout or 10), what = what or s.name } end
    end)
    if not ok then
        check(false, "STEP '%s' threw: %s", steps[idx] and steps[idx].name or "?", tostring(err))
        waiting = nil
    end
    busy = false
end
local runner
local okL, res = pcall(LoopInGameThreadWithDelay, 250, function()
    tick()
    if finished and runner then pcall(CancelDelayedAction, runner); runner = nil end
end)
if okL then runner = res else say("END result=FAIL checks=0 failures=1 reason=loop %s", tostring(res)) end
say("LOADED %d steps", #steps)
