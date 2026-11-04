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
-- Story 4 (cold, frostbite, reinforcement tokens; no enemy cases, natural enemies cleared every 2 s):
--   cold            Nightmare, Cold Exposure 50: Temperature set to 0 once (a lowering: a raise would be scaled like
--                   cooling), then 60 s outdoors; the rise must be a quarter of Nightmare's stock range (60 s / 600..310
--                   per s, +-10%). Difficulty's COLD line has the exact ratio (check.ps1).
--   cold-zero       Cold Exposure 0: Temperature stays at its start (0) outdoors for 60 s.
--   frostbite       Frostbite 3, cold Default: Temperature held at 1.5 (raising it is fine: cold is Default); Health
--                   loss over 20 s = 60 +-10%.
--   frostbite-zero  Frostbite 0: no Health loss over 20 s while frozen.
--   tokens-more     Classified Minium 0 (limit 2), N 4: the computer's text shows 4; four reinforcements accepted,
--                   then Disable Reinforcement set (and not before).
--   tokens-fewer    Classified Minium 3 (limit 8), N 2: after two, Disable set and the text shows 0.
--   A reinforcement is the synthetic revive (the game state's UpdateRespawnQue + the radio's ReinforceSpecficPlayer
--   on the living host, as test/MarkersDriver did on V8.1.2); if the count doesn't move in 15 s, the radio's
--   SpawnReinforcmentSpectator() (which has no gate), destroying the orphan character it spawns. The token text is
--   read from a NukeComputer_UI_C widget made with WidgetBlueprintLibrary:Create and never added to the viewport.
-- Lines: OK / FAIL <check>; NOTSHOWN <case> (the driver couldn't make the case happen: not a pass);
-- END result=PASS|FAIL|NOTSHOWN.
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
    -- Story 4: one special phase each (cases stay empty).
    ["cold"] = { diff = 0, special = "cold", factor = 0.25, cases = {} },
    ["cold-zero"] = { diff = 0, special = "cold", factor = 0, cases = {} },
    ["frostbite"] = { diff = 2, special = "frost", want = 60, tol = 6, cases = {} },
    ["frostbite-zero"] = { diff = 2, special = "frost", want = 0, tol = 0.05, cases = {} },
    ["tokens-more"] = { diff = 2, special = "tokens", cm = 0, limit = 2, n = 4, cases = {} },
    ["tokens-fewer"] = { diff = 2, special = "tokens", cm = 3, limit = 8, n = 2, cases = {} },
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
    -- clash: this driver's own pre-hook changes Health on every enemy hit (as another mod might). frostbite: counts
    -- the 1-2 HP calls on the local player while the frostbite window is open.
    hook("/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent", function(selfp, amount)
        local v, n = get(selfp), num(get(amount))
        if S.frostOn and (n == 1 or n == 2) and isMe(v) then S.frostCalls = (S.frostCalls or 0) + 1 end
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
            if SC.cm then
                local okC = pcall(function() gi["Minium Classified"] = SC.cm end)
                say("GI Minium Classified=%d set=%s", SC.cm, tostring(okC))
            end
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

-- ---------------------------------------------------------------- story 4 phases
local COLD_SECONDS, FROST_LEAD, FROST_SECONDS = 60, 3, 20
local STOCK_COOL_SLOW, STOCK_COOL_FAST = 600, 310 -- s per full meter on Nightmare (knob-mechanics.md "Cooling")
local NUKE_UI = "/Game/Graphics/Computer/NukeComputer_UI.NukeComputer_UI_C"
local function readBool(o, k) local ok, v = pcall(function() return o[k] end) if ok then return v end return nil end
local function temperatureOf(ch) local ok, t = pcall(function() return num(ch.Temperature) end) return ok and t or nil end
-- Natural enemies are cleared every 2 s during a phase (no enemy case runs in story 4).
local function keepClear(st) if os.clock() - (st.clearAt or 0) >= 2 then st.clearAt = os.clock() clearOthers(nil) end end

if SC.special == "cold" then
    local P = { }
    step("cold", function()
        local m = me()
        if not m then if gone() then S.dead = true end return end
        pcall(function() m.Temperature = 0 end) -- a lowering only (test only): the poll leaves falls alone
        local t = temperatureOf(m)
        if not check(t ~= nil, "%s Temperature readable (%s)", SCENARIO, tostring(t)) then return end
        P.t0, P.start, P.max, P.last, P.samples, P.outside, P.path = os.clock(), t, t, t, 0, 0, pathOf(m)
        say("COLDRUN start Temperature=0 (test only), %d s outdoors, factor %s", COLD_SECONDS, tostring(SC.factor))
        return function()
            local p = me()
            if not p then if gone() then S.dead = true return true end return false end
            keepClear(P)
            if pathOf(p) ~= P.path then P.changed = true end
            local t = temperatureOf(p)
            P.samples = P.samples + 1
            if t then P.last = t if t > P.max then P.max = t end end
            if readBool(p, "IsInInside") == true or readBool(p, "InsideEnoughToStopFreezing") == true or readBool(p, "CanTakeTemperature") ~= true then
                P.outside = P.outside + 1
            end
            return os.clock() - P.t0 >= COLD_SECONDS
        end, COLD_SECONDS + 15, "cold phase"
    end)
    step("cold verdict", function()
        if S.dead or not P.t0 then return end
        local secs = os.clock() - P.t0
        local rise = P.last - P.start
        say("COLDRUN end seconds=%.1f start=%.4f end=%.4f max=%.4f rise=%.4f samples=%d indoors_or_vehicle=%d pawn_changed=%s",
            secs, P.start, P.last, P.max, rise, P.samples, P.outside, tostring(P.changed == true))
        if P.outside > 0 or P.changed then
            S.notShown = S.notShown + 1
            say("NOTSHOWN cold: the player was not outdoors on foot throughout (%d of %d samples; pawn changed %s)", P.outside, P.samples, tostring(P.changed == true))
            return
        end
        if SC.factor == 0 then
            check(P.max <= 0.005, "%s Temperature stayed at its start outdoors for %.0f s (max %.4f, want <= 0.005)", SCENARIO, secs, P.max)
            return
        end
        if rise <= 0.0005 then
            S.notShown = S.notShown + 1
            say("NOTSHOWN cold: Temperature didn't rise in %.0f s (rise %.4f): no cooling here", secs, rise)
            return
        end
        -- A quarter of Nightmare's stock range for this time, +-10% (the weather sets where in the range).
        local lo, hi = secs * SC.factor / STOCK_COOL_SLOW * 0.9, secs * SC.factor / STOCK_COOL_FAST * 1.1
        check(rise >= lo and rise <= hi, "%s rise %.4f in %.0f s within a quarter of Nightmare's stock (%.4f..%.4f)", SCENARIO, rise, secs, lo, hi)
    end)
elseif SC.special == "frost" then
    local P = {}
    step("frostbite", function()
        local m = me()
        if not m then if gone() then S.dead = true end return end
        if not check(temperatureOf(m) ~= nil and hpOf(m) ~= nil, "%s Temperature and Health readable", SCENARIO) then return end
        P.t0, P.path, P.phase = os.clock(), pathOf(m), "lead"
        say("FROSTRUN Temperature held at 1.5 (test only; cold is Default), %d s lead, then %d s", FROST_LEAD, FROST_SECONDS)
        return function()
            local p = me()
            if not p then if gone() then S.dead = true return true end return false end
            keepClear(P)
            pcall(function() p.Temperature = 1.5 end)
            if pathOf(p) ~= P.path then P.changed = true end
            if readBool(p, "InsideEnoughToStopFreezing") == true or readBool(p, "CanTakeTemperature") ~= true then P.outside = (P.outside or 0) + 1 end
            if P.phase == "lead" and os.clock() - P.t0 >= FROST_LEAD then
                refill("frostbite window start")
                P.phase, P.t1, P.hp0 = "window", os.clock(), hpOf(p)
                S.frostOn, S.frostCalls = true, 0
                return false
            end
            if P.phase == "window" and os.clock() - P.t1 >= FROST_SECONDS then
                S.frostOn = false
                P.hp1, P.secs = hpOf(p), os.clock() - P.t1
                return true
            end
            return false
        end, FROST_LEAD + FROST_SECONDS + 15, "frostbite phase"
    end)
    step("frostbite verdict", function()
        S.frostOn = false
        local m = me()
        if m then pcall(function() m.Temperature = 0 end) end -- a lowering: the frost ends (test only)
        if S.dead or not P.t0 then return end
        local loss = (P.hp0 and P.hp1) and (P.hp0 - P.hp1) or nil
        say("FROSTRUN end seconds=%.1f calls=%d hp %s -> %s loss=%s outside_gates=%d pawn_changed=%s", P.secs or 0, S.frostCalls or 0,
            fmt1(P.hp0), fmt1(P.hp1), fmt1(loss), P.outside or 0, tostring(P.changed == true))
        if (S.frostCalls or 0) == 0 or P.changed then
            S.notShown = S.notShown + 1
            say("NOTSHOWN frostbite: no frostbite tick on the player in %d s (calls %d; inside, a vehicle or a new pawn)", FROST_SECONDS, S.frostCalls or 0)
            return
        end
        check(loss ~= nil and math.abs(loss - SC.want) <= SC.tol, "%s lost %s HP in %.0f s while frozen (want %s +- %s; %d ticks)", SCENARIO,
            fmt1(loss), P.secs or 0, fmt1(SC.want), fmt1(SC.tol), S.frostCalls)
    end)
elseif SC.special == "tokens" then
    local P = { via = "synthetic" }
    local function radioActor()
        for _, r in ipairs(FindAllOf("BP_Radio_C") or {}) do if notDefault(r) and alive(r) then return r end end
        return nil
    end
    local function fpPaths()
        local t = {}
        for _, ch in ipairs(FindAllOf(FP) or {}) do if notDefault(ch) and alive(ch) then t[pathOf(ch)] = true end end
        return t
    end
    local function reinf()
        local g = gameState()
        if not g then return nil end
        local cnt, dis, cm
        pcall(function() cnt = num(g.TimesUsedReinforcements) end)
        pcall(function() dis = g["Disable Reinforcement"] end)
        pcall(function() cm = num(g["Classified Minium"]) end)
        return cnt, dis, cm
    end
    -- The computer's own text (GetText_3: "Reinforcement Tokens <limit - count>") from a widget never shown.
    local function tokenText()
        local cls = loadClass(NUKE_UI)
        if not cls then return nil, "class not loaded" end
        local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local okW, w = pcall(function() return wbl:Create(pc(), cls, pc()) end)
        if not okW or not valid(w) then return nil, "Create failed: " .. tostring(w) end
        local okT, t = pcall(function() return w:GetText_3() end)
        local s
        if okT then
            if type(t) == "string" then s = t else pcall(function() s = t:ToString() end) end
        end
        pcall(function() w:RemoveFromParent() end)
        if not s then return nil, "GetText_3 failed: " .. tostring(t) end
        return s
    end
    local function textCheck(left, when)
        local s, why = tokenText()
        say("TEXT %s %s", when, tostring(s or why))
        check(s == ("Reinforcement Tokens " .. left), "%s the computer's text %s is 'Reinforcement Tokens %d' (got %s)", SCENARIO, when, left, tostring(s or why))
    end
    step("tokens start", function()
        local cnt, dis, cm = reinf()
        say("REINF start count=%s disable=%s classifiedMin=%s", tostring(cnt), tostring(dis), tostring(cm))
        check(cm == SC.cm, "%s Classified Minium is %d (got %s)", SCENARIO, SC.cm, tostring(cm))
        check(cnt == SC.limit - SC.n, "%s count at the start is limit - N = %d (got %s)", SCENARIO, SC.limit - SC.n, tostring(cnt))
        check(dis == false, "%s Disable Reinforcement false at the start (got %s)", SCENARIO, tostring(dis))
        textCheck(SC.n, "at the start")
        return after(1), 3
    end)
    for i = 1, SC.n do
        step("reinforce #" .. i, function()
            if P.abort then return end
            local p, c, g, r = me(), pc(), gameState(), radioActor()
            if not (p and c and g and r) then S.notShown = S.notShown + 1 P.abort = true say("NOTSHOWN reinforce #%d: no pawn, controller, game state or radio", i) return end
            local before = reinf()
            local t0, others = os.clock(), fpPaths()
            local function spectator()
                -- The count right before this call: a late synthetic revive already counted is judged from here.
                P.via, t0, others, before = "spectator", os.clock(), fpPaths(), reinf()
                local okS, eS = pcall(function() radioActor():SpawnReinforcmentSpectator() end)
                say("REVIVE #%d SpawnReinforcmentSpectator ok=%s %s", i, tostring(okS), okS and "" or tostring(eS))
            end
            if P.via == "synthetic" then
                local okQ, eQ = pcall(function() g:UpdateRespawnQue(c, p) end)
                local okR, eR = pcall(function() r:ReinforceSpecficPlayer(p) end)
                say("REVIVE #%d synthetic UpdateRespawnQue ok=%s %s; ReinforceSpecficPlayer ok=%s %s", i, tostring(okQ), okQ and "" or tostring(eQ), tostring(okR), okR and "" or tostring(eR))
            else
                spectator()
            end
            return function()
                if not me() then if gone() then S.dead = true return true end end
                keepClear(P)
                local now = reinf()
                if now and before and now == before + 1 then
                    if P.via == "spectator" then
                        local mine = me() and pathOf(me()) or ""
                        for path in pairs(fpPaths()) do
                            if not others[path] and path ~= mine then
                                local x = StaticFindObject(path)
                                if valid(x) then pcall(function() x:K2_DestroyActor() end) say("REVIVE #%d destroyed the orphan %s", i, path) end
                            end
                        end
                    end
                    say("REVIVE #%d via=%s count %d -> %d", i, P.via, before, now)
                    check(true, "%s reinforcement #%d accepted (via %s)", SCENARIO, i, P.via)
                    return true
                end
                if now and before and now > before + 1 then
                    -- Both paths landed (a late synthetic revive and the fallback): the case can't be judged one by one.
                    S.notShown = S.notShown + 1
                    P.abort = true
                    say("NOTSHOWN reinforce #%d: the count jumped %d -> %d (a late synthetic revive and the %s path both counted)", i, before, now, P.via)
                    return true
                end
                if P.via == "synthetic" and os.clock() - t0 > 15 then
                    say("REVIVE #%d the synthetic revive wasn't accepted in 15 s (count %s); falling back to SpawnReinforcmentSpectator()", i, tostring(now))
                    spectator()
                    return false
                end
                if P.via == "spectator" and os.clock() - t0 > 10 then
                    S.notShown = S.notShown + 1
                    P.abort = true
                    say("NOTSHOWN reinforce #%d: neither path moved the count (%s)", i, tostring(now))
                    return true
                end
                return false
            end, 40, "reinforcement #" .. i
        end)
        -- The new pawn settles, Difficulty's callback or poll re-checks; then Disable is false before N and true at N.
        step("after reinforce #" .. i, function()
            if P.abort or S.dead then return end
            local t0 = os.clock()
            return function()
                local m = me()
                if m then pcall(function() m.Temperature = 0 end) end -- a lowering (cold is Default): no frost while waiting
                keepClear(P)
                local _, dis = reinf()
                if i == SC.n then
                    if dis == true or os.clock() - t0 > 5 then
                        check(dis == true, "%s Disable Reinforcement set after reinforcement #%d = N (got %s)", SCENARIO, i, tostring(dis))
                        return true
                    end
                    return false
                end
                if os.clock() - t0 < 4 then return false end
                check(dis == false, "%s Disable Reinforcement still false after reinforcement #%d of %d (got %s)", SCENARIO, i, SC.n, tostring(dis))
                return true
            end, 10, "after reinforcement #" .. i
        end)
    end
    step("tokens end", function()
        if P.abort or S.dead then return end
        local cnt, dis = reinf()
        say("REINF end count=%s disable=%s via=%s", tostring(cnt), tostring(dis), P.via)
        check(cnt == SC.limit, "%s count after N reinforcements is the limit %d (got %s)", SCENARIO, SC.limit, tostring(cnt))
        textCheck(0, "after N reinforcements")
    end)
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
