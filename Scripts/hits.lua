-- Difficulty: enemy damage on the host and survivable grabs for the host's own player (spec-difficulty-v1 story 3;
-- knob-mechanics.md "Enemy damage" and "Survivable grabs"). The game adapter: hooks, match state, attribution,
-- Health compensation, the grab flip and its restore, the guards against other mods. The math is damage.lua's.
--
-- Rules every hook body follows (spec "Always"):
--   * it runs under pcall; a failure logs one ERROR and turns damage and grab changes off for the match (a pending
--     temporary Health is still restored);
--   * it returns unless this machine hosts the current world, the match started in it (UpdateFriendlyFire ran), the
--     mod hasn't backed off this match, and a knob the hit or grab depends on isn't Default (all Default: no write);
--   * GameState.Diffculty is read live at each hit and grab, never written;
--   * no UObject is kept between callbacks: victims and attackers are kept as paths and found again;
--   * nothing runs per frame; the only deferred call is a grab's next-tick restore fallback.
local damage = require("damage")
local knobs = require("knobs")
local M = {}

local CTX_CDO = "/Script/NuclearNightmare.Default__NNEnemyAttackContext"
local DOG_CDO = "/Script/NuclearNightmare.Default__NNInfectedDogSupport"
local GS_CDO = "/Script/Engine.Default__GameplayStatics"
local FPC = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C"
local GAMESTATE = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C"

M.GRAB_WINDOW = 8     -- s: hits on a victim this long after its grab decision belong to that grab (Stalker 4.9 s)
M.WEAK_WINDOW = 0.25  -- s: a Blueprint wrapper's context (Worm, Leech, ...) applies to the victim's next hit this soon
M.BAT_RANGE = 300     -- cm: a phase-3 bat this close to the victim made the hit
M.STALKER_RANGE = 1000 -- cm: the nearest Stalker this close is the grab's attacker when nothing names it
M.TOLERANCE = 0.01    -- HP: the guards' tolerance
M.RESTORE_DELAY = 10  -- ms: the next-tick restore fallback

-- Native hooks (registered at ready; their classes are always loaded).
M.NATIVES = {
    locked = "/Script/NuclearNightmare.NNEnemyAttackContext:ApplyLockedDamage",
    stalker = "/Script/NuclearNightmare.NNEnemyAttackContext:ApplyStalkerDamage",
    boss = "/Script/NuclearNightmare.NNBossAttackRecovery:CommitLethalDamage",
    cde = "/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent",
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
-- Blueprint wrappers that name a context for the victim's next hit (they can't bracket it: base ratio for the
-- Leech, Infected Player and Playable Monster; the Worm's row from ResponsibleActor). attacker/victim: param index
-- (0 = self).
M.WRAPPERS = {
    { key = "worm", class = FPC, fn = "ExplosionDamage", victim = 0, attacker = 1, via = "ExplosionDamage" },
    { key = "infectedPlayer", class = FPC, fn = "AttackPInfectedAll", victim = 1, via = "AttackPInfectedAll" },
    { key = "leech", class = "/Game/Horror_worm/Mesh/BabyWorm_AI.BabyWorm_AI_C", fn = "AttackAll", victim = 1, via = "AttackAll(Leech)" },
    { key = "monster", class = "/Game/ThirdPerson/Blueprints/BP_ThirdPersonCharacter.BP_ThirdPersonCharacter_C", fn = "AttackAll", victim = 2, via = "AttackAll(Monster)" },
}

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
-- (the KismetSystemLibrary:IsValid UFunction), opts.clock() (s), opts.rng() ([0, 1)), opts.seed(n).
function M.new(opts)
    local self = setmetatable({ o = opts, hooks = {}, bpHooks = {}, st = nil }, A)
    self.clock = opts.clock or os.clock
    self.rng = opts.rng or math.random
    self.seed = opts.seed or function(n) math.randomseed(n) end
    self:reset(nil)
    return self
end

-- reset(world): a new match state (a fresh world or a new match). Pending restores survive it: a temporary Health is
-- always put back.
function A:reset(world)
    local old = self.st
    self.st = {
        world = world, started = false, backedOff = false, values = {},
        grabs = {},     -- victim path -> { kind, attacker, row, at }
        weak = {},      -- victim path -> { row, via, at } (Blueprint wrapper context)
        boss = {},      -- stack of { row, via } (CommitLethalDamage)
        apply = {},     -- stack of plans (or false) for ApplyLockedDamage / ApplyStalkerDamage
        cde = {},       -- stack of plans (or false) for CallDamageEvent
        pending = old and old.pending or {}, -- victim path -> { saved, temp, label }
    }
end

function A:active()
    local st = self.st
    return st.started and not st.backedOff and st.world ~= nil and st.world == self.o.world() and self.o.isHost() == true
end

-- backOff(level, fmt, ...): one line, then no damage or grab change until the next match.
function A:backOff(level, fmt, ...)
    if self.st.backedOff then return end
    self.st.backedOff = true
    self.o.say(level, fmt .. "; damage and grab changes off until the next match", ...)
end

-- guard(label, fn): fn under pcall; a failure logs one ERROR and backs off.
function A:guard(label, fn)
    return function(...)
        local ok, err = pcall(fn, self, ...)
        if not ok then
            local first = not self.st.backedOff
            self.st.backedOff = true
            if first then self.o.say("error", "%s failed: %s; damage and grab changes off until the next match", label, tostring(err))
            else self.o.say("debug", "%s failed again: %s", label, tostring(err)) end
        end
    end
end

-- ---------------------------------------------------------------- reading the game
function A:alive(o) return exists(o) and self.o.alive(o) == true end

-- difficulty(ctx) -> EDiffculty 0..3 read live from the game state, or nil.
function A:difficulty(ctx)
    local gs
    local g = cdo(GS_CDO)
    if g then pcall(function() gs = g:GetGameState(ctx) end) end
    if not exists(gs) then
        for _, s in ipairs(FindAllOf("BP_FirstPersonGameState_C") or {}) do
            local p = pathOf(s)
            if p and not p:find("Default__", 1, true) and self:alive(s) then gs = s break end
        end
    end
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

-- The grab's attacker for victim v at HasPerk(0x27): the AI whose locked victim is v, else the Stalker (its
-- presentation source, or the nearest live Stalker). Returns path, row, short class (any may be nil).
function A:grabAttacker(v, vpath)
    local ctx = cdo(CTX_CDO)
    for _, g in ipairs(M.GRABS) do
        for _, a in ipairs(FindAllOf(g.short) or {}) do
            local ap = pathOf(a)
            if ap and not ap:find("Default__", 1, true) and self:alive(a) then
                local lv
                if ctx then pcall(function() lv = ctx:GetLockedVictim(a) end) end
                if exists(lv) and pathOf(lv) == vpath then return ap, M.CLASS_ROW[g.short], g.short end
            end
        end
    end
    local src
    if ctx then pcall(function() src = ctx:GetStalkerPresentationSource(v) end) end
    if exists(src) and self:alive(src) then return pathOf(src), self:rowOf(src), classOf(src) end
    local best, bestD
    for _, s in ipairs(FindAllOf("Stalker_AI_C") or {}) do
        local sp = pathOf(s)
        if sp and not sp:find("Default__", 1, true) and self:alive(s) then
            local d = dist(s, v)
            if d and d <= M.STALKER_RANGE and (not bestD or d < bestD) then best, bestD = sp, d end
        end
    end
    if best then return best, "stalker", "Stalker_AI_C" end
    return nil, nil, nil
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
function A:grabKind(vpath, apath)
    local g = self.st.grabs[vpath]
    if not g then return "hit" end
    if self.clock() - g.at > M.GRAB_WINDOW then self.st.grabs[vpath] = nil return "hit" end
    if g.attacker and apath and g.attacker ~= apath then return "hit" end
    return g.kind
end

-- ---------------------------------------------------------------- one hit
-- plan(v, stock, row, via, apath, inGrab) -> a plan (Health compensated) or false (left alone).
function A:plan(v, stock, row, via, apath, inGrab)
    local values = self.st.values
    if not damage.acts(values, row) then return false end
    if not self:alive(v) then return false end
    local vpath = pathOf(v)
    local n = num(stock)
    if not vpath or not n or n <= 0 then return false end
    local hp = hpOf(v)
    if not hp then return false end
    local d = self:difficulty(v)
    if not d then return false end
    local kind = inGrab and self:grabKind(vpath, apath) or "hit"
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
    local row, via, apath
    local b = st.boss[#st.boss]
    if b then
        row, via, apath = b.row, "CommitLethalDamage", b.path
    else
        -- Frostbite (1 or 2 with no enemy context) is story 4's; never touched here.
        if n == 1 or n == 2 then return end
        local w = vpath and st.weak[vpath]
        if w and self.clock() - w.at <= M.WEAK_WINDOW then
            st.weak[vpath] = nil
            row, via = w.row, w.via
        else
            if w then st.weak[vpath] = nil end
            row, via = self:nativeAttacker(v, vpath)
            if not row then return end -- environmental or unknown: never touched
        end
    end
    local p = self:plan(v, n, row, via, apath, false)
    if p then p.delivered = true end
    st.cde[slot] = p
end
function A:onCdePost()
    local p = table.remove(self.st.cde)
    if p then self:check(p) end
end

-- HasPerk(0x27): the grab decision (knob-mechanics.md "Where to set it").
function A:onHasPerk(selfp, perk)
    if num(get(perk)) ~= 39 then return end
    if not self:active() then return end
    local v = get(selfp)
    if not self:alive(v) then return end
    local vpath = pathOf(v)
    if not vpath or self.st.pending[vpath] then return end -- our own temporary value (a repeated callback)
    local apath, row, short = self:grabAttacker(v, vpath)
    if short then self:needClassHooks(short) end
    local values = self.st.values
    if not damage.acts(values, row) then return end
    local hp = hpOf(v)
    local d = self:difficulty(v)
    if not hp or not d then return end
    local mine = self:myPath(v) == vpath
    local g = damage.grab(hp, values, d, row, mine)
    if not g then return end
    local flip = "none"
    if g.flip then
        if not setHp(v, g.flip) then error("could not write the temporary Health on " .. vpath) end
        self.st.pending[vpath] = { saved = hp, temp = g.flip, label = "enemy=" .. (row or "?") }
        flip = F(g.flip)
        self:later(vpath)
    end
    self.st.grabs[vpath] = { kind = g.decision == "s" and "survivable" or "execution", attacker = apath, row = row, at = self.clock() }
    self.o.say("info", "GRAB enemy=%s hp=%s E=%s game=%s decision=%s flip=%s", row or "?", F(hp), F(g.E), g.game, g.decision, flip)
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
    local fn = self:guard("restore fallback", function(s) s:restore(vpath, "next tick") end)
    if type(ExecuteInGameThreadWithDelay) == "function" and pcall(ExecuteInGameThreadWithDelay, M.RESTORE_DELAY, fn) then return end
    local handle, done = nil, false
    local ok, h = pcall(LoopInGameThreadWithDelay, M.RESTORE_DELAY, function()
        if not done then done = true fn() end
        if handle ~= nil then pcall(CancelDelayedAction, handle) end
        return true
    end)
    if ok then handle = h else self.o.warnOnce("later", "no game-thread delay available (%s); the grab hook restores alone", tostring(h)) end
end

function A:onWrapper(w, ...)
    if not self:active() then return end
    local args = { ... }
    local v = get(args[w.victim + 1])
    if not self:alive(v) then return end
    local vpath = pathOf(v)
    if not vpath then return end
    local row
    if w.key == "worm" then
        local a = get(args[w.attacker + 1])
        if not (self:alive(a) and self:rowOf(a) == "worm") then return end
        row = "worm"
    end
    -- Leech, Infected Player, Playable Monster: base ratio only (row nil).
    self.st.weak[vpath] = { row = row, via = w.via, at = self.clock() }
end

-- UpdateFriendlyFire (host): the match starts. Knob values are parsed again for every match.
function A:onStart()
    if not self.o.isHost() then return end
    local world = self.o.world()
    self:reset(world)
    local st = self.st
    local values, problems = knobs.parse(self.o.knobs())
    for _, p in ipairs(problems) do self.o.warnOnce("knobs:" .. p, "knobs: %s", p) end
    st.values = values
    self.seed(math.floor((os.time() % 1000000) * 1000 + (self.clock() * 1000) % 1000))
    st.started = true
    self.o.say("info", "MATCH start knobs=%s", knobs.describe(values))
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
    local N = M.NATIVES
    local defs = {
        { N.locked, self:guard("ApplyLockedDamage hook", A.onLocked), self:guard("ApplyLockedDamage post-hook", A.onApplyPost) },
        { N.stalker, self:guard("ApplyStalkerDamage hook", A.onStalker), self:guard("ApplyStalkerDamage post-hook", A.onApplyPost) },
        { N.boss, self:guard("CommitLethalDamage hook", A.onBoss), self:guard("CommitLethalDamage post-hook", A.onBossPost) },
        { N.cde, self:guard("CallDamageEvent hook", A.onCde), self:guard("CallDamageEvent post-hook", A.onCdePost) },
    }
    local missing = {}
    for _, d in ipairs(defs) do
        if not self.hooks[d[1]] then
            if self:register(d[1], d[2], d[3]) then self.hooks[d[1]] = true else missing[#missing + 1] = d[1]:match("[^:]+$") end
        end
    end
    if #missing > 0 then return false, "could not hook " .. table.concat(missing, ", ") end
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
    end
    for _, g in ipairs(M.GRABS) do
        if g.class == classPath then
            defs[#defs + 1] = { g.class .. ":" .. g.fn, self:guard(g.fn .. " hook", function(s, ...) s:onGrabMulticast(g.victim, ...) end) }
        end
    end
    for _, w in ipairs(M.WRAPPERS) do
        if w.class == classPath then
            defs[#defs + 1] = { w.class .. ":" .. w.fn, self:guard(w.via .. " hook", function(s, ...) s:onWrapper(w, ...) end) }
        end
    end
    return defs
end

function A:classes()
    local t = { GAMESTATE, FPC }
    for _, g in ipairs(M.GRABS) do t[#t + 1] = g.class end
    for _, w in ipairs(M.WRAPPERS) do if w.class ~= FPC then t[#t + 1] = w.class end end
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
        if g.short == short and not self.bpHooks[g.class .. ":" .. g.fn] and not self.queued then
            local fn = self:guard("class hooks", function(s) s.queued = false s:installClass(g.class) end)
            if type(ExecuteInGameThreadWithDelay) == "function" and pcall(ExecuteInGameThreadWithDelay, 100, fn) then self.queued = true end
            return
        end
    end
end

-- onWorld(name, host, fresh): per world (main.lua's LoadMap evaluation). A fresh world is a new match state; the
-- Blueprint hooks of the last world are unregistered and, on a host world, registered again for the loaded classes.
function A:onWorld(name, host, fresh)
    if fresh or self.st.world ~= name then self:reset(name) end
    for path, ids in pairs(self.bpHooks) do pcall(UnregisterHook, path, ids.pre, ids.post) end
    self.bpHooks, self.queued = {}, false
    if host ~= true then return end
    for _, c in ipairs(self:classes()) do self:installClass(c) end
end

return M
