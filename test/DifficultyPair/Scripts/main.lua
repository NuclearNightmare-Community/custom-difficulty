-- DifficultyPair: story 2's pair checks (spec-difficulty-v1, knob-mechanics.md "To verify in game", items 4-6).
-- Test-only, never shipped; plain UE4SS Lua (no core). One copy on each machine; Scripts\role.txt picks the role:
--   host-grab          (A, host) holds B's Temperature at 0.6 for 60 s (item 5), then spawns grabbing enemies at B and
--                      at itself (item 6). Like the mod for a modded victim, it flips the grab decision for B and for
--                      itself at HasPerk(0x27). Every enemy hit on either player is compensated to 5 HP.
--   host-grab-vanilla  (A, host) the same, but never flips for B (B counts as unmodded); B still gets the same hits.
--   client-grab        (B, VM) flips the decision for its own player (not while a Psycho is alive: that case is the
--                      execution whose recovery is observed); logs what it sees of both players.
--   client-observe     (B, VM) logs only (an unmodded B as far as the grab decision goes).
--   host-revive        (A, host) reinforcement steps (item 4): dies three times; sets TimesUsedReinforcements and
--                      Disable Reinforcement from Lua; revives B through the radio; logs every count.
--   client-revive      (B, VM) opens the military computer through its own ServerInteract, logs the reinforcement
--                      panel, requests the host's revive past the limit, dies on the host's signal; logs its counts.
-- The two machines coordinate only through files: a driver logs "SIGNAL <name>", the scenario script
-- (test/pair/difficulty-scenarios.ps1) writes <name>.txt next to the other machine's copy of this file.
-- Never keeps a UObject across steps: paths only, re-found each step.
local ME = "DifficultyPair"
local scriptDir = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]")
local function say(fmt, ...) print("[" .. ME .. "] " .. string.format(fmt, ...) .. "\n") end

local ROLE
do
    local f = io.open(scriptDir .. "\\role.txt", "r")
    if f then ROLE = (f:read("*l") or ""):match("^%s*([%a-]+)%s*$") f:close() end
end
local ROLES = { ["host-grab"] = true, ["host-grab-vanilla"] = true, ["client-grab"] = true, ["client-observe"] = true,
                ["host-revive"] = true, ["client-revive"] = true }
if not ROLES[ROLE] then say("END result=FAIL reason=no role (role.txt: %s)", tostring(ROLE)) return end
local IS_HOST = ROLE:sub(1, 4) == "host"
-- Stale signal files from an earlier run.
for _, n in ipairs({ "bready", "temp-start", "temp-end", "done", "s1", "s2", "s3", "s3done", "kill-b", "s4done",
                     "b-s1", "b-s2", "b-s3", "b-s3done", "b-s4done" }) do os.remove(scriptDir .. "\\" .. n .. ".txt") end

local FP = "BP_FirstPersonCharacter_C"
local FPC_PATH = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
local STANDARD = { [0] = 100, [1] = 50, [2] = 25, [3] = 17 }
local LIMIT = { [0] = 2, [1] = 4, [2] = 6, [3] = 8 } -- tokens for Classified Minium 0..3 (NukeComputer_UI_C)
local PROBE_HIT = 5
local SPAWN_DIST = 700

local S = { checks = 0, failures = 0, seq = 0, ctx = {}, nested = 0, hooks = {}, case = nil, saved = {}, pending = {},
            diff = 0, grabsOnMe = 0, flipsMe = 0, hostHpMax = 0, ownGrabAt = nil, hostGrabAt = nil }

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
    return not ok or r == true
end
local function notDefault(o) return valid(o) and not pathOf(o):find("Default__", 1, true) end
local function num(v) return type(v) == "number" and v or tonumber(tostring(v)) end
local function fmt1(v) return v and string.format("%.2f", v) or "?" end
local function fmt3(v) return v and string.format("%.3f", v) or "?" end
local function get(p) if p == nil then return nil end local ok, v = pcall(function() return p:get() end) return ok and v or nil end
local function hpOf(ch) local ok, h = pcall(function() return ch.Health end) return ok and num(h) or nil end
local function tempOf(ch) local ok, t = pcall(function() return ch.Temperature end) return ok and num(t) or nil end
local function montageOf(ch)
    local ok, m = pcall(function() return ch:GetCurrentMontage() end)
    return ok and valid(m) and nameOf(m) or "none"
end
local function stateOf(ch)
    local playing, mode
    pcall(function() playing = ch.PlayingMontage end)
    pcall(function() mode = ch.CharacterMovement.MovementMode end)
    return string.format("montage=%s PlayingMontage=%s movement=%s hp=%s", montageOf(ch), tostring(playing), tostring(mode), fmt1(hpOf(ch)))
end

local function pc()
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) then
            local ok, l = pcall(function() return c:IsLocalPlayerController() end)
            if ok and l then return c end
        end
    end
end
local function pawnOf(c) if not c then return nil end local ok, p = pcall(function() return c:K2_GetPawn() end) return ok and valid(p) and p or nil end
local function me() local p = pawnOf(pc()) return p and classOf(p) == FP and p or nil end
local function isMe(ch) local m = me() return m ~= nil and valid(ch) and pathOf(ch) == pathOf(m) end
-- The other player's first-person character (host: the remote controller's pawn; client: the FP character that isn't mine).
local function other()
    local mine = me()
    if IS_HOST then
        for _, c in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(c) then
                local ok, l = pcall(function() return c:IsLocalPlayerController() end)
                if ok and not l then local p = pawnOf(c) if p and classOf(p) == FP then return p end end
            end
        end
        return nil
    end
    for _, ch in ipairs(FindAllOf(FP) or {}) do
        if notDefault(ch) and alive(ch) and (not mine or pathOf(ch) ~= pathOf(mine)) then
            local okC, ctl = pcall(function() return ch:GetController() end)
            -- On a client the other player's character has no controller; an AI-controlled (infected) one does.
            if not (okC and valid(ctl)) then return ch end
        end
    end
end
local function isOther(ch) local o = other() return o ~= nil and valid(ch) and pathOf(ch) == pathOf(o) end
local function who(ch) if isMe(ch) then return "me" elseif isOther(ch) then return "other" end return valid(ch) and nameOf(ch) or "none" end
local function worldName() local c = pc() return c and c:GetWorld():GetFullName() or "" end
local function gameState()
    for _, g in ipairs(FindAllOf("BP_FirstPersonGameState_C") or {}) do if notDefault(g) then return g end end
end
local function radio()
    for _, r in ipairs(FindAllOf("BP_Radio_C") or {}) do if notDefault(r) and alive(r) then return r end end
end
local function liveHud()
    for _, w in ipairs(FindAllOf("InventoryUI_C") or {}) do
        local ok, v = pcall(function() return w:IsInViewport() end)
        if valid(w) and ok and v then return w end
    end
end
local function lenOf(t)
    if t == nil then return "?" end
    local ok, n = pcall(function() return #t end)
    if ok and type(n) == "number" then return tostring(n) end
    ok, n = pcall(function() return t:GetArrayNum() end)
    if ok then return tostring(n) end
    ok, n = pcall(function() local c = 0 t:ForEach(function() c = c + 1 end) return c end)
    return ok and tostring(n) or "?"
end
local function reinfState(tag)
    local g = gameState()
    if not g then say("REINF %s no game state", tag) return end
    local cnt, dis, cm, qd, sp, gm
    pcall(function() cnt = num(g.TimesUsedReinforcements) end)
    pcall(function() dis = g["Disable Reinforcement"] end)
    pcall(function() cm = num(g["Classified Minium"]) end)
    pcall(function() qd = lenOf(g.QuedPlayers) end)
    pcall(function() sp = lenOf(g.ReinforcementSpectators) end)
    pcall(function() gm = num(g.Gamemode) end)
    say("REINF %s count=%s disable=%s classifiedMin=%s limit=%s qued=%s spectators=%s gamemode=%s", tag, tostring(cnt),
        tostring(dis), tostring(cm), tostring(cm and LIMIT[cm]), tostring(qd), tostring(sp), tostring(gm))
    return cnt, dis, cm
end

-- ---------------------------------------------------------------- steps and signals
local steps = {}
local function step(name, fn) steps[#steps + 1] = { name = name, fn = fn } end
local function after(sec) local t = os.clock() + sec return function() return os.clock() >= t end end
local function has(name) local f = io.open(scriptDir .. "\\" .. name .. ".txt", "r") if f then f:close() return true end return false end
local function signal(name) say("SIGNAL %s", name) end
local function waitFile(name, timeout)
    step("wait " .. name, function() return function() return has(name) end, timeout or 300, "signal file " .. name end)
end
local function wait(name, sec) step(name, function() return after(sec), sec + 5 end) end

local function waitMatch()
    step("match world", function()
        return function() local w = worldName() return w:find("/Game/Maps/", 1, true) ~= nil and not w:find("NewMainMenu", 1, true) end, 900, "a match world"
    end)
    step("in the match", function()
        local t0
        return function()
            if not (me() and liveHud()) then t0 = nil return false end
            t0 = t0 or os.clock()
            return os.clock() - t0 > 10
        end, 400, "first-person pawn with the HUD"
    end)
    step("difficulty", function()
        local g = gameState()
        local ok, d = pcall(function() return num(g.Diffculty) end)
        S.diff = ok and d or 0
        say("MATCH role=%s world=%s Diffculty=%s me=%s", ROLE, worldName(), tostring(d), pathOf(me()))
    end)
end

-- ---------------------------------------------------------------- hooks
local function hook(fn, pre, post)
    if S.hooks[fn] then return true end
    local ok, err = pcall(RegisterHook, fn, pre, post or function() end)
    if ok then S.hooks[fn] = true end
    say("HOOK %s %s%s", fn, ok and "ok" or "FAIL", ok and "" or (" " .. tostring(err)))
    return ok
end

-- Grab cases (host-grab*): enemy class, the victim ("other" = B, "me" = the host), and whether the host flips it.
local CASES = {
    { name = "Meek", path = "/Game/AI/SCP_AI.SCP_AI_C", target = "other", flip = true },
    { name = "Husk", path = "/Game/AI/FastLearner_AI.FastLearner_AI_C", target = "other", flip = true },
    { name = "Watcher", path = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C", target = "other", flip = true },
    { name = "Mimic", path = "/Game/AI/Mimic_AI.Mimic_AI_C", target = "me", flip = true },
    { name = "Psycho", path = "/Game/AI/MadPatent_AI.MadPatent_AI_C", target = "other", flip = false, wanted = 1 },
}
for _, c in ipairs(CASES) do c.wanted = c.wanted or 2 end
local ENEMY_OF = {}
for _, c in ipairs(CASES) do ENEMY_OF[c.path:match("%.([^.]+)$")] = c.name end
for _, n in ipairs({ "Stalker_AI_C", "SlugQueen_AI_C", "ApexPredatorAI_C", "Worm_AI_C", "BabyWorm_AI_C", "BP_BatEnemy_C", "Dog_Infected_AI_C" }) do ENEMY_OF[n] = n end
local function enemyName(o) return valid(o) and (ENEMY_OF[classOf(o)] or classOf(o)) or "none" end
local GRABS = {
    { fn = "/Game/AI/SCP_AI.SCP_AI_C:Attack", victim = 2 },
    { fn = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C:AttackMulti", victim = 2 },
    { fn = "/Game/AI/Mimic_AI.Mimic_AI_C:AttackMulti", victim = 2 },
    { fn = "/Game/AI/MadPatent_AI.MadPatent_AI_C:AttackMulti", victim = 2 },
    { fn = "/Game/AI/FastLearner_AI.FastLearner_AI_C:AttackAll", victim = 2 },
    { fn = FPC_PATH .. ":PlayDamageEvent", victim = 0, attacker = 1 },
}

-- Should this machine flip the grab decision for victim v (survivable)?
local function wantFlip(v)
    if ROLE == "host-grab" or ROLE == "host-grab-vanilla" then
        local c = S.case
        if not c or not c.flip then return false end
        if c.target == "me" then return isMe(v) end
        return ROLE == "host-grab" and isOther(v)
    elseif ROLE == "client-grab" then
        if not isMe(v) then return false end
        for _, p in ipairs(FindAllOf("MadPatent_AI_C") or {}) do if notDefault(p) and alive(p) then return false end end
        return true
    end
    return false
end

local function restore(path, why)
    local saved = S.saved[path]
    if saved == nil then return end
    S.saved[path] = nil
    local v = StaticFindObject(path)
    if valid(v) then pcall(function() v.Health = saved end) end
    say("RESTORE %s hp -> %s (%s)", path:match("[^.]+$") or path, fmt1(saved), why)
end

local function installGrabHooks()
    hook(FPC_PATH .. ":HasPerk", function(self, perk)
        local v, k = get(self), num(get(perk))
        if k ~= 39 then return end
        local hp = hpOf(v)
        local set = false
        if wantFlip(v) and hp then
            local want = STANDARD[S.diff] + 1
            if hp ~= want then
                if S.saved[pathOf(v)] == nil then S.saved[pathOf(v)] = hp end
                pcall(function() v.Health = want end)
                set = true
                if isMe(v) then S.flipsMe = S.flipsMe + 1 end
                S.pending[#S.pending + 1] = pathOf(v)
            end
        end
        say("MARK HasPerk(0x27) victim=%s hp=%s flip=%s", who(v), fmt1(hp), tostring(set))
    end)
    for _, g in ipairs(GRABS) do
        -- The callback runs after the multicast's body (pinned UE4SS, seen on v8.1.3): the decision is made, the
        -- montage is playing; restore Health in the same frame.
        hook(g.fn, function(self, a1, a2)
            local args = { [0] = get(self), get(a1), get(a2) }
            local victim, attacker = args[g.victim], args[g.attacker or 0]
            S.seq = S.seq + 1
            local hpSeen = hpOf(victim)
            if valid(victim) then restore(pathOf(victim), "multicast") end
            say("GRAB #%d %s %s victim=%s hpSeen=%s hpNow=%s montage=%s", S.seq, enemyName(attacker), g.fn:match(":(.+)$"),
                who(victim), fmt1(hpSeen), fmt1(hpOf(victim)), valid(victim) and montageOf(victim) or "?")
            if isMe(victim) then S.grabsOnMe = S.grabsOnMe + 1 S.ownGrabAt = { t = os.clock(), n = 0, seq = S.seq } end
            if isOther(victim) then S.hostGrabAt = { t = os.clock(), n = 0, seq = S.seq } end
            local c = S.case
            if c and valid(attacker) and pathOf(attacker) == c.actor then c.grabs = (c.grabs or 0) + 1 c.lastGrab = os.clock() end
        end)
    end
end

-- Host: damage compensation (every enemy hit on either player costs PROBE_HIT), as the mod's Health compensation.
local function compensate(victim, amount, why)
    if not (isMe(victim) or isOther(victim)) or not amount or amount <= 2 then return end
    local hp = hpOf(victim)
    if not hp then return end
    local new = hp + amount - PROBE_HIT
    pcall(function() victim.Health = new end)
    say("COMP %s victim=%s hp %.2f -> %.2f (the native %.2f should leave %.2f)", why, who(victim), hp, new, amount, new - amount)
end
local function installDamageHooks()
    hook("/Script/NuclearNightmare.NNEnemyAttackContext:ApplyLockedDamage", function(self, attacker, amount)
        local a, n = get(attacker), num(get(amount))
        local v
        pcall(function() v = StaticFindObject("/Script/NuclearNightmare.Default__NNEnemyAttackContext"):GetLockedVictim(a) end)
        say("DMG ApplyLockedDamage amount=%s attacker=%s victim=%s hp=%s", fmt1(n), enemyName(a), who(v), fmt1(hpOf(v)))
        S.nested = S.nested + 1
        compensate(v, n, "ApplyLockedDamage")
    end, function() S.nested = S.nested - 1 end)
    hook("/Script/NuclearNightmare.NNEnemyAttackContext:ApplyStalkerDamage", function(self, victim, amount)
        local v, n = get(victim), num(get(amount))
        say("DMG ApplyStalkerDamage amount=%s victim=%s hp=%s", fmt1(n), who(v), fmt1(hpOf(v)))
        S.nested = S.nested + 1
        compensate(v, n, "ApplyStalkerDamage")
    end, function() S.nested = S.nested - 1 end)
    hook("/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent", function(self, amount)
        local v, n = get(self), num(get(amount))
        say("DMG CallDamageEvent amount=%s victim=%s hp=%s nested=%d", fmt1(n), who(v), fmt1(hpOf(v)), S.nested)
        if S.nested == 0 then compensate(v, n, "CallDamageEvent") end
    end)
end

local clearNatural
-- Every 250 ms: Health fallbacks, and what each machine sees of both players.
local function monitor()
    for i = #S.pending, 1, -1 do restore(S.pending[i], "next tick") table.remove(S.pending, i) end
    local m, o = me(), other()
    -- Host, once the steps begin: no natural enemies (only the case's), and nobody freezes outside the hold phase.
    if IS_HOST and S.guard and os.clock() - (S.guardAt or 0) >= 2 then
        S.guardAt = os.clock()
        clearNatural(S.case and S.case.actor)
        if not S.tempHold then for _, ch in ipairs({ m, o }) do if ch then pcall(function() ch.Temperature = 0 end) end end end
    end
    if not IS_HOST and o then
        local h = hpOf(o)
        if h and h ~= S.lastHostHp then say("OTHERHP %s", fmt1(h)) S.lastHostHp = h end
        if h and h > S.hostHpMax then S.hostHpMax = h end
    end
    if m then
        local h = hpOf(m)
        if h and h ~= S.lastMyHp then say("MYHP %s", fmt1(h)) S.lastMyHp = h end
    end
    -- 6 s and 12 s after a grab: the victim's state on this machine (no recovery is forced: does it come back alone?).
    for _, k in ipairs({ "ownGrabAt", "hostGrabAt" }) do
        local g = S[k]
        local ch = k == "ownGrabAt" and m or o
        if g and ch then
            local dt = os.clock() - g.t
            if (g.n == 0 and dt >= 6) or (g.n == 1 and dt >= 12) then
                g.n = g.n + 1
                say("AFTERGRAB #%d %s %d s: %s", g.seq, k == "ownGrabAt" and "me" or "other", g.n * 6, stateOf(ch))
                if g.n >= 2 then S[k] = nil end
            end
        end
    end
    -- Temperature as this machine sees it during the hold phase.
    if not IS_HOST and has("temp-start") and not has("temp-end") and m then
        if os.clock() - (S.tempAt or 0) >= 1 then S.tempAt = os.clock() say("TEMP me=%s", fmt3(tempOf(m))) end
    end
end

-- ---------------------------------------------------------------- spawning (host)
local function loadClass(path)
    local c = StaticFindObject(path)
    if valid(c) then return c end
    pcall(LoadAsset, path:gsub("%.[^.]+$", ""))
    c = StaticFindObject(path)
    return valid(c) and c or nil
end
local function spawnInFront(cls, target)
    local loc, fwd = target:K2_GetActorLocation(), target:GetActorForwardVector()
    local at = { X = loc.X + fwd.X * SPAWN_DIST, Y = loc.Y + fwd.Y * SPAWN_DIST, Z = loc.Z + 50 }
    local yaw = math.atan(-fwd.Y, -fwd.X)
    local xf = { Rotation = { X = 0, Y = 0, Z = math.sin(yaw / 2), W = math.cos(yaw / 2) }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
    local x = GS():BeginDeferredActorSpawnFromClass(target, cls, xf, 2, nil, 1)
    if not valid(x) then error("BeginDeferredActorSpawnFromClass returned no actor") end
    GS():FinishSpawningActor(x, xf, 1)
    local okC, ctl = pcall(function() return x:GetController() end)
    if not (okC and valid(ctl)) then pcall(function() x:SpawnDefaultController() end) end
    pcall(function() x:ActivateDormancyServer(true) end)
    okC, ctl = pcall(function() return x:GetController() end)
    return x, okC and valid(ctl) and classOf(ctl) or "none"
end
function clearNatural(keep)
    for short in pairs(ENEMY_OF) do
        for _, e in ipairs(FindAllOf(short) or {}) do
            if notDefault(e) and alive(e) and pathOf(e) ~= keep then
                say("CLEAR natural %s %s", enemyName(e), nameOf(e))
                pcall(function() e:K2_DestroyActor() end)
            end
        end
    end
end

-- ---------------------------------------------------------------- roles
local function buildHostGrab()
    waitMatch()
    step("other present", function() return function() return other() ~= nil end, 600, "the other player's character" end)
    waitFile("bready", 600)
    step("hooks", function() installDamageHooks() installGrabHooks() S.guard = true end)
    -- Item 5: the host's Temperature writes must show on B (the game's own tick marks it dirty every frame).
    step("temperature hold", function()
        signal("temp-start")
        S.tempHold = true
        local t0, logAt = os.clock(), 0
        return function()
            local o, m = other(), me()
            if o then
                local before = tempOf(o)
                pcall(function() o.Temperature = 0.6 end)
                if os.clock() - logAt >= 2 then logAt = os.clock() say("TEMP host set other 0.600 (was %s)", fmt3(before)) end
            end
            if m then pcall(function() m.Temperature = 0 end) end
            clearNatural(nil)
            if os.clock() - t0 < 60 then return false end
            if o then pcall(function() o.Temperature = 0 end) end
            S.tempHold = false
            signal("temp-end")
            return true
        end, 75, "temperature hold"
    end)
    for _, c in ipairs(CASES) do
        local label = c.name .. (c.flip and " (flip)" or "") .. " on " .. c.target
        step("spawn " .. label, function()
            local target = c.target == "me" and me() or other()
            if not target then check(false, "CASE %s: no target", label) return end
            for _, ch in ipairs({ me(), other() }) do if ch then pcall(function() ch.Health = 100 end) end end
            local cls = loadClass(c.path)
            if not check(cls ~= nil, "CLASS %s", c.path) then return end
            c.grabs = 0
            S.case = c
            local okS, x, ctl = pcall(spawnInFront, cls, target)
            if not check(okS and valid(x), "SPAWN %s %s controller=%s", label, okS and pathOf(x) or tostring(x), tostring(ctl)) then S.case = nil return end
            c.actor = pathOf(x)
            say("CASE start %s", label)
            local t0 = os.clock()
            return function()
                local tg = c.target == "me" and me() or other()
                if not tg then say("CASE %s: target gone", label) return true end
                if os.clock() - (c.clearAt or 0) >= 2 then c.clearAt = os.clock() clearNatural(c.actor) end
                local hp = hpOf(tg)
                if hp and hp < 30 and not (c.lastGrab and os.clock() - c.lastGrab < 8) then
                    pcall(function() tg.Health = 100 end)
                    say("REFILL %s hp %.2f -> 100", c.target, hp)
                end
                if os.clock() - (c.seeAt or 0) >= 10 and (c.grabs or 0) == 0 then
                    c.seeAt = os.clock()
                    local x2 = StaticFindObject(c.actor)
                    if valid(x2) then
                        for _, fn in ipairs({ "SeePlayerServer", "SeeCharacter", "SeePlayer" }) do
                            if pcall(function() x2[fn](x2, tg) end) then break end
                        end
                    end
                end
                local enough = (c.grabs or 0) >= c.wanted
                -- Leave 14 s after the last grab so both machines log the 6 s and 12 s states.
                if enough and os.clock() - c.lastGrab > 14 then return true end
                if os.clock() - t0 > 120 then say("TIMEOUT %s grabs=%d", label, c.grabs or 0) return true end
                return false
            end, 130, label
        end)
        step("despawn " .. label, function()
            say("CASE end %s grabs=%d", label, c.grabs or 0)
            S.case = nil
            local x = c.actor and StaticFindObject(c.actor)
            if valid(x) then pcall(function() x:K2_DestroyActor() end) end
            for _, ch in ipairs({ me(), other() }) do if ch then pcall(function() ch.Health = 100 end) end end
            return after(4), 8
        end)
    end
    step("done", function()
        local o = other()
        say("FINAL other %s", o and stateOf(o) or "gone")
        signal("done")
        return after(8), 12
    end)
end

local function buildClientGrab()
    waitMatch()
    step("ready", function() installGrabHooks() signal("bready") end)
    step("until done", function()
        return function() return has("done") end, 1500, "the host's done signal"
    end)
    step("summary", function()
        local m = me()
        say("SUMMARY grabsOnMe=%d flipsMe=%d otherHpMax=%s final %s", S.grabsOnMe, S.flipsMe, fmt1(S.hostHpMax), m and stateOf(m) or "no pawn")
        check(S.hostHpMax <= 100, "OTHERHP the host's Health never showed above 100 here (max %s)", fmt1(S.hostHpMax))
    end)
end

-- Kills this machine's own pawn (DeathEvent, again after 5 s if still possessed; MarkersDriver's proven path).
local function selfKill(tag)
    step(tag .. ": die", function()
        local p = me()
        if not p then say("KILL %s no pawn", tag) return end
        local was = pathOf(p)
        S.deadPath = was
        local ok, err = pcall(function() p:DeathEvent() end)
        say("KILL %s DeathEvent on my pawn ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
        local t0, again = os.clock(), false
        return function()
            local q = me()
            if not q or pathOf(q) ~= was then return os.clock() - t0 > 3 end
            if not again and os.clock() - t0 > 5 then
                again = true
                local ok2 = pcall(function() q:DeathEvent() end)
                say("KILL %s still possessed after 5 s: DeathEvent again ok=%s", tag, tostring(ok2))
            end
            return false
        end, 30, tag .. " dead"
    end)
end
local function setCount(n, disable)
    local g = gameState()
    pcall(function() g.TimesUsedReinforcements = n end)
    if disable ~= nil then pcall(function() g["Disable Reinforcement"] = disable end) end
    say("SET TimesUsedReinforcements=%d%s", n, disable ~= nil and (" Disable Reinforcement=" .. tostring(disable)) or "")
end

local function installRadioHooks()
    local R = "/Game/Gameplay/ClassifiedMaterials/BP_Radio.BP_Radio_C:"
    for _, fn in ipairs({ "ReinforceSpecficPlayer", "SpawnReinforcmentSpectator", "SpawnReinforcementMethod2", "Reinformant" }) do
        hook(R .. fn, function() say("RADIO %s called", fn) end, function() reinfState("after " .. fn) end)
    end
    hook(R .. "RPCReinforcementMethod2", function(self, spawned, old, ctl, times)
        say("RADIO RPCReinforcementMethod2 TimesReinforced=%s", tostring(num(get(times))))
        reinfState("in RPCReinforcementMethod2")
    end)
    hook(R .. "SpawnReinforcementSpectatorMulti", function(self, ctl, ch, n)
        say("RADIO SpawnReinforcementSpectatorMulti Reinforcements=%s", tostring(num(get(n))))
        reinfState("in SpawnReinforcementSpectatorMulti")
    end)
end

local function buildHostRevive()
    waitMatch()
    step("other present", function() return function() return other() ~= nil end, 600, "the other player's character" end)
    waitFile("bready", 600)
    step("hooks", function() installRadioHooks() reinfState("start") S.guard = true end)
    -- S1: count 0, not disabled, the host dead: B's panel should show (control).
    step("s1 set", function() setCount(0, false) end)
    selfKill("s1")
    wait("s1 settle", 10)
    step("s1 signal", function() reinfState("s1 host dead") signal("s1") end)
    waitFile("b-s1", 120)
    -- S2: the host's Lua write to Disable Reinforcement; B's panel should stay hidden.
    step("s2 set", function() setCount(0, true) reinfState("s2") signal("s2") end)
    waitFile("b-s2", 120)
    -- S3: the count at the limit (vanilla: no more tokens on the host); B requests the host's revive anyway.
    step("s3 set", function()
        local _, _, cm = reinfState("s3 before")
        S.limit = LIMIT[cm or 2] or 6
        setCount(S.limit, false)
        signal("s3")
    end)
    waitFile("b-s3", 120)
    step("s3 revived", function()
        return function() local m = me() return m ~= nil and pathOf(m) ~= S.deadPath end, 120, "the host's new character (B's request)"
    end)
    step("s3 check", function()
        local cnt = reinfState("s3 host revived")
        check(me() ~= nil, "REVIVE past the limit: B's request revived the host (count %s, limit %s)", tostring(cnt), tostring(S.limit))
        signal("s3done")
    end)
    waitFile("b-s3done", 120)
    -- S4: B dies, the host revives it through the radio; the revived machine's count.
    step("s4 kill", function() S.otherPath = pathOf(other()) signal("kill-b") end)
    step("s4 b dead", function()
        local t0
        return function()
            local o = other()
            if o and pathOf(o) == S.otherPath then t0 = nil return false end
            t0 = t0 or os.clock()
            return os.clock() - t0 > 3
        end, 120, "B dead"
    end)
    wait("s4 settle", 10)
    step("s4 reinforce", function()
        reinfState("s4 b dead")
        local r = radio()
        local ok, err = pcall(function() r:Reinformant() end)
        say("REINFORCE radio:Reinformant() ok=%s %s", tostring(ok), ok and "" or tostring(err))
    end)
    step("s4 b revived", function()
        return function() local o = other() return o ~= nil and pathOf(o) ~= S.otherPath end, 180, "B's new character"
    end)
    step("s4 check", function()
        local cnt = reinfState("s4 b revived")
        check(cnt == (S.limit or 6) + 2, "COUNT host after two revives past the limit: %s (want %d)", tostring(cnt), (S.limit or 6) + 2)
        signal("s4done")
    end)
    waitFile("b-s4done", 120)
end

-- Client: open the military computer as a player would (its own ServerInteract on the radio), log the panel, close.
local function panelState(tag)
    local any = false
    for _, w in ipairs(FindAllOf("NukeComputer_UI_C") or {}) do
        local okV, inVp = pcall(function() return w:IsInViewport() end)
        if valid(w) and okV and inVp then
            any = true
            local okB, vis = pcall(function() return w.ReinforcementBorder:GetVisibility() end)
            say("PANEL %s computer open, ReinforcementBorder visibility=%s (0 visible, 1 collapsed)", tag, okB and tostring(vis) or "?")
        end
    end
    if not any then say("PANEL %s no computer UI in the viewport", tag) end
end
local function openComputer(tag)
    step(tag .. ": open computer", function()
        local m, r = me(), radio()
        if not (m and r) then say("COMPUTER %s me=%s radio=%s", tag, tostring(m ~= nil), tostring(r ~= nil)) return end
        local ok, err = pcall(function() m:ServerInteract(r, m) end)
        say("COMPUTER %s ServerInteract(radio) ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
        return after(4), 6
    end)
    step(tag .. ": panel", function() reinfState(tag .. " client") panelState(tag) end)
end
local function closeComputer(tag)
    step(tag .. ": close computer", function()
        local r = radio()
        local ok = r and pcall(function() r:eXITcOMPUTERsERVER() end)
        say("COMPUTER %s eXITcOMPUTERsERVER ok=%s", tag, tostring(ok))
        return after(3), 5
    end)
    step(tag .. ": closed", function() panelState(tag .. " after close") end)
end

local function buildClientRevive()
    waitMatch()
    step("ready", function() installRadioHooks() reinfState("client start") signal("bready") end)
    waitFile("s1", 600)
    openComputer("s1")
    closeComputer("s1")
    step("s1 ack", function() signal("b-s1") end)
    waitFile("s2", 120)
    openComputer("s2")
    closeComputer("s2")
    step("s2 ack", function() signal("b-s2") end)
    waitFile("s3", 120)
    openComputer("s3")
    step("s3 request", function()
        local r = radio()
        local ok, err = pcall(function() r:SpawnReinforcementMethod2(0) end)
        say("REQUEST radio:SpawnReinforcementMethod2(0) from the client ok=%s %s", tostring(ok), ok and "" or tostring(err))
        return after(2), 4
    end)
    closeComputer("s3")
    step("s3 ack", function() signal("b-s3") end)
    waitFile("s3done", 240)
    step("s3 count", function() reinfState("s3 client, not revived") signal("b-s3done") end)
    waitFile("kill-b", 120)
    selfKill("s4")
    waitFile("s4done", 300)
    step("s4 count", function()
        local cnt = reinfState("s4 client, revived")
        say("SUMMARY revived me=%s", tostring(me() ~= nil))
        signal("b-s4done")
    end)
end

if ROLE == "host-grab" or ROLE == "host-grab-vanilla" then buildHostGrab()
elseif ROLE == "client-grab" or ROLE == "client-observe" then buildClientGrab()
elseif ROLE == "host-revive" then buildHostRevive()
else buildClientRevive() end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    say("END result=%s checks=%d failures=%d role=%s", (S.failures == 0 and S.checks > 0) and "PASS" or "FAIL", S.checks, S.failures, ROLE)
end
local function tick()
    if busy or finished then return end
    busy = true
    local okM, errM = pcall(monitor)
    if not okM then say("MONITOR error %s", tostring(errM)) end
    local ok, err = pcall(function()
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
say("LOADED role=%s %d steps", ROLE, #steps)
