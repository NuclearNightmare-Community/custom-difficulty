-- DifficultyDriver: Difficulty's in-game test driver for story 3 (spec-difficulty-v1, enemy damage and survivable
-- grabs). Installed only by deploy.ps1 -Test -Scenario, never shipped; Difficulty carries no test code. Plain UE4SS
-- Lua (no core); the spawn and match code is adapted from test/DifficultyProbe. It can't reach Difficulty's Lua state,
-- so it judges Difficulty by the world: the local player's Health after each enemy hit (refilled to 100 before every
-- case, test-only and logged), the grab montage and whether the player moves again. check.ps1 reads both Difficulty's
-- lines (HIT, GRAB, RESTORE, WARN clash) and these.
--
-- mods.txt order (deploy.ps1): Nucleus, DifficultyDriver, Difficulty. Scenario (Scripts/scenario.txt, one per
-- launch; the knobs are deploy.ps1's, in Difficulty's dev.lua):
--   scaled     Hard, Enemy Damage 17: a Meek hit at 100 HP takes 17.
--   flip       Nightmare, Enemy Damage 25: a Meek grab at 100 HP plays the survivable montage, takes 25 (about 75 HP
--              left), and the player moves again within 6 s.
--   per-enemy  Normal, Stalker 200%: a Stalker hit takes 50, a Meek hit 25.
--   default    Hard, no knobs: a Meek hit takes the game's 50 (Difficulty logs no HIT line).
--   clash      Hard, Enemy Damage 17, and this driver's own CallDamageEvent pre-hook adds 5 HP to every hit: the
--              first hit takes 12 (17 - 5; Difficulty logs one WARN and backs off), the next one the stock 45 (50 - 5).
-- Lines: OK / FAIL <check>; NOTSHOWN <case> (the enemy didn't attack in time: not a pass); END result=PASS|FAIL|NOTSHOWN.
-- Keys it can't press itself (Enter for touchdown) go to run.ps1 through request.txt / done.txt next to this file.
-- Never keeps a UObject across steps: paths only, re-found each step.
local ME = "DifficultyDriver"
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local SCENARIO
do
    local f = io.open(scriptDir .. "\\scenario.txt", "r")
    if f then SCENARIO = (f:read("*a") or ""):match("^%s*([%a%-]+)") f:close() end
end
local MEEK = { name = "Meek", path = "/Game/AI/SCP_AI.SCP_AI_C" }
local STALKER = { name = "Stalker", path = "/Game/AI/Stalker_AI.Stalker_AI_C" }
-- Per scenario: the match difficulty and the cases, each with the HP the first hit should take (want) and the
-- tolerance (tol).
local SCENARIOS = {
    ["scaled"] = { diff = 1, cases = { { enemy = MEEK, want = 17, tol = 0.05 } } },
    ["flip"] = { diff = 0, cases = { { enemy = MEEK, want = 25, tol = 0.05, survivable = "StabStomach", moves = true } } },
    ["per-enemy"] = { diff = 2, cases = { { enemy = STALKER, want = 50, tol = 0.05 }, { enemy = MEEK, want = 25, tol = 0.05 } } },
    ["default"] = { diff = 1, cases = { { enemy = MEEK, want = 50, tol = 0.05 } } },
    ["clash"] = { diff = 1, clash = 5, cases = { { enemy = MEEK, want = 12, tol = 0.05 }, { enemy = MEEK, want = 45, tol = 0.05 } } },
}
local SC = SCENARIOS[SCENARIO or ""]
say("SCENARIO %s", tostring(SCENARIO))
if not SC then say("END result=FAIL checks=0 failures=1 reason=unknown scenario '%s'", tostring(SCENARIO)) return end

local REQ, DONE = scriptDir .. "\\request.txt", scriptDir .. "\\done.txt"
os.remove(REQ); os.remove(DONE)

local MATCH_MAP = "/Game/Maps/SmallLoweIsland/SmallMap"
local FP = "BP_FirstPersonCharacter_C"
local SPAWN_DIST = 700
local ENEMY_SHORTS = { "SCP_AI_C", "Mimic_AI_C", "MadPatent_AI_C", "FastLearner_AI_C", "EyeMonster_AI_C", "Stalker_AI_C",
                       "SlugQueen_AI_C", "ApexPredatorAI_C", "Worm_AI_C", "BabyWorm_AI_C", "BP_BatEnemy_C", "Dog_Infected_AI_C" }

local S = { checks = 0, failures = 0, notShown = 0, hooks = {}, case = nil, dead = false, nested = 0 }

-- ---------------------------------------------------------------- helpers
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
    return ok and r == true
end
local function notDefault(o) return valid(o) and not pathOf(o):find("Default__", 1, true) end
local function num(v) return type(v) == "number" and v or tonumber(tostring(v)) end
local function fmt1(v) return v and string.format("%.2f", v) or "?" end
local function get(p) if p == nil then return nil end local ok, v = pcall(function() return p:get() end) return ok and v or nil end
local function hpOf(ch) local ok, h = pcall(function() return ch.Health end) return ok and num(h) or nil end
local function montageOf(ch)
    local ok, m = pcall(function() return ch:GetCurrentMontage() end)
    return ok and valid(m) and nameOf(m) or "none"
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
local function me()
    local c = pc()
    if not c then return nil end
    local ok, p = pcall(function() return c:K2_GetPawn() end)
    return ok and valid(p) and classOf(p) == FP and p or nil
end
local function isMe(ch) local m = me() return m ~= nil and valid(ch) and pathOf(ch) == pathOf(m) end
local function worldName() local c = pc() local ok, n = pcall(function() return c:GetWorld():GetFullName() end) return ok and n or "" end
local function gameState()
    for _, g in ipairs(FindAllOf("BP_FirstPersonGameState_C") or {}) do if notDefault(g) then return g end end
    return nil
end
local lostAt
local function gone()
    if me() then lostAt = nil return false end
    lostAt = lostAt or os.clock()
    return os.clock() - lostAt > 3
end
-- Test-only Health refill (logged), never while a grab may be in progress.
local function refill(why)
    local m = me()
    if not m then return end
    local hp = hpOf(m)
    if hp and math.abs(hp - 100) > 0.001 then pcall(function() m.Health = 100 end) say("REFILL hp %s -> 100 (%s, test only)", fmt1(hp), why) end
end

-- ---------------------------------------------------------------- hooks (natives: always loaded)
local function hook(fn, pre, post)
    if S.hooks[fn] then return true end
    local ok, err = pcall(RegisterHook, fn, function(...) local okB, e = pcall(pre, ...) if not okB then say("HOOKERR %s %s", fn, tostring(e)) end end,
        function(...) if post then local okB, e = pcall(post, ...) if not okB then say("HOOKERR %s post %s", fn, tostring(e)) end end end)
    if ok then S.hooks[fn] = true end
    say("HOOK %s %s%s", fn, ok and "ok" or "FAIL", ok and "" or (" " .. tostring(err)))
    return ok
end

-- A hit on the local player from the case's enemy: the first one is judged (Health read after the native).
local function onHit(via, attacker)
    local c = S.case
    if not c or c.judged or S.nested > 1 then return end
    if attacker and c.actor and pathOf(attacker) ~= c.actor then say("OTHER hit from %s during %s (not judged)", classOf(attacker), c.label) return end
    local m = me()
    local hp = m and hpOf(m)
    c.judged = true
    c.hitAt = os.clock()
    local loss = hp and (100 - hp) or nil
    check(loss ~= nil and math.abs(loss - c.want) <= c.tol, "%s %s hit took %s HP (want %s) via %s, hp now %s", SCENARIO, c.label, fmt1(loss), fmt1(c.want), via, fmt1(hp))
end

local function installHooks()
    local CTX = "/Script/NuclearNightmare.Default__NNEnemyAttackContext"
    hook("/Script/NuclearNightmare.NNEnemyAttackContext:ApplyLockedDamage", function(_, attacker)
        S.nested = S.nested + 1
        local a = get(attacker)
        local v
        pcall(function() v = StaticFindObject(CTX):GetLockedVictim(a) end)
        S.lockedMine = isMe(v)
        S.lockedAttackerPath = S.lockedMine and valid(a) and pathOf(a) or nil
    end, function()
        S.nested = S.nested - 1
        if S.lockedMine then
            S.lockedMine = false
            local c = S.case
            if c and not c.judged and c.actor and S.lockedAttackerPath == c.actor then onHit("ApplyLockedDamage", nil) end
        end
    end)
    hook("/Script/NuclearNightmare.NNEnemyAttackContext:ApplyStalkerDamage", function(_, victim)
        S.nested = S.nested + 1
        S.stalkerMine = isMe(get(victim))
    end, function()
        S.nested = S.nested - 1
        if S.stalkerMine then S.stalkerMine = false onHit("ApplyStalkerDamage", nil) end
    end)
    -- clash: this driver's own pre-hook changes Health on every enemy hit (as another mod might).
    hook("/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent", function(selfp, amount)
        local v, n = get(selfp), num(get(amount))
        if SC.clash and isMe(v) and n and n > 2 and S.case then
            local hp = hpOf(v)
            pcall(function() v.Health = hp + SC.clash end)
            say("CLASH +%s HP before CallDamageEvent(%s): hp %s -> %s (test only)", fmt1(SC.clash), fmt1(n), fmt1(hp), fmt1(hp + SC.clash))
        end
    end)
end

-- The Meek's grab multicast (after the body): the montage it picked on the victim.
local function installGrabHook(path)
    if path ~= MEEK.path then return end
    hook(MEEK.path .. ":Attack", function(_, _, character)
        local v = get(character)
        local c = S.case
        if not c or not isMe(v) then return end
        c.grabs = (c.grabs or 0) + 1
        if c.grabs == 1 then
            c.grabAt = os.clock()
            local m = montageOf(v)
            say("GRABSEEN %s montage=%s hp=%s", c.label, m, fmt1(hpOf(v)))
            if c.survivable then check(m:find(c.survivable, 1, true) ~= nil, "%s %s grab played the survivable montage (%s; want *%s*)", SCENARIO, c.label, m, c.survivable) end
        end
    end)
end

-- ---------------------------------------------------------------- spawning (from DifficultyProbe)
local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path:gsub("%.[^.]+$", ""))
    c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(function()
        local ar = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        local pkg = path:match("^(.-)%.")
        ar:GetAsset({ PackageName = FName(pkg), AssetName = FName(pkg:match("[^/]+$")) })
    end)
    c = StaticFindObject(path)
    return valid(c) and c or nil
end
local function spawnInFront(cls)
    local p = me()
    local loc, fwd = p:K2_GetActorLocation(), p:GetActorForwardVector()
    local at = { X = loc.X + fwd.X * SPAWN_DIST, Y = loc.Y + fwd.Y * SPAWN_DIST, Z = loc.Z + 50 }
    local yaw = math.atan(-fwd.Y, -fwd.X)
    local x
    local sp
    for _, a in ipairs(FindAllOf("AISpawner_C") or {}) do if alive(a) and notDefault(a) then sp = a end end
    if sp then
        local ok, r = pcall(function() return sp:SpawnValidatedEnemy(cls, 0) end)
        if ok and valid(r) then
            x = r
            pcall(function() local arr = sp.EnemiesSpawned arr[#arr + 1] = x end)
            pcall(function() x:K2_SetActorLocationAndRotation(at, { Pitch = 0, Yaw = math.deg(yaw), Roll = 0 }, false, {}, true) end)
        end
    end
    if not x then
        local xf = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
        x = GS():BeginDeferredActorSpawnFromClass(p, cls, xf, 2, nil, 1)
        if not valid(x) then error("BeginDeferredActorSpawnFromClass returned no actor") end
        GS():FinishSpawningActor(x, xf, 1)
    end
    local okC, ctl = pcall(function() return x:GetController() end)
    if not (okC and valid(ctl)) then pcall(function() x:SpawnDefaultController() end) end
    pcall(function() x:ActivateDormancyServer(true) end)
    return x
end
local function clearOthers(keep)
    for _, short in ipairs(ENEMY_SHORTS) do
        for _, e in ipairs(FindAllOf(short) or {}) do
            if notDefault(e) and alive(e) and pathOf(e) ~= keep then
                say("CLEAR natural %s %s", short, nameOf(e))
                pcall(function() e:K2_DestroyActor() end)
            end
        end
    end
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
        if notDefault(gi) then
            local ok = pcall(function() gi.Diffculty = SC.diff end)
            local okL = pcall(function() gi.LobbyMins = 0 end)
            say("GI Diffculty=%d set=%s LobbyMins=0 set=%s", SC.diff, tostring(ok), tostring(okL))
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
        return os.clock() - t0 > 20
    end, 120, "first-person pawn"
end)
-- The lobby countdown ends (UpdateFriendlyFire: Difficulty's match start) with the scenario's Diffculty. Shortened
-- on the host, test only. The driver never writes Diffculty itself.
step("match start", function()
    local g = gameState()
    pcall(function() if num(g.LobbyMinutes) == 0 and num(g.LobbySeconds) > 5 then g.LobbySeconds = 5 say("LOBBY seconds -> 5 (test only)") end end)
    return function()
        local gs = gameState()
        local okS, started = pcall(function() return gs["StartedGame?"] end)
        local okD, d = pcall(function() return num(gs.Diffculty) end)
        if okS and started == true and okD and d == SC.diff then say("STARTED Diffculty=%s", tostring(d)) return true end
        return false
    end, 150, "match start (StartedGame? with Diffculty " .. SC.diff .. ")"
end)
step("set-up", function()
    for _, sky in ipairs(FindAllOf("Ultra_Dynamic_Sky_C") or {}) do
        if notDefault(sky) then pcall(function() sky["Animate Time of Day"] = false end) end
    end
    installHooks()
    return after(3), 5
end)

for i, c in ipairs(SC.cases) do
    c.label = ("%s #%d"):format(c.enemy.name, i)
    step("spawn " .. c.label, function()
        local p = me()
        if not p then if gone() then S.dead = true end return end
        clearOthers(nil)
        refill("before " .. c.label)
        local cls = loadClass(c.enemy.path)
        if not check(cls ~= nil, "CLASS %s %s", c.label, c.enemy.path) then return end
        installGrabHook(c.enemy.path)
        S.case = c
        local okS, x = pcall(spawnInFront, cls)
        if not check(okS and valid(x), "SPAWN %s %s", c.label, okS and pathOf(x) or tostring(x)) then S.case = nil return end
        c.actor = pathOf(x)
        local t = os.clock()
        return function()
            local m = me()
            if not m then if gone() then S.dead = true return true end return false end
            pcall(function() m.Temperature = 0 end) -- no frostbite during the cases (test only)
            if os.clock() - (c.clearAt or 0) >= 2 then c.clearAt = os.clock() clearOthers(c.actor) end
            if os.clock() - (c.pokeAt or 0) >= 10 and not c.judged then
                c.pokeAt = os.clock()
                local x2 = StaticFindObject(c.actor)
                if valid(x2) then
                    for _, fn in ipairs({ "SeePlayerServer", "SeeCharacter", "SeePlayer" }) do
                        if pcall(function() x2[fn](x2, m) end) then break end
                    end
                    pcall(function() x2:FindNewTarget() end)
                end
            end
            -- flip: 6 s after the grab, the player must be free (no montage, walking).
            if c.moves and c.grabAt and not c.moveChecked and os.clock() - c.grabAt >= 6 then
                c.moveChecked = true
                local playing, mode
                pcall(function() playing = m.PlayingMontage end)
                pcall(function() mode = num(m.CharacterMovement.MovementMode) end)
                check(playing ~= true and mode == 1, "%s %s moving again 6 s after the grab (PlayingMontage=%s movement=%s montage=%s hp=%s)", SCENARIO, c.label, tostring(playing), tostring(mode), montageOf(m), fmt1(hpOf(m)))
            end
            local done = c.judged and (not c.moves or c.moveChecked) and (not c.survivable or c.grabs)
            if done then return true end
            if os.clock() - t > 120 then return true end
            return false
        end, 130, c.label
    end)
    step("despawn " .. c.label, function()
        if S.dead then return end
        if not c.judged then S.notShown = S.notShown + 1 say("NOTSHOWN %s: the %s didn't hit in 120 s", c.label, c.enemy.name)
        elseif c.survivable and not c.grabs then S.notShown = S.notShown + 1 say("NOTSHOWN %s: no grab seen", c.label) end
        S.case = nil
        local x = c.actor and StaticFindObject(c.actor)
        if valid(x) then pcall(function() x:K2_DestroyActor() end) end
        return after(4), 6
    end)
    step("refill after " .. c.label, function() refill("after " .. c.label) return after(1), 3 end)
end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    local result = (S.failures > 0 or S.checks == 0 or S.dead) and "FAIL" or (S.notShown > 0 and "NOTSHOWN" or "PASS")
    say("END result=%s checks=%d failures=%d notshown=%d dead=%s", result, S.checks, S.failures, S.notShown, tostring(S.dead))
end
local function tick()
    if busy or finished then return end
    busy = true
    local ok, err = pcall(function()
        if S.dead then say("DEATH the player died (case %s)", S.case and S.case.label or "-") finish() return end
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
say("LOADED scenario=%s %d steps", SCENARIO, #steps)
