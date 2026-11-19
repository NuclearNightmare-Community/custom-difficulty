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
--   cold-whiteout   (opt-in, never in a default list) Nightmare, Cold Exposure 50, White Outs on: the driver calls
--                   NNBlizzardController:RequestBlizzard() and samples 60 s outdoors while the storm phase runs. The
--                   rise must be above a quarter of Nightmare's stock range (the knob scales the storm's cold too);
--                   the storm never reached, or a rise inside that range, is NOTSHOWN.
--   tokens-more     Classified Minium 0 (limit 2), N 4: the computer's text shows 4; four reinforcements accepted,
--                   then Disable Reinforcement set (and not before).
--   tokens-fewer    Classified Minium 3 (limit 8), N 2: after two, Disable set and the text shows 0.
--   tokens-classified  (story 12) Classified Minium 3, N 2, Tokens per Classified 2, Max Classified Tokens 3: two
--                   reinforcements, Disable set; a classified objective completed on the host (a real intel pickup's
--                   PrimaryInteraction, else the game state's UpdateClassifieds(value + 1); CLASSIFIED says which):
--                   count 6, Disable cleared, the text 2; a second one: +1 only (capped), the text 3; three more
--                   reinforcements, then Disable at used 5 and the text 0.
--   A reinforcement goes through V8.2's native terminal first (RadioTerminal:OpenTerminal(radio, pawn), then
--   OnReinforcement(), closed with CloseTerminal() whenever it is open at the end). check.ps1 requires only that the
--   terminal opened (TERMINAL open active=true). A living solo host has nobody queued, so OnReinforcement() moves
--   nothing: after 15 s the driver logs "TERMINAL reinforce #i moved=false" and "TERMINAL OnReinforcement needs a
--   queued player", and that and every later reinforcement use the fallbacks. (A count that doesn't move past the
--   stock limit after the terminal had worked is a FAIL; solo never gets there.) The terminal route past the stock
--   limit is proven by the pair run's dp-revive s3. The fallbacks, each logged: the synthetic revive (the game state's UpdateRespawnQue + the radio's
--   ReinforceSpecficPlayer on the living host, as test/MarkersDriver did on V8.1.2) and, if the count doesn't move in
--   15 s, the radio's SpawnReinforcmentSpectator() (which has no gate), destroying the orphan character it spawns.
--   The token text is read from a NukeComputer_UI_C widget made with WidgetBlueprintLibrary:Create and never added
--   to the viewport.
-- Story 6 (menu only, no match):
--   presets         opens the create-world screen (WidgetBlueprintLibrary:Create + AddToViewport), deletes leftover
--                   DT6-* presets, saves DT6-A and DT6-B (PresetName, then the Create_1 handler), selects A
--                   (SetSelectedOption, then the OnSelectionChanged handler), updates A, selects None, deletes A,
--                   removes the screen, appends a stale line "99<tab>DT6-gone<tab>cold=50" to the sidecar, reopens,
--                   deletes B. After each step it reads Difficulty's sidecar: the DT6 entries by index and name, all
--                   Default, the baseline entries unchanged. A handler that can't be driven is NOTSHOWN.
--                   Story 14: after B, Meek's Insta-kill box is clicked through its button's click function (core's
--                   checkbox), DT6-K saved (its entry kill.meek=1), the box clicked again (unticked); after the reopen
--                   DT6-K is selected (Difficulty's PRESETS select line has kill.meek=1) and deleted at the end.
-- Story 7 (menu only, no match; VM only: real clicks, a drag and typing through run.ps1 -Target vm):
--   screen          ten opens of the create-world screen by real clicks on START GAME and Back: the 21 rows in
--                   VerticalBox_202 (knob rows at children 2-8 after Overlay_28, per-enemy rows right after
--                   Overlay_738, the game rows in the order read at Construct, one widget each), and on each open the
--                   Difficulty picker's arrows clicked for real (next, then back); an eleventh open with CONFIGURE: a
--                   drag on Enemy Damage, 57 / 999 / empty typed, Cold 150, Frostbite 2.3 (2.5), Nightmare through the
--                   Difficulty picker's handler (Default hints follow, Cold kept), a real click on that picker's arrow
--                   and on the Classified Minimum picker's (tokens hint follows), Cold cleared, a preset DT7-A with
--                   Enemy Damage 17 saved on Hard, None (rows kept), the screen on Easy, DT7-A (17, Default rows follow
--                   its Hard), DT7-A deleted; one more open starts Default on Normal. Screenshots screen-rows,
--                   screen-nightmare, screen-preset. Story 14: before the preset part, an Insta-kill box in the eight
--                   kill rows only (SCBOXES), a real click on Meek's box (Difficulty's ROWS change kill.meek=1 is
--                   check.ps1's; DT7-A is then saved with it) and the screenshot screen-kill.
-- Story 8 (the epic's success checks):
--   spread          Normal, Damage Spread 20: 200 Meek standard hits at full Health (refilled between hits), straight
--                   through the hooked static NNEnemyAttackContext:ApplyLockedDamage(<an idle spawned Meek>, 25) after
--                   TryBeginAttack locks the player (one probe call first: when it doesn't lower Health, real attacks
--                   instead, with the scenario's longer time limit). check.ps1 judges Difficulty's rolled values.
--   spread-grab     Nightmare, Enemy Damage 25, Spread 50: 20 Meek grabs, Health set to 26 before each (test only):
--                   each survivable, each leaving Health >= 1 (at most 25 taken).
--   signal-a        (VM, real input; launch 1 of signal) the create-world screen: Nightmare by real clicks on the
--                   Difficulty picker, Enemy Damage 25, Damage Spread 20, Stalker 200, Tokens per Classified 2 and Max Classified Tokens 3 typed, Cold Exposure 0 and
--                   Frostbite Damage 0 dragged to the slider's start, Reinforcement Tokens 8 dragged (typed if the drag
--                   lands elsewhere); saved as preset DT8-SIGNAL (leftover DT8-* deleted first). No dev.lua.
--   signal-b        (VM; launch 2, saves kept) DT8-SIGNAL selected, every row checked, a friends-only solo match
--                   hosted with the screen's Create button (real click): a Meek grab at full Health (15..35 taken), a
--                   Stalker grab (30..70), 60 s outdoors without the meter rising, the computer's text 8 tokens; then
--                   back to the menu, DT8-SIGNAL deleted. No dev.lua.
--   no-core, old-core  (menu only) waits for the menu world and 20 s, so the run reaches the menu; Difficulty's one
--                   line is check.ps1's.
-- Story 13 (difficulty v1; the bosses' finisher grabs, observed, no fix):
--   boss            Nightmare, Enemy Damage 25: the Slug Queen, then the Apex Predator, spawned near the player and
--                   made to grab (ladder: the player teleported about 100 uu in front of the boss and the boss nudged
--                   every 2 s, the Queen with SeePlayerServer(player), the Apex with HeardNoise(playerLocation, 1.0);
--                   after 20 s without CommitLethalDamage, the player teleported in front again and AttackServer(player)
--                   every 5 s; 60 s without one is NOTSHOWN, extended by up to 20 s while a grab is under way). Logs
--                   CommitLethalDamage's Health in/out and return (BOSSCLD), StartWatching, WatchFinisherPresentation
--                   and AttackMulti (BOSSHOOK), and the player at 0, 6 and 12 s (BOSSSTATE). Verdicts per boss: alive
--                   at 12 s with Health >= 1, and moving at 12 s (PlayingMontage false, movement 1).
--   boss-default    the same with no knobs (the control): OK when the stock grab kills (alive=false by 12 s). That
--                   death is expected: BOSSDEATH <boss> expected (stock), never DEATH, and the run ends there (a
--                   remaining Apex is "NOTSHOWN Apex: the control player is dead", not counted).
-- Story 14 (difficulty v1; the Insta-kill boxes):
--   insta-kill      Normal, kill.meek=1: a Stalker grab at 100 HP takes the stock 25 and the player moves again 8 s
--                   after the hit (an unticked enemy is unchanged); then a Meek grab at 100 HP plays the execution
--                   (StabAndDump: Difficulty flips the game's survivable test) and its hit leaves Health <= 0. That
--                   death is expected: INSTAKILL <case> death expected (the pawn gone, or Health <= 0 for 12 s), never
--                   DEATH, and the run ends there.
--   insta-kill-boss Nightmare, Enemy Damage 25, kill.slugQueen=1: as boss, the Apex first (alive at 12 s with 75 HP,
--                   moving), then the Slug Queen: the stock presentation and the player dead at 12 s (BOSSDEATH Slug
--                   Queen expected (insta-kill)); the run ends there.
-- White Outs: every scenario sets the game instance's DisableWhiteOuts before the match (cold-whiteout clears it) and
-- logs one WHITEOUT line after the start; check.ps1 requires disabled=true, or disabled=false for cold-whiteout.
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
    ["cold-whiteout"] = { diff = 0, special = "cold", factor = 0.25, whiteouts = true, cases = {} }, -- opt-in
    ["frostbite"] = { diff = 2, special = "frost", want = 60, tol = 6, cases = {} },
    ["frostbite-zero"] = { diff = 2, special = "frost", want = 0, tol = 0.05, cases = {} },
    ["tokens-more"] = { diff = 2, special = "tokens", cm = 0, limit = 2, n = 4, cases = {} },
    ["tokens-fewer"] = { diff = 2, special = "tokens", cm = 3, limit = 8, n = 2, cases = {} },
    -- Story 12: revives=2 classifiedTokens=2 classifiedTokensMax=3 (deploy.ps1): two objectives give +2, then +1 (capped).
    ["tokens-classified"] = { diff = 2, special = "tokens", cm = 3, limit = 8, n = 2, classified = { adds = { 2, 1 } }, cases = {} },
    -- Story 6: the main menu only (no match, no WHITEOUT line).
    ["presets"] = { diff = 2, special = "presets", cases = {} },
    -- Story 7: the rows on the create-world screen (the main menu only; real input, VM only).
    ["screen"] = { diff = 2, special = "screen", cases = {} },
    -- Story 8.
    ["spread"] = { diff = 2, special = "spread", n = 200, cases = {} },
    ["spread-grab"] = { diff = 0, cases = {} }, -- 20 grab cases, below
    ["signal-a"] = { diff = 2, special = "signal-a", cases = {} },
    ["signal-b"] = { diff = 0, special = "signal-b", cases = {
        { enemy = MEEK, lo = 15, hi = 35, grab = true }, -- Enemy Damage 25, Spread 20: 25 +- 2 sigma
        { enemy = STALKER, lo = 30, hi = 70 },           -- Stalker 200 %: 50 +- 2 sigma
    } },
    ["no-core"] = { diff = 2, special = "menu", cases = {} },
    ["old-core"] = { diff = 2, special = "menu", cases = {} },
    -- Story 13: the bosses' finisher grabs (Nightmare; boss Enemy Damage 25, boss-default the stock control).
    ["boss"] = { diff = 0, special = "boss", cases = {} },
    ["boss-default"] = { diff = 0, special = "boss", control = true, cases = {} },
    -- Story 14: the Insta-kill boxes (insta-kill: kill.meek=1 on Normal; insta-kill-boss: Enemy Damage 25 and
    -- kill.slugQueen=1 on Nightmare, the Apex first).
    ["insta-kill"] = { diff = 2, cases = {
        { enemy = STALKER, want = 25, tol = 0.05, moves = true, moveAfterHit = true, moveDelay = 8 }, -- unticked: stock
        { enemy = MEEK, kills = true, execution = "StabAndDump" },                                     -- ticked: killed
    } },
    ["insta-kill-boss"] = { diff = 0, special = "boss", kill = "SlugQueen_AI_C", order = { "Apex", "Slug Queen" }, apexHp = 75, cases = {} },
}
-- spread-grab: 20 Meek grabs, each at Health 26 (E 25: survivable; the hit takes at most 25).
for _ = 1, 20 do
    local t = SCENARIOS["spread-grab"].cases
    t[#t + 1] = { enemy = MEEK, base = 26, maxLoss = 25, grab = true }
end
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
-- The match's severe-blizzard director (native; nil where the map has none).
local function director()
    for _, b in ipairs(FindAllOf("NNBlizzardController") or {}) do if notDefault(b) and alive(b) then return b end end
    return nil
end
local function phaseOf(b) local ok, p = pcall(function() return num(b.Phase) end) return ok and p or nil end
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
    local loss = hp and ((c.base or 100) - hp) or nil
    if c.lo then -- a rolled hit: within the knob's 2-sigma range
        check(loss ~= nil and loss >= c.lo - 0.05 and loss <= c.hi + 0.05, "%s %s hit took %s HP (want %s..%s) via %s, hp now %s", SCENARIO, c.label, fmt1(loss), fmt1(c.lo), fmt1(c.hi), via, fmt1(hp))
    elseif c.kills then -- story 14: a ticked enemy's grab kills (at least Health applied)
        check(hp ~= nil and hp <= 0, "%s %s the grab's hit killed: took %s HP, hp now %s (want Health <= 0) via %s", SCENARIO, c.label, fmt1(loss), fmt1(hp), via)
    elseif c.maxLoss then -- a survivable grab from c.base: at most maxLoss taken, never below 1 HP
        check(loss ~= nil and hp >= 1 and loss <= c.maxLoss + 0.05, "%s %s hit took %s HP from %s (want at most %s, Health >= 1) via %s, hp now %s", SCENARIO, c.label, fmt1(loss), fmt1(c.base), fmt1(c.maxLoss), via, fmt1(hp))
    else
        check(loss ~= nil and math.abs(loss - c.want) <= c.tol, "%s %s hit took %s HP (want %s) via %s, hp now %s", SCENARIO, c.label, fmt1(loss), fmt1(c.want), via, fmt1(hp))
    end
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
            S.lockedHits, S.lockedAt = (S.lockedHits or 0) + 1, os.clock()
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
    -- frostbite: counts V8.2's frostbite ticks on the local player while the frostbite window is open.
    hook("/Script/NuclearNightmare.NuclearNightmareCharacter:CallFrostbiteDamageEvent", function(selfp, amount)
        local v, n = get(selfp), num(get(amount))
        if S.frostOn and (n == 1 or n == 2) and isMe(v) then S.frostCalls = (S.frostCalls or 0) + 1 end
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
            if c.execution then check(m:find(c.execution, 1, true) ~= nil, "%s %s grab played the execution montage (%s; want *%s*)", SCENARIO, c.label, m, c.execution) end
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
            local disable = SC.whiteouts ~= true
            local okW = pcall(function() gi.DisableWhiteOuts = disable end)
            say("GI DisableWhiteOuts=%s set=%s", tostring(disable), tostring(okW))
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
-- signal-b keeps the steps from here on (it reaches the match through the screen's Create button, not OpenLevel).
local MATCH_WORLD_IDX = #steps + 1
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
    local gs = gameState()
    local disabled, n, phase = "?", 0, "?"
    pcall(function() disabled = tostring(gs.DisableWhiteOuts) end)
    for _, b in ipairs(FindAllOf("NNBlizzardController") or {}) do
        if notDefault(b) and alive(b) then n = n + 1 phase = tostring(phaseOf(b)) end
    end
    say("WHITEOUT disabled=%s director=%d phase=%s", disabled, n, phase)
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
        if c.base then -- test only: the grab is decided at this Health (spread-grab)
            local okH = pcall(function() p.Health = c.base end)
            say("SETHP %s -> %s before %s ok=%s (test only)", fmt1(hpOf(p)), fmt1(c.base), c.label, tostring(okH))
        end
        local t = os.clock()
        return function()
            local m = me()
            if not m then
                if gone() then
                    -- story 14: a ticked enemy's kill is the expected end (only after its hit was judged)
                    if c.kills and c.judged then c.died = c.died or "the pawn gone" return true end
                    S.dead = true return true
                end
                return false
            end
            -- story 14: the killed player still possessed: dead once Health stays <= 0 for 12 s after the hit
            if c.kills and c.judged and c.hitAt then
                local hp = hpOf(m)
                if hp and hp > 0 then c.lowSince = nil else c.lowSince = c.lowSince or os.clock() end
                if c.lowSince and os.clock() - c.hitAt >= 12 then c.died = "Health " .. fmt1(hp) .. " for 12 s" return true end
                if os.clock() - t > 120 then return true end
                return false
            end
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
            -- flip: 6 s after the grab, the player must be free (no montage, walking). Story 14's Stalker case (no grab
            -- hook for it) counts moveDelay seconds from its hit instead.
            local from = c.grabAt or (c.moveAfterHit and c.hitAt) or nil
            local delay = c.moveDelay or 6
            if c.moves and from and not c.moveChecked and os.clock() - from >= delay then
                c.moveChecked = true
                local playing, mode
                pcall(function() playing = m.PlayingMontage end)
                pcall(function() mode = num(m.CharacterMovement.MovementMode) end)
                check(playing ~= true and mode == 1, "%s %s moving again %d s after the %s (PlayingMontage=%s movement=%s montage=%s hp=%s)", SCENARIO, c.label, delay,
                    c.grabAt and "grab" or "hit", tostring(playing), tostring(mode), montageOf(m), fmt1(hpOf(m)))
            end
            local done = c.judged and (not c.moves or c.moveChecked) and (not c.survivable or c.grabs) and (not c.grab or c.grabs)
            if done then return true end
            if os.clock() - t > 120 then return true end
            return false
        end, 130, c.label
    end)
    step("despawn " .. c.label, function()
        if S.dead or S.over then return end
        if not c.judged then S.notShown = S.notShown + 1 say("NOTSHOWN %s: the %s didn't hit in 120 s", c.label, c.enemy.name)
        elseif (c.survivable or c.grab or c.execution) and not c.grabs then S.notShown = S.notShown + 1 say("NOTSHOWN %s: no grab seen", c.label) end
        if c.kills and c.judged then
            -- story 14: the expected death ends the run (no refill, no later case)
            if check(c.died ~= nil, "%s %s the player died after the grab (%s)", SCENARIO, c.label, tostring(c.died or "still alive")) then
                say("INSTAKILL %s death expected (%s)", c.label, c.died)
            end
            S.over = true
            S.case = nil
            return
        end
        S.case = nil
        local x = c.actor and StaticFindObject(c.actor)
        if valid(x) then pcall(function() x:K2_DestroyActor() end) end
        return after(4), 6
    end)
    step("refill after " .. c.label, function() if S.over then return end refill("after " .. c.label) return after(1), 3 end)
end

-- ---------------------------------------------------------------- story 4 phases
local COLD_SECONDS, FROST_LEAD, FROST_SECONDS = 60, 3, 20
local STOCK_COOL_SLOW, STOCK_COOL_FAST = 600, 310 -- s per full meter on Nightmare (knob-mechanics.md "Cooling")
local STORM_PHASE, STORM_WAIT = 2, 180 -- ENNBlizzardPhase::Blizzard; s to wait for it after RequestBlizzard
local NUKE_UI = "/Game/Graphics/Computer/NukeComputer_UI.NukeComputer_UI_C"
local function readBool(o, k) local ok, v = pcall(function() return o[k] end) if ok then return v end return nil end
local function temperatureOf(ch) local ok, t = pcall(function() return num(ch.Temperature) end) return ok and t or nil end
-- Natural enemies are cleared every 2 s during a phase (no enemy case runs in story 4).
local function keepClear(st) if os.clock() - (st.clearAt or 0) >= 2 then st.clearAt = os.clock() clearOthers(nil) end end

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
-- The cold phase (cold, cold-zero, cold-whiteout; signal-b with cfg.factor 0): cfg = { factor, whiteouts }.
local function addColdSteps(cfg)
    local P = { }
    if cfg.whiteouts then
        step("storm", function()
            local b = director()
            if not b then
                P.noStorm = true
                S.notShown = S.notShown + 1
                say("NOTSHOWN cold-whiteout: no NNBlizzardController in this match")
                return
            end
            local ok, err = pcall(function() b:RequestBlizzard() end)
            local function f(k) local okF, v = pcall(function() return b[k] end) return okF and tostring(v) or "?" end
            say("STORM RequestBlizzard ok=%s %s enabled=%s phase=%s approach=%s storm=%s..%s", tostring(ok), ok and "" or tostring(err),
                f("bEnabled"), tostring(phaseOf(b)), f("ApproachSeconds"), f("MinimumStormSeconds"), f("MaximumStormSeconds"))
            local t0 = os.clock()
            return function()
                keepClear(P)
                local d = director()
                if d and phaseOf(d) == STORM_PHASE then say("STORM phase=%d after %.0f s", STORM_PHASE, os.clock() - t0) return true end
                if os.clock() - t0 < STORM_WAIT then return false end
                P.noStorm = true
                S.notShown = S.notShown + 1
                say("STORM at the timeout scheduled=%s start=%s grace=%s lead=%s",
                    d and tostring(d.bBlizzardScheduled) or "?", d and tostring(d.ScheduledStartServerSeconds) or "?",
                    d and tostring(d.InitialGraceSeconds) or "?", d and tostring(d.PlanningLeadSeconds) or "?")
                say("NOTSHOWN cold-whiteout: the storm phase never came in %d s (phase %s)", STORM_WAIT, d and tostring(phaseOf(d)) or "no director")
                return true
            end, STORM_WAIT + 10, "storm phase"
        end)
    end
    step("cold", function()
        if P.noStorm then return end
        local m = me()
        if not m then if gone() then S.dead = true end return end
        pcall(function() m.Temperature = 0 end) -- a lowering only (test only): the poll leaves falls alone
        local t = temperatureOf(m)
        if not check(t ~= nil, "%s Temperature readable (%s)", SCENARIO, tostring(t)) then return end
        P.t0, P.start, P.max, P.last, P.samples, P.outside, P.path = os.clock(), t, t, t, 0, 0, pathOf(m)
        say("COLDRUN start Temperature=0 (test only), %d s outdoors, factor %s", COLD_SECONDS, tostring(cfg.factor))
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
            if cfg.whiteouts then
                local b = director()
                if not b or phaseOf(b) ~= STORM_PHASE then P.stormOff = (P.stormOff or 0) + 1 end
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
        if cfg.whiteouts and (P.stormOff or 0) > 0 then
            S.notShown = S.notShown + 1
            say("NOTSHOWN cold-whiteout: the storm phase didn't last the %d s (%d of %d samples outside it)", COLD_SECONDS, P.stormOff, P.samples)
            return
        end
        if cfg.factor == 0 then
            check(P.max <= 0.005, "%s Temperature stayed at its start outdoors for %.0f s (max %.4f, want <= 0.005)", SCENARIO, secs, P.max)
            return
        end
        if rise <= 0.0005 then
            S.notShown = S.notShown + 1
            say("NOTSHOWN cold: Temperature didn't rise in %.0f s (rise %.4f): no cooling here", secs, rise)
            return
        end
        -- A quarter of Nightmare's stock range for this time, +-10% (the weather sets where in the range).
        local lo, hi = secs * cfg.factor / STOCK_COOL_SLOW * 0.9, secs * cfg.factor / STOCK_COOL_FAST * 1.1
        if cfg.whiteouts then
            if rise > hi then
                check(true, "%s rise %.4f in %.0f s above a quarter of Nightmare's stock range (up to %.4f): the storm cooled, scaled by the knob", SCENARIO, rise, secs, hi)
            else
                S.notShown = S.notShown + 1
                say("NOTSHOWN cold-whiteout: rise %.4f in %.0f s isn't above a quarter of Nightmare's stock range (%.4f); the storm's cold wasn't seen", rise, secs, hi)
            end
            return
        end
        check(rise >= lo and rise <= hi, "%s rise %.4f in %.0f s within a quarter of Nightmare's stock (%.4f..%.4f)", SCENARIO, rise, secs, lo, hi)
    end)
end
if SC.special == "cold" then addColdSteps(SC) end
if SC.special == "frost" then
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
    -- The native terminal on the local pawn (V8.2's route). Nothing is kept between steps.
    local function terminal(pawn)
        local t
        if pawn then pcall(function() t = pawn.RadioTerminal end) end
        return valid(t) and t or nil
    end
    local function terminalActive(t)
        local ok, a = pcall(function() return t:IsTerminalActive() end)
        return ok and a == true
    end
    local function openTerminal(tag)
        local p, r = me(), radioActor()
        local t = terminal(p)
        if not (p and r and t) then say("TERMINAL %s: no pawn, radio or RadioTerminal", tag) return end
        if terminalActive(t) then return end
        -- The terminal opens only on a powered computer the player stands at (BP_Radio_C's PoweredOn? gate, test only).
        local okP = pcall(function() r:ToggleEquipment(true) end)
        local okL = pcall(function()
            local at = r:K2_GetActorLocation()
            p:K2_TeleportTo({ X = at.X - 120, Y = at.Y, Z = at.Z + 100 }, p:K2_GetActorRotation())
        end)
        say("TERMINAL %s power=%s poweredOn=%s moved=%s", tag, tostring(okP), tostring(r["PoweredOn?"]), tostring(okL))
        local cdo = StaticFindObject("/Script/NuclearNightmare.Default__NNRadioTerminalComponent")
        local ok, err = pcall(function() cdo:OpenTerminal(r, p) end)
        say("TERMINAL %s OpenTerminal ok=%s %s", tag, tostring(ok), ok and "" or tostring(err))
        return after(2), 4
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
    step("terminal open", function() return openTerminal("start") end)
    step("terminal state", function()
        local t = terminal(me())
        local active = t ~= nil and terminalActive(t)
        local orig = "none"
        if t then
            local okW, w = pcall(function() return t.OriginalWidget end)
            if okW and valid(w) then orig = classOf(w) end
        end
        say("TERMINAL open active=%s original=%s", tostring(active), orig)
        if not active then
            P.noTerminal = true
            S.notShown = S.notShown + 1
            say("NOTSHOWN terminal: OpenTerminal didn't activate the native terminal on the local pawn; the fallbacks run")
        end
    end)
    -- One reinforcement's steps; nAt: the reinforcement at which Disable must be set (the effective N).
    local function addReinforce(i, nAt)
        step("terminal ready #" .. i, function() -- a reinforcement can replace the pawn, and with it the terminal
            if P.abort or S.dead or P.noTerminal then return end
            return openTerminal("#" .. i)
        end)
        step("reinforce #" .. i, function()
            if P.abort then return end
            local p, c, g, r = me(), pc(), gameState(), radioActor()
            if not (p and c and g and r) then S.notShown = S.notShown + 1 P.abort = true say("NOTSHOWN reinforce #%d: no pawn, controller, game state or radio", i) return end
            local before = reinf()
            local t0, others = os.clock(), fpPaths()
            local via = P.via
            local function spectator()
                -- The count right before this call: a late synthetic revive already counted is judged from here.
                P.via, via, t0, others, before = "spectator", "spectator", os.clock(), fpPaths(), reinf()
                local okS, eS = pcall(function() radioActor():SpawnReinforcmentSpectator() end)
                say("REVIVE #%d SpawnReinforcmentSpectator ok=%s %s", i, tostring(okS), okS and "" or tostring(eS))
            end
            local function synthetic()
                via, t0, others, before = "synthetic", os.clock(), fpPaths(), reinf()
                local g2, c2, p2, r2 = gameState(), pc(), me(), radioActor()
                local okQ, eQ = pcall(function() g2:UpdateRespawnQue(c2, p2) end)
                local okR, eR = pcall(function() r2:ReinforceSpecficPlayer(p2) end)
                say("REVIVE #%d synthetic UpdateRespawnQue ok=%s %s; ReinforceSpecficPlayer ok=%s %s", i, tostring(okQ), okQ and "" or tostring(eQ), tostring(okR), okR and "" or tostring(eR))
            end
            local t = terminal(p)
            if not P.noTerminal and t and terminalActive(t) then
                via = "terminal"
                local okT, eT = pcall(function() t:OnReinforcement() end)
                say("REVIVE #%d terminal OnReinforcement ok=%s %s", i, tostring(okT), okT and "" or tostring(eT))
            elseif P.via == "synthetic" then
                synthetic()
            else
                spectator()
            end
            return function()
                if not me() then if gone() then S.dead = true return true end end
                keepClear(P)
                local now = reinf()
                if now and before and now == before + 1 then
                    if via ~= "synthetic" then -- a spectator reinforcement (the terminal may be one) leaves an orphan
                        local mine = me() and pathOf(me()) or ""
                        for path in pairs(fpPaths()) do
                            if not others[path] and path ~= mine then
                                local x = StaticFindObject(path)
                                if valid(x) then pcall(function() x:K2_DestroyActor() end) say("REVIVE #%d destroyed the orphan %s", i, path) end
                            end
                        end
                    end
                    say("REVIVE #%d via=%s count %d -> %d", i, via, before, now)
                    if via == "terminal" then P.terminalMoved = true say("TERMINAL reinforce #%d moved=true", i) end
                    check(true, "%s reinforcement #%d accepted (via %s)", SCENARIO, i, via)
                    return true
                end
                if now and before and now > before + 1 then
                    -- Both paths landed (a late terminal or synthetic revive and the fallback): the case can't be judged one by one.
                    S.notShown = S.notShown + 1
                    P.abort = true
                    say("NOTSHOWN reinforce #%d: the count jumped %d -> %d (a late terminal or synthetic revive and the %s path both counted)", i, before, now, via)
                    return true
                end
                if via == "terminal" and os.clock() - t0 > 15 then
                    local past = i > SC.limit and P.terminalMoved == true
                    say("TERMINAL reinforce #%d moved=false count=%s past_stock_limit=%s", i, tostring(now), tostring(past))
                    if past then
                        check(false, "%s the native terminal refused reinforcement #%d past the stock limit %d (moved=false): blocked", SCENARIO, i, SC.limit)
                    else
                        -- A living solo host has nobody queued to reinforce: the pair run's dp-revive proves this route.
                        P.noTerminal = true
                        say("TERMINAL OnReinforcement needs a queued player (solo: count %s); the rest use the fallbacks", tostring(now))
                    end
                    if P.via == "synthetic" then synthetic() else spectator() end
                    return false
                end
                if via == "synthetic" and os.clock() - t0 > 15 then
                    say("REVIVE #%d the synthetic revive wasn't accepted in 15 s (count %s); falling back to SpawnReinforcmentSpectator()", i, tostring(now))
                    spectator()
                    return false
                end
                if via == "spectator" and os.clock() - t0 > 10 then
                    S.notShown = S.notShown + 1
                    P.abort = true
                    say("NOTSHOWN reinforce #%d: neither path moved the count (%s)", i, tostring(now))
                    return true
                end
                return false
            end, 60, "reinforcement #" .. i
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
                if i == nAt then
                    if dis == true or os.clock() - t0 > 5 then
                        check(dis == true, "%s Disable Reinforcement set after reinforcement #%d = N (got %s)", SCENARIO, i, tostring(dis))
                        return true
                    end
                    return false
                end
                if os.clock() - t0 < 4 then return false end
                check(dis == false, "%s Disable Reinforcement still false after reinforcement #%d of %d (got %s)", SCENARIO, i, nAt, tostring(dis))
                return true
            end, 10, "after reinforcement #" .. i
        end)
    end
    for i = 1, SC.n do addReinforce(i, SC.n) end
    -- Story 12 (tokens-classified): after the N tokens are used, each classified objective completed on the host gives
    -- k back (capped): Disable cleared, the count lowered, the computer's text up; then the bonus tokens are used and
    -- Disable comes back at N + bonus. An objective is completed through a real intel actor's host-side interaction
    -- (BP_ClassifiedMaterial_C:PrimaryInteraction on the host: its authority branch calls the game state's
    -- UpdateClassifieds(value + 1)); if the counter doesn't rise, through the game state's UpdateClassifieds(value + 1).
    if SC.classified then
        local CM_CLASSES = { "BP_ClassifiedMaterial_C", "BP_CM_V1_C", "BP_CM_V2_C", "BP_CM_V3_C", "BP_CM_V4_C", "BP_CM_V5_C",
                             "BP_CM_V6_C", "BP_CM_V7_C", "BP_CM_V8_C", "BP_CM_V9_C" }
        local function classifiedValue()
            local g = gameState()
            if not g then return nil end
            local ok, v = pcall(function() return num(g.ClassifiedDynamicValue) end)
            return ok and v or nil
        end
        -- An intel pickup not used yet in this run (path), or nil.
        local function intel()
            for _, cls in ipairs(CM_CLASSES) do
                for _, a in ipairs(FindAllOf(cls) or {}) do
                    if notDefault(a) and alive(a) then
                        local p = pathOf(a)
                        local picked = readBool(a, "PickedUp")
                        if p and not P.usedIntel[p] and picked ~= true then return a, p, cls end
                    end
                end
            end
            return nil
        end
        P.usedIntel = {}
        local bonus = 0
        for j, add in ipairs(SC.classified.adds) do
            bonus = bonus + add
            local total = bonus -- this objective's running bonus (the closures below run later)
            local left = total -- every one of the N tokens is used by now: the computer shows the bonus
            step("classified #" .. j, function()
                if P.abort or S.dead then return end
                local before = classifiedValue()
                local t0, tries, via = os.clock(), 0, nil
                local function tryIntel()
                    local a, p, cls = intel()
                    if not a then return false end
                    P.usedIntel[p] = true
                    tries = tries + 1
                    local okI, eI = pcall(function() a:PrimaryInteraction(me()) end)
                    say("CLASSIFIED #%d intel %s %s PrimaryInteraction ok=%s %s", j, cls, p, tostring(okI), okI and "" or tostring(eI))
                    via = "intel"
                    return true
                end
                local function direct()
                    local g, v = gameState(), classifiedValue()
                    local okU, eU = pcall(function() g:UpdateClassifieds(v + 1) end)
                    say("CLASSIFIED #%d UpdateClassifieds(%s) ok=%s %s", j, tostring(v and v + 1), tostring(okU), okU and "" or tostring(eU))
                    via, t0 = "UpdateClassifieds", os.clock()
                end
                say("CLASSIFIED #%d before value=%s", j, tostring(before))
                if not tryIntel() then say("CLASSIFIED #%d no unused intel pickup on this map; the game state's UpdateClassifieds", j) direct() end
                return function()
                    keepClear(P)
                    local now = classifiedValue()
                    if now and before and now > before then
                        say("CLASSIFIED #%d done via=%s value %d -> %d", j, via, before, now)
                        if now ~= before + 1 then
                            S.notShown = S.notShown + 1
                            P.abort = true
                            say("NOTSHOWN classified #%d: the value jumped %d -> %d (two objectives at once)", j, before, now)
                        end
                        return true
                    end
                    if via == "intel" and os.clock() - t0 > 5 then
                        -- A second try on another pickup (the first call may only have initialized its DoOnce), then direct.
                        if tries < 2 and tryIntel() then t0 = os.clock() return false end
                        say("CLASSIFIED #%d the intel interaction didn't raise the value in 5 s; the game state's UpdateClassifieds", j)
                        direct()
                        return false
                    end
                    if via == "UpdateClassifieds" and os.clock() - t0 > 5 then
                        S.notShown = S.notShown + 1
                        P.abort = true
                        say("NOTSHOWN classified #%d: ClassifiedDynamicValue didn't rise (%s)", j, tostring(now))
                        return true
                    end
                    return false
                end, 30, "classified objective #" .. j
            end)
            -- Difficulty's callback or poll (<= 250 ms) awards it: Disable cleared, the count down by the award.
            step("after classified #" .. j, function()
                if P.abort or S.dead then return end
                local t0 = os.clock()
                local want = SC.limit - total -- limit - (N + bonus) + used, with used = N
                return function()
                    keepClear(P)
                    local cnt, dis = reinf()
                    if (cnt == want and dis == false) or os.clock() - t0 > 5 then
                        say("REINF classified #%d count=%s disable=%s", j, tostring(cnt), tostring(dis))
                        check(cnt == want, "%s count after classified objective #%d is %d (+%d given back; got %s)", SCENARIO, j, want, add, tostring(cnt))
                        check(dis == false, "%s Disable Reinforcement cleared after classified objective #%d (got %s)", SCENARIO, j, tostring(dis))
                        textCheck(left, "after classified objective #" .. j)
                        return true
                    end
                    return false
                end, 10, "after classified objective #" .. j
            end)
        end
        -- The bonus tokens, then Disable again at N + bonus.
        for i = SC.n + 1, SC.n + bonus do addReinforce(i, SC.n + bonus) end
        P.total = SC.n + bonus
    end
    step("terminal close", function()
        local t = terminal(me())
        if not (t and terminalActive(t)) then return end -- closed whenever it's open, also after the solo fallbacks
        local ok, err = pcall(function() t:CloseTerminal() end)
        say("TERMINAL close CloseTerminal ok=%s %s", tostring(ok), ok and "" or tostring(err))
        return after(2), 4
    end)
    step("tokens end", function()
        if P.abort or S.dead then return end
        local cnt, dis = reinf()
        say("REINF end count=%s disable=%s via=%s", tostring(cnt), tostring(dis), P.via)
        check(cnt == SC.limit, "%s count after N reinforcements is the limit %d (got %s)", SCENARIO, SC.limit, tostring(cnt))
        textCheck(0, "after N reinforcements")
        if SC.classified then check(dis == true, "%s Disable Reinforcement set after N + bonus = %d (got %s)", SCENARIO, P.total or -1, tostring(dis)) end
    end)
end

-- ---------------------------------------------------------------- story 8: the match part of signal-b, spread, menu
if SC.special == "signal-b" then
    -- After the grab cases: 60 s outdoors with Cold Exposure 0 (the meter never rises), then the computer's text.
    addColdSteps({ factor = 0 })
    step("sig: tokens text", function()
        local s, why = tokenText()
        say("TEXT signal %s", tostring(s or why))
        check(s == "Reinforcement Tokens 8", "SIGTOKENS the computer's text is 'Reinforcement Tokens 8' (got %s)", tostring(s or why))
    end)
end

-- spread: 200 standard Meek hits at full Health. The direct route (one probe first) calls the hooked static
-- ApplyLockedDamage with an idle Meek as the attacker after TryBeginAttack locked the local player; the real route lets
-- a spawned Meek attack. Health is refilled to 100 between hits (test only; the real route only outside a grab
-- window). check.ps1 judges Difficulty's rolled values; the driver's own losses are logged and bounded.
if SC.special == "spread" then
    local CTX = "/Script/NuclearNightmare.Default__NNEnemyAttackContext"
    local P = { losses = {}, mode = nil }
    local function ctx() return StaticFindObject(CTX) end
    local function meek() local x = P.actor and StaticFindObject(P.actor) return alive(x) and x or nil end
    local function stats(t)
        local n, sum, sq, lo, hi = #t, 0, 0, math.huge, -math.huge
        for _, v in ipairs(t) do sum = sum + v if v < lo then lo = v end if v > hi then hi = v end end
        local mean = n > 0 and sum / n or 0
        for _, v in ipairs(t) do sq = sq + (v - mean) ^ 2 end
        return n, mean, n > 1 and math.sqrt(sq / (n - 1)) or 0, lo, hi
    end
    -- An idle Meek: spawned, its controller unpossessed, so it only serves as the attacker.
    local function spawnIdle()
        local cls = loadClass(MEEK.path)
        if not cls then return nil, "class not loaded" end
        local p = me()
        local loc, fwd = p:K2_GetActorLocation(), p:GetActorForwardVector()
        local at = { X = loc.X + fwd.X * 1500, Y = loc.Y + fwd.Y * 1500, Z = loc.Z + 50 }
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = at, Scale3D = { X = 1, Y = 1, Z = 1 } }
        local x = GS():BeginDeferredActorSpawnFromClass(p, cls, xf, 1, nil, 1)
        if not valid(x) then return nil, "BeginDeferredActorSpawnFromClass returned no actor" end
        GS():FinishSpawningActor(x, xf, 1)
        local okC, ctl = pcall(function() return x:GetController() end)
        if okC and valid(ctl) then pcall(function() ctl:UnPossess() end) end
        return x
    end
    -- One direct hit: refill, lock, ApplyLockedDamage(meek, 25), complete. Returns the Health lost (nil: no hit).
    local function directHit()
        local m, x, c = me(), meek(), ctx()
        if not (m and x and c) then return nil, "no player, Meek or attack context" end
        pcall(function() m.Health = 100 end)
        local okB, eB = pcall(function() c:TryBeginAttack(x, m, 5.0) end)
        local okA, eA = pcall(function() c:ApplyLockedDamage(x, 25.0) end)
        pcall(function() c:CompleteAttack(x) end)
        local hp = hpOf(m)
        if not (okB and okA) then
            return nil, ("TryBeginAttack ok=%s %s; ApplyLockedDamage ok=%s %s"):format(tostring(okB), okB and "" or tostring(eB), tostring(okA), okA and "" or tostring(eA))
        end
        if not hp or hp > 99.95 then return nil, "Health still " .. fmt1(hp) end
        return 100 - hp
    end
    step("spread: idle Meek", function()
        if not me() then if gone() then S.dead = true end return end
        clearOthers(nil)
        refill("before spread")
        local ok, x, why = pcall(spawnIdle)
        if not check(ok and valid(x), "SPAWN spread idle Meek %s", ok and (valid(x) and pathOf(x) or tostring(why)) or tostring(x)) then P.abort = true return end
        P.actor = pathOf(x)
        return after(2), 4
    end)
    step("spread: probe", function()
        if P.abort or S.dead then return end
        local loss, why = directHit()
        say("SPREAD probe direct ApplyLockedDamage: loss=%s %s", fmt1(loss), loss and "" or tostring(why))
        if loss then
            P.mode = "direct"
            P.losses[#P.losses + 1] = loss
        else
            P.mode = "real"
            local d = meek()
            if d then pcall(function() d:K2_DestroyActor() end) end
            P.actor = nil
        end
        say("SPREADMODE %s", P.mode)
        refill("after the probe")
        return after(1), 3
    end)
    step("spread: hits", function()
        if P.abort or S.dead then return end
        local t0 = os.clock()
        if P.mode == "direct" then
            return function()
                if not me() then if gone() then S.dead = true return true end return false end
                if os.clock() - (P.clearAt or 0) >= 2 then P.clearAt = os.clock() clearOthers(P.actor) end
                local loss, why = directHit()
                if loss then P.losses[#P.losses + 1] = loss
                else
                    P.misses = (P.misses or 0) + 1
                    if P.misses <= 5 then say("SPREAD direct hit missed: %s", tostring(why)) end
                end
                if #P.losses >= SC.n then return true end
                if (P.misses or 0) > 50 then say("SPREAD direct route stopped after %d misses", P.misses) return true end
                return false
            end, 400, "spread: " .. SC.n .. " direct hits"
        end
        -- Real attacks: a Meek in front; each locked hit on the player is counted by the ApplyLockedDamage hook.
        S.lockedHits = 0
        return function()
            local m = me()
            if not m then if gone() then S.dead = true return true end return false end
            pcall(function() m.Temperature = 0 end)
            -- A Meek grab can start an infection that ends the player minutes later (VM run 2026-11-17: the pawn
            -- gone after 45 grabs): its timer is cleared (test only, logged).
            local okA, act = pcall(function() return KSL():K2_IsTimerActive(m, "BecomeInfected") end)
            local okI, inf = pcall(function() return m["StartedInfection?"] end)
            if (okA and act == true) or (okI and inf == true) then
                local okC = pcall(function() KSL():K2_ClearTimer(m, "BecomeInfected") end)
                local okW = pcall(function() m["StartedInfection?"] = false end)
                P.infections = (P.infections or 0) + 1
                say("INFECTCLEAR #%d timer=%s started=%s cleared=%s/%s (test only)", P.infections, tostring(act), tostring(inf), tostring(okC), tostring(okW))
            end
            if os.clock() - (P.clearAt or 0) >= 2 then P.clearAt = os.clock() clearOthers(P.actor) end
            if (S.lockedHits or 0) > #P.losses then
                local hp = hpOf(m)
                P.losses[#P.losses + 1] = hp and (100 - hp) or -1
                S.lockedHits = #P.losses
            end
            -- Refill half a second after each hit: on Normal at full Health every Meek grab is the game's own
            -- survivable one (no flip, so no temporary Health to restore), and the Meek grabs again about every 7 s.
            if S.lockedAt and os.clock() - S.lockedAt >= 0.5 then
                local hp = hpOf(m)
                if hp and hp > 0 and hp < 100 then refill("spread real route") end
            end
            if not meek() then
                local cls = loadClass(MEEK.path)
                local ok, x = pcall(spawnInFront, cls)
                if ok and valid(x) then P.actor = pathOf(x) end
            elseif os.clock() - (P.pokeAt or 0) >= 10 then
                P.pokeAt = os.clock()
                local x2 = meek()
                for _, fn in ipairs({ "SeePlayerServer", "SeeCharacter", "SeePlayer" }) do
                    if pcall(function() x2[fn](x2, m) end) then break end
                end
            end
            -- Ends by itself (NOTSHOWN below 200) before run.ps1's 2400 s host limit, counting the menu, travel and set-up.
            return #P.losses >= SC.n or os.clock() - t0 > 1950
        end, 2000, "spread: " .. SC.n .. " real hits"
    end)
    step("spread: verdict", function()
        local x = meek()
        if x then pcall(function() x:K2_DestroyActor() end) end
        refill("after spread")
        if S.dead or P.abort then return end
        local n, mean, sd, lo, hi = stats(P.losses)
        say("SPREADRUN end mode=%s hits=%d mean=%.3f sd=%.3f min=%.2f max=%.2f", tostring(P.mode), n, mean, sd, n > 0 and lo or 0, n > 0 and hi or 0)
        if n < SC.n then
            S.notShown = S.notShown + 1
            say("NOTSHOWN spread: only %d of %d hits (%s route)", n, SC.n, tostring(P.mode))
            return
        end
        -- The driver's own view on the direct route (one hit per refill): every loss inside 15..35 (25 +- 2 sigma).
        -- Difficulty's rolled values are check.ps1's; the real route's losses can overlap a refill, so they are logged only.
        if P.mode == "direct" then
            check(lo >= 14.95 and hi <= 35.05, "spread %d hits, every loss in 15..35 (min %.2f, max %.2f; mean %.2f, sd %.2f)", n, lo, hi, mean, sd)
        else
            check(true, "spread %d real hits counted (losses logged only)", n)
        end
    end)
end

-- ---------------------------------------------------------------- story 13: the bosses' finisher grabs
-- Each boss ends its grab with the native static NNBossAttackRecovery:CommitLethalDamage(Boss, Victim) and plays the
-- kill presentation (its AttackMulti) only when that returns true. The driver makes each boss grab the local player,
-- logs the native's Health in/out and the player's state 0, 6 and 12 s after it, and judges survival (boss) or the
-- stock kill (boss-default). Difficulty's own HIT line (via=CommitLethalDamage) is check.ps1's. Never keeps a UObject
-- between steps: the boss by path, the player re-found each poll.
if SC.special == "boss" then
    local REC = "/Script/NuclearNightmare.NNBossAttackRecovery:"
    local BOSSES = {
        { name = "Slug Queen", path = "/Game/AI/SlugQueen_AI.SlugQueen_AI_C", short = "SlugQueen_AI_C" },
        { name = "Apex", path = "/Game/AI/ApexPredator/ApexPredatorAI.ApexPredatorAI_C", short = "ApexPredatorAI_C" },
    }
    local NEAR, NUDGE_EVERY, LADDER_AT, ATTACK_EVERY, GIVE_UP = 100, 2, 20, 5, 60
    -- Story 14: insta-kill-boss runs the Apex first (SC.order) and expects the ticked boss (SC.kill) to kill.
    if SC.order then
        local byName = {}
        for _, b in ipairs(BOSSES) do byName[b.name] = b end
        BOSSES = {}
        for _, n in ipairs(SC.order) do BOSSES[#BOSSES + 1] = byName[n] end
    end
    local B = { cur = nil, over = false, tempLogged = false }
    local control = SC.control == true
    local function tf(v) if v == nil then return "?" end return tostring(v) end
    -- The grabbed player's state now, from the local pawn or else the victim's body by path (alive only while the
    -- local controller still possesses it, it is live and Health > 0; no body: alive=false).
    local function snap(vpath)
        local s = { alive = false, playing = "?", movement = "?", montage = "none" }
        local m = me()
        local possessed = m ~= nil and (not vpath or pathOf(m) == vpath)
        local ch = possessed and m or nil
        if not possessed and vpath then
            ch = StaticFindObject(vpath)
            if not alive(ch) then return s end
        end
        if not ch then return s end
        s.hp = hpOf(ch)
        s.alive = possessed and alive(ch) and s.hp ~= nil and s.hp > 0
        pcall(function() s.playing = ch.PlayingMontage end)
        pcall(function() s.movement = num(ch.CharacterMovement.MovementMode) end)
        s.montage = montageOf(ch)
        return s
    end
    local function stateLine(c, t, s, extra)
        say("BOSSSTATE %s t=%d alive=%s hp=%s playing=%s movement=%s montage=%s%s", c.name, t, tostring(s.alive), fmt1(s.hp),
            tf(s.playing), tf(s.movement), s.montage, extra or "")
    end
    local function caseFor(cls) local c = B.cur if c and cls == c.short then return c end return nil end

    step("boss: hooks", function()
        local okC = hook(REC .. "CommitLethalDamage", function(_, boss, victim)
            local b, v = get(boss), get(victim)
            local cls = classOf(b)
            local mine = isMe(v)
            say("BOSSCLD pre boss=%s victim=%s hp=%s", cls, mine and "local" or "other", fmt1(hpOf(v)))
            local c = caseFor(cls)
            B.lastPre = { cls = cls, vpath = valid(v) and pathOf(v) or nil }
            if c and mine and not c.cldAt then c.cldPre, c.vpath = os.clock(), pathOf(v) end
        end, function(_, _, _, ...)
            -- The post-hook's parameters are not readable (VM run 2026-11-18: boss=? and a victim Health of 150 read
            -- through them), so the boss and the victim are the pre-hook's: the case's boss class and the victim's path.
            -- The return value, if the pinned UE4SS passes one after the parameters (otherwise '?').
            local ret = "?"
            if select("#", ...) >= 1 then
                local r = get((select(1, ...)))
                if r == nil then r = (select(1, ...)) end
                if type(r) == "boolean" then ret = tostring(r) end
            end
            local c, lp = B.cur, B.lastPre or {}
            B.lastPre = nil
            local v = lp.vpath and StaticFindObject(lp.vpath)
            say("BOSSCLD post boss=%s hp=%s ret=%s", lp.cls or "?", fmt1(valid(v) and hpOf(v) or nil), ret)
            if c and c.cldPre and not c.cldAt then
                c.cldAt, c.ret, c.s0 = os.clock(), ret, snap(c.vpath)
            end
        end)
        check(okC, "BOSSHOOKS CommitLethalDamage hooked (the boss cases need it)")
        for _, fn in ipairs({ "StartWatching", "WatchFinisherPresentation" }) do
            hook(REC .. fn, function(_, boss)
                local cls = classOf(get(boss))
                say("BOSSHOOK %s boss=%s", fn, cls)
                local c = caseFor(cls)
                if c and fn == "StartWatching" and not c.watchAt then c.watchAt = os.clock() end
            end)
        end
        return after(1), 3
    end)

    for _, c in ipairs(BOSSES) do
        c.label = c.name
        step("boss: spawn " .. c.name, function()
            if B.over then say("NOTSHOWN %s: the control player is dead", c.name) return end
            local p = me()
            if not p then if gone() then S.dead = true end return end
            clearOthers(nil)
            refill("before the " .. c.name)
            local cls = loadClass(c.path)
            if not check(cls ~= nil, "CLASS %s %s", c.name, c.path) then return end
            -- AttackMulti is a Blueprint multicast: the callback runs after the body (never a pre-hook).
            hook(c.path .. ":AttackMulti", function(selfp)
                local cls2 = classOf(get(selfp))
                say("BOSSHOOK AttackMulti boss=%s", cls2)
                local cc = caseFor(cls2)
                if cc then cc.multiAt = os.clock() end
            end)
            local okS, x = pcall(spawnInFront, cls)
            if not check(okS and valid(x), "SPAWN %s %s", c.name, okS and pathOf(x) or tostring(x)) then return end
            c.actor = pathOf(x)
            B.cur = c
            c.tries = 0
            local t0 = os.clock()
            return function()
                local now = os.clock()
                local m = me()
                if not c.cldAt then
                    if not m then if gone() then S.dead = true return true end return false end
                    pcall(function() m.Temperature = 0 end)
                    if not B.tempLogged then B.tempLogged = true say("TEMP Temperature held at 0 during the boss cases (test only)") end
                    if now - (c.clearAt or 0) >= 2 then c.clearAt = now clearOthers(c.actor) end
                    local el = now - t0
                    -- A grab under way (the boss's AttackingPlayer, or its StartWatching seen): no more teleports or
                    -- nudges while it lasts, which could break the presentation; a grab under way at 60 s gets up to 20 s more.
                    local x1 = StaticFindObject(c.actor)
                    local okG, grabbing = pcall(function() return x1.AttackingPlayer end)
                    local busyNow = (okG and grabbing == true) or (c.watchAt ~= nil and now - c.watchAt < 15)
                    if busyNow then
                        c.busyAt = now
                        if not c.grabSeen then
                            c.grabSeen = now
                            say("BOSSGRAB %s t=%.0f AttackingPlayer=%s StartWatching=%s", c.name, el, tostring(okG and grabbing), tostring(c.watchAt ~= nil))
                        end
                    end
                    if el >= GIVE_UP and not (busyNow and el < GIVE_UP + 20) then
                        S.notShown = S.notShown + 1
                        say("NOTSHOWN %s: no CommitLethalDamage in %d s (%d BOSSTRY attempts)", c.name, GIVE_UP, c.tries)
                        return true
                    end
                    local route = el >= LADDER_AT and "attack" or "near"
                    local every = route == "attack" and ATTACK_EVERY or NUDGE_EVERY
                    if not busyNow and now - (c.tryAt or -1e9) >= every then
                        c.tryAt = now
                        c.tries = c.tries + 1
                        local x2 = StaticFindObject(c.actor)
                        if not alive(x2) then say("BOSSTRY %s route=%s t=%.0f boss gone", c.name, route, el) return false end
                        -- Route 1 (and before each route 2 call): the player about 100 uu in front of the boss.
                        local okT = pcall(function()
                            local bl, bf = x2:K2_GetActorLocation(), x2:GetActorForwardVector()
                            m:K2_SetActorLocation({ X = bl.X + bf.X * NEAR, Y = bl.Y + bf.Y * NEAR, Z = bl.Z }, false, {}, true)
                        end)
                        local okN, how
                        if route == "near" then
                            if c.short == "SlugQueen_AI_C" then
                                how = "SeePlayerServer"
                                okN = pcall(function() x2:SeePlayerServer(m) end)
                            else
                                how = "HeardNoise"
                                okN = pcall(function()
                                    local l = m:K2_GetActorLocation()
                                    x2:HeardNoise({ X = l.X, Y = l.Y, Z = l.Z }, 1.0)
                                end)
                            end
                        else
                            how = "AttackServer"
                            okN = pcall(function() x2:AttackServer(m) end)
                        end
                        say("BOSSTRY %s route=%s t=%.0f teleport=%s %s=%s", c.name, route, el, tostring(okT), how, tostring(okN))
                    end
                    return false
                end
                -- After CommitLethalDamage: the state lines at 0 (once the presentation is known: an AttackMulti for this
                -- boss within 2 s of the post-hook), 6 and 12 s.
                local since = now - c.cldAt
                -- The case lasts until the 12 s line: natural enemies still cleared, Temperature still held at 0.
                if m then pcall(function() m.Temperature = 0 end) end
                if now - (c.clearAt or 0) >= 2 then c.clearAt = now clearOthers(c.actor) end
                if not c.line0 and ((c.multiAt and c.multiAt >= c.cldAt) or since >= 2) then
                    c.line0 = true
                    c.presentation = (c.multiAt and c.multiAt >= c.cldAt and c.multiAt - c.cldAt <= 2) and "yes" or "no"
                    stateLine(c, 0, c.s0, (" ret=%s presentation=%s"):format(c.ret, c.presentation))
                end
                if c.line0 and not c.s6 and since >= 6 then c.s6 = snap(c.vpath) stateLine(c, 6, c.s6) end
                if c.s6 and since >= 12 then
                    local s = snap(c.vpath)
                    stateLine(c, 12, s)
                    local died = not s.alive -- the spec's rule: alive=false at 12 s
                    local ticked = SC.kill ~= nil and SC.kill == c.short -- story 14: this boss's Insta-kill box
                    if control or ticked then
                        local why = control and "stock" or "insta-kill"
                        check(died, "%s %s the %s grab kills (alive=false at 12 s; at 0/6/12 s alive=%s/%s/%s hp=%s)", SCENARIO, c.name,
                            control and "stock" or "ticked", tostring(c.s0.alive), tostring(c.s6.alive), tostring(s.alive), fmt1(s.hp))
                        if ticked then
                            check(c.presentation == "yes", "%s %s the kill presentation played (presentation=%s)", SCENARIO, c.name, tostring(c.presentation))
                        end
                        if died then
                            say("BOSSDEATH %s expected (%s)", c.name, why)
                            B.over = true
                        end
                    else
                        check(s.alive and s.hp ~= nil and s.hp >= 1, "%s %s alive at 12 s with Health >= 1 (alive=%s hp=%s)", SCENARIO, c.name, tostring(s.alive), fmt1(s.hp))
                        if SC.apexHp and c.short == "ApexPredatorAI_C" then
                            check(s.hp ~= nil and math.abs(s.hp - SC.apexHp) <= 0.05, "%s %s left %s HP at 12 s (want %s: unticked, the scaled hit)", SCENARIO, c.name, fmt1(s.hp), fmt1(SC.apexHp))
                        end
                        check(s.playing == false and s.movement == 1, "%s %s moving at 12 s (PlayingMontage=%s movement=%s montage=%s)", SCENARIO, c.name,
                            tf(s.playing), tf(s.movement), s.montage)
                        if not s.alive then S.dead = true end
                    end
                    return true
                end
                return false
            end, GIVE_UP + 45, "boss case " .. c.name
        end)
        step("boss: despawn " .. c.name, function()
            B.cur = nil
            local x = c.actor and StaticFindObject(c.actor)
            if valid(x) then pcall(function() x:K2_DestroyActor() end) end
            if B.over or S.dead then return end
            return after(4), 6
        end)
    end
end

-- no-core, old-core: the menu only. Difficulty stops itself (its one line is check.ps1's); the driver only proves the
-- run reached the menu and stayed 20 s there.
if SC.special == "menu" then
    steps = {}
    step("menu", function() return function() return worldName():find("NewMainMenu", 1, true) ~= nil end, 240, "menu world" end)
    step("menu: 20 s", function() return after(20), 25 end)
    step("menu: reached", function() check(true, "MENU %s reached the menu world and stayed 20 s", SCENARIO) end)
end

-- ---------------------------------------------------------------- story 6: presets (menu only)
-- The create-world screen's own preset handlers, driven on the main menu (no match, no session). Difficulty keeps its
-- sidecar in step; this driver reads the file after each step and checks the DT6-* entries (index, decoded name, all
-- Default) and that the presets that were there before (the baseline) keep their entries. It cleans up its own presets
-- (the VM copy's _userdir is never reset by tools/vm). Never keeps the screen: found again in each step.
if SC.special == "presets" then
    steps = {}
    local CS_CLASS = "/Game/Graphics/MainMenu/CreateServer.CreateServer_C"
    local H_SELECT = "BndEvt__CreateServer_MultipleSelectBox_11_K2Node_ComponentBoundEvent_31_OnSelectionChanged__DelegateSignature"
    local H_SAVE = "BndEvt__CreateServer_Create_1_K2Node_ComponentBoundEvent_33_OnButtonClickedEvent__DelegateSignature"
    local H_UPDATE = "BndEvt__CreateServer_Create_2_K2Node_ComponentBoundEvent_34_OnButtonClickedEvent__DelegateSignature"
    local H_DELETE = "BndEvt__CreateServer_Create_4_K2Node_ComponentBoundEvent_35_OnButtonClickedEvent__DelegateSignature"
    local H_TEXT = "BndEvt__CreateServer_EditableText_K2Node_ComponentBoundEvent_32_OnEditableTextChangedEvent__DelegateSignature"
    local PREFIX = "DT6-"
    local P = { baseline = nil, file = nil, abort = false }
    local KPRESET = { PREFIX .. "K", "kill.meek=1" } -- story 14: the preset saved with Meek's Insta-kill box ticked
    local BOX_TAG = "nucleus:" .. ME:gsub("Driver$", "") .. ":c-kill.meek"
    local function str(v) if type(v) == "string" then return v end local ok, s = pcall(function() return v:ToString() end) return ok and s or nil end
    local function isOurs(name) return name:sub(1, #PREFIX) == PREFIX end
    local function screen()
        for _, w in ipairs(FindAllOf("CreateServer_C") or {}) do
            if notDefault(w) then
                local ok, v = pcall(function() return w:IsInViewport() end)
                if ok and v then return w end
            end
        end
        return nil
    end
    -- The game's preset names (selector items 2..n; item 1 is "None").
    local function names(cs)
        local r = {}
        local ok = pcall(function()
            local items = cs.MultipleSelectBox_11.Items
            for i = 2, math.min(items:GetArrayNum(), 300) do r[#r + 1] = str(items[i]) or "?" end
        end)
        return ok and r or nil
    end
    local function position(cs, name) for i, n in ipairs(names(cs) or {}) do if n == name then return i end end return nil end
    local function decode(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
    -- The sidecar's entries: { index, name, values (the raw field) } in file order; nil when there is no file.
    local function readFile()
        local f = io.open(P.file, "rb")
        if not f then return nil end
        local text = f:read(256 * 1024) or ""
        f:close()
        local r = {}
        for line in text:gmatch("([^\n]*)\n") do
            local i, n, v = (line:gsub("\r$", "")):match("^(%d+)\t([^\t]*)\t([^\t]*)$")
            if i then r[#r + 1] = { index = tonumber(i), name = decode(n), values = v } end
        end
        return r
    end
    local function show(list)
        local t = {}
        for _, e in ipairs(list or {}) do t[#t + 1] = ("%d:%s:%s"):format(e.index, e.name, e.values == "" and "Default" or e.values) end
        return #t > 0 and table.concat(t, ",") or "-"
    end
    -- After a step: the baseline entries unchanged, and exactly the DT6-* entries in want (names in order, right after
    -- the baseline, all Default unless an entry of want is { name, values }); the game's own DT6 presets the same names.
    local function judge(label, want)
        local list = readFile()
        if not check(list ~= nil, "%s the sidecar exists (%s)", label, P.file) then return end
        local base, ours = {}, {}
        for _, e in ipairs(list) do if isOurs(e.name) then ours[#ours + 1] = e else base[#base + 1] = e end end
        check(show(base) == show(P.baseline), "%s baseline entries unchanged (%s)", label, show(base))
        local exp, wantNames = {}, {}
        for i, n in ipairs(want) do
            local nm, v = n, ""
            if type(n) == "table" then nm, v = n[1], n[2] end
            exp[i] = { index = #P.baseline + i - 1, name = nm, values = v }
            wantNames[i] = nm
        end
        check(show(ours) == show(exp), "%s DT6 entries %s (want %s)", label, show(ours), show(exp))
        local cs = screen()
        local game = cs and names(cs)
        if game then
            local g = {}
            for _, n in ipairs(game) do if isOurs(n) then g[#g + 1] = n end end
            check(table.concat(g, ",") == table.concat(wantNames, ","), "%s the game's DT6 presets [%s] (want [%s])", label, table.concat(g, ","), table.concat(wantNames, ","))
        end
    end
    -- Story 14: Meek's Insta-kill box (core's checkbox, a tagged button widget in the Meek row), found in the screen's
    -- tree (a user widget's own tree through its HBox), and clicked through the button's click function, which core's
    -- click hook routes to the checkbox (Difficulty's onChange logs ROWS change kill.meek=...).
    local function tagged(cs, tag)
        local ok0, root = pcall(function() return cs.WidgetTree.RootWidget end)
        if not ok0 or not valid(root) then return nil end
        local stack, seen = { root }, 0
        while #stack > 0 and seen < 4096 do
            local w = table.remove(stack)
            seen = seen + 1
            local okT, t = pcall(function() return w.CoreTag:ToString() end)
            if okT and t == tag then return w end
            local okN, n = pcall(function() return w:GetChildrenCount() end)
            if okN and type(n) == "number" then
                for i = n - 1, 0, -1 do
                    local okC, c = pcall(function() return w:GetChildAt(i) end)
                    if okC and valid(c) then stack[#stack + 1] = c end
                end
            end
            local okH, hb = pcall(function() return w.HBox end)
            if okH and valid(hb) then stack[#stack + 1] = hb end
        end
        return nil
    end
    -- Calls one of the screen's handlers; a handler that can't be driven is NOTSHOWN (and ends the scenario).
    local function drive(what, fn)
        local cs = screen()
        if not cs then P.abort = true S.notShown = S.notShown + 1 say("NOTSHOWN %s: no create-world screen in the viewport", what) return false end
        local ok, err = pcall(fn, cs)
        if not ok then P.abort = true S.notShown = S.notShown + 1 say("NOTSHOWN %s: %s", what, tostring(err)) return false end
        say("DRIVE %s", what)
        return true
    end
    local function clickBox(what)
        return drive(what, function(cs)
            local w = tagged(cs, BOX_TAG)
            if not w then error("no widget tagged " .. BOX_TAG .. " on the screen") end
            w:Nucleus_OnClicked()
        end)
    end
    local function open(what)
        local p = pc()
        local cls = loadClass(CS_CLASS)
        local ok, err = pcall(function()
            if not cls then error("CreateServer_C not loaded") end
            local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(p, cls, p)
            if not valid(w) then error("WidgetBlueprintLibrary:Create returned no widget") end
            w:AddToViewport(0)
        end)
        if not ok then P.abort = true S.notShown = S.notShown + 1 say("NOTSHOWN %s: %s", what, tostring(err)) return false end
        say("DRIVE %s", what)
        return true
    end
    local function selectAt(cs, i, option)
        cs.MultipleSelectBox_11:SetSelectedOption(i)
        cs[H_SELECT](cs, option, i)
    end
    local function selectName(what, name)
        return drive(what, function(cs)
            local i = position(cs, name)
            if not i then error("no preset " .. name) end
            selectAt(cs, i, name)
        end)
    end
    local function save(name)
        return drive("save " .. name, function(cs)
            local before = #(names(cs) or {})
            -- PresetName, as the name box's text-changed handler sets it; that handler (with an FText) if the write fails.
            local okN = pcall(function() cs.PresetName = name end)
            if not okN or str(cs.PresetName) ~= name then cs[H_TEXT](cs, FText(name)) say("NAME set through the text-changed handler") end
            cs[H_SAVE](cs)
            if #(names(cs) or {}) ~= before + 1 then error("the game's preset count didn't grow (PresetName " .. tostring(str(cs.PresetName)) .. ")") end
        end)
    end
    local function deleteName(name)
        if not selectName("select " .. name .. " for delete", name) then return false end
        return drive("delete " .. name, function(cs)
            cs[H_DELETE](cs)
            if position(cs, name) then error("the game still lists " .. name) end
        end)
    end
    local function pstep(name, fn) step(name, function() if P.abort then return end return fn() end) end

    step("menu", function() return function() return worldName():find("NewMainMenu", 1, true) ~= nil end, 240, "menu world" end)
    step("load the screen class", function()
        local cls = loadClass(CS_CLASS)
        check(cls ~= nil, "CLASS CreateServer_C loaded")
        local okD, d = pcall(function() return StaticFindObject("/Script/Engine.Default__BlueprintPathsLibrary"):ProjectSavedDir() end)
        d = okD and str(d) or nil
        if not check(type(d) == "string" and d ~= "", "SAVEDDIR %s", tostring(d)) then P.abort = true return end
        if not d:match("[/\\]$") then d = d .. "/" end
        P.file = d .. "SaveGames/" .. ME:gsub("Driver$", "") .. "_WorldPresets.txt"
        say("SIDECAR %s", P.file)
        -- Difficulty registers its CreateServer_C hooks after the menu's LoadMap (retried every 3 s, 3 times).
        return after(12), 15
    end)
    pstep("1 open", function()
        if not open("open #1") then return end
        return after(2), 4
    end)
    pstep("1 delete leftovers", function()
        local n = 0
        while n < 20 do
            local cs = screen()
            local left
            for _, nm in ipairs(cs and names(cs) or {}) do if isOurs(nm) then left = nm break end end
            if not left then break end
            n = n + 1
            if not deleteName(left) then return end
        end
        say("CLEANUP deleted %d leftover %s preset(s)", n, PREFIX)
        return after(1), 3
    end)
    pstep("1 baseline", function()
        local list = readFile() or {}
        P.baseline = {}
        for _, e in ipairs(list) do if not isOurs(e.name) then P.baseline[#P.baseline + 1] = e end end
        local cs = screen()
        local game = cs and names(cs) or {}
        say("BASELINE presets=%d entries=%s", #game, show(P.baseline))
        check(#P.baseline == #game, "1 baseline: one sidecar entry per game preset (%d entries, %d presets)", #P.baseline, #game)
        if #game > 0 then judge("1 baseline:", {}) end
    end)
    pstep("2 save A", function() if save(PREFIX .. "A") then judge("2 save A:", { PREFIX .. "A" }) end return after(1), 3 end)
    pstep("2 save B", function() if save(PREFIX .. "B") then judge("2 save B:", { PREFIX .. "A", PREFIX .. "B" }) end return after(1), 3 end)
    -- Story 14: K saved with Meek's box ticked, then the box unticked again (the later steps stay Default).
    pstep("2 tick Meek's box", function() clickBox("tick Meek's Insta-kill box") return after(1), 3 end)
    pstep("2 save K", function() if save(KPRESET[1]) then judge("2 save K:", { PREFIX .. "A", PREFIX .. "B", KPRESET }) end return after(1), 3 end)
    pstep("2 untick Meek's box", function() clickBox("untick Meek's Insta-kill box") return after(1), 3 end)
    pstep("3 select A", function()
        if selectName("select " .. PREFIX .. "A", PREFIX .. "A") then judge("3 select A:", { PREFIX .. "A", PREFIX .. "B", KPRESET }) end
        return after(1), 3
    end)
    pstep("4 update A", function()
        if drive("update " .. PREFIX .. "A", function(cs) cs[H_UPDATE](cs) end) then judge("4 update A:", { PREFIX .. "A", PREFIX .. "B", KPRESET }) end
        return after(1), 3
    end)
    pstep("4 select None", function()
        if drive("select None", function(cs) selectAt(cs, 0, "None") end) then judge("4 select None:", { PREFIX .. "A", PREFIX .. "B", KPRESET }) end
        return after(1), 3
    end)
    pstep("4 delete A", function() if deleteName(PREFIX .. "A") then judge("4 delete A:", { PREFIX .. "B", KPRESET }) end return after(1), 3 end)
    pstep("5 remove the screen", function()
        drive("remove the screen", function(cs) cs:RemoveFromParent() end)
        return function() return screen() == nil end, 5, "the screen removed"
    end)
    pstep("5 stale line", function()
        local f = io.open(P.file, "ab")
        if not check(f ~= nil, "5 the sidecar opened for append") then P.abort = true return end
        f:write("99\t" .. PREFIX .. "gone\tcold=50\n")
        f:close()
        say("STALE appended 99 %sgone cold=50 (test only)", PREFIX)
        return after(1), 3
    end)
    pstep("5 reopen", function()
        if not open("open #2") then return end
        return after(2), 4
    end)
    pstep("5 after reopen", function() judge("5 reopen:", { PREFIX .. "B", KPRESET }) end)
    -- Story 14: K read back after the reopen (Difficulty's PRESETS select line carries kill.meek=1: check.ps1).
    pstep("5 select K", function()
        if selectName("select " .. KPRESET[1], KPRESET[1]) then judge("5 select K:", { PREFIX .. "B", KPRESET }) end
        return after(1), 3
    end)
    pstep("6 delete B", function() if deleteName(PREFIX .. "B") then judge("6 delete B:", { KPRESET }) end return after(1), 3 end)
    pstep("6 delete K", function() if deleteName(KPRESET[1]) then judge("6 delete K:", {}) end return after(1), 3 end)
    step("6 close", function()
        local cs = screen()
        if cs then pcall(function() cs:RemoveFromParent() end) say("CLOSE the screen removed") end
        return after(1), 3
    end)
end

-- ---------------------------------------------------------------- story 7: the rows on the screen (menu only, VM)
-- Real input through run.ps1 -Target vm (tools/vm/vm-sp.ps1: click, drag, type, key, shot). Ten opens by real clicks on
-- START GAME and Back: the 21 rows in VerticalBox_202 in the wanted order against the game's own order (read in a
-- Construct hook, before core attaches anything): the knob rows at children 2-8 right after Overlay_28 (story 12's
-- Tokens per Classified and Max Classified Tokens 4th and 5th, right after Reinforcement Tokens; their Default boxes
-- empty with the hints 0 and "no cap", SCNEWROWS), the per-enemy
-- rows right after Overlay_738, the game rows in their stock order, one widget per row; then CONFIGURE and real clicks
-- on the Difficulty picker's next and previous arrows (the value changes and comes back), CONFIRM and Back. An eleventh
-- open: CONFIGURE, a screenshot, a drag on Enemy Damage, 57 / 999 / empty typed into its box, a custom Cold, 2.3 typed
-- into Frostbite (2.5), Nightmare through the Difficulty picker's own handler (Default hints follow, Cold keeps its
-- value), a real click on that picker's prev arrow and on the Classified Minimum picker's next arrow (the tokens row
-- follows), then a preset: Cold cleared, Enemy Damage 17 saved as DT7-A on Hard, 40 typed, None (rows unchanged), the
-- screen put on Easy, DT7-A (17 again, Default rows follow DT7-A's Hard), DT7-A deleted; CONFIRM, Back and one more
-- open that starts Default on Normal. Difficulty's own ROWS lines are judged by check.ps1. Never clicks Create.
if SC.special == "screen" or SC.special == "signal-a" or SC.special == "signal-b" then
    -- signal-b keeps the match steps (from "match world" on: the grab cases, cold and the computer's text) as its tail.
    local tail = {}
    if SC.special == "signal-b" then for i = MATCH_WORLD_IDX, #steps do tail[#tail + 1] = steps[i] end end
    steps = {}
    local CS_CLASS = "/Game/Graphics/MainMenu/CreateServer.CreateServer_C"
    local CS_SHORT, MENU_SHORT, START = "CreateServer_C", "MainMenu_C", "UI_Button_Master"
    local VB, CORE_NAME, OPENS, PREFIX = "VerticalBox_202", "Nucleus", 10, "DT7-"
    local ROW_SHORT, SLIDER_SHORT = "WBP_" .. CORE_NAME .. "Row_C", "WBP_" .. CORE_NAME .. "Slider_C"
    local TAG = CORE_NAME:lower() .. ":" .. ME:gsub("Driver$", "") .. ":"
    local ACTOR_CDO = "/Game/Mods/" .. CORE_NAME .. "/ModActor.Default__ModActor_C"
    local H_SELECT = "BndEvt__CreateServer_MultipleSelectBox_11_K2Node_ComponentBoundEvent_31_OnSelectionChanged__DelegateSignature"
    local H_SAVE = "BndEvt__CreateServer_Create_1_K2Node_ComponentBoundEvent_33_OnButtonClickedEvent__DelegateSignature"
    local H_DELETE = "BndEvt__CreateServer_Create_4_K2Node_ComponentBoundEvent_35_OnButtonClickedEvent__DelegateSignature"
    local H_TEXT = "BndEvt__CreateServer_EditableText_K2Node_ComponentBoundEvent_32_OnEditableTextChangedEvent__DelegateSignature"
    local H_DIFF = "BndEvt__CreateServer_MultipleSelectBox_6_K2Node_ComponentBoundEvent_5_OnSelectionChanged__DelegateSignature"
    local KNOBS = { "enemyDamage", "spread", "revives", "classifiedTokens", "classifiedTokensMax", "cold", "frostbite" }
    local NROWS = #KNOBS + 14 -- the knob rows and the fourteen per-enemy rows (21)
    local ENEMY = { "meek", "mimic", "psycho", "husk", "watcher", "stalker", "slugQueen", "apex", "worm", "leech", "bat",
                    "infectedDog", "infectedPlayer", "monster" }
    local Z = { snap = nil, snaps = 0, snapOurs = nil, paths = {}, abort = false, allOk = true }
    local function try(f) local ok, r = pcall(f) if ok then return r end return nil end
    local function prop(o, k) local r = try(function() return o[k] end) return valid(r) and r or nil end
    local function str(x) if type(x) == "string" then return x end return try(function() return x:ToString() end) end
    local function liveOf(short)
        for _, w in ipairs(FindAllOf(short) or {}) do
            if notDefault(w) and try(function() return w:IsInViewport() end) then return w end
        end
        return nil
    end
    local function screen() return liveOf(CS_SHORT) end
    local function nchild(w) return try(function() return w:GetChildrenCount() end) or 0 end
    local function child(w, i) local c = try(function() return w:GetChildAt(i) end) return valid(c) and c or nil end
    local function findIn(root, name)
        local stack, seen = { root }, 0
        while #stack > 0 and seen < 4096 do
            local w = table.remove(stack)
            seen = seen + 1
            if nameOf(w) == name then return w end
            for i = nchild(w) - 1, 0, -1 do local c = child(w, i) if c then stack[#stack + 1] = c end end
        end
        return nil
    end
    local function rootOf(s) local t = prop(s, "WidgetTree") return t and prop(t, "RootWidget") or nil end
    local function vbOf(s) s = s or screen() local r = s and rootOf(s) return r and findIn(r, VB) or nil end
    local function tagOf(w) return try(function() return w.CoreTag:ToString() end) end
    -- The box's children: { name (a game row's widget name, or our row's id), ours, w }.
    local function listOf(vb)
        local l = {}
        for i = 0, nchild(vb) - 1 do
            local c = child(vb, i)
            local t = c and classOf(c) == ROW_SHORT and tagOf(c)
            local id = type(t) == "string" and t:sub(1, #TAG) == TAG and t:sub(#TAG + 1) or nil
            l[#l + 1] = { name = id or (c and nameOf(c) or "?"), ours = id ~= nil, w = c }
        end
        return l
    end
    local function names(l) local t = {} for _, e in ipairs(l) do t[#t + 1] = e.name end return table.concat(t, ",") end
    local function rowW(key) local vb = vbOf() for _, e in ipairs(vb and listOf(vb) or {}) do if e.name == "r-" .. key then return e.w end end return nil end
    -- Our slider widget inside a row (tagged s-<key>), searched in the row's own widget tree.
    local function sliderW(key)
        local r = rowW(key)
        if not r then return nil end
        -- The row is a UserWidget: its tree starts at its own HBox (a UserWidget has no GetChildAt).
        local stack, seen = { prop(r, "HBox") }, 0
        while #stack > 0 and seen < 256 do
            local w = table.remove(stack)
            seen = seen + 1
            if classOf(w) == SLIDER_SHORT and tagOf(w) == TAG .. "s-" .. key then return w end
            for i = nchild(w) - 1, 0, -1 do local c = child(w, i) if c then stack[#stack + 1] = c end end
        end
        return nil
    end
    -- Story 14: the Insta-kill box in an enemy's row (a button widget tagged c-kill.<enemy>), or nil; any c-* widget
    -- there counts for the "no box" rows.
    local function boxW(enemy, any)
        local r = rowW("dmg." .. enemy)
        if not r then return nil end
        local stack, seen = { prop(r, "HBox") }, 0
        while #stack > 0 and seen < 256 do
            local w = table.remove(stack)
            seen = seen + 1
            local t = tagOf(w)
            if type(t) == "string" and (t == TAG .. "c-kill." .. enemy or (any and t:sub(1, #TAG + 2) == TAG .. "c-")) then return w end
            for i = nchild(w) - 1, 0, -1 do local c = child(w, i) if c then stack[#stack + 1] = c end end
        end
        return nil
    end
    local KILLROW = { meek = true, mimic = true, psycho = true, husk = true, watcher = true, stalker = true, slugQueen = true, apex = true }
    -- A slider's bar value, box text and hint text.
    local function sstate(key)
        local w = sliderW(key)
        if not w then return nil, "?", "?" end
        local bar, box = prop(w, "Bar"), prop(w, "Box")
        return bar and try(function() return bar:GetValue() end), box and str(try(function() return box:GetText() end)) or "?",
            box and str(try(function() return box:GetHintText() end)) or "?"
    end
    -- A widget's rectangle in desktop pixels, from core's ModActor helpers (as core's own scenarios do).
    local function absR(w)
        local cdo = StaticFindObject(ACTOR_CDO)
        if not (valid(cdo) and valid(w)) then return nil end
        local ok, r = pcall(function()
            local a, b = cdo[CORE_NAME .. "_AbsTopLeft"](cdo, w), cdo[CORE_NAME .. "_AbsBottomRight"](cdo, w)
            return { l = a.X, t = a.Y, r = b.X, b = b.Y }
        end)
        return ok and r or nil
    end
    local function pointOf(w, fx, fy)
        local r = w and absR(w)
        if not (r and r.r > r.l and r.b > r.t) then return nil end
        return math.floor(r.l + (r.r - r.l) * fx + 0.5), math.floor(r.t + (r.b - r.t) * fy + 0.5)
    end
    local function sstep(name, fn) step(name, function() if Z.abort then return end return fn() end) end
    local function req(label, cmdOf, settle)
        sstep("sc: " .. label, function()
            local cmd = cmdOf()
            if not check(cmd ~= nil, "SCPOINT %s has a point on screen", label) then Z.abort = true return end
            say("SCREQ %s: %s", label, cmd)
            return request(cmd), 40, label
        end)
        sstep("sc: settle " .. label, function() return after(settle or 1.2), (settle or 1.2) + 3 end)
    end
    local function click(label, finder, fx, fy)
        req(label, function() local x, y = pointOf(finder(), fx or 0.5, fy or 0.5) if x then return string.format("click %d %d", x, y) end end)
    end
    -- A click on the box (it selects its text), then the text (or Backspace to empty it), then Enter.
    local function typeInto(label, key, text)
        click(label .. " focus", function() return prop(sliderW(key), "Box") end, 0.85, 0.5)
        if text == "" then req(label .. " back", function() return "key BACK" end, 0.8)
        else req(label .. " type", function() return "type " .. text end, 0.8) end
        req(label .. " enter", function() return "key ENTER" end)
    end
    local function shot(label) sstep("sc: shot " .. label, function() return request("shot " .. label), 30, "screenshot " .. label end) end
    local function fmtv(x) return x == nil and "nil" or string.format("%g", x) end
    local function near(a, b) return a ~= nil and b ~= nil and math.abs(a - b) < 0.01 end
    -- The game's preset names (selector items 2..n; item 1 is "None").
    local function presetNames(cs)
        local r = {}
        pcall(function()
            local items = cs.MultipleSelectBox_11.Items
            for i = 2, math.min(items:GetArrayNum(), 300) do r[#r + 1] = str(items[i]) or "?" end
        end)
        return r
    end
    local function selectAt(cs, i, option) cs.MultipleSelectBox_11:SetSelectedOption(i) cs[H_SELECT](cs, option, i) end
    local function drive(what, fn)
        local cs = screen()
        if not cs then Z.abort = true S.notShown = S.notShown + 1 say("NOTSHOWN %s: no create-world screen in the viewport", what) return false end
        local ok, err = pcall(fn, cs)
        if not ok then Z.abort = true S.notShown = S.notShown + 1 say("NOTSHOWN %s: %s", what, tostring(err)) return false end
        say("DRIVE %s", what)
        return true
    end
    local function deletePreset(cs, name)
        local pos
        for i, n in ipairs(presetNames(cs)) do if n == name then pos = i break end end
        if not pos then return false end
        selectAt(cs, pos, name)
        cs[H_DELETE](cs)
        return true
    end
    -- The wanted order: the game's own rows (Z.snap) with the knob rows after Overlay_28 and the per-enemy rows after
    -- Overlay_738.
    local function wanted()
        local t = {}
        for _, n in ipairs(Z.snap or {}) do
            t[#t + 1] = n
            if n == "Overlay_28" then for _, k in ipairs(KNOBS) do t[#t + 1] = "r-" .. k end end
            if n == "Overlay_738" then for _, e in ipairs(ENEMY) do t[#t + 1] = "r-dmg." .. e end end
        end
        return table.concat(t, ",")
    end
    local function ours(vb) local k = 0 for _, e in ipairs(listOf(vb)) do if e.ours then k = k + 1 end end return k end

    step("menu", function() return function() return worldName():find("NewMainMenu", 1, true) ~= nil end, 240, "menu world" end)
    step("sc: class and the Construct snapshot", function()
        local cls = loadClass(CS_CLASS)
        if not check(cls ~= nil, "CLASS CreateServer_C loaded") then Z.abort = true return end
        -- The game's own rows, read right after Construct (core attaches our rows about a second later).
        hook(CS_CLASS .. ":Construct", function(ctx)
            local s = get(ctx)
            local vb = s and vbOf(s)
            if not vb then return end
            local t, k = {}, 0
            for _, e in ipairs(listOf(vb)) do if e.ours then k = k + 1 else t[#t + 1] = e.name end end
            Z.snap, Z.snaps, Z.snapOurs = t, Z.snaps + 1, k
            say("SCSNAP %d game rows, %d of ours at Construct: %s", #t, k, table.concat(t, ","))
        end)
        return after(12), 15 -- Difficulty's preset hooks (and core's poll) settle after the menu's LoadMap
    end)
    sstep("sc: startup", function()
        if liveOf(MENU_SHORT) then return end
        local done = request("key ENTER")
        local deadline, tries = os.clock() + 15, 1
        return function()
            if liveOf(MENU_SHORT) then return true end
            if os.clock() > deadline and done() and tries < 4 then
                tries, deadline = tries + 1, os.clock() + 15
                say("STARTUP no menu yet; Enter again (%d)", tries)
                done = request("key ENTER")
            end
            return false
        end, 70, "menu after Enter"
    end)
    sstep("sc: settle menu", function() return after(3), 6 end)

    local function openOnce(n)
        click("START GAME " .. n, function() return prop(liveOf(MENU_SHORT), START) end)
        sstep("sc: rows attached " .. n, function()
            return function() local vb = vbOf() return vb ~= nil and ours(vb) >= NROWS end, 12, "open " .. n .. ": the " .. NROWS .. " rows attached"
        end)
        sstep("sc: settle attach " .. n, function() return after(1), 4 end) -- the insert pass runs on the opened tick
        sstep("sc: order " .. n, function()
            local vb = vbOf()
            if not check(vb ~= nil, "SCLIST open %d: %s found", n, VB) then Z.allOk = false return end
            local l = listOf(vb)
            local got, want = names(l), wanted()
            local seen, games = {}, {}
            for _, e in ipairs(l) do if e.ours then seen[e.name] = (seen[e.name] or 0) + 1 else games[#games + 1] = e.name end end
            local one = true
            for _, k in ipairs(KNOBS) do if seen["r-" .. k] ~= 1 then one = false end end
            for _, e in ipairs(ENEMY) do if seen["r-dmg." .. e] ~= 1 then one = false end end
            local kIdx
            for i, e in ipairs(l) do if e.name == "r-enemyDamage" then kIdx = i - 1 break end end
            local stock = #games > 0 and table.concat(games, ",") == table.concat(Z.snap or {}, ",") and Z.snapOurs == 0
            local okOrder = got == want and kIdx == 2
            check(okOrder, "SCORDER open %d: the knob rows at children 2-8 after Overlay_28, the per-enemy rows right after Overlay_738 (enemyDamage at %s)%s",
                n, tostring(kIdx), okOrder and "" or (": got " .. got .. " want " .. want))
            check(stock, "SCSTOCK open %d: the %d game rows in their stock order (as read at Construct, none of ours there yet)", n, #games)
            check(one, "SCONE open %d: one widget per row (%d ids)", n, NROWS)
            local w = rowW("enemyDamage")
            local p = w and pathOf(w)
            local new = p ~= nil and not Z.paths[p]
            if p then Z.paths[p] = true end
            local _, box, hint = sstate("enemyDamage")
            check(new and box == "" and hint == "25", "SCNEW open %d: a new row widget, Enemy Damage empty with the hint 25 (box '%s', hint %s)", n, tostring(box), tostring(hint))
            if n == 1 then
                -- Story 12: the two new rows start Default: Tokens per Classified at 0, Max Classified Tokens at 40 ("no cap").
                local cv, cb, ch = sstate("classifiedTokens")
                local mv, mb, mh = sstate("classifiedTokensMax")
                check(cb == "" and ch == "0" and near(cv, 0) and mb == "" and mh == "no cap" and near(mv, 40),
                    "SCNEWROWS Tokens per Classified Default (box '%s', hint %s, bar %s; want empty, 0, 0) and Max Classified Tokens Default (box '%s', hint %s, bar %s; want empty, no cap, 40)",
                    tostring(cb), tostring(ch), fmtv(cv), tostring(mb), tostring(mh), fmtv(mv))
            end
            if n == 1 or not okOrder then say("SCROWS open %d: %s", n, got) end
            Z.allOk = Z.allOk and okOrder and stock and one and new
        end)
    end
    -- CONFIGURE shows the settings list (hidden until then), scrolled to its start.
    local function configure(label)
        click("CONFIGURE " .. label, function() return prop(screen(), "Button_216") end)
        sstep("sc: configure " .. label, function()
            local s = screen()
            local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
            if sb then pcall(function() sb:ScrollToStart() end) end
            local vis = try(function() return prop(s, "Overlay_0"):GetVisibility() end)
            check(vis ~= nil and vis ~= 1 and vis ~= 2, "SCCONFIG %s: CONFIGURE shows the world settings (Overlay_0 visibility %s)", label, tostring(vis))
            return after(1.5), 4
        end)
    end
    -- The screen's Diffculty, the Difficulty picker's shown option and Enemy Damage's hint.
    local function diffState()
        local cs = screen()
        local _, _, hint = sstate("enemyDamage")
        return cs and num(try(function() return cs.Diffculty end)), cs and str(try(function() return cs.MultipleSelectBox_6.SelectedOption end)), hint
    end
    -- One CONFIRM and Back (CONFIRM hides the settings again, so Back is reachable).
    local function confirmBack(label)
        click("CONFIRM " .. label, function() return prop(screen(), "Create_3") end)
        click("Back " .. label, function() return prop(screen(), "Back") end)
        sstep("sc: closed " .. label, function() return function() return screen() == nil end, 10, "screen closed " .. label end)
    end
    if SC.special == "screen" then
    Z.picks = 0
    for n = 1, OPENS do
        openOnce(n)
        -- The game's Difficulty picker works on every open: next (Normal -> Hard), then back (Hard -> Normal).
        configure(tostring(n))
        click("Difficulty next " .. n, function() return prop(prop(screen(), "MultipleSelectBox_6"), "Button") end)
        sstep("sc: picked " .. n, function()
            local d, opt, hint = diffState()
            local okN = check(d == 1 and opt == "Hard" and hint == "50", "SCPICK open %d next: Diffculty %s, shown %s, Enemy Damage hint %s (want 1, Hard, 50)", n, tostring(d), tostring(opt), tostring(hint))
            Z.pickNext = okN
        end)
        click("Difficulty prev " .. n, function() return prop(prop(screen(), "MultipleSelectBox_6"), "Button_60") end)
        sstep("sc: picked back " .. n, function()
            local d, opt, hint = diffState()
            local okP = check(d == 2 and opt == "Normal" and hint == "25", "SCPICK open %d prev: Diffculty %s, shown %s, Enemy Damage hint %s (want 2, Normal, 25)", n, tostring(d), tostring(opt), tostring(hint))
            if okP and Z.pickNext then Z.picks = Z.picks + 1 end
        end)
        confirmBack(tostring(n))
    end
    sstep("sc: ten opens", function()
        local k = 0
        for _ in pairs(Z.paths) do k = k + 1 end
        check(Z.allOk and k == OPENS and Z.snaps >= OPENS, "SCTEN %d opens by real clicks: every row once, in order, the game rows in stock order; %d distinct row widgets, %d Construct snapshots", OPENS, k, Z.snaps)
        check(Z.picks == OPENS, "SCPICKTEN the Difficulty picker changed its value by real clicks (and back) on %d of %d opens", Z.picks, OPENS)
    end)

    -- The eleventh open: the settings shown, then the real input.
    openOnce(OPENS + 1)
    sstep("sc: delete leftovers", function()
        local n = 0
        drive("delete leftover " .. PREFIX .. " presets", function(cs)
            for _ = 1, 20 do
                local left
                for _, nm in ipairs(presetNames(cs)) do if nm:sub(1, #PREFIX) == PREFIX then left = nm break end end
                if not left or not deletePreset(cs, left) then break end
                n = n + 1
            end
        end)
        say("CLEANUP deleted %d leftover %s preset(s)", n, PREFIX)
        return after(1), 3
    end)
    configure(tostring(OPENS + 1))
    shot("screen-rows")

    -- Enemy Damage: a drag, then 57, 999 and empty typed into its box. Difficulty's ROWS change lines are check.ps1's.
    req("drag Enemy Damage", function()
        local bar = prop(sliderW("enemyDamage"), "Bar")
        local x1, y = pointOf(bar, 25 / 200, 0.5)
        local x2 = pointOf(bar, 0.4, 0.5)
        if x1 then return string.format("drag %d %d %d %d", x1, y, x2, y) end
    end, 1.5)
    sstep("sc: dragged", function()
        local val, box = sstate("enemyDamage")
        local v = tonumber(box)
        check(v ~= nil and v ~= 25 and v >= 40 and v <= 120 and math.floor(v) == v and near(val, v), "SCDRAG value=%s bar=%s (the box followed the drag)", tostring(box), fmtv(val))
    end)
    typeInto("ed 57", "enemyDamage", "57")
    sstep("sc: ed 57", function()
        local val, box = sstate("enemyDamage")
        check(box == "57" and near(val, 57), "SCTYPE 57: box '%s' bar %s", tostring(box), fmtv(val))
    end)
    typeInto("ed 999", "enemyDamage", "999")
    sstep("sc: ed 999", function()
        local val, box = sstate("enemyDamage")
        check(box == "200" and near(val, 200), "SCTYPE 999: clamped, box '%s' bar %s", tostring(box), fmtv(val))
    end)
    typeInto("ed empty", "enemyDamage", "")
    sstep("sc: ed empty", function()
        local val, box, hint = sstate("enemyDamage")
        check(box == "" and hint == "25" and near(val, 25), "SCTYPE empty: Default, box '%s' hint %s bar %s", tostring(box), tostring(hint), fmtv(val))
    end)
    typeInto("cold 150", "cold", "150")
    sstep("sc: cold 150", function()
        local val, box = sstate("cold")
        check(box == "150" and near(val, 150), "SCTYPE cold 150: box '%s' bar %s", tostring(box), fmtv(val))
    end)
    -- The 0.5 step in game: 2.3 typed into Frostbite Damage becomes 2.5 (check.ps1: ROWS change frostbite=2.5).
    typeInto("frostbite 2.3", "frostbite", "2.3")
    sstep("sc: frostbite 2.3", function()
        local val, box = sstate("frostbite")
        check((box == "2.5" or box == "2,5") and near(val, 2.5), "SCSTEP frostbite 2.3 typed: box '%s' bar %s (want 2.5)", tostring(box), fmtv(val))
    end)

    -- Nightmare through the Difficulty picker's own handler: the Default rows follow, the custom Cold stays.
    sstep("sc: Nightmare", function()
        drive("Difficulty Nightmare (handler)", function(cs)
            local msb = cs.MultipleSelectBox_6
            local idx
            local items = msb.Items
            for i = 1, math.min(items:GetArrayNum(), 16) do if str(items[i]) == "Nightmare" then idx = i - 1 end end
            if not idx then error("no Nightmare option") end
            msb:SetSelectedOption(idx)
            cs[H_DIFF](cs, "Nightmare", idx)
        end)
        return after(1), 3
    end)
    sstep("sc: Nightmare check", function()
        local cs = screen()
        local d = cs and num(try(function() return cs.Diffculty end))
        local val, box, hint = sstate("enemyDamage")
        local cv, cb, ch = sstate("cold")
        check(d == 0, "SCDIFF the screen's Diffculty is 0 (Nightmare): %s", tostring(d))
        check(box == "" and hint == "100" and near(val, 100), "SCNIGHTMARE Enemy Damage Default: hint %s, slider at %s, box '%s'", tostring(hint), fmtv(val), tostring(box))
        check(cb == "150" and near(cv, 150) and ch == "200", "SCNIGHTMARE Cold keeps 150 (box '%s', bar %s, hint %s)", tostring(cb), fmtv(cv), tostring(ch))
    end)
    shot("screen-nightmare")
    -- The game's own picker still works: a real click on its previous arrow (Nightmare -> Hard).
    click("Difficulty prev arrow", function() return prop(prop(screen(), "MultipleSelectBox_6"), "Button_60") end)
    sstep("sc: picker check", function()
        local cs = screen()
        local d = cs and num(try(function() return cs.Diffculty end))
        local opt = cs and str(try(function() return cs.MultipleSelectBox_6.SelectedOption end))
        local _, _, hint = sstate("enemyDamage")
        check(d == 1 and opt == "Hard", "SCPICKER a real click on the Difficulty picker's arrow: Diffculty %s, shown %s (want 1, Hard)", tostring(d), tostring(opt))
        check(hint == "50", "SCPICKER the Default Enemy Damage row follows the picker: hint %s (want 50)", tostring(hint))
    end)
    -- The Classified Minimum picker (MultipleSelectBox): a real click on its next arrow (Normal -> Hard, index 1); the
    -- Default Reinforcement Tokens row follows (6 -> 4; check.ps1: ROWS follow ... classified=1).
    click("Classified next", function() return prop(prop(screen(), "MultipleSelectBox"), "Button") end)
    sstep("sc: classified check", function()
        local cs = screen()
        local cm = cs and num(try(function() return cs["Minium Classified"] end))
        local opt = cs and str(try(function() return cs.MultipleSelectBox.SelectedOption end))
        local val, box, hint = sstate("revives")
        check(cm == 1 and opt == "Hard", "SCCLASS a real click on the Classified Minimum picker's arrow: Minium Classified %s, shown %s (want 1, Hard)", tostring(cm), tostring(opt))
        check(box == "" and hint == "4" and near(val, 4), "SCCLASS the Default Reinforcement Tokens row follows: hint %s, slider at %s, box '%s' (want 4)", tostring(hint), fmtv(val), tostring(box))
    end)

    -- Story 14: the Insta-kill boxes in the eight kill rows only, then a real click on Meek's (the list scrolled to its
    -- row first and back to its start after, so the later clicks find their rows on screen).
    sstep("sc: boxes", function()
        local bad = {}
        for _, e in ipairs(ENEMY) do
            local has = boxW(e, not KILLROW[e]) ~= nil
            if has ~= (KILLROW[e] == true) then bad[#bad + 1] = e .. (has and " has a box" or " has no box") end
        end
        check(#bad == 0, "SCBOXES an Insta-kill box in the eight kill rows only (Meek .. Apex Predator; none for Worm, Leech, Bat, Infected Dog, Infected Player, Playable Monster)%s",
            #bad > 0 and (": " .. table.concat(bad, ", ")) or "")
    end)
    sstep("sc: scroll to Meek", function()
        local s = screen()
        local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
        local r = rowW("dmg.meek")
        if sb and r then pcall(function() sb:ScrollWidgetIntoView(r, false, 2, 0) end) end
        return after(1), 3
    end)
    click("Meek Insta-kill box", function() return boxW("meek") end)
    shot("screen-kill")
    sstep("sc: scroll back", function()
        local s = screen()
        local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
        if sb then pcall(function() sb:ScrollToStart() end) end
        return after(1), 3
    end)

    -- A preset: Enemy Damage 17 (Cold back to Default) saved as DT7-A on Hard; 40 typed; None leaves the rows; the
    -- screen put on Easy; DT7-A brings 17 back and the Default rows follow its Hard.
    typeInto("cold empty", "cold", "")
    typeInto("ed 17", "enemyDamage", "17")
    sstep("sc: save", function()
        drive("save " .. PREFIX .. "A", function(cs)
            local before = #presetNames(cs)
            local okN = pcall(function() cs.PresetName = PREFIX .. "A" end)
            if not okN or str(cs.PresetName) ~= PREFIX .. "A" then cs[H_TEXT](cs, FText(PREFIX .. "A")) say("NAME set through the text-changed handler") end
            cs[H_SAVE](cs)
            if #presetNames(cs) ~= before + 1 then error("the game's preset count didn't grow") end
        end)
        return after(1), 3
    end)
    typeInto("ed 40", "enemyDamage", "40")
    sstep("sc: None", function()
        drive("select None", function(cs) selectAt(cs, 0, "None") end)
        return after(1), 3
    end)
    sstep("sc: None check", function()
        local val, box = sstate("enemyDamage")
        check(box == "40" and near(val, 40), "SCNONE None leaves the rows: Enemy Damage box '%s' bar %s (want 40)", tostring(box), fmtv(val))
    end)
    sstep("sc: Easy", function()
        drive("Difficulty Easy (handler)", function(cs)
            local msb = cs.MultipleSelectBox_6
            local idx
            local items = msb.Items
            for i = 1, math.min(items:GetArrayNum(), 16) do if str(items[i]) == "Easy" then idx = i - 1 end end
            if not idx then error("no Easy option") end
            msb:SetSelectedOption(idx)
            cs[H_DIFF](cs, "Easy", idx)
        end)
        return after(1), 3
    end)
    sstep("sc: Easy check", function()
        local d = diffState()
        local _, _, ch = sstate("cold")
        check(d == 3 and ch == "50", "SCEASY the screen on Easy before the select: Diffculty %s, Cold hint %s (want 3, 50)", tostring(d), tostring(ch))
    end)
    sstep("sc: select A", function()
        drive("select " .. PREFIX .. "A", function(cs)
            local pos
            for i, n in ipairs(presetNames(cs)) do if n == PREFIX .. "A" then pos = i end end
            if not pos then error("no preset " .. PREFIX .. "A") end
            selectAt(cs, pos, PREFIX .. "A")
        end)
        return after(1), 3
    end)
    sstep("sc: select A check", function()
        local val, box = sstate("enemyDamage")
        check(box == "17" and near(val, 17), "SCPRESET DT7-A shows Enemy Damage 17: box '%s' bar %s", tostring(box), fmtv(val))
        local d = diffState()
        local cv, cb, ch = sstate("cold")
        check(d == 1 and cb == "" and ch == "133" and near(cv, 133), "SCPRESETDIFF the Default rows follow DT7-A's Hard: Diffculty %s, Cold box '%s' hint %s slider %s (want 1, empty, 133)",
            tostring(d), tostring(cb), tostring(ch), fmtv(cv))
    end)
    shot("screen-preset")
    sstep("sc: delete A", function()
        drive("delete " .. PREFIX .. "A", function(cs) if not deletePreset(cs, PREFIX .. "A") then error("no preset " .. PREFIX .. "A") end end)
        return after(1), 3
    end)
    -- One more real Back and START GAME: the rows start Default on Normal again (story 6's rule).
    confirmBack("final")
    openOnce(OPENS + 2)
    sstep("sc: reopen check", function()
        local _, eb, eh = sstate("enemyDamage")
        local _, cb, ch = sstate("cold")
        check(eb == "" and eh == "25" and cb == "" and ch == "100", "SCREOPEN a new open starts Default on Normal: Enemy Damage box '%s' hint %s, Cold box '%s' hint %s (want empty 25, empty 100)",
            tostring(eb), tostring(eh), tostring(cb), tostring(ch))
    end)
    click("Back reopen", function() return prop(screen(), "Back") end)
    step("sc: close", function()
        local cs = screen()
        if cs then pcall(function() cs:RemoveFromParent() end) say("CLOSE the screen removed") end
        return after(1), 3
    end)
    else
    -- ------------------------------------------------------------ story 8: signal (two launches, saves kept)
    -- signal-a sets the rows on the screen the way a player would and saves DT8-SIGNAL; signal-b (the next launch)
    -- selects it, checks every row and hosts a friends-only solo match through the screen's Create button; the match
    -- part (grabs, cold, the computer's text) is the generic tail kept above. No dev.lua in either launch.
    local SIG = "DT8-SIGNAL"
    local SIGPREFIX = "DT8-"
    local H_CREATE = "BndEvt__CreateServer_Create_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature"
    local MAPSAVE = "/Game/Graphics/MainMenu/MapSelect_Save.MapSelect_Save_C"
    -- The values the screen gets, in the rows' own text (the box shows what the model holds).
    local WANT = { { "enemyDamage", "25" }, { "spread", "20" }, { "revives", "8" }, { "classifiedTokens", "2" },
                   { "classifiedTokensMax", "3" }, { "cold", "0" }, { "frostbite", "0" }, { "dmg.stalker", "200" } }
    local KMIN = { enemyDamage = 0, spread = 0, revives = 0, cold = 0, frostbite = 0, ["dmg.stalker"] = 0 }
    local KMAX = { enemyDamage = 200, spread = 50, revives = 20, cold = 400, frostbite = 20, ["dmg.stalker"] = 500 }
    local G = { fixRevives = false, sessionAt = nil }
    -- A step that asks for real input only when cond() holds (otherwise it does nothing).
    local function reqIf(label, cond, cmdOf, settle)
        sstep("sig: " .. label, function()
            if cond and not cond() then return end
            local cmd = cmdOf()
            if not check(cmd ~= nil, "SCPOINT %s has a point on screen", label) then Z.abort = true return end
            say("SCREQ %s: %s", label, cmd)
            return request(cmd), 40, label
        end)
        sstep("sig: settle " .. label, function() if cond and not cond() then return end return after(settle or 1.2), (settle or 1.2) + 3 end)
    end
    -- The settings list scrolled so a row is in view (its centre), before a click, a drag or typing on it.
    local function scrollTo(key)
        sstep("sig: scroll to " .. key, function()
            local s = screen()
            local sb = s and rootOf(s) and findIn(rootOf(s), "ScrollBox_54")
            local r = rowW(key)
            if sb and r then pcall(function() sb:ScrollWidgetIntoView(r, false, 2, 0) end) end
            return after(1), 3
        end)
    end
    local function typeRow(key, text, cond)
        scrollTo(key)
        reqIf("type " .. key .. " focus", cond, function()
            local x, y = pointOf(prop(sliderW(key), "Box"), 0.85, 0.5)
            if x then return string.format("click %d %d", x, y) end
        end)
        reqIf("type " .. key .. " text", cond, function() return "type " .. text end, 0.8)
        reqIf("type " .. key .. " enter", cond, function() return "key ENTER" end)
        sstep("sig: typed " .. key, function()
            if cond and not cond() then return end
            local val, box = sstate(key)
            check(box == text and near(val, tonumber(text)), "SIGTYPE %s typed %s: box '%s' bar %s", key, text, tostring(box), fmtv(val))
        end)
    end
    -- A real drag on a row's slider from its thumb to the value's point (target "min": past the bar's left end).
    local function dragRow(key, target)
        scrollTo(key)
        reqIf("drag " .. key, nil, function()
            local bar = prop(sliderW(key), "Bar")
            local val = sstate(key)
            local span = KMAX[key] - KMIN[key]
            local from = ((val or KMIN[key]) - KMIN[key]) / span
            local x1, y = pointOf(bar, from, 0.5)
            local r = bar and absR(bar)
            if not (x1 and r) then return nil end
            local x2 = target == "min" and math.floor(r.l - 40) or select(1, pointOf(bar, (target - KMIN[key]) / span, 0.5))
            return string.format("drag %d %d %d %d", x1, y, x2, y)
        end, 1.5)
    end
    local function rowsCheck(tag)
        sstep("sig: rows " .. tag, function()
            local bad = {}
            for _, kv in ipairs(WANT) do
                local val, box = sstate(kv[1])
                if box ~= kv[2] or not near(val, tonumber(kv[2])) then bad[#bad + 1] = ("%s box '%s' bar %s (want %s)"):format(kv[1], tostring(box), fmtv(val), kv[2]) end
            end
            local d, opt = diffState()
            check(#bad == 0 and d == 0, "SIGROWS %s: every row shows its value and the screen is on Nightmare (Diffculty %s, shown %s)%s", tag, tostring(d), tostring(opt),
                #bad > 0 and (": " .. table.concat(bad, "; ")) or "")
        end)
    end
    local function devLua()
        sstep("sig: dev.lua", function()
            local dir = scriptDir:gsub("[/\\][^/\\]+[/\\]Scripts$", "")
            local path = dir .. "\\" .. ME:gsub("Driver$", "") .. "\\Scripts\\dev.lua"
            local f = io.open(path, "r")
            if f then f:close() end
            say("DEVLUA %s %s", f and "present" or "absent", path)
            check(f == nil, "SIGDEV no dev.lua in %s's Scripts (the values come only from the screen, the preset and the capture)", ME:gsub("Driver$", ""))
        end)
    end
    local function deleteOurs(tag)
        sstep("sig: delete " .. tag, function()
            local n = 0
            drive("delete " .. SIGPREFIX .. "* (" .. tag .. ")", function(cs)
                for _ = 1, 20 do
                    local left
                    for _, nm in ipairs(presetNames(cs)) do if nm:sub(1, #SIGPREFIX) == SIGPREFIX then left = nm break end end
                    if not left or not deletePreset(cs, left) then break end
                    n = n + 1
                end
            end)
            say("CLEANUP deleted %d %s preset(s) (%s)", n, SIGPREFIX, tag)
            return after(1), 3
        end)
    end

    devLua()
    openOnce(1)
    if SC.special == "signal-a" then
        deleteOurs("leftovers")
        configure("signal")
        -- Nightmare by real clicks on the Difficulty picker's next arrow (Normal -> Hard -> Nightmare).
        for k = 1, 3 do
            reqIf("Nightmare click " .. k, function() return diffState() ~= 0 end, function()
                local x, y = pointOf(prop(prop(screen(), "MultipleSelectBox_6"), "Button"), 0.5, 0.5)
                if x then return string.format("click %d %d", x, y) end
            end)
        end
        sstep("sig: Nightmare", function()
            local d, opt, hint = diffState()
            check(d == 0 and opt == "Nightmare" and hint == "100", "SIGDIFF Nightmare by real clicks: Diffculty %s, shown %s, Enemy Damage hint %s (want 0, Nightmare, 100)", tostring(d), tostring(opt), tostring(hint))
        end)
        typeRow("enemyDamage", "25")
        typeRow("spread", "20")
        typeRow("dmg.stalker", "200")
        -- Story 12: Tokens per Classified and Max Classified Tokens, restored after the restart (SIGROWS in launch 2).
        typeRow("classifiedTokens", "2")
        typeRow("classifiedTokensMax", "3")
        -- Two drags to the slider's start (Cold Exposure 0, Frostbite Damage 0) and one to a value (Tokens 8).
        for _, key in ipairs({ "cold", "frostbite" }) do
            dragRow(key, "min")
            sstep("sig: dragged " .. key, function()
                local val, box = sstate(key)
                check(box == "0" and near(val, 0), "SIGDRAG %s dragged to the start: box '%s' bar %s (want 0)", key, tostring(box), fmtv(val))
            end)
        end
        dragRow("revives", 8)
        sstep("sig: dragged revives", function()
            local val, box = sstate("revives")
            local okD = box == "8" and near(val, 8)
            say("SIGDRAG revives dragged to 8: box '%s' bar %s%s", tostring(box), fmtv(val), okD and "" or " (typed next)")
            G.fixRevives = not okD
        end)
        typeRow("revives", "8", function() return G.fixRevives end)
        rowsCheck("before the save")
        shot("signal-rows")
        sstep("sig: save", function()
            drive("save " .. SIG, function(cs)
                local before = #presetNames(cs)
                local okN = pcall(function() cs.PresetName = SIG end)
                if not okN or str(cs.PresetName) ~= SIG then cs[H_TEXT](cs, FText(SIG)) say("NAME set through the text-changed handler") end
                cs[H_SAVE](cs)
                if #presetNames(cs) ~= before + 1 then error("the game's preset count didn't grow") end
            end)
            return after(1.5), 4
        end)
        sstep("sig: saved", function()
            local cs = screen()
            local found = false
            for _, n in ipairs(cs and presetNames(cs) or {}) do if n == SIG then found = true end end
            check(found, "SIGSAVED %s is in the game's presets", SIG)
        end)
        confirmBack("signal")
    else
        -- signal-b: the preset saved by launch 1, after a restart.
        configure("signal")
        sstep("sig: select", function()
            local cs = screen()
            local pos
            for i, n in ipairs(cs and presetNames(cs) or {}) do if n == SIG then pos = i end end
            if not check(pos ~= nil, "SIGFOUND %s is in the game's presets after the restart (presets across a restart)", SIG) then Z.abort = true return end
            drive("select " .. SIG, function(c) selectAt(c, pos, SIG) end)
            return after(1.5), 4
        end)
        rowsCheck("after the select")
        shot("signal-select")
        -- Before hosting (test only, logged): Tower Island (the MapType save slot the screen's own map buttons write),
        -- a friends-only session, no lobby countdown, no White Outs. Never clicks Create unless FriendsOnly reads true.
        sstep("sig: host settings", function()
            local cs = screen()
            if not cs then Z.abort = true S.notShown = S.notShown + 1 say("NOTSHOWN signal: no create-world screen") return end
            local okF = pcall(function() cs.FriendsOnly = true end)
            local fo = try(function() return cs.FriendsOnly end)
            local okL = pcall(function() cs["Lobby Minutes"] = 0 end)
            local okW = false
            for _, gi in ipairs(FindAllOf("BP_GameInstance_C") or {}) do
                if notDefault(gi) then okW = pcall(function() gi.DisableWhiteOuts = true end) end
            end
            local okM, typ = pcall(function()
                local gs = GS()
                local sg = gs:LoadGameFromSlot("MapType", 0)
                if not valid(sg) then
                    local cls = loadClass(MAPSAVE)
                    sg = gs:CreateSaveGameObject(cls)
                end
                local was = num(sg.Type)
                if was ~= 2 then sg.Type = 2 gs:SaveGameToSlot(sg, "MapType", 0) end
                return was
            end)
            say("SIGHOST FriendsOnly=%s (set %s) LobbyMinutes=0 set=%s DisableWhiteOuts set=%s MapType was %s -> 2 ok=%s (test only)",
                tostring(fo), tostring(okF), tostring(okL), tostring(okW), tostring(typ), tostring(okM))
            if not check(fo == true, "SIGFRIENDS the screen's FriendsOnly reads true before Create (a friends-only lobby)") then Z.abort = true end
            -- A Blueprint function's UE4SS hook runs its first callback after the body (the second one never runs).
            hook("/Game/FirstPerson/Blueprints/BP_GameInstance.BP_GameInstance_C:CreateSteamSession", function(_, _, advertise, _, lan, friendsOnly)
                -- get() turns false into nil; these are booleans, read as they are.
                local function b(prm) local ok, v = pcall(function() return prm:get() end) if ok then return v end return nil end
                local a, l, f = b(advertise), b(lan), b(friendsOnly)
                G.sessionAt = os.clock()
                say("SIGSESSION advertise=%s lan=%s friendsOnly=%s", tostring(a), tostring(l), tostring(f))
                check(a == false and f == true, "SIGSESSION CreateSteamSession friends-only (advertise=%s friendsOnly=%s)", tostring(a), tostring(f))
            end)
            return after(1), 3
        end)
        click("CONFIRM signal", function() return prop(screen(), "Create_3") end)
        -- The screen's own Create button, a real click; the handler only if no session started within 15 s.
        reqIf("Create", function() return G.sessionAt == nil end, function()
            local x, y = pointOf(prop(screen(), "Create"), 0.5, 0.5)
            if x then return string.format("click %d %d", x, y) end
        end, 1)
        sstep("sig: session", function()
            local t0 = os.clock()
            return function()
                if G.sessionAt then say("SIGCREATE via=click") return true end
                if os.clock() - t0 < 15 then return false end
                if not screen() then -- the click took the screen away (the travel began): no handler call
                    say("SIGCREATE the screen is gone 15 s after the click, but no CreateSteamSession seen")
                    return true
                end
                local fo = try(function() return screen().FriendsOnly end)
                if fo ~= true then check(false, "SIGCREATE no session after the click, and FriendsOnly no longer reads true: not hosting") Z.abort = true return true end
                say("SIGCREATE no session 15 s after the click; the Create handler instead")
                drive("Create (handler)", function(cs) cs[H_CREATE](cs) end)
                return true
            end, 25, "the session after Create"
        end)
        sstep("sig: session started", function()
            return function() return G.sessionAt ~= nil end, 30, "CreateSteamSession"
        end)
        -- The match part, skipped when hosting was refused or failed (Z.abort: a FAIL or NOTSHOWN is already logged).
        for _, s in ipairs(tail) do
            local fn = s.fn
            steps[#steps + 1] = { name = s.name, fn = function() if Z.abort then return end return fn() end }
        end
        -- Back to the menu, DT8-SIGNAL deleted on the screen (opened without the menu's buttons, as story 6 does).
        step("sig: back to the menu", function()
            say("SIGBACK OpenLevel NewMainMenu")
            pcall(function() GS():OpenLevel(pc(), FName("NewMainMenu"), true, "") end)
            return function() return worldName():find("NewMainMenu", 1, true) ~= nil end, 120, "menu world after the match"
        end)
        step("sig: menu settle", function() return after(12), 15 end)
        step("sig: open for cleanup", function()
            local p = pc()
            local cls = loadClass(CS_CLASS)
            local ok, err = pcall(function()
                local w = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(p, cls, p)
                if not valid(w) then error("WidgetBlueprintLibrary:Create returned no widget") end
                w:AddToViewport(0)
            end)
            say("SIGCLEAN open ok=%s %s", tostring(ok), ok and "" or tostring(err))
            return after(3), 5
        end)
        step("sig: delete " .. SIG, function()
            local cs = screen()
            local n = 0
            if cs then
                for _ = 1, 20 do
                    local left
                    for _, nm in ipairs(presetNames(cs)) do if nm:sub(1, #SIGPREFIX) == SIGPREFIX then left = nm break end end
                    if not left or not pcall(deletePreset, cs, left) then break end
                    n = n + 1
                end
            end
            local still = false
            for _, nm in ipairs(cs and presetNames(cs) or {}) do if nm:sub(1, #SIGPREFIX) == SIGPREFIX then still = true end end
            say("CLEANUP deleted %d %s preset(s) at the end", n, SIGPREFIX)
            -- Soft (check.ps1 "?OK SIGCLEAN"): a leftover goes at the next launch 1, so it never fails the run.
            say("%s SIGCLEAN no %s preset left (deleted %d)", (cs ~= nil and not still) and "OK" or "WARN", SIGPREFIX, n)
            if cs then pcall(function() cs:RemoveFromParent() end) end
            return after(1), 3
        end)
    end
    end
end

-- ---------------------------------------------------------------- runner (game thread, every 250 ms)
local idx, waiting, busy, finished = 0, nil, false, false
local function finish()
    finished = true
    local result = (S.failures > 0 or S.dead) and "FAIL" or (S.notShown > 0 and "NOTSHOWN") or (S.checks == 0 and "FAIL" or "PASS")
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
