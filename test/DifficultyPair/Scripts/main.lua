-- DifficultyPair: story 2's pair checks (spec-difficulty-v1, knob-mechanics.md "To verify in game", items 4-6).
-- Test-only, never shipped; plain UE4SS Lua (no core). One copy on each machine; Scripts\role.txt picks the role:
--   host-grab          (A, host) holds B's Temperature at 0.6 for 60 s (item 5), then spawns grabbing enemies at B and
--                      at itself (item 6). Like the mod for a modded victim, it flips the grab decision for B and for
--                      itself at HasPerk(0x27). Every enemy hit on either player is compensated to 5 HP.
--   host-grab-vanilla  (A, host) the same, but never flips for B (B counts as unmodded); B still gets the same hits.
--   client-grab        (B, VM) flips the decision for its own player (not while a Psycho is alive: that case is the
--                      execution whose recovery is observed); logs what it sees of both players.
--   client-observe     (B, VM) logs only (an unmodded B as far as the grab decision goes).
--   host-spawn         (A, host; stories 5 and 11) spawns a Meek, Mimic, Psycho, Stalker and Watcher (last) in front
--                      of B, one at a time (no Husk: a survivable Husk grab infects by design). Never flips and never
--                      touches damage: the real Difficulty does both. Before each spawn it refills the host (only when
--                      alive) and teleports it at least 2500 cm from B (MOVE host), so B is the enemies' only target.
--                      hp <= 0 is dead: a case ends as died then, and no Health write ever touches such a body. Refills
--                      B to 100 HP between cases, only outside a grab window and only while alive. A dead B is revived
--                      specifically: after its real death (B's controller no longer holds the case's character, up to
--                      30 s), ReinforceSpecficPlayer(<B's dead character>), then Reinformant() every 5 s (up to 6
--                      tries) until B has a new character; a playable-monster B is a FAIL at once. The host is revived
--                      the same way when it has no character. Clears infection timers (story 2's hook) and
--                      either player's StartedInfection? on the host (it decides a playable monster at death), at once
--                      in the UpdateInfectionStatus hook and every 2 s.
--                      With Scripts\watcher-near.txt (story 11, d5-grab-modded) the Watcher case instead keeps the host
--                      within 2 m of B, first just in front of it (MOVE host ... (near ...)), facing where B faces (FACE), re-placed outside grab
--                      windows, and logs the Watcher's state every 5 s (WATCH), so the Watcher has two players in reach:
--                      it guards the Watcher's victim rule (Target vs AttackedPlayer).
--                      Story 10: logs its view of B once a second for 16 s after each grab on B (OTHERPOS: position,
--                      montage, PlayingMontage, movement mode). With Scripts\measure.txt (d10-measure, no Difficulty on
--                      the host) only the Meek and the Watcher, each enemy hit on either player costs 25 HP (an
--                      execution doesn't kill), a case ends at least 17 s after its first grab on B and only while the
--                      host sees B free, and B is refilled only 17 s after the last grab.
--   client-watch       (B, VM; story 5) logs only: each grab on B with its montage, and B's montage, PlayingMontage,
--                      movement mode, Health and position 6, 12 and 16 s later (AFTERGRAB). The real Difficulty (or
--                      none) decides. Clears infection timers like the host. Story 10, with Scripts\measure.txt: also
--                      5 s after the grab, B's own view once a second for 16 s (MYPOS), and B walks backwards from
--                      +1 s to +16 s (WALK: how far it got).
-- Every role's GRAB #n line on a Watcher ends with target=<me|other|none> attacked=<me|other|none>, read from that
-- Watcher in the multicast hook (story 11).
--   host-revive        (A, host) reinforcement steps (item 4): dies three times; sets TimesUsedReinforcements and
--                      Disable Reinforcement from Lua; revives B through the radio; logs every count.
--   client-revive      (B, VM) opens the military computer through its own ServerInteract, logs the reinforcement
--                      panel, requests the host's revive past the limit, dies on the host's signal; logs its counts.
--   host-tokens        (A, host; story 8, d8-tokens) the real Difficulty with Reinforcement Tokens 2: dies twice, each
--                      time revived by B's terminal, then once more; never writes the count or Disable Reinforcement.
--   client-tokens      (B, VM; story 8) no Difficulty: each round opens its own terminal and checks the offer (shown
--                      before the 2nd reinforcement, gone after it), asks for the host's revive, closes the terminal.
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
                ["host-revive"] = true, ["client-revive"] = true, ["host-spawn"] = true, ["client-watch"] = true,
                ["host-tokens"] = true, ["client-tokens"] = true }
if not ROLES[ROLE] then say("END result=FAIL reason=no role (role.txt: %s)", tostring(ROLE)) return end
local IS_HOST = ROLE:sub(1, 4) == "host"
-- Story 11: Scripts\watcher-near.txt (staged by d5-grab-modded) keeps the host next to B in host-spawn's Watcher case.
local WATCHER_NEAR = false
do
    local f = io.open(scriptDir .. "\\watcher-near.txt", "r")
    if f then f:close() WATCHER_NEAR = ROLE == "host-spawn" end
end
-- Story 10: Scripts\measure.txt (staged by d10-measure) turns on the grab-recovery measurement. host-spawn: only the
-- Meek and the Watcher, every enemy hit on either player costs MEASURE_HIT (the executions don't kill; no Difficulty
-- on the host), and a case ends at least 17 s after its first grab on B, only while the host sees B free (no enemy
-- despawned while it holds B). client-watch: after each grab on B, B walks backwards from +1 s to +16 s (WALK) and
-- logs its own state once a second (MYPOS).
local MEASURE = false
do
    local f = io.open(scriptDir .. "\\measure.txt", "r")
    if f then f:close() MEASURE = ROLE == "host-spawn" or ROLE == "client-watch" end
end
-- Stale signal files from an earlier run.
for _, n in ipairs({ "bready", "temp-start", "temp-end", "done", "s1", "s2", "s3", "s3done", "kill-b", "s4done",
                     "b-s1", "b-s2", "b-s3", "b-s3done", "b-s4done", "t1", "t2", "tfinal", "b-t1", "b-t2", "b-tfinal" }) do os.remove(scriptDir .. "\\" .. n .. ".txt") end

local FP = "BP_FirstPersonCharacter_C"
local FPC_PATH = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
local STANDARD = { [0] = 100, [1] = 50, [2] = 25, [3] = 17 }
local LIMIT = { [0] = 2, [1] = 4, [2] = 6, [3] = 8 } -- tokens for Classified Minium 0..3 (NukeComputer_UI_C)
local PROBE_HIT = 5
local MEASURE_HIT = 25 -- story 10 (measure.txt): what each enemy hit costs, as Enemy Damage 25 on Nightmare
local AFTER_AT = MEASURE and { 5, 6, 12, 16 } or { 6, 12, 16 } -- s after a grab: the AFTERGRAB lines
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
-- me / other / none: who a player reference names (the Watcher's Target and AttackedPlayer).
local function whoP(ch) if isMe(ch) then return "me" elseif isOther(ch) then return "other" end return "none" end
-- The remote player's controller and whatever it possesses (host only; any class: Spectator_C, a playable monster).
local function remoteController()
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) and notDefault(c) then
            local ok, l = pcall(function() return c:IsLocalPlayerController() end)
            if ok and not l then return c end
        end
    end
end
local function remotePawn() return pawnOf(remoteController()) end
local function who(ch) if isMe(ch) then return "me" elseif isOther(ch) then return "other" end return valid(ch) and nameOf(ch) or "none" end
-- Every controller's pawn and every first-person character, to see what replaced a character that disappeared.
local function whereAre(tag)
    for _, c in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(c) and notDefault(c) then
            local okL, l = pcall(function() return c:IsLocalPlayerController() end)
            local p = pawnOf(c)
            say("WHERE %s controller=%s local=%s pawn=%s class=%s", tag, nameOf(c), tostring(okL and l), p and pathOf(p) or "none", p and classOf(p) or "-")
        end
    end
    for _, ch in ipairs(FindAllOf(FP) or {}) do
        if notDefault(ch) then
            local okC, ctl = pcall(function() return ch:GetController() end)
            local inf, prof, called
            pcall(function() inf = ch.Infected end)
            pcall(function() prof = ch.bInfectedMovementProfile end)
            pcall(function() called = ch["HasCalledDeathEvent?"] end)
            say("WHERE %s fp=%s alive=%s controller=%s infected=%s infectedMovement=%s deathCalled=%s %s", tag, pathOf(ch), tostring(alive(ch)),
                (okC and valid(ctl)) and classOf(ctl) or "none", tostring(inf), tostring(prof), tostring(called), stateOf(ch))
        end
    end
end
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

-- ---------------------------------------------------------------- positions and B's walk (story 10)
local function posOf(ch)
    local ok, l = pcall(function() return ch:K2_GetActorLocation() end)
    if not ok or not l then return nil end
    local x, y, z = num(l.X), num(l.Y), num(l.Z)
    if not (x and y and z) then return nil end
    return { X = x, Y = y, Z = z }
end
local function posStr(p) return p and string.format("x=%.0f y=%.0f z=%.0f", p.X, p.Y, p.Z) or "x=? y=? z=?" end
local function posDist(a, b) if not (a and b) then return nil end return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end -- horizontal
-- B (client-watch with measure.txt) walks backwards, away from the enemy spawned in front of it, from +1 s to +16 s
-- after a grab on it: AddMovementInput every 30 ms from a game-thread loop (LoopInGameThreadWithDelay, never an async
-- loop). A newer grab or +16 s stops it with one WALK line: how far B got on its own screen.
local function walkStop(why)
    local w = S.walk
    if not w then return end
    S.walk = nil
    if w.handle ~= nil then pcall(CancelDelayedAction, w.handle) end
    local m = me()
    local p = m and posOf(m)
    local d = posDist(w.start, p)
    local sp
    pcall(function() sp = num(m.CharacterMovement.MaxWalkSpeed) end)
    say("WALK #%d %s dist=%s start=(%s) end=(%s) inputs=%d fails=%d maxWalkSpeed=%s", w.seq, why, d and string.format("%.0f", d) or "?",
        posStr(w.start), posStr(p), w.inputs, w.fails, sp and string.format("%.0f", sp) or "?")
end
local function walkStart(seq)
    local m = me()
    if not m then say("WALK #%d no pawn", seq) return end
    local w = { seq = seq, start = posOf(m), inputs = 0, fails = 0 }
    S.walk = w
    local ok, h = pcall(LoopInGameThreadWithDelay, 30, function()
        if S.walk ~= w then return true end
        local p = me()
        if not p then return end
        local okI = pcall(function()
            local f = p:GetActorForwardVector()
            p:AddMovementInput({ X = -f.X, Y = -f.Y, Z = 0 }, 1.0, false)
        end)
        if okI then w.inputs = w.inputs + 1 else w.fails = w.fails + 1 end
    end)
    if ok then w.handle = h say("WALK #%d start (%s)", seq, posStr(w.start))
    else S.walk = nil say("WALK #%d no game-thread loop: %s", seq, tostring(h)) end
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
        if IS_HOST then
            for _, sky in ipairs(FindAllOf("Ultra_Dynamic_Sky_C") or {}) do
                if notDefault(sky) then
                    local okS = pcall(function() sky["Animate Time of Day"] = false end)
                    local t = "?" pcall(function() t = string.format("%.0f", num(sky["Time of Day"])) end)
                    say("SKY frozen at %s ok=%s", t, tostring(okS))
                end
            end
        end
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
-- Story 5 (host-spawn): every grab-class enemy but the Husk, each on B, never flipped here.
-- Story 11: the Watcher last, so a regression there can't cascade into the other cases.
local SPAWN_CASES = {
    { name = "Meek", path = "/Game/AI/SCP_AI.SCP_AI_C", target = "other", flip = false, wanted = 1 },
    { name = "Mimic", path = "/Game/AI/Mimic_AI.Mimic_AI_C", target = "other", flip = false, wanted = 1 },
    { name = "Psycho", path = "/Game/AI/MadPatent_AI.MadPatent_AI_C", target = "other", flip = false, wanted = 1 },
    { name = "Stalker", path = "/Game/AI/Stalker_AI.Stalker_AI_C", target = "other", flip = false, wanted = 1 },
    { name = "Watcher", path = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C", target = "other", flip = false, wanted = 1, near = true },
}
ENEMY_OF["Stalker_AI_C"] = "Stalker"
-- Story 10 (measure.txt): the Watcher's EyeGouge and one more execution, the Meek's.
if MEASURE then SPAWN_CASES = { SPAWN_CASES[1], SPAWN_CASES[5] } end
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

S.infQueue = {}
local function installInfectionHook()
    hook(FPC_PATH .. ":StartInfectionProcess", function(self)
        local v = get(self)
        if not valid(v) then return end
        S.infQueue[#S.infQueue + 1] = { path = pathOf(v), at = os.clock() }
    end)
    -- Story 11 (host-spawn): the host decides a playable monster from StartedInfection? at the death itself, which can
    -- come within a second of an execution's infection (d5-host-vanilla 2026-11-19: the Meek's StabAndDump infected B
    -- at 03:15:32.0, B died at 32.9, the 2 s guard cleared at 33.7, too late). The flag is set by the multicast
    -- UpdateInfectionStatus(bool, Char) (BP_FirstPersonCharacter_C.cpp:18000), so clear it in that hook, after its body.
    if ROLE == "host-spawn" then
        hook(FPC_PATH .. ":UpdateInfectionStatus", function(_, b, char)
            if get(b) ~= true then return end
            local c = get(char)
            if not valid(c) then return end
            local okW = pcall(function() c["StartedInfection?"] = false end)
            say("INFECTCLEAR host at once victim=%s StartedInfection? -> false ok=%s hp=%s", who(c), tostring(okW), fmt1(hpOf(c)))
        end)
    end
end
local function infectionTick()
    while #S.infQueue > 0 and os.clock() - S.infQueue[1].at >= 0.2 do
        local q = table.remove(S.infQueue, 1)
        local v = StaticFindObject(q.path)
        if valid(v) then
            local okA, act = pcall(function() return KSL():K2_IsTimerActive(v, "BecomeInfected") end)
            local okR, rem = pcall(function() return KSL():K2_GetTimerRemainingTime(v, "BecomeInfected") end)
            local okL, loc = pcall(function() return StaticFindObject("/Script/NuclearNightmare.Default__NNInfectedControllerLibrary"):IsLocalInfectionRecipient(v) end)
            local st = "?" pcall(function() st = tostring(v["StartedInfection?"]) end)
            S.infN = (S.infN or 0) + 1
            say("INFECT #%d victim=%s here: recipient=%s timer=%s remaining=%s StartedInfection?=%s", S.infN, who(v),
                okL and tostring(loc) or "err", okA and tostring(act) or "err", okR and string.format("%.1f", num(rem) or -1) or "err", st)
            if okA and act == true then
                local okC = pcall(function() KSL():K2_ClearTimer(v, "BecomeInfected") end)
                pcall(function() v["StartedInfection?"] = false end)
                local okB, after = pcall(function() return KSL():K2_IsTimerActive(v, "BecomeInfected") end)
                say("INFECTCLEAR #%d victim=%s ok=%s active after=%s", S.infN, who(v), tostring(okC), okB and tostring(after) or "err")
            end
        end
    end
end

-- noInfect: no infection hook (it clears an infection timer; every role installs it since story 11).
local function installGrabHooks(noInfect)
    if not noInfect then installInfectionHook() end
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
            local dNow = "?"
            pcall(function() dNow = tostring(num(gameState().Diffculty)) end)
            -- Story 11: a Watcher's chase Target and AttackedPlayer, read here (after the body), at the end of the line.
            local wf = ""
            if valid(attacker) and classOf(attacker) == "EyeMonster_AI_C" then
                local t, ap
                pcall(function() t = attacker.Target end)
                pcall(function() ap = attacker.AttackedPlayer end)
                wf = string.format(" target=%s attacked=%s", whoP(t), whoP(ap))
            end
            say("GRAB #%d %s %s victim=%s hpSeen=%s hpNow=%s montage=%s diff=%s (start %s)%s", S.seq, enemyName(attacker), g.fn:match(":(.+)$"),
                who(victim), fmt1(hpSeen), fmt1(hpOf(victim)), valid(victim) and montageOf(victim) or "?", dNow, tostring(S.diff), wf)
            S.anyGrabAt = os.clock()
            if isMe(victim) then
                S.grabsOnMe = S.grabsOnMe + 1 S.ownGrabAt = { t = os.clock(), n = 0, seq = S.seq }
                -- Story 10: B's walk restarts with each grab on it (a running one ends here).
                if MEASURE and not IS_HOST then
                    walkStop("cut by grab #" .. S.seq)
                    S.walkFor = { t = os.clock(), seq = S.seq }
                    S.myPosAt = { t = os.clock(), n = 0, seq = S.seq }
                end
            end
            if isOther(victim) then
                S.hostGrabAt = { t = os.clock(), n = 0, seq = S.seq }
                -- Story 10: the host's view of B once a second for 16 s (OTHERPOS).
                if IS_HOST then S.posAt = { t = os.clock(), n = 0, seq = S.seq } end
            end
            local c = S.case
            -- A case counts only grabs on its own target (a Meek sent at B can pick the host instead).
            local onTarget = (c and c.target == "me") and isMe(victim) or (c and c.target ~= "me" and isOther(victim))
            if c and onTarget and valid(attacker) and pathOf(attacker) == c.actor then c.grabs = (c.grabs or 0) + 1 c.lastGrab = os.clock() end
        end)
    end
end

-- Host: damage compensation (every enemy hit on either player costs PROBE_HIT, MEASURE_HIT with measure.txt), as the
-- mod's Health compensation.
local function compensate(victim, amount, why)
    if not (isMe(victim) or isOther(victim)) or not amount or amount <= 2 then return end
    local hp = hpOf(victim)
    if not hp then return end
    local new = hp + amount - (MEASURE and MEASURE_HIT or PROBE_HIT)
    -- measure.txt: never below 1 HP after the hit (a 4th hit in one case would kill B, and a dead B reads as stuck).
    if MEASURE and new - amount < 1 then new = amount + 1 end
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
    infectionTick()
    for i = #S.pending, 1, -1 do restore(S.pending[i], "next tick") table.remove(S.pending, i) end
    local m, o = me(), other()
    local mp, op = m and pathOf(m) or "none", o and pathOf(o) or "none"
    if S.lastMe ~= nil and (mp ~= S.lastMe or op ~= S.lastOther) then
        say("CHANGE me %s -> %s, other %s -> %s", S.lastMe, mp, S.lastOther, op)
        whereAre("change")
    end
    S.lastMe, S.lastOther = mp, op
    -- Host, once the steps begin: no natural enemies (only the case's), and nobody freezes outside the hold phase.
    if IS_HOST and S.guard and os.clock() - (S.guardAt or 0) >= 2 then
        S.guardAt = os.clock()
        clearNatural(S.case and S.case.actor)
        if not S.tempHold then for _, ch in ipairs({ m, o }) do if ch then pcall(function() ch.Temperature = 0 end) end end end
        -- Story 11 (host-spawn): the host's own StartedInfection? decides a playable monster at death, and a client's
        -- clear of its own timer doesn't reach it (d5-grab-unmodded 2026-11-17: B turned into a monster after the
        -- Watcher's execution infected it). Cleared here for both players, a dying body included (not a Health write).
        if ROLE == "host-spawn" then
            for _, ch in ipairs({ m, o }) do
                local okI, inf = pcall(function() return ch and ch["StartedInfection?"] end)
                if okI and inf == true then
                    pcall(function() KSL():K2_ClearTimer(ch, "BecomeInfected") end)
                    local okW = pcall(function() ch["StartedInfection?"] = false end)
                    say("INFECTCLEAR host guard victim=%s StartedInfection? -> false ok=%s hp=%s", who(ch), tostring(okW), fmt1(hpOf(ch)))
                end
            end
        end
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
    -- 6, 12 and 16 s after a grab (5 s too with measure.txt: just before Difficulty's recovery at 6 s): the victim's
    -- state on this machine and where it stands (no recovery is forced here: does it come back alone?).
    for _, k in ipairs({ "ownGrabAt", "hostGrabAt" }) do
        local g = S[k]
        local ch = k == "ownGrabAt" and m or o
        if g and ch then
            local at = AFTER_AT[g.n + 1]
            if at and os.clock() - g.t >= at then
                g.n = g.n + 1
                say("AFTERGRAB #%d %s %d s: %s %s", g.seq, k == "ownGrabAt" and "me" or "other", at, stateOf(ch), posStr(posOf(ch)))
                if g.n >= #AFTER_AT then S[k] = nil end
            end
        end
    end
    -- Story 10: once a second for 16 s after a grab on B, B's position, montage, PlayingMontage and movement mode: the
    -- host's view (OTHERPOS), and with measure.txt B's own (MYPOS). A newer grab on B starts a new window.
    for _, w in ipairs({ { k = "posAt", tag = "OTHERPOS", ch = o, on = IS_HOST }, { k = "myPosAt", tag = "MYPOS", ch = m, on = MEASURE and not IS_HOST } }) do
        local p = S[w.k]
        if w.on and p and w.ch and os.clock() - p.t >= p.n + 1 then
            p.n = p.n + 1
            say("%s #%d t=%d %s %s", w.tag, p.seq, p.n, posStr(posOf(w.ch)), stateOf(w.ch))
            if p.n >= 16 then S[w.k] = nil end
        end
    end
    -- Story 10: B walks from +1 s to +16 s after a grab on it (input while it is held does nothing: a player would
    -- keep pressing too), so it moves as soon as the game lets it.
    if MEASURE and not IS_HOST and S.walkFor then
        local w = S.walkFor
        local dt = os.clock() - w.t
        if not w.started and dt >= 1 then w.started = true walkStart(w.seq) end
        if dt >= 16 then walkStop("done") S.walkFor = nil end
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
            if not target then check(false, "CASE %s: no target", label) whereAre("no target") return end
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
                if not tg then say("CASE %s: target gone", label) whereAre("target gone") return true end
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
                -- Enemies grab again every ~6 s, so end 13 s after the wanted grab (both machines log its 6 s and 12 s states).
                if (c.grabs or 0) >= c.wanted then
                    c.tEnough = c.tEnough or os.clock()
                    if os.clock() - c.tEnough >= 13 then return true end
                end
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

-- Story 5: the host spawns, the real Difficulty decides. Story 11: the host out of B's way, hp <= 0 is dead, and a dead
-- player is revived specifically (never a refilled corpse, never the wrong player).
local MONSTER = "BP_ThirdPersonCharacter_C" -- the playable-monster pawn: not in the reinforcement queue
local HOST_AWAY = 2500                      -- cm: the host's least distance from B at each spawn
local AWAY_OFFSETS = { { 2600, 0, 100 }, { -2600, 0, 100 }, { 0, 2600, 100 }, { 0, -2600, 100 }, { 1900, 1900, 100 },
                       { -1900, -1900, 100 }, { 1900, -1900, 100 }, { -1900, 1900, 100 }, { 2600, 0, 600 },
                       { -2600, 0, 600 }, { 0, 2600, 600 }, { 0, -2600, 600 } }
local function dead(ch) local h = hpOf(ch) return h ~= nil and h <= 0 end
local function distance(a, b)
    local ok, d = pcall(function()
        local x, y = a:K2_GetActorLocation(), b:K2_GetActorLocation()
        return math.sqrt((x.X - y.X) ^ 2 + (x.Y - y.Y) ^ 2 + (x.Z - y.Z) ^ 2)
    end)
    return ok and d or nil
end
-- The host at least HOST_AWAY from B: K2_TeleportTo around B, several directions, each one measured.
local function moveHost(b)
    local m = me()
    if not m then check(false, "MOVE host: no host character") return end
    local d = distance(m, b)
    if d and d >= HOST_AWAY then say("MOVE host %.0f cm from B (already)", d) return end
    local okL, loc = pcall(function() return b:K2_GetActorLocation() end)
    local okR, rot = pcall(function() return m:K2_GetActorRotation() end)
    if okL and okR then
        for i, o in ipairs(AWAY_OFFSETS) do
            local okT, r = pcall(function() return m:K2_TeleportTo({ X = loc.X + o[1], Y = loc.Y + o[2], Z = loc.Z + o[3] }, rot) end)
            d = distance(m, b)
            if d and d >= HOST_AWAY then say("MOVE host %.0f cm from B (try %d)", d, i) return end
            say("MOVE try %d teleport ok=%s returned=%s: %s cm from B", i, tostring(okT), tostring(r), d and string.format("%.0f", d) or "?")
        end
    end
    check(false, "MOVE host: no teleport reached %d cm from B (%s cm)", HOST_AWAY, d and string.format("%.0f", d) or "?")
end
-- Story 11 (watcher-near.txt): the host within HOST_NEAR of B, first a little in front of B (between B and the spawn, a
-- bit to the side), facing where B faces (the spawn), each try measured. In front: the Watcher chases B (its Target, B
-- is who it spawned at) but grabs its attack context's locked victim (AttackMulti(chance, GetLockedVictim),
-- EyeMonster_AI_C.cpp:2027-2033), so a host nearer the Watcher can be grabbed while B is the Target, the mismatch the
-- victim rule handles; beside B, B was both (second host-near run, d5-grab-modded-20261117-184447). The facing matters:
-- the Watcher only changes its speed while its Target looks at it (EyeMonster_AI_C.cpp:2187-2207, dot >= 0.95), so a
-- host Target looking away left it standing (first host-near run, d5-grab-modded-20261117-183343: no grab in 120 s).
local HOST_NEAR = 200
local NEAR_OFFSETS = { { 150, 50, 0 }, { 150, -50, 0 }, { 120, 60, 30 }, { 120, -60, 30 }, { 0, 150, 0 }, { 0, -150, 0 },
                       { -150, 0, 0 }, { 0, 120, 30 }, { 0, -120, 30 } } -- { forward, right, up } in B's frame, cm

-- The host's actor and control rotation set to B's yaw (pitch 0).
local function faceLikeB(m, b)
    local okR, r = pcall(function() return b:K2_GetActorRotation() end)
    if not okR or not r then say("FACE host: no B rotation") return end
    local yaw = num(r.Yaw) or 0
    local rot = { Pitch = 0, Yaw = yaw, Roll = 0 }
    local okA = pcall(function() m:K2_SetActorRotation(rot, false) end)
    local okC = pcall(function() pc():SetControlRotation(rot) end)
    say("FACE host yaw=%.0f actor=%s control=%s", yaw, tostring(okA), tostring(okC))
end
local function moveHostNear(b, why)
    local m = me()
    if not m then check(false, "MOVE host near: no host character") return end
    local d = distance(m, b)
    if d and d <= HOST_NEAR then say("MOVE host %.0f cm from B (near, %s, already)", d, why) faceLikeB(m, b) return end
    local okL, loc = pcall(function() return b:K2_GetActorLocation() end)
    local okF, fwd = pcall(function() return b:GetActorForwardVector() end)
    local okG, rgt = pcall(function() return b:GetActorRightVector() end)
    local okR, rot = pcall(function() return b:K2_GetActorRotation() end)
    if okL and okF and okG and okR then
        for i, o in ipairs(NEAR_OFFSETS) do
            local at = { X = loc.X + fwd.X * o[1] + rgt.X * o[2], Y = loc.Y + fwd.Y * o[1] + rgt.Y * o[2], Z = loc.Z + o[3] }
            local okT, r = pcall(function() return m:K2_TeleportTo(at, rot) end)
            d = distance(m, b)
            if d and d <= HOST_NEAR then say("MOVE host %.0f cm from B (near, %s, try %d)", d, why, i) faceLikeB(m, b) return end
            say("MOVE near try %d teleport ok=%s returned=%s: %s cm from B", i, tostring(okT), tostring(r), d and string.format("%.0f", d) or "?")
        end
    end
    check(false, "MOVE host near: no teleport reached %d cm of B (%s cm)", HOST_NEAR, d and string.format("%.0f", d) or "?")
end
-- watcher-near: what the Watcher does (its chase Target and AttackedPlayer, distances, speed), every 5 s of the case.
local function watchState(path, b)
    local w = path and StaticFindObject(path)
    if not valid(w) then say("WATCH watcher gone") return end
    local t, ap, sp
    pcall(function() t = w.Target end)
    pcall(function() ap = w.AttackedPlayer end)
    pcall(function() sp = num(w.CharacterMovement.MaxWalkSpeed) end)
    local m = me()
    local dB, dH = b and distance(w, b), m and distance(w, m)
    say("WATCH target=%s attacked=%s toB=%s toHost=%s hostToB=%s speed=%s", whoP(t), whoP(ap),
        dB and string.format("%.0f", dB) or "?", dH and string.format("%.0f", dH) or "?",
        (m and b and distance(m, b)) and string.format("%.0f", distance(m, b)) or "?", sp and string.format("%.0f", sp) or "?")
end

-- revive(tag, whom): whom "B" (other(), B's controller, the dead path S.bPath) or "host" (me(), the local controller,
-- S.hostPath). Nothing to do while that player has a live character. Else: wait up to 30 s for the real death (the
-- controller no longer holds the dead character); a playable monster is a FAIL at once; then
-- ReinforceSpecficPlayer(<dead character>), and Reinformant() every 5 s, up to 6 tries, until a new character is there.
-- The checker's line contract (difficulty-scenarios.ps1, unchanged): per B death exactly one line matching
-- "^REVIVE .* radio:Reinformant\(\)", per B revive exactly one "REVIVE <tag> B back after <n> s"; the retries (RETRY)
-- and the host's lines (REVIVE-HOST) match neither.
local function revive(tag, whom)
    local isB = whom == "B"
    local function char() if isB then return other() end return me() end
    local function held() if isB then return remotePawn() end return pawnOf(pc()) end
    local pre = isB and "REVIVE" or "REVIVE-HOST"
    step(tag .. ": " .. whom .. " alive", function()
        local c = char()
        if c and not dead(c) then return end
        local deadPath = isB and S.bPath or S.hostPath
        if c then deadPath = pathOf(c) end
        whereAre(tag .. " " .. whom .. " dead")
        local t0, t1, tries, nextTry, phase = os.clock(), nil, 0, nil, "death"
        return function()
            local now = os.clock()
            local p = held()
            if p and classOf(p) == MONSTER then
                check(false, "%s %s: %s is a playable monster (%s); no revive possible", pre, tag, whom, pathOf(p))
                return true
            end
            if phase == "death" then
                local holds = p ~= nil and deadPath ~= nil and pathOf(p) == deadPath
                if holds and now - t0 < 30 then return false end
                if holds then say("%s-WAIT %s %s's controller still holds %s after 30 s", pre, tag, whom, deadPath) end
                local r = radio()
                local corpse = deadPath and StaticFindObject(deadPath)
                local ok, err = false, r and "the dead character is gone" or "no radio"
                if r and valid(corpse) then ok, err = pcall(function() r:ReinforceSpecficPlayer(corpse) end) end
                say("%s %s %s dead after %.0f s: radio:ReinforceSpecficPlayer(%s) ok=%s %s; radio:Reinformant() every 5 s as the fallback",
                    pre, tag, whom, now - t0, whom, tostring(ok), ok and "" or tostring(err))
                phase, t1, nextTry = "back", now, now + 5
                return false
            end
            local c2 = char()
            if c2 and pathOf(c2) ~= deadPath and not dead(c2) then
                say("%s %s %s back after %.0f s", pre, tag, whom, now - t1)
                return true
            end
            if now >= nextTry then
                if tries >= 6 then
                    check(false, "%s %s: %s not back after ReinforceSpecficPlayer and %d Reinformant() tries", pre, tag, whom, tries)
                    whereAre(tag .. " " .. whom .. " not back")
                    return true
                end
                tries, nextTry = tries + 1, now + 5
                local r = radio()
                local ok, err = false, "no radio"
                if r then ok, err = pcall(function() r:Reinformant() end) end
                say("RETRY %s %s Reinformant #%d ok=%s %s", tag, whom, tries, tostring(ok), ok and "" or tostring(err))
            end
            return false
        end, 100, tag .. ": " .. whom .. " revived"
    end)
end
-- B first (the case's player), then the host if it has no character.
local function reviveB(tag) revive(tag, "B") revive(tag, "host") end
local function buildHostSpawn()
    waitMatch()
    step("other present", function() return function() return other() ~= nil end, 600, "the other player's character" end)
    waitFile("bready", 600)
    -- Spawn only after the lobby countdown: Difficulty acts from its match start (UpdateFriendlyFire), and the lobby
    -- runs on the match map, so waitMatch() alone returns during the countdown (pair runs 2026-11-15).
    step("match started", function()
        return function()
            local ok, st = pcall(function() return gameState()["StartedGame?"] end)
            return ok and st == true
        end, 600, "StartedGame?"
    end)
    wait("after the start", 10)
    step("difficulty after the start", function()
        local ok, d = pcall(function() return num(gameState().Diffculty) end)
        S.diff = ok and d or S.diff
        say("STARTED Diffculty=%s", tostring(d))
    end)
    -- Story 11: story 2's infection hook too (it clears the BecomeInfected timer), so infection doesn't end a case.
    -- Story 10 (measure.txt): the damage hooks too, so each enemy hit costs MEASURE_HIT and an execution doesn't kill.
    step("hooks", function() installGrabHooks(false) if MEASURE then installDamageHooks() end S.guard = true end)
    for _, c in ipairs(SPAWN_CASES) do
        local label = c.name .. " on B"
        reviveB("before " .. c.name)
        step("spawn " .. label, function()
            local target = other()
            if not target or dead(target) then check(false, "CASE %s: no live target", label) whereAre("no target") return end
            S.bPath = pathOf(target)
            local m = me()
            if m then S.hostPath = pathOf(m) end
            -- The host: refilled only while alive, then out of the enemies' reach.
            local hh = m and hpOf(m)
            if hh and hh > 0 and hh < 100 then pcall(function() m.Health = 100 end) say("REFILL me hp %.2f -> 100 (before the spawn)", hh) end
            local near = c.near and WATCHER_NEAR
            if near then moveHostNear(target, "spawn") else moveHost(target) end
            local h = hpOf(target)
            if h and h > 0 and h < 100 then pcall(function() target.Health = 100 end) say("REFILL other hp %.2f -> 100 (between cases)", h) end
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
                local tg = other()
                if not tg or dead(tg) then
                    say("CASE %s: B died (grabs=%d hp=%s)", label, c.grabs or 0, tg and fmt1(hpOf(tg)) or "none")
                    c.died = true
                    return true
                end
                if os.clock() - (c.clearAt or 0) >= 2 then c.clearAt = os.clock() clearNatural(c.actor) end
                -- watcher-near: the host back within 2 m of B when it drifted, only while alive and outside a grab
                -- window (10 s after any grab on either player).
                if near and os.clock() - (c.nearAt or 0) >= 5 then
                    c.nearAt = os.clock()
                    watchState(c.actor, tg)

                    local m2 = me()
                    if m2 and not dead(m2) and os.clock() - (S.anyGrabAt or -100) >= 10 then
                        local d2 = distance(m2, tg)
                        if d2 and d2 > HOST_NEAR then moveHostNear(tg, "drifted") end
                    end
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
                -- B logs its own 6 s state (AFTERGRAB); end 9 s after the first grab. measure.txt: 17 s after it, and
                -- only while the host sees B free (no montage playing, walking), so no enemy is despawned while it
                -- holds B (the despawn kept B stuck on 2026-11-15).
                if (c.grabs or 0) >= c.wanted then
                    c.tEnough = c.tEnough or os.clock()
                    if not MEASURE and os.clock() - c.tEnough >= 9 then return true end
                    if MEASURE and os.clock() - c.tEnough >= 17 then
                        local pm, mode
                        pcall(function() pm = tg.PlayingMontage end)
                        pcall(function() mode = num(tg.CharacterMovement.MovementMode) end)
                        if pm == false and mode == 1 then return true end
                    end
                end
                if os.clock() - t0 > 120 then say("TIMEOUT %s grabs=%d", label, c.grabs or 0) return true end
                return false
            end, 130, label
        end)
        step("despawn " .. label, function()
            say("CASE end %s grabs=%d died=%s", label, c.grabs or 0, tostring(c.died == true))
            check((c.grabs or 0) >= 1, "CASE %s: at least one grab on B (%d)", label, c.grabs or 0)
            S.case = nil
            local x = c.actor and StaticFindObject(c.actor)
            if valid(x) then pcall(function() x:K2_DestroyActor() end) end
            -- Refill only outside a grab window: 8 s after the last grab on B (measure.txt: 17 s, after its 16 s of
            -- OTHERPOS and MYPOS lines).
            local win = MEASURE and 17 or 8
            return function() return not c.lastGrab or os.clock() - c.lastGrab >= win end, win + 12, "the grab window over"
        end)
        step("refill after " .. label, function()
            local o = other()
            local h = o and hpOf(o)
            -- Never a body at hp <= 0 (a refilled corpse stays frozen, or turns into a playable monster).
            if o and h and h > 0 and h < 100 then pcall(function() o.Health = 100 end) say("REFILL other hp %.2f -> 100 (after the case)", h) end
        end)
    end
    reviveB("final")
    step("done", function()
        local o = other()
        say("FINAL other %s", o and stateOf(o) or "gone")
        signal("done")
        return after(8), 12
    end)
end

local function buildClientGrab()
    waitMatch()
    step("ready", function() installGrabHooks(false) signal("bready") end)
    -- Story 10 (measure.txt): B's walk with no grab first, 3 s, the baseline for the WALK distances after grabs.
    if MEASURE then
        step("baseline walk", function() walkStart(0) return after(3), 8 end)
        step("baseline walk end", function() walkStop("baseline") end)
    end
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
-- The host kills a player (itself or B): CallDamageEvent, the game's own kill call (with authority), logging V8.1.5's
-- terminal-death guard first; Health 0 + DeathEvent as a fallback after 5 s. Waits until that character is gone.
local function deathGuard(ch)
    local lib = StaticFindObject("/Script/NuclearNightmare.Default__NNDeathFadeLibrary")
    local fn = StaticFindObject("/Script/NuclearNightmare.NNDeathFadeLibrary:CanBeginTerminalDeathEffects")
    if not (valid(lib) and valid(fn)) then return "?" end
    local ok, r = pcall(function() return fn(lib, ch) end)
    return ok and tostring(r) or ("error " .. tostring(r))
end
local function hostKill(tag, whom)
    step(tag .. ": kill " .. whom, function()
        local p = whom == "me" and me() or other()
        if not p then say("KILL %s no %s", tag, whom) return end
        local was = pathOf(p)
        if whom == "me" then S.deadPath = was else S.otherPath = was end
        say("KILL %s %s guard=%s %s", tag, whom, deathGuard(p), stateOf(p))
        local ok, err = pcall(function() p:CallDamageEvent(1000) end)
        say("KILL %s CallDamageEvent(1000) on %s ok=%s %s", tag, whom, tostring(ok), ok and "" or tostring(err))
        local t0, again = os.clock(), false
        return function()
            local q = whom == "me" and me() or other()
            if not q or pathOf(q) ~= was then
                if not S.killLogged then S.killLogged = true whereAre(tag .. " dead") end
                return os.clock() - t0 > 3
            end
            if not again and os.clock() - t0 > 5 then
                again = true
                say("KILL %s still there after 5 s: guard=%s %s", tag, deathGuard(q), stateOf(q))
                pcall(function() q.Health = 0 end)
                local ok2, e2 = pcall(function() q:DeathEvent() end)
                say("KILL %s Health 0 + DeathEvent ok=%s %s", tag, tostring(ok2), ok2 and "" or tostring(e2))
            end
            return false
        end, 30, tag .. " dead"
    end)
    step(tag .. ": reset", function() S.killLogged = false end)
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
    hostKill("s1", "me")
    wait("s1 settle", 10)
    step("s1 computer", function()
        -- The terminal opens only on a powered computer the player stands at (test only).
        local r, o = radio(), other()
        local okP = pcall(function() r:ToggleEquipment(true) end)
        local okM = pcall(function()
            local at = r:K2_GetActorLocation()
            o:K2_TeleportTo({ X = at.X - 120, Y = at.Y, Z = at.Z + 100 }, o:K2_GetActorRotation())
        end)
        say("COMPUTER powered=%s poweredOn=%s B moved=%s", tostring(okP), tostring(r["PoweredOn?"]), tostring(okM))
        return after(2), 4
    end)
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
    step("s4 signal", function() signal("kill-b") end)
    hostKill("s4", "other")
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

-- Client: open the native terminal (V8.2) on its own pawn, log the panel, close it. The panel is the opener's
-- RadioTerminal.OriginalWidget, else any NukeComputer_UI_C: it lives on the computer's screen, not in the viewport.
local function myTerminal()
    local m = me()
    local t
    if m then pcall(function() t = m.RadioTerminal end) end
    return valid(t) and t or nil
end
local function terminalActive()
    local t = myTerminal()
    if not t then return false end
    local ok, a = pcall(function() return t:IsTerminalActive() end)
    return ok and a == true
end
local function panelState(tag)
    local t = myTerminal()
    local w
    if t then pcall(function() w = t.OriginalWidget end) end
    local via = "OriginalWidget"
    local list = { w }
    if not valid(w) then via, list = "FindAllOf", FindAllOf("NukeComputer_UI_C") or {} end
    local any = false
    for _, x in ipairs(list) do
        if valid(x) and not pathOf(x):find("Default__", 1, true) then
            any = true
            local okB, vis = pcall(function() return x.ReinforcementBorder:GetVisibility() end)
            say("PANEL %s computer open (%s, terminal active=%s), ReinforcementBorder visibility=%s (0 visible, 1 collapsed)", tag, via, tostring(terminalActive()), okB and tostring(vis) or "?")
        end
    end
    if not any then say("PANEL %s no computer UI (terminal active=%s)", tag, tostring(terminalActive())) end
end
local function openComputer(tag)
    step(tag .. ": open computer", function()
        local m, r, t = me(), radio(), myTerminal()
        if not (m and r and t) then say("COMPUTER %s me=%s radio=%s terminal=%s", tag, tostring(m ~= nil), tostring(r ~= nil), tostring(t ~= nil)) return end
        local cdo = StaticFindObject("/Script/NuclearNightmare.Default__NNRadioTerminalComponent")
        local ok, err = pcall(function() cdo:OpenTerminal(r, m) end)
        say("COMPUTER %s OpenTerminal ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
        return after(3), 5
    end)
    step(tag .. ": open fallback", function()
        if terminalActive() then return end
        local m, r = me(), radio()
        if not (m and r) then return end
        local ok, err = pcall(function() m:ServerInteract(r, m) end)
        say("COMPUTER %s terminal not active after OpenTerminal; ServerInteract(radio) ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
        return after(3), 5
    end)
    step(tag .. ": panel", function() reinfState(tag .. " client") panelState(tag) end)
end
local function closeComputer(tag)
    step(tag .. ": close computer", function()
        local t = myTerminal()
        local ok, err = false, "no RadioTerminal"
        if t then ok, err = pcall(function() t:CloseTerminal() end) end
        say("COMPUTER %s CloseTerminal ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
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
        local t = myTerminal()
        local ok, err = false, "no RadioTerminal"
        -- Read before the request: a fast revive replaces the host's pawn before the call returns.
        S.hostBefore = other() and pathOf(other()) or ""
        if t then ok, err = pcall(function() t:OnReinforcement() end) end
        say("REQUEST terminal OnReinforcement past the limit active=%s ok=%s %s", tostring(terminalActive()), tostring(ok), ok and "" or tostring(err))
        return after(20), 25
    end)
    step("s3 fallback", function()
        local now = other() and pathOf(other()) or ""
        say("REQUEST terminal result host before=%s now=%s moved=%s", S.hostBefore, now, tostring(now ~= S.hostBefore))
        if now ~= S.hostBefore then return end
        -- The story's blocking condition: the verdict counts this FAIL line.
        check(false, "dp-revive the native terminal refused past the limit (moved=false)")
        local r = radio()
        local ok, err = pcall(function() r:SpawnReinforcementMethod2(0) end)
        say("REQUEST fallback radio:SpawnReinforcementMethod2(0) from the client ok=%s %s", tostring(ok), ok and "" or tostring(err))
        return after(2), 4
    end)
    closeComputer("s3")
    step("s3 ack", function() signal("b-s3") end)
    waitFile("s3done", 240)
    step("s3 count", function() reinfState("s3 client, not revived") signal("b-s3done") end)
    waitFile("kill-b", 120)
    step("s4 dead", function()
        local was = pathOf(me())
        S.deadPath = was
        return function() local q = me() return not q or pathOf(q) ~= was end, 60, "s4 dead (killed by the host)"
    end)
    step("s4 where", function() whereAre("s4 dead") end)
    waitFile("s4done", 300)
    step("s4 count", function()
        local cnt = reinfState("s4 client, revived")
        say("SUMMARY revived me=%s", tostring(me() ~= nil))
        signal("b-s4done")
    end)
end

-- Story 8 (d8-tokens): the real Difficulty on the host with Reinforcement Tokens N (TOKENS_N, below the Classified
-- Minimum's stock limit); B runs no Difficulty. The host dies N times and B revives it each time through its own
-- terminal (OnReinforcement); after the N-th, Difficulty (never this driver: no SET line, no write to
-- TimesUsedReinforcements or Disable Reinforcement) sets Disable Reinforcement, and B's computer no longer offers a
-- reinforcement when the host dies once more. B checks its panel each round: offered before N, gone after.
local TOKENS_N = 2
local function buildHostTokens()
    waitMatch()
    step("other present", function() return function() return other() ~= nil end, 600, "the other player's character" end)
    waitFile("bready", 600)
    -- Difficulty's token count is written at its match start (UpdateFriendlyFire), after the lobby countdown.
    step("match started", function()
        return function()
            local ok, st = pcall(function() return gameState()["StartedGame?"] end)
            return ok and st == true
        end, 600, "StartedGame?"
    end)
    wait("after the start", 8)
    step("hooks", function() installRadioHooks() reinfState("start") S.guard = true end)
    local function round(tag, last)
        hostKill(tag, "me")
        wait(tag .. " settle", 8)
        step(tag .. " computer", function()
            -- The terminal opens only on a powered computer the player stands at (test only: B is moved there).
            local r, o = radio(), other()
            local okP = pcall(function() r:ToggleEquipment(true) end)
            local okM = pcall(function()
                local at = r:K2_GetActorLocation()
                o:K2_TeleportTo({ X = at.X - 120, Y = at.Y, Z = at.Z + 100 }, o:K2_GetActorRotation())
            end)
            say("COMPUTER powered=%s poweredOn=%s B moved=%s", tostring(okP), tostring(r and r["PoweredOn?"]), tostring(okM))
            return after(2), 4
        end)
        step(tag .. " signal", function() reinfState(tag .. " host dead") signal(tag) end)
        waitFile("b-" .. tag, 180)
        if not last then
            step(tag .. " revived", function()
                return function() local m = me() return m ~= nil and pathOf(m) ~= S.deadPath end, 90, tag .. ": the host's new character (B's request)"
            end)
            step(tag .. " count", function()
                local cnt, dis = reinfState(tag .. " host revived")
                say("TOKENROUND %s host revived count=%s disable=%s", tag, tostring(cnt), tostring(dis))
            end)
        else
            step(tag .. " final", function()
                local cnt, dis = reinfState(tag .. " host final")
                check(dis == true, "TOKENS the host's Disable Reinforcement is set after %d reinforcements (by Difficulty; got %s)", TOKENS_N, tostring(dis))
            end)
        end
    end
    for i = 1, TOKENS_N do round("t" .. i, false) end
    round("tfinal", true)
    step("done", function() signal("done") return after(8), 12 end)
end

-- B: each round opens its own terminal, logs the panel and the replicated flag, asks for the host's revive
-- (OnReinforcement) and closes it; the last round only looks: the offer must be gone.
local function buildClientTokens()
    waitMatch()
    step("ready", function() installRadioHooks() reinfState("client start") signal("bready") end)
    local function round(tag, last)
        waitFile(tag, 600)
        openComputer(tag)
        step(tag .. " offer", function()
            local _, dis = reinfState(tag .. " offer")
            local t = myTerminal()
            local w
            if t then pcall(function() w = t.OriginalWidget end) end
            local okB, vis = false, nil
            if valid(w) then okB, vis = pcall(function() return num(w.ReinforcementBorder:GetVisibility()) end) end
            local shown = terminalActive() and okB and vis == 0 and dis == false
            local gone = dis == true and (not terminalActive() or (okB and vis ~= 0))
            say("OFFER %s terminal=%s visibility=%s disable=%s", tag, tostring(terminalActive()), okB and tostring(vis) or "?", tostring(dis))
            if last then
                check(gone, "OFFER gone after the %d-th reinforcement: Disable Reinforcement %s, terminal active %s, ReinforcementBorder visibility %s (want true and not 0)",
                    TOKENS_N, tostring(dis), tostring(terminalActive()), okB and tostring(vis) or "?")
            else
                check(shown, "OFFER %s shown before N: Disable Reinforcement %s, ReinforcementBorder visibility %s (want false, 0)", tag, tostring(dis), okB and tostring(vis) or "?")
            end
        end)
        if not last then
            step(tag .. " request", function()
                local t = myTerminal()
                local ok, err = false, "no RadioTerminal"
                S.hostBefore = other() and pathOf(other()) or ""
                if t then ok, err = pcall(function() t:OnReinforcement() end) end
                say("REQUEST %s terminal OnReinforcement ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
                return after(15), 20
            end)
            step(tag .. " result", function()
                local now = other() and pathOf(other()) or ""
                say("REQUEST %s result host before=%s now=%s moved=%s", tag, S.hostBefore, now, tostring(now ~= S.hostBefore))
                check(now ~= S.hostBefore, "REVIVE %s B's terminal revived the host", tag)
            end)
        end
        closeComputer(tag)
        step(tag .. " ack", function() signal("b-" .. tag) end)
    end
    for i = 1, TOKENS_N do round("t" .. i, false) end
    round("tfinal", true)
    waitFile("done", 300)
end

if ROLE == "host-grab" or ROLE == "host-grab-vanilla" then buildHostGrab()
elseif ROLE == "host-spawn" then buildHostSpawn()
elseif ROLE == "client-grab" or ROLE == "client-observe" or ROLE == "client-watch" then buildClientGrab()
elseif ROLE == "host-revive" then buildHostRevive()
elseif ROLE == "host-tokens" then buildHostTokens()
elseif ROLE == "client-tokens" then buildClientTokens()
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
