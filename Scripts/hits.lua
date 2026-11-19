-- Difficulty: the host's match state and every gameplay hook (spec-difficulty-v1 stories 3 and 4; knob-mechanics.md).
-- Story 3: enemy damage on the host and survivable grabs for the host's own player (attribution, Health
-- compensation, the grab flip and its restore, the guards against other mods; the math is damage.lua's). Story 4:
-- frostbite in the CallFrostbiteDamageEvent pre-hook (V8.2's native), cold in the host poll (env.lua), reinforcement
-- tokens at the match start, in the radio's server-event callbacks and in the poll (tokens.lua); story 12 adds the
-- classified bonus (tokens.classified) in the game state's UpdateClassifieds callback and the poll. Story 5: survivable
-- grabs on modded clients. The host publishes the grab inputs through core.net at the match start (net.lua) and spares
-- a client victim only when core's presence says its machine runs a compatible Difficulty; a modded client flips only
-- its own player's grab from the host's values (HasPerk(0x27) for the five AI grabs, the BeginStalkerPresentation
-- pre-hook for the Stalker); every machine runs the 6 s recovery for its own player after an execution began.
--
-- Rules every hook body follows (spec "Always"):
--   * it runs under pcall; a failure logs one ERROR and turns every knob off for the match (a pending temporary
--     Health is still restored);
--   * it returns unless this machine hosts the current world, the match started in it (UpdateFriendlyFire ran), the
--     mod hasn't backed off this match, and a knob the hit or grab depends on isn't Default (all Default: no write).
--     The exceptions run on a modded client for its own player only: the grab flip (only from the host's published
--     values, once they have arrived), its restore, and the recovery (which also runs after a back-off);
--   * GameState.Diffculty is read live at each hit and grab, never written;
--   * no UObject is kept between callbacks: victims and attackers are kept as paths and found again;
--   * nothing runs per frame: one 250 ms game-thread poll (cold, token re-check; no work while those knobs are
--     Default) and a grab's next-tick restore fallback.
local damage = require("damage")
local knobs = require("knobs")
local env = require("env")
local tokens = require("tokens")
local net = require("net")
local M = {}

local CTX_CDO = "/Script/NuclearNightmare.Default__NNEnemyAttackContext"
local DOG_CDO = "/Script/NuclearNightmare.Default__NNInfectedDogSupport"
local GS_CDO = "/Script/Engine.Default__GameplayStatics"
local FPC = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
local GAMESTATE = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C"
local RADIO = "/Game/Gameplay/ClassifiedMaterials/BP_Radio.BP_Radio_C"
local FP_SHORT = "BP_FirstPersonCharacter_C"
local WATCHER = "EyeMonster_AI_C"
M.RADIO = RADIO
-- The radio's server events: each adds 1 to TimesUsedReinforcements on the host (the callback runs after the body).
M.RADIO_EVENTS = { "ReinforceSpecficPlayer", "SpawnReinforcementMethod2", "SpawnReinforcmentSpectator" }

M.GRAB_WINDOW = 8     -- s: hits on a victim this long after its grab decision belong to that grab (Stalker 4.9 s)
M.BAT_RANGE = 300     -- cm: a phase-3 bat this close to the victim made the hit
M.STALKER_RANGE = 1000 -- cm: the nearest Stalker this close is the grab's attacker when nothing names it
M.TOLERANCE = 0.01    -- HP: the guards' tolerance
M.RESTORE_DELAY = 10  -- ms: the next-tick restore fallback
M.CLIENT_RANGE = 1000 -- cm: on a client, the nearest grab-class AI this close is the grab's attacker when nothing names it
M.RECOVER_DELAY = 6000 -- ms: the recovery check after an execution began on this machine's own player

-- The Stalker's presentation (native, first call in PlayDamageEvent's body on every machine, before its Health
-- test): a modded client's hook point for its own Stalker grab (the Stalker's HasPerk(0x27) runs on the host only).
M.PRESENT = "/Script/NuclearNightmare.NNEnemyAttackContext:BeginStalkerPresentation"

-- Native hooks (registered at ready; their classes are always loaded).
M.NATIVES = {
    locked = "/Script/NuclearNightmare.NNEnemyAttackContext:ApplyLockedDamage",
    stalker = "/Script/NuclearNightmare.NNEnemyAttackContext:ApplyStalkerDamage",
    boss = "/Script/NuclearNightmare.NNBossAttackRecovery:CommitLethalDamage",
    cde = "/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent",
    frost = "/Script/NuclearNightmare.NuclearNightmareCharacter:CallFrostbiteDamageEvent",
}

-- Attacker class (short name) -> row (knobs.ROWS).
M.CLASS_ROW = {
    SCP_AI_C = "meek", Mimic_AI_C = "mimic", MadPatent_AI_C = "psycho", FastLearner_AI_C = "husk",
    EyeMonster_AI_C = "watcher", Stalker_AI_C = "stalker", SlugQueen_AI_C = "slugQueen", ApexPredatorAI_C = "apex",
    Worm_AI_C = "worm", BabyWorm_AI_C = "leech", BP_BatEnemy_C = "bat", Dog_Infected_AI_C = "infectedDog",
}
-- The five AI grabs (the Stalker's is the character's own): class short name, class path, multicast, victim param.
M.GRABS = {
    { short = "SCP_AI_C", class = "/Game/AI/SCP_AI.SCP_AI_C", fn = "Attack", victim = 2 },
    { short = "Mimic_AI_C", class = "/Game/AI/Mimic_AI.Mimic_AI_C", fn = "AttackMulti", victim = 2 },
    { short = "MadPatent_AI_C", class = "/Game/AI/MadPatent_AI.MadPatent_AI_C", fn = "AttackMulti", victim = 2 },
    { short = "FastLearner_AI_C", class = "/Game/AI/FastLearner_AI.FastLearner_AI_C", fn = "AttackAll", victim = 2 },
    { short = "EyeMonster_AI_C", class = "/Game/AI/EyeMonster_AI.EyeMonster_AI_C", fn = "AttackMulti", victim = 2 },
}
-- The Leech, Infected Player, Playable Monster and Worm hit through Blueprint wrappers whose UE4SS callback runs
-- after the body (too late to name the hit): their hits stay stock in v1 (spec decision, 2026-11-03).

-- ---------------------------------------------------------------- small helpers (every UObject access guarded)
local function num(v) if type(v) == "number" then return v end return tonumber(tostring(v)) end
local function get(p)
    if p == nil then return nil end
    local ok, v = pcall(function() return p:get() end)
    if ok then return v end
    return nil
end
local function exists(o)
    if o == nil or (type(o) ~= "userdata" and type(o) ~= "table") then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function pathOf(o)
    local ok, r = pcall(function() return (o:GetFullName():gsub("^%S+ ", "")) end)
    if ok and type(r) == "string" and r ~= "" then return r end
    return nil
end
local function classOf(o)
    local ok, r = pcall(function() return o:GetClass():GetFName():ToString() end)
    if ok then return r end
    return nil
end
local function hpOf(o)
    local ok, h = pcall(function() return o.Health end)
    if ok then return num(h) end
    return nil
end
local function setHp(o, v) return pcall(function() o.Health = v end) end
local function cdo(path)
    local o = StaticFindObject(path)
    if exists(o) then return o end
    return nil
end
local function dist(a, b)
    local ok, d = pcall(function()
        local x, y = a:K2_GetActorLocation(), b:K2_GetActorLocation()
        return math.sqrt((x.X - y.X) ^ 2 + (x.Y - y.Y) ^ 2 + (x.Z - y.Z) ^ 2)
    end)
    if ok then return d end
    return nil
end
local F = damage.fmt

-- ---------------------------------------------------------------- the adapter
local A = {}
A.__index = A

-- new(opts): opts.say(level, fmt, ...), opts.warnOnce(key, fmt, ...), opts.isHost() -> bool (this machine hosts the
-- current world), opts.world() -> the current world's name, opts.knobs() -> the knob text (dev.lua), opts.alive(obj)
-- (the KismetSystemLibrary:IsValid UFunction), opts.clock() (s), opts.rng() ([0, 1)), opts.seed(n), opts.micros()
-- (core's microsecond clock, optional: the poll's cost; os.clock otherwise), opts.ref / deref / free (core's weak
-- handles, optional: the match's game state for the poll; without them the poll falls back to a FindAllOf).
-- Story 5: opts.net (core.net), opts.modId (Difficulty's own mod.json id), opts.version (VERSION), opts.netCompat
-- (mod.json's netCompat, nil: core's default), opts.netMissing (the first core feature missing, nil when all are
-- there: then the host spares only its own player and a client stays inactive).
function M.new(opts)
    local self = setmetatable({ o = opts, hooks = {}, bpHooks = {}, queued = {}, st = nil, installFailed = true }, A) -- until install() hooks the natives
    self.recover = { seq = 0 } -- grabs begun on this machine's own player (the recovery's "no other grab since")
    self.clock = opts.clock or os.clock
    self.micros = opts.micros
    self.rng = opts.rng or math.random
    self.seed = opts.seed or function(n) math.randomseed(n) end
    self:reset(nil)
    return self
end

-- reset(world): a new match state (a fresh world or a new match). Pending restores survive it: a temporary Health is
-- always put back.
function A:reset(world)
    local old = self.st
    if old and self.o.free then
        if old.gsRef ~= nil then pcall(self.o.free, old.gsRef) end
        for _, e in ipairs(old.charRefs or {}) do pcall(self.o.free, e.h) end
    end
    self.st = {
        world = world, started = false, backedOff = false, values = {},
        grabs = {},     -- victim path -> { kind, attacker, row, at }
        boss = {},      -- stack of { row, via } (CommitLethalDamage)
        apply = {},     -- stack of plans (or false) for ApplyLockedDamage / ApplyStalkerDamage
        cde = {},       -- stack of plans (or false) for CallDamageEvent
        frost = {},     -- stack of plans (or false) for CallFrostbiteDamageEvent; its length is the nesting depth
        pending = old and old.pending or {}, -- victim path -> { saved, temp, label }
        cold = env.newPoll{ say = self.o.say, clock = function() return self.clock() end, -- per-path state, per match
                            micros = function() if self.micros then return self.micros() end return nil end },
        tok = nil,      -- the token state (tokens.start); nil while the knob does nothing
        gsRef = nil,    -- core's weak handle on this match's game state (onStart), never the object
        charRefs = nil, -- the characters between discoveries: { h = weak handle, path } (nil: discover next poll)
        sinceDiscovery = 0,
        isFP = {},      -- pawn path -> true when it is a BP_FirstPersonCharacter_C (the class check once per path)
        client = false, -- story 5: this world is a client's (onWorld)
        inactiveSaid = false, -- the client's inactive line, at most once per world
        oobSaid = {},   -- net key -> true: its out-of-bounds line was logged this match
        published = false, -- the host published every grab input this match (publish); clients may be spared
    }
end

-- The host gate: this machine hosts the current world and the match started in it.
function A:active()
    local st = self.st
    return not self.installFailed and st.started and not st.backedOff and st.world ~= nil and st.world == self.o.world() and self.o.isHost() == true
end

-- The client grab gate (story 5): this machine is a client in the current world, the mod hasn't backed off. Whether
-- the host's values are usable is decided at each grab (clientGrab).
function A:clientActive()
    local st = self.st
    return not self.installFailed and st.client == true and not st.backedOff and st.world ~= nil and st.world == self.o.world() and self.o.isHost() ~= true
end

M.OFF = "; every knob off until the next match"

-- releaseTokens(): at a back-off, the token count goes back to stock once (tokens.release) and the token state is
-- dropped; a failure here is only logged (the back-off already happened).
function A:releaseTokens()
    local t = self.st.tok
    if not t then return end
    self.st.tok = nil
    local ok, err = pcall(function()
        local gs = self:pollGameState(true)
        if gs then tokens.release(t, gs, self.o) else self.o.say("info", "TOKENS released at back-off used=? (no game state; left as it is)") end
    end)
    if not ok then self.o.say("debug", "TOKENS release at back-off failed: %s", tostring(err)) end
end

-- backOff(level, fmt, ...): one line, then no knob acts until the next match (damage, grabs, frostbite, cold; the
-- token count goes back to stock; any other value already written stays).
function A:backOff(level, fmt, ...)
    if self.st.backedOff then return end
    self.st.backedOff = true
    self.o.say(level, fmt .. M.OFF, ...)
    self:releaseTokens()
    self:retract()
end

-- retract(): at the host's first back-off in a match where it published, modded clients must stop flipping too (the
-- host now keeps the game's decision). core.net has no unpublish, so compat is republished as VER_MAX: a netCompat above
-- any version, which every client's versionsCompatible rejects (inactive, reason incompatible). Under pcall.
function A:retract()
    local st, o = self.st, self.o
    if not st.published then return end
    st.published = false
    local ok, r, why = pcall(o.net.publish, o.modId .. ".compat", net.VER_MAX)
    if ok and r == true then o.say("info", "NET compat=%d republished at the back-off: modded clients stop flipping", net.VER_MAX)
    else o.say("warn", "NET could not withdraw the published values at the back-off (%s); modded clients may still flip", tostring(ok and why or r)) end
end

-- guard(label, fn): fn under pcall; a failure logs one ERROR and backs off.
function A:guard(label, fn)
    return function(...)
        local ok, err = pcall(fn, self, ...)
        if not ok then
            local first = not self.st.backedOff
            self.st.backedOff = true
            if first then self.o.say("error", "%s failed: %s" .. M.OFF, label, tostring(err)) self:releaseTokens() self:retract()
            else self.o.say("debug", "%s failed again: %s", label, tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------- reading the game
function A:alive(o) return exists(o) and self.o.alive(o) == true end

-- gameState(ctx) -> the live game state (GetGameState from ctx, else the first live one), or nil.
function A:gameState(ctx)
    local gs
    local g = cdo(GS_CDO)
    if g and ctx ~= nil then pcall(function() gs = g:GetGameState(ctx) end) end
    if not exists(gs) then
        gs = nil
        for _, s in ipairs(FindAllOf("BP_FirstPersonGameState_C") or {}) do
            local p = pathOf(s)
            if p and not p:find("Default__", 1, true) and self:alive(s) then gs = s break end
        end
    end
    return gs
end

-- difficulty(ctx, gs) -> EDiffculty 0..3 read live from the game state (gs, or the one found from ctx), or nil.
function A:difficulty(ctx, gs)
    gs = gs or self:gameState(ctx)
    if not exists(gs) then return nil end
    local ok, d = pcall(function() return gs.Diffculty end)
    d = ok and num(d) or nil
    if not damage.standard(d) then
        self.o.warnOnce("diff" .. tostring(d), "GameState.Diffculty reads %s, not 0..3; hits and grabs stay stock", tostring(d))
        return nil
    end
    return d
end

-- The local player's pawn path (the host's own player).
function A:myPath(ctx)
    local g = cdo(GS_CDO)
    local p
    if g then pcall(function() p = g:GetPlayerController(ctx, 0):K2_GetPawn() end) end
    if exists(p) then return pathOf(p) end
    return nil
end

function A:rowOf(o) return M.CLASS_ROW[classOf(o) or ""] end

-- The grab's attacker for victim v at HasPerk(0x27) (a Watcher grab grabVictim redirected arrives with its attacker
-- and never comes here): the AI whose locked victim is v, else the Stalker presenting v, else a Watcher whose chase
-- Target is v (story 11: the Watcher calls HasPerk(0x27) on its Target; after the guard, the Stalker's own grab next to
-- a Watcher chasing v is the Stalker's), else the nearest live Stalker. Returns path, row, short class, the attacker
-- object (for this callback only; any may be nil).
-- client (story 5): HasPerk(0x27) on a client is always one of the five AI grabs, and GetLockedVictim may not be set
-- there, so the fallback is the nearest of those AI within CLIENT_RANGE; the client returns before the Watcher-by-Target
-- fallback (story 11 guard), so another enemy's grab next to a Watcher chasing v keeps its own row; nothing found: no
-- row (enemy % 100).
function A:grabAttacker(v, vpath, client)
    local ctx = cdo(CTX_CDO)
    local best, bestD, bestShort, bestObj
    local watcher
    for _, g in ipairs(M.GRABS) do
        for _, a in ipairs(FindAllOf(g.short) or {}) do
            local ap = pathOf(a)
            if ap and not ap:find("Default__", 1, true) and self:alive(a) then
                local lv
                if ctx then pcall(function() lv = ctx:GetLockedVictim(a) end) end
                if exists(lv) and pathOf(lv) == vpath then return ap, M.CLASS_ROW[g.short], g.short, a end
                if g.short == WATCHER and not watcher then
                    local t
                    pcall(function() t = a.Target end)
                    if exists(t) and pathOf(t) == vpath then watcher = { ap, a } end
                end
                if client then
                    local d = dist(a, v)
                    if d and d <= M.CLIENT_RANGE and (not bestD or d < bestD) then best, bestD, bestShort, bestObj = ap, d, g.short, a end
                end
            end
        end
    end
    if client then
        if best then return best, M.CLASS_ROW[bestShort], bestShort, bestObj end
        return nil, nil, nil, nil
    end
    local src
    if ctx then pcall(function() src = ctx:GetStalkerPresentationSource(v) end) end
    if exists(src) and self:alive(src) then return pathOf(src), self:rowOf(src), classOf(src), src end
    if watcher then return watcher[1], M.CLASS_ROW[WATCHER], WATCHER, watcher[2] end
    local best, bestD, bestObj
    for _, s in ipairs(FindAllOf("Stalker_AI_C") or {}) do
        local sp = pathOf(s)
        if sp and not sp:find("Default__", 1, true) and self:alive(s) then
            local d = dist(s, v)
            if d and d <= M.STALKER_RANGE and (not bestD or d < bestD) then best, bestD, bestObj = sp, d, s end
        end
    end
    if best then return best, "stalker", "Stalker_AI_C", bestObj end
    return nil, nil, nil, nil
end

-- enemyText(row, short, v) -> the GRAB line's enemy field and, when the attacker isn't known, the reason (story 11:
-- never "enemy=?"). unknown(<class>): the nearest of the five AI grab classes within CLIENT_RANGE of v (none: "none";
-- a Stalker that close was already named by grabAttacker).
function A:enemyText(row, short, v)
    if row then return row, nil end
    if short then return "unknown(" .. short .. ")", "no-row" end
    local near, nearD
    for _, g in ipairs(M.GRABS) do
        local sh = g.short
        for _, a in ipairs(FindAllOf(sh) or {}) do
            local ap = pathOf(a)
            if ap and not ap:find("Default__", 1, true) and self:alive(a) then
                local d = dist(a, v)
                if d and d <= M.CLIENT_RANGE and (not nearD or d < nearD) then near, nearD = sh, d end
            end
        end
    end
    if near then return "unknown(" .. near .. ")", "no-locked-victim" end
    return "unknown(none)", "no-grab-ai-near"
end

-- whoIs(o, myp) -> "local" (this machine's own player), "client" (another player character) or "none".
function A:whoIs(o, myp)
    if not exists(o) then return "none" end
    local p = pathOf(o)
    if not p then return "none" end
    if myp and p == myp then return "local" end
    if classOf(o) == FP_SHORT then return "client" end
    return "none"
end

-- watcherLine(attacker, myp): a Watcher grab's Target and AttackedPlayer, read from that Watcher at decision time
-- (story 11). Its own line right after the GRAB line, so the GRAB line keeps the format the pair checks match.
function A:watcherLine(attacker, short, myp)
    if short ~= WATCHER or attacker == nil then return end
    local t, ap
    pcall(function() t = attacker.Target end)
    pcall(function() ap = attacker.AttackedPlayer end)
    self.o.say("info", "WATCHER target=%s attacked=%s", self:whoIs(t, myp), self:whoIs(ap, myp))
end

-- Bat and Infected Dog rules for a CallDamageEvent with no context (knob-mechanics.md enemy table).
function A:nativeAttacker(v, vpath)
    for _, b in ipairs(FindAllOf("BP_BatEnemy_C") or {}) do
        local bp = pathOf(b)
        if bp and not bp:find("Default__", 1, true) and self:alive(b) then
            local d = dist(b, v)
            local okP, phase = pcall(function() return b:GetBatPhase() end)
            if d and d <= M.BAT_RANGE and okP and num(phase) == 3 then return "bat", "bat" end
        end
    end
    local sup = cdo(DOG_CDO)
    if sup then
        for _, d in ipairs(FindAllOf("Dog_Infected_AI_C") or {}) do
            local dp = pathOf(d)
            if dp and not dp:find("Default__", 1, true) and self:alive(d) then
                local okA, act = pcall(function() return sup:IsAttackActive(d) end)
                local okV, tv = pcall(function() return sup:GetAttackVictim(d) end)
                if okA and act == true and okV and exists(tv) and pathOf(tv) == vpath then return "infectedDog", "dog" end
            end
        end
    end
    return nil, nil
end

-- The grab decision recorded for victim vpath, if this hit belongs to it (attacker matches when both are known).
-- Different attacker paths with the same row still count (the grab's Stalker may come from the nearest-Stalker
-- fallback, the hit's from the presentation source).
function A:grabKind(vpath, apath, row)
    local g = self.st.grabs[vpath]
    if not g then return "hit" end
    if self.clock() - g.at > M.GRAB_WINDOW then self.st.grabs[vpath] = nil return "hit" end
    if g.attacker and apath and g.attacker ~= apath and not (row ~= nil and g.row == row) then return "hit" end
    return g.kind
end

-- ---------------------------------------------------------------- one hit
-- plan(v, stock, row, via, apath, inGrab, kind) -> a plan (Health compensated) or false (left alone). kind (story 14):
-- the hit's kind when the caller knows it (a ticked boss's finisher: "execution"); nil: the grab's, or "hit".
function A:plan(v, stock, row, via, apath, inGrab, kind)
    local values = self.st.values
    if not damage.acts(values, row) then return false end
    if not self:alive(v) then return false end
    local vpath = pathOf(v)
    local n = num(stock)
    if not vpath or not n or n <= 0 then return false end
    -- A grab's temporary Health still in place: put it back before planning from it.
    if self.st.pending[vpath] then self:restore(vpath, "hit") end
    local hp = hpOf(v)
    if not hp then return false end
    local d = self:difficulty(v)
    if not d then return false end
    kind = kind or (inGrab and self:grabKind(vpath, apath, row)) or "hit"
    local p = damage.hit(n, values, d, row, kind, hp, self.rng)
    if not p then return false end
    if not setHp(v, p.new) then error("could not write Health on " .. vpath) end
    p.path, p.before, p.kind, p.row, p.via = vpath, hp, kind, row, via
    self.o.say("info", "HIT enemy=%s via=%s stock=%s scaled=%s rolled=%s applied=%s hp=%s kind=%s", row or "?", via,
        F(p.stock), F(p.scaled), F(p.rolled), F(p.applied), F(hp), kind)
    return p
end

-- check(p, how): the guard after the native. Health must read planned (+- TOLERANCE). If it still reads the
-- compensated value, the native applied nothing: the compensation is undone. Anything else is a clash.
function A:check(p)
    if not p then return end
    local v = StaticFindObject(p.path)
    if not exists(v) then return end
    local hp = hpOf(v)
    if not hp then return end
    if math.abs(hp - p.planned) <= M.TOLERANCE then return end
    if math.abs(hp - p.new) <= M.TOLERANCE and math.abs(p.new - p.planned) > M.TOLERANCE then
        setHp(v, p.before)
        self.o.say("debug", "HIT via=%s: the native applied nothing; Health back to %s", p.via, F(p.before))
        return
    end
    self:backOff("warn", "clash: after the hit enemy=%s via=%s Health is %s, planned %s (another mod changed it)",
        p.row or "?", p.via, F(hp), F(p.planned))
end

-- ---------------------------------------------------------------- hook bodies
function A:onLocked(_, attacker, amount)
    local st = self.st
    local slot = #st.apply + 1
    st.apply[slot] = false
    if not self:active() then return end
    local a = get(attacker)
    if not self:alive(a) then return end
    local ctx = cdo(CTX_CDO)
    local v
    if ctx then pcall(function() v = ctx:GetLockedVictim(a) end) end
    st.apply[slot] = self:plan(v, get(amount), self:rowOf(a), "ApplyLockedDamage", pathOf(a), true)
end
function A:onStalker(_, victim, amount)
    local st = self.st
    local slot = #st.apply + 1
    st.apply[slot] = false
    if not self:active() then return end
    local v = get(victim)
    if not self:alive(v) then return end
    local ctx = cdo(CTX_CDO)
    local src
    if ctx then pcall(function() src = ctx:GetStalkerPresentationSource(v) end) end
    local row, ap
    if exists(src) then row, ap = self:rowOf(src), pathOf(src) end
    st.apply[slot] = self:plan(v, get(amount), row, "ApplyStalkerDamage", ap, true)
end
function A:onApplyPost()
    local p = table.remove(self.st.apply)
    if p and p.delivered then self:check(p)
    elseif p then
        -- The native never called CallDamageEvent: undo the compensation (Health still holds it).
        local v = StaticFindObject(p.path)
        if exists(v) and math.abs((hpOf(v) or -1e9) - p.new) <= M.TOLERANCE then setHp(v, p.before) end
        self.o.say("debug", "HIT via=%s: no CallDamageEvent inside; compensation undone", p.via)
    end
end

function A:onBoss(_, boss)
    local b = get(boss)
    local row = self:alive(b) and self:rowOf(b) or nil
    self.st.boss[#self.st.boss + 1] = { row = row, path = b and pathOf(b) }
end
function A:onBossPost() table.remove(self.st.boss) end

function A:onCde(selfp, amount)
    local st = self.st
    local slot = #st.cde + 1
    st.cde[slot] = false
    -- Inside CallFrostbiteDamageEvent (if the native forwards through the reflected function): that hook planned it.
    if #st.frost > 0 then return end
    -- Inside ApplyLockedDamage / ApplyStalkerDamage: that hook planned the hit already (depth counter).
    if #st.apply > 0 then
        local outer = st.apply[#st.apply]
        if outer then outer.delivered = true end
        return
    end
    if not self:active() then return end
    local v = get(selfp)
    local n = num(get(amount))
    if not n or n <= 0 or not self:alive(v) then return end
    local vpath = pathOf(v)
    local row, via, apath, kind
    local b = st.boss[#st.boss]
    if b then
        row, via, apath = b.row, "CommitLethalDamage", b.path
        -- Story 14: a ticked boss's finisher kills (step 4: at least Health); unticked it stays an ordinary hit.
        if damage.kill(st.values, row) then kind = "execution" end
    else
        row, via = self:nativeAttacker(v, vpath)
        if not row then return end -- environmental, unknown or a Blueprint-wrapper enemy: never touched
    end
    local p = self:plan(v, n, row, via, apath, false, kind)
    if p then p.delivered = true end
    st.cde[slot] = p
end
function A:onCdePost()
    local p = table.remove(self.st.cde)
    if p then self:check(p) end
end

-- frost(v, vpath, n) -> a plan for CallFrostbiteDamageEvent(n) (Health compensated; onFrostPost's guard checks it like
-- any hit) or false. The function itself says it is frostbite: amount 1 or 2 is a tick; 100 at Frostbite 0 and
-- 0 < Health < 1 is the finisher, absorbed; anything else stays stock.
function A:frost(v, vpath, n)
    local chosen = self.st.values.frostbite
    if chosen == nil or not vpath then return false end
    local tick = env.isFrostbite(n)
    if not tick and not (n == env.FINISHER and chosen == 0) then return false end
    -- A grab's temporary Health still in place: put it back before planning from it.
    if self.st.pending[vpath] then self:restore(vpath, "hit") end
    local hp = hpOf(v)
    if not hp then return false end
    if not tick and not env.isFinisher(n, hp, chosen) then return false end
    local p = env.frostbite(hp, n, chosen)
    if not p then return false end
    if not setHp(v, p.new) then error("could not write Health on " .. vpath) end
    local via = tick and "frostbite" or "frostbite-finisher"
    p.path, p.before, p.kind, p.row, p.via = vpath, hp, "hit", "frostbite", via
    self.o.say("info", "HIT enemy=frostbite via=%s stock=%s scaled=%s rolled=%s applied=%s hp=%s kind=hit", via,
        F(p.stock), F(p.scaled), F(p.rolled), F(p.applied), F(hp))
    return p
end

function A:onFrost(selfp, amount)
    local st = self.st
    local slot = #st.frost + 1
    st.frost[slot] = false -- the depth rises even when this call does nothing, so a nested CallDamageEvent is skipped
    if not self:active() then return end
    local v = get(selfp)
    local n = num(get(amount))
    if not n or n <= 0 or not self:alive(v) then return end
    st.frost[slot] = self:frost(v, pathOf(v), n)
end
function A:onFrostPost()
    local p = table.remove(self.st.frost)
    if p then self:check(p) end
end

-- livePlayer(o): a live player character: BP_FirstPersonCharacter_C, alive by the KismetSystemLibrary:IsValid
-- UFunction, and Health > 0 (a dead player's body stays in the world and can still be a stale AttackedPlayer).
function A:livePlayer(o)
    if not (exists(o) and classOf(o) == FP_SHORT and self:alive(o)) then return false end
    local hp = hpOf(o)
    return hp ~= nil and hp > 0
end

-- grabVictim(v, vpath) -> victim, victim path, attacker | nil (story 11). v is HasPerk(0x27)'s self. The Watcher calls
-- HasPerk(0x27) on its chase Target but decides from AttackedPlayer's Health (EyeMonster_AI_C AttackMulti sets
-- AttackedPlayer to the grabbed character first; both are replicated actor state, read on this machine). AttackedPlayer
-- is never cleared, and HasPerk(0x27) is also every other grab's hook point (the four other AI grabs, the host's
-- Stalker), so the redirect applies only when the grab's attacker is that Watcher itself (guard, user 2026-11-18):
--   * a grab-class AI whose locked victim is v: another grab on v is under way, v is the victim;
--   * a candidate is a live Watcher whose Target is v and whose AttackedPlayer is another live player (Health > 0)
--     within CLIENT_RANGE of it; none: v;
--   * the multicast's attacker named: a candidate whose own locked victim is its AttackedPlayer (both of the Watcher's
--     AttackMulti call sites pass GetLockedVictim, so on the host a Watcher grab always names itself this way): that
--     AttackedPlayer is the victim and that Watcher the attacker;
--   * unnamed, on a client only (GetLockedVictim may be unset there): the nearest of the five grab-class AI within
--     CLIENT_RANGE of v; when that is a candidate with no locked victim, the redirect as above;
--   * else v (solo, Target == AttackedPlayer, or another enemy's grab next to a Watcher with a stale AttackedPlayer).
-- On the host an unnamed grab is never redirected: the Stalker's grab (no locked victim) keeps its victim.
-- Every UObject read is under pcall; nothing is kept.
function A:grabVictim(v, vpath)
    local ctx = cdo(CTX_CDO)
    local client = self.o.isHost() ~= true
    local cands = {}
    local near, nearD
    for _, g in ipairs(M.GRABS) do
        for _, a in ipairs(FindAllOf(g.short) or {}) do
            local ap = pathOf(a)
            if ap and not ap:find("Default__", 1, true) and self:alive(a) then
                local lv, lpath
                if ctx then pcall(function() lv = ctx:GetLockedVictim(a) end) end
                if exists(lv) then lpath = pathOf(lv) end
                if lpath == vpath then return v, vpath, nil end
                if g.short == WATCHER then
                    local t, att
                    pcall(function() t = a.Target end)
                    pcall(function() att = a.AttackedPlayer end)
                    if exists(t) and pathOf(t) == vpath and self:livePlayer(att) then
                        local app = pathOf(att)
                        local d = dist(a, att)
                        if app and app ~= vpath and d and d <= M.CLIENT_RANGE then
                            cands[#cands + 1] = { w = a, att = att, app = app, lock = lpath }
                        end
                    end
                end
                local d = dist(a, v)
                if d and d <= M.CLIENT_RANGE and (not nearD or d < nearD) then near, nearD = a, d end
            end
        end
    end
    if #cands == 0 then return v, vpath, nil end
    for _, c in ipairs(cands) do
        if c.lock == c.app then return c.att, c.app, c.w end
    end
    if not client then return v, vpath, nil end
    for _, c in ipairs(cands) do
        if c.lock == nil and near == c.w then return c.att, c.app, c.w end
    end
    return v, vpath, nil
end

-- HasPerk(0x27): the grab decision (knob-mechanics.md "Where to set it"), for the victim grabVictim resolves (the
-- Watcher's HasPerk self is its chase Target, not always the player it grabs).
-- On the host it decides for every victim (hostGrab); on a client only for its own player (clientGrab): when this
-- machine's player is only the Watcher's Target, nothing is written, logged or noted. Any other local grab only feeds
-- the recovery.
function A:onHasPerk(selfp, perk)
    if num(get(perk)) ~= 39 then return end
    if self.installFailed then return end
    local self0 = get(selfp)
    if not self:alive(self0) then return end
    local path0 = pathOf(self0)
    if not path0 then return end
    local v, vpath, attacker = self:grabVictim(self0, path0)
    if not vpath or self.st.pending[vpath] then return end -- our own temporary value (a repeated callback)
    local isLocal = self:myPath(v) == vpath
    if self:active() then return self:hostGrab(v, vpath, isLocal, attacker) end
    if not isLocal then return end -- never a remote player's grab outside the host's match
    if self:clientActive() then return self:clientGrab(v, vpath, attacker) end
    self:noteGrab(v, vpath, nil) -- the host before its match start or after a back-off: the recovery only
end

-- flipFor(v, vpath, hp, g, enemy): the temporary Health for decision g (when it differs from the game's), restored in
-- the grab multicast's hook or on the next tick. Returns the flip text for the GRAB line.
function A:flipFor(v, vpath, hp, g, enemy)
    if not g.flip then return "none" end
    if not setHp(v, g.flip) then error("could not write the temporary Health on " .. vpath) end
    self.st.pending[vpath] = { saved = hp, temp = g.flip, label = "enemy=" .. tostring(enemy) }
    self:later(vpath)
    return F(g.flip)
end

-- spareClient(v) -> true | false, why: the host spares a client victim only when core's presence reports its machine
-- running a Difficulty compatible with the host's (core's netCompat rule), keyed by the victim pawn's own PlayerState.
function A:spareClient(v)
    local o = self.o
    if o.netMissing then return false, "core" end
    if not (o.net and o.modId) then return false, "core" end
    if not self.st.published then return false, "unpublished" end
    local ps
    pcall(function() ps = v.PlayerState end)
    if not exists(ps) or not self:alive(ps) then return false, "no-player-state" end
    local ok, r, why = pcall(o.net.compatible, ps, o.modId)
    if not ok then
        o.warnOnce("compatible:" .. tostring(r), "core.net.compatible failed (%s); that client keeps the game's decision", tostring(r))
        return false, "error"
    end
    if r == true then return true end
    return false, tostring(why or "absent")
end

-- The host's grab on any victim: its own player, or a client spared by presence; anyone else keeps the game's decision.
-- attacker: the Watcher grabVictim redirected the grab from (nil: found by grabAttacker).
function A:hostGrab(v, vpath, isLocal, attacker)
    local apath, row, short, aobj
    if attacker ~= nil and self:alive(attacker) then
        apath, short, aobj = pathOf(attacker), classOf(attacker), attacker
        row = M.CLASS_ROW[short or ""]
    else
        apath, row, short, aobj = self:grabAttacker(v, vpath)
    end
    if short then self:needClassHooks(short) end
    local values = self.st.values
    if not damage.acts(values, row) then
        if isLocal then self:noteGrab(v, vpath, nil) end
        return
    end
    local hp = hpOf(v)
    local d = self:difficulty(v)
    if not hp or not d then
        if isLocal then self:noteGrab(v, vpath, nil) end
        return
    end
    local spare, why = true, nil
    if not isLocal then spare, why = self:spareClient(v) end
    local g = damage.grab(hp, values, d, row, spare)
    if not g then
        if isLocal then self:noteGrab(v, vpath, nil) end
        return
    end
    local enemy, unknown = self:enemyText(row, short, v)
    local flip = self:flipFor(v, vpath, hp, g, enemy)
    self.st.grabs[vpath] = { kind = g.decision == "s" and "survivable" or "execution", attacker = apath, row = row, at = self.clock() }
    self.o.say("info", "GRAB enemy=%s hp=%s E=%s game=%s decision=%s flip=%s victim=%s spare=%s%s%s", enemy, F(hp), F(g.E),
        g.game, g.decision, flip, isLocal and "local" or "client", spare and "yes" or ("no(" .. tostring(why) .. ")"),
        unknown and (" why=" .. unknown) or "", g.kill and " kill=yes" or "")
    self:watcherLine(aobj, short, isLocal and vpath or self:myPath(v))
    if isLocal then self:noteGrab(v, vpath, g.decision) end
end

-- inactive(reason): the client's one line per world when the host's values aren't usable.
function A:inactive(reason)
    if self.st.inactiveSaid then return end
    self.st.inactiveSaid = true
    self.o.say("info", "host has no Difficulty, inactive (%s)", tostring(reason))
end

-- hostValues() -> values | nil: the host's published grab inputs, read now (never cached), checked against this
-- machine's own bounds and version. nil: no change for this grab (the reason is logged: the inactive line once per
-- world, an out-of-bounds key once per match).
function A:hostValues()
    local o, st = self.o, self.st
    if o.netMissing or not (o.net and o.modId) then return nil end -- connect's one line named the missing feature
    local values, a, b = net.decode(function(name, lo, hi) return o.net.read(o.modId .. "." .. name, lo, hi) end)
    if not values then
        if a == "out-of-bounds" then
            if not st.oobSaid[b] then
                st.oobSaid[b] = true
                o.say("warn", "the host's %s is outside this mod's bounds; grabs on this player keep the game's decision while it is", tostring(b))
            end
        else
            self:inactive(a)
        end
        return nil
    end
    local okC, compat = pcall(o.net.versionsCompatible, o.version, o.netCompat, a, b)
    if not okC or compat ~= true then self:inactive("incompatible") return nil end
    return values
end

-- The client's grab on its own player (HasPerk(0x27) of an AI grab, or the Stalker's presentation with its attacker):
-- the host's decision rule from the host's values, flipped and restored like the host's own.
function A:clientGrab(v, vpath, attacker)
    local values = self:hostValues()
    if not values then self:noteGrab(v, vpath, nil) return end
    local apath, row, short, aobj
    if attacker ~= nil and self:alive(attacker) then
        apath, short, aobj = pathOf(attacker), classOf(attacker), attacker
        row = M.CLASS_ROW[short or ""]
    else
        apath, row, short, aobj = self:grabAttacker(v, vpath, true)
    end
    if short then self:needClassHooks(short) end
    local hp = hpOf(v)
    local d = self:difficulty(v)
    if not damage.acts(values, row) or not hp or not d then self:noteGrab(v, vpath, nil) return end
    local g = damage.grab(hp, values, d, row, true)
    if not g then self:noteGrab(v, vpath, nil) return end
    local enemy, unknown = self:enemyText(row, short, v)
    local flip = self:flipFor(v, vpath, hp, g, enemy)
    self.o.say("info", "GRAB enemy=%s hp=%s E=%s game=%s decision=%s flip=%s victim=local spare=yes%s%s", enemy, F(hp), F(g.E),
        g.game, g.decision, flip, unknown and (" why=" .. unknown) or "", g.kill and " kill=yes" or "")
    self:watcherLine(aobj, short, vpath)
    self:noteGrab(v, vpath, g.decision)
end

-- The Stalker's presentation (native pre-hook, before PlayDamageEvent's Health test): a client's own Stalker grab.
-- Nothing on the host, which decides the Stalker at its HasPerk(0x27).
function A:onPresent(_, attacker, victim)
    if self.installFailed or self.o.isHost() == true then return end
    local v = get(victim)
    if not self:alive(v) then return end
    local vpath = pathOf(v)
    if not vpath or self.st.pending[vpath] then return end
    if self:myPath(v) ~= vpath then return end -- never a remote player
    if self:clientActive() then return self:clientGrab(v, vpath, get(attacker)) end
    self:noteGrab(v, vpath, nil)
end

-- ---------------------------------------------------------------- the recovery (every machine, own player only)
-- noteGrab(v, vpath, decision): a grab began on this machine's own player. decision is the one this machine's game
-- test makes ("e" / "s"; nil: the game's own, from Health and the standard hit). After an execution, the check runs
-- RECOVER_DELAY later.
function A:noteGrab(v, vpath, decision)
    local R = self.recover
    R.seq = R.seq + 1
    if decision == nil then
        local hp, s = hpOf(v), damage.standard(self:difficulty(v))
        if hp and s then decision = damage.decide(hp, s) end
    end
    if decision ~= "e" then return end
    local seq, world = R.seq, self.o.world()
    local o = self.o
    -- core's weak handle when there is one (no StaticFindObject miss after the pawn is gone), else the path.
    local h
    if o.ref and o.deref then
        local okR, r = pcall(o.ref, v)
        if okR and r ~= nil then h = r end
    end
    self:delay(M.RECOVER_DELAY, function()
        local ok, err = pcall(self.recoverCheck, self, vpath, seq, world, h)
        if h ~= nil and o.free then pcall(o.free, h) end
        if not ok then o.warnOnce("recover:" .. tostring(err), "recovery check failed: %s", tostring(err)) end
    end, "recovery")
end

-- recoverCheck(vpath, seq, world, h): the player still alive, no newer grab, same world: stop the montage,
-- PlayingMontage = false, walking movement (the game's own enemy-died branch). Runs after a back-off too. h: core's
-- weak handle on the pawn (nil: found again by path).
function A:recoverCheck(vpath, seq, world, h)
    if self.recover.seq ~= seq then return end -- another grab began since
    if world == nil or self.o.world() ~= world then return end
    local v
    if h ~= nil then
        local okD, d = pcall(self.o.deref, h)
        v = okD and d or nil
    else
        v = StaticFindObject(vpath)
    end
    if not exists(v) or not self:alive(v) or pathOf(v) ~= vpath then return end
    local hp = hpOf(v)
    if not hp or hp <= 0 then return end
    local m
    pcall(function() m = v:GetCurrentMontage() end)
    local okS = pcall(function() if exists(m) then v:StopAnimMontage(m) else v:StopAnimMontage() end end)
    local okP = pcall(function() v.PlayingMontage = false end)
    local okM = pcall(function() v.CharacterMovement:SetMovementMode(1, 0) end)
    self.o.say("info", "RECOVER hp=%s montage=%s stop=%s playing=%s movement=%s", F(hp), exists(m) and "yes" or "none",
        tostring(okS), tostring(okP), tostring(okM))
end

-- restore(vpath, how): put the saved Health back, only if Health still holds the temporary value.
function A:restore(vpath, how)
    local p = vpath and self.st.pending[vpath]
    if not p then return end
    self.st.pending[vpath] = nil
    local v = StaticFindObject(vpath)
    if not exists(v) then self.o.say("info", "RESTORE %s: the victim is gone (%s)", p.label, how) return end
    local hp = hpOf(v)
    if hp and math.abs(hp - p.temp) <= M.TOLERANCE then
        setHp(v, p.saved)
        self.o.say("info", "RESTORE %s hp=%s -> %s via=%s", p.label, F(p.temp), F(p.saved), how)
    else
        self:backOff("warn", "clash: at the grab's restore (%s) Health is %s, not the temporary %s; left as it is", p.label, F(hp), F(p.temp))
    end
end

function A:onGrabMulticast(victimIndex, ...)
    local args = { ... }
    local v = get(args[victimIndex + 1])
    if not exists(v) then return end
    self:restore(pathOf(v), "multicast")
end

-- The next-tick fallback: ExecuteInGameThreadWithDelay from the game thread (the HasPerk hook), else a one-shot
-- game-thread loop. Never ExecuteInGameThread, never LoopAsync.
function A:later(vpath)
    self:delay(M.RESTORE_DELAY, self:guard("restore fallback", function(s) s:restore(vpath, "next tick") end), "restore")
end

-- delay(ms, fn, what): fn once on the game thread ms later (called from the game thread: a hook body).
function A:delay(ms, fn, what)
    if type(ExecuteInGameThreadWithDelay) == "function" and pcall(ExecuteInGameThreadWithDelay, ms, fn) then return end
    local handle, done = nil, false
    local ok, h = pcall(LoopInGameThreadWithDelay, ms, function()
        if not done then done = true fn() end
        if handle ~= nil then pcall(CancelDelayedAction, handle) end
        return true
    end)
    if ok then handle = h
    elseif what == "restore" then self.o.warnOnce("later", "no game-thread delay available (%s); the grab hook restores alone", tostring(h))
    else self.o.warnOnce("later:" .. tostring(what), "no game-thread delay available (%s); no %s", tostring(h), tostring(what)) end
end

-- UpdateFriendlyFire (host): the match starts. Knob values are parsed again for every match.
function A:onStart(gsParam)
    if not self.o.isHost() then return end
    local world = self.o.world()
    -- Only the first call per world starts the match (it is a server RPC a client can call again).
    if self.st.started and self.st.world == world then return end
    self:reset(world)
    local st = self.st
    local values, problems = knobs.parse(self.o.knobs())
    for _, p in ipairs(problems) do self.o.warnOnce("knobs:" .. p, "knobs: %s", p) end
    st.values = values
    self.seed(math.floor((os.time() % 1000000) * 1000 + (self.clock() * 1000) % 1000))
    st.started = true
    self.o.say("info", "MATCH start knobs=%s", knobs.describe(values))
    self:publish(values)
    -- Story 12: Tokens per Classified acts only above 0 (0 is the game's behaviour, like Default).
    local cls = M.classifiedOpts(values)
    local gs0 = (values.cold ~= nil or values.revives ~= nil or cls ~= nil) and self:gameState(get(gsParam)) or nil
    -- The poll re-finds this game state through a weak handle each tick (no scan, no UObject kept).
    if self.o.ref and gs0 then
        local okR, h = false, nil
        if gs0 then okR, h = pcall(self.o.ref, gs0) end
        if okR and h ~= nil then st.gsRef = h
        else self.o.say("debug", "no weak handle on the game state (%s); the poll finds it with FindAllOf", tostring(h)) end
    end
    -- Grab classes and the radio loaded by now are hooked before their first use.
    for _, g in ipairs(M.GRABS) do self:installClass(g.class) end
    self:installClass(RADIO)
    -- Tokens: the offset count (and Disable at N = 0) now; re-checked in the radio callbacks and the poll. The
    -- classified bonus (story 12) shares the token state: its baseline is read now, its rises in the
    -- UpdateClassifieds callback and the poll.
    if values.revives ~= nil or cls ~= nil then
        local gs = gs0
        if gs then st.tok = tokens.start(gs, values.revives, self.o, cls)
        else self.o.warnOnce("tokens:gs", "TOKENS no game state at the match start; tokens stay stock") end
    end
end

-- publish(values) (host, match start): the grab inputs for modded clients through core.net (net.lua's keys). Under
-- pcall: a failure costs only the clients' flips (they stay inactive), never the host's match. In solo play core
-- answers "standalone" and nothing is published.
function A:publish(values)
    local o = self.o
    if o.netMissing or not (o.net and o.modId) then return end
    local ok, err = pcall(function()
        local list, problems = net.encode(values, o.version, o.netCompat)
        for _, p in ipairs(problems) do o.warnOnce("net:" .. p, "NET %s", p) end
        local names = {}
        for _, kv in ipairs(list) do
            local okP, why = o.net.publish(o.modId .. "." .. kv[1], kv[2])
            if okP ~= true then
                o.say("debug", "NET nothing more published (%s) at %s", tostring(why), kv[1])
                break
            end
            names[#names + 1] = kv[1] .. "=" .. tostring(kv[2])
        end
        if #names > 0 then o.say("info", "NET published %s", table.concat(names, " ")) end
        -- Only a complete set (ver and compat come last) lets the host spare a client.
        self.st.published = #list > 0 and #names == #list
    end)
    if not ok then o.say("warn", "NET publish failed: %s; modded clients keep the game's grab decisions this match", tostring(err)) end
end

-- classifiedOpts(values) -> { k, cap } for tokens.start, or nil while Tokens per Classified is Default or 0 (then
-- Max Classified Tokens does nothing either).
function M.classifiedOpts(values)
    local k = values and values.classifiedTokens
    if type(k) ~= "number" or k <= 0 then return nil end
    return { k = k, cap = values.classifiedTokensMax }
end

-- The game state's UpdateClassifieds callback (story 12; host only): a classified objective completed. The poll
-- runs the same award (deduplicated by the value seen last), so a callback UE4SS doesn't run only delays it.
function A:onClassified()
    local t = self.st.tok
    if not t or not t.k or not self:active() then return end
    local gs = self:pollGameState(true) -- the match's handle; a FindAllOf only without core's handles
    if gs then
        tokens.classified(t, gs, "UpdateClassifieds", self.o)
        tokens.check(t, gs, "UpdateClassifieds", self.o)
    end
end

-- The radio's server-event callbacks (host only; they run after the body, so the count already moved).
function A:onRadio(event)
    if not self.st.tok or not self:active() then return end
    local gs = self:pollGameState(true) -- the match's handle; a FindAllOf only without core's handles
    if gs then tokens.check(self.st.tok, gs, event, self.o) end
end

-- ---------------------------------------------------------------- the host poll (cold, token re-check)
function A:now()
    if self.micros then
        local ok, us = pcall(self.micros)
        if ok and type(us) == "number" then return us, "core" end
    end
    return os.clock() * 1e6, "os"
end

M.REDISCOVER_EVERY = 8 -- polls: the characters are found again every 2 s (and on a match's first poll)

-- handles() -> true when the poll keeps weak handles (core has them and the game state has one this match).
function A:handles() return self.st.gsRef ~= nil and self.o.ref ~= nil and self.o.deref ~= nil end

-- pollGameState(check) -> this match's game state: through the weak handle (nil once it is gone: the tick is
-- skipped; the KSL liveness check only when check is set, at a discovery), or without core's handles the old way
-- (a FindAllOf of the game states).
function A:pollGameState(check)
    local st = self.st
    if st.gsRef ~= nil and self.o.deref then
        local ok, gs = pcall(self.o.deref, st.gsRef)
        if ok and gs ~= nil and (not check or self:alive(gs)) then return gs end
        return nil
    end
    return self:gameState(nil)
end

-- freeChars(): the character handles go (a rediscovery, a dropped entry handled by the caller).
function A:freeChars()
    for _, e in ipairs(self.st.charRefs or {}) do if self.o.free then pcall(self.o.free, e.h) end end
    self.st.charRefs = nil
end

-- pollChars(gs) -> chars, discovered. With handles: a discovery (PlayerArray, liveness, paths, one handle per
-- character) on a match's first poll and every REDISCOVER_EVERY polls; between, only a deref per handle (an entry
-- whose deref is nil is dropped until the next discovery). Without handles: a discovery every poll.
function A:pollChars(gs)
    local st = self.st
    if not self:handles() then return self:players(gs), true end
    if st.charRefs == nil or st.sinceDiscovery >= M.REDISCOVER_EVERY - 1 then
        self:freeChars()
        local found = self:players(gs)
        local refs = {}
        for _, c in ipairs(found) do
            local ok, h = pcall(self.o.ref, c.obj)
            if ok and h ~= nil then refs[#refs + 1] = { h = h, path = c.path } end
        end
        st.charRefs, st.sinceDiscovery = refs, 0
        return found, true
    end
    st.sinceDiscovery = st.sinceDiscovery + 1
    local chars, keep = {}, {}
    for _, e in ipairs(st.charRefs) do
        local ok, o = pcall(self.o.deref, e.h)
        if ok and o ~= nil then
            chars[#chars + 1] = { obj = o, path = e.path }
            keep[#keep + 1] = e
        elseif self.o.free then
            pcall(self.o.free, e.h)
        end
    end
    st.charRefs = keep
    return chars, false
end

-- players(gs) -> { { obj, path } } for each player state's pawn in gs.PlayerArray that is a live
-- BP_FirstPersonCharacter_C (no FindAllOf: the AI-controlled infected aren't players, and the game skips them too).
function A:players(gs)
    local chars = {}
    local okA, arr = pcall(function() return gs.PlayerArray end)
    if not okA or arr == nil then return chars end
    local okN, n = pcall(function() return #arr end)
    if not okN or type(n) ~= "number" then okN, n = pcall(function() return arr:GetArrayNum() end) end
    if not okN or type(n) ~= "number" then return chars end
    for i = 1, math.min(n, 64) do
        local okE, ps = pcall(function() return arr[i] end)
        if okE and ps ~= nil then
            local okG, inner = pcall(function() return ps:get() end) -- an element wrapper, if UE4SS hands one
            if okG and inner ~= nil and type(inner) ~= "boolean" then ps = inner end
            local pawn
            pcall(function() pawn = ps.PawnPrivate end)
            if not exists(pawn) then pawn = nil pcall(function() pawn = ps:GetPawn() end) end
            if exists(pawn) and self:alive(pawn) then
                local path = pathOf(pawn)
                if path then
                    local fp = self.st.isFP[path]
                    if fp == nil then
                        local cls = classOf(pawn)
                        fp = cls == FP_SHORT
                        if cls ~= nil then self.st.isFP[path] = fp end -- a failed class read is tried again next time
                    end
                    if fp then chars[#chars + 1] = { obj = pawn, path = path } end
                end
            end
        end
    end
    return chars
end

-- onPoll(): every 250 ms on the game thread. No work unless the match is active here and cold or tokens act. The game
-- state through the weak handle, the characters from its PlayerArray (no FindAllOf, no StaticFindObject miss).
function A:onPoll()
    local st = self.st
    if st.client then return self:clientHooks() end
    if not st.started or st.backedOff then return end
    local cold = st.values.cold
    if cold == nil and not st.tok then return end
    if not self:active() then return end
    local t0, clockName = self:now()
    local discovering = not self:handles() or st.charRefs == nil or st.sinceDiscovery >= M.REDISCOVER_EVERY - 1
    local gs = self:pollGameState(discovering)
    if not gs then return end
    local chars, discovered = {}, false
    if cold ~= nil then chars, discovered = self:pollChars(gs) end
    local tFind = self:now()
    if cold ~= nil then
        local d = gs and self:difficulty(nil, gs) or nil
        if d then st.cold:tick(chars, cold, d) end
    end
    if st.tok and gs then
        tokens.classified(st.tok, gs, "poll", self.o) -- story 12; nothing unless Tokens per Classified acts
        tokens.check(st.tok, gs, "poll", self.o)
    end
    if cold ~= nil then
        st.cold:cost(self:now() - t0, tFind - t0, discovered)
        st.cold:summary(clockName)
    end
end

-- clientHooks() (the poll, on a client world): the character's grab hooks if the class wasn't loaded yet when the
-- world was evaluated. Tried every REDISCOVER_EVERY polls (2 s), at most CLIENT_HOOK_TRIES times per world (a failed
-- registration costs a StaticFindObject miss); then one line.
M.CLIENT_HOOK_TRIES = 30
function A:clientHooks()
    local st = self.st
    if self.bpHooks[FPC .. ":HasPerk"] or st.world == nil or st.world ~= self.o.world() then return end
    st.hookPolls = (st.hookPolls or 0) + 1
    if st.hookPolls % M.REDISCOVER_EVERY ~= 0 then return end
    st.hookTries = (st.hookTries or 0) + 1
    if st.hookTries > M.CLIENT_HOOK_TRIES then return end
    self:installClass(FPC)
    if self.bpHooks[FPC .. ":HasPerk"] then self.o.say("debug", "client grab hooks registered (try %d)", st.hookTries)
    elseif st.hookTries == M.CLIENT_HOOK_TRIES then
        self.o.warnOnce("clienthooks:" .. tostring(st.world), "the character class never loaded on this client; its grabs keep the game's decision this world")
    end
end

-- startPoll() -> ok, problem: the one LoopInGameThreadWithDelay loop, for the session (never LoopAsync). Its body
-- returns at once while no match is active or cold and tokens are Default.
function A:startPoll()
    if self.pollHandle ~= nil then return true end
    local fn = self:guard("poll", A.onPoll)
    local ok, h = pcall(LoopInGameThreadWithDelay, env.POLL_MS, function() fn() end)
    if not ok then return false, tostring(h) end
    self.pollHandle = h or true
    return true
end

-- ---------------------------------------------------------------- registration
function A:register(path, pre, post, tag)
    local ok, a, b = pcall(RegisterHook, path, pre, post or function() end)
    if ok then
        self.o.say("debug", "HOOK %s ok", path)
        return true, a, b
    end
    self.o.say("debug", "HOOK %s not now (%s)", path, tostring(a))
    return false
end

-- install(): the native hooks, once (at ready). Returns ok, problem.
function A:install()
    self.installFailed = true -- stays true if this throws
    local N = M.NATIVES
    local defs = {
        { N.locked, self:guard("ApplyLockedDamage hook", A.onLocked), self:guard("ApplyLockedDamage post-hook", A.onApplyPost) },
        { N.stalker, self:guard("ApplyStalkerDamage hook", A.onStalker), self:guard("ApplyStalkerDamage post-hook", A.onApplyPost) },
        { N.boss, self:guard("CommitLethalDamage hook", A.onBoss), self:guard("CommitLethalDamage post-hook", A.onBossPost) },
        { N.cde, self:guard("CallDamageEvent hook", A.onCde), self:guard("CallDamageEvent post-hook", A.onCdePost) },
        { N.frost, self:guard("CallFrostbiteDamageEvent hook", A.onFrost), self:guard("CallFrostbiteDamageEvent post-hook", A.onFrostPost) },
    }
    local missing = {}
    for _, d in ipairs(defs) do
        if not self.hooks[d[1]] then
            if self:register(d[1], d[2], d[3]) then self.hooks[d[1]] = true else missing[#missing + 1] = d[1]:match("[^:]+$") end
        end
    end
    if #missing > 0 then
        self.installFailed = true -- no flips and no compensation without the damage hooks
        return false, "could not hook " .. table.concat(missing, ", ")
    end
    -- Story 5: the Stalker's presentation, for a client's own Stalker grab. Without it only that grab stays the game's.
    if not self.hooks[M.PRESENT] then
        if self:register(M.PRESENT, self:guard("BeginStalkerPresentation hook", A.onPresent)) then self.hooks[M.PRESENT] = true
        else self.o.warnOnce("present", "could not hook BeginStalkerPresentation; a client's own Stalker grabs keep the game's decision") end
    end
    self.installFailed = false
    return true
end

-- The Blueprint hooks of one class (registered per host world once the class is loaded).
function A:classDefs(classPath)
    local defs = {}
    if classPath == FPC then
        defs[#defs + 1] = { FPC .. ":HasPerk", self:guard("HasPerk hook", A.onHasPerk) }
        defs[#defs + 1] = { FPC .. ":PlayDamageEvent", self:guard("PlayDamageEvent hook", function(s, ...) s:onGrabMulticast(0, ...) end) }
    elseif classPath == GAMESTATE then
        defs[#defs + 1] = { GAMESTATE .. ":UpdateFriendlyFire", self:guard("UpdateFriendlyFire hook", A.onStart) }
        defs[#defs + 1] = { GAMESTATE .. ":UpdateClassifieds", self:guard("UpdateClassifieds hook", A.onClassified) }
    elseif classPath == RADIO then
        for _, ev in ipairs(M.RADIO_EVENTS) do
            defs[#defs + 1] = { RADIO .. ":" .. ev, self:guard(ev .. " hook", function(s) s:onRadio(ev) end) }
        end
    end
    for _, g in ipairs(M.GRABS) do
        if g.class == classPath then
            defs[#defs + 1] = { g.class .. ":" .. g.fn, self:guard(g.fn .. " hook", function(s, ...) s:onGrabMulticast(g.victim, ...) end) }
        end
    end
    return defs
end

-- classes(client): the classes whose Blueprint hooks a host world registers; a client world (story 5) only the grab
-- hooks: HasPerk, PlayDamageEvent and the five AI grab multicasts (no match start, no radio).
function A:classes(client)
    local t = client and { FPC } or { GAMESTATE, FPC }
    for _, g in ipairs(M.GRABS) do t[#t + 1] = g.class end
    if not client then t[#t + 1] = RADIO end
    return t
end

-- installClass(path): register what isn't registered in this world yet; a class that isn't loaded stays pending.
function A:installClass(classPath)
    for _, d in ipairs(self:classDefs(classPath)) do
        if not self.bpHooks[d[1]] then
            local ok, a, b = self:register(d[1], d[2])
            if ok then self.bpHooks[d[1]] = { pre = a, post = b } end
        end
    end
end

-- needClassHooks(short): an attacker of this class was seen, so the class is loaded: register its multicast on the
-- next tick (never from inside the multicast that is running).
function A:needClassHooks(short)
    for _, g in ipairs(M.GRABS) do
        if g.short == short and not self.bpHooks[g.class .. ":" .. g.fn] and not self.queued[g.class] then
            local fn = self:guard("class hooks", function(s) s.queued[g.class] = nil s:installClass(g.class) end)
            if type(ExecuteInGameThreadWithDelay) == "function" and pcall(ExecuteInGameThreadWithDelay, 100, fn) then self.queued[g.class] = true end
            return
        end
    end
end

-- onWorld(name, host, fresh): per world (main.lua's LoadMap evaluation). A fresh world is a new match state (the
-- poll's per-path cold state and the token state go with it); the Blueprint hooks of the last world are unregistered
-- and, on a host world, registered again for the loaded classes; on a client world (client: IsServer false, story 5)
-- only the grab hooks.
function A:onWorld(name, host, fresh, client)
    if fresh or self.st.world ~= name then self:reset(name) end
    self.st.client = host ~= true and client == true
    for path, ids in pairs(self.bpHooks) do pcall(UnregisterHook, path, ids.pre, ids.post) end
    self.bpHooks, self.queued = {}, {}
    if host ~= true and not self.st.client then return end
    for _, c in ipairs(self:classes(self.st.client)) do self:installClass(c) end
end

return M
