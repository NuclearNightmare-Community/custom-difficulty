-- Unit tests for Scripts/main.lua outside the game: the bootstrap paths (no core, connect's arguments, a failed
-- connect, dev.lua and the dev core mode), and isHost per world through the real world.lua over a fake core and fake
-- UE4SS globals.
-- Run from the repo root:  texlua test/unit/main_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("main_test")
local ok, eq = H.ok, H.eq
local MAIN = ROOT .. "/Scripts/main.lua"
local realLoadfile, realLoad, realOpen = loadfile, load, io.open
local W, S -- the fake world; S.dev is the text of dev.lua (nil: no file)

local function newLog(tag)
    local L = { debugEnabled = false }
    local function emit(level, fmt, ...) print("[" .. tag .. "] " .. level .. string.format(fmt, ...) .. "\n") end
    function L.info(f, ...) emit("", f, ...) end
    function L.warn(f, ...) emit("WARN ", f, ...) end
    function L.error(f, ...) emit("ERROR ", f, ...) end
    function L.debug(f, ...) if L.debugEnabled then emit("DEBUG ", f, ...) end end
    return L
end

-- Loads main.lua fresh. opts.client = false: core not installed; opts.connectThrows: connect raises.
-- The caret rule core's connect applies (nucleus.semver): 0.x needs the same minor, 1.x the same major; at least need.
local function satisfies(have, need)
    local a, b, c = tostring(have):match("^(%d+)%.(%d+)%.(%d+)$")
    local x, y, z = tostring(need):match("^(%d+)%.(%d+)%.(%d+)$")
    if not a or not x then return false end
    a, b, c, x, y, z = tonumber(a), tonumber(b), tonumber(c), tonumber(x), tonumber(y), tonumber(z)
    if a ~= x then return false end
    if x == 0 then return b == y and c >= z end
    if b ~= y then return b > y end
    return c >= z
end

local function boot(opts)
    opts = opts or {}
    W = F.new()
    F.install(W)
    S = { dev = opts.dev, connects = {} }
    for _, m in ipairs({ "world", "hits", "damage", "knobs", "nucleus.client" }) do package.loaded[m] = nil end
    package.preload["nucleus.client"] = nil
    if opts.client ~= false then
        package.preload["nucleus.client"] = function()
            return { connect = function(o)
                if opts.connectThrows then error("connect{ mod = <string>, need = <semver> }") end
                S.connects[#S.connects + 1] = o
            end }
        end
    end
    io.open = function(path, mode)
        if tostring(path):match("[/\\]dev%.lua$") then
            if S.dev == nil then return nil, path .. ": No such file or directory" end
            return { close = function() end }
        end
        return realOpen(path, mode)
    end
    loadfile = function(path, mode, env)
        if tostring(path):match("[/\\]dev%.lua$") then
            S.devEnv = env
            if S.dev == nil then return nil, "cannot open " .. path end
            return realLoad(S.dev, "=dev.lua", "t", env)
        end
        return realLoadfile(path, mode, env)
    end
    local chunk = assert(realLoadfile(MAIN))
    chunk()
end
local function newCore(version)
    return { name = "Nucleus", version = version or "0.4.0", log = newLog("Difficulty") }
end
-- As core's connect: onReady only when the core satisfies need; otherwise core's one ERROR line and onFail.
local function ready(core)
    local c = S.connects[1]
    if not satisfies(core.version, c.need) then
        local msg = ("%s %s is not compatible; %s needs %s (^ rules). Update %s."):format(core.name, core.version, c.mod, c.need, core.name)
        print("[" .. c.mod .. "] ERROR " .. msg .. " " .. c.mod .. " will not run.\n")
        c.onFail(msg)
        return false
    end
    c.onReady(core)
    return true
end
local function lines(pat) local r = {} for _, l in ipairs(W.printed) do if l:find(pat) then r[#r + 1] = l end end return r end
local function count(pat) return #lines(pat) end
local function ours() return count("^%[Difficulty%]") end

-- ---------------------------------------------------------------- no core (CAP-7)
do
    boot{ client = false }
    eq(#W.printed, 1, "no core: exactly one line")
    eq(W.printed[1], "[Difficulty] Nucleus is not installed. Difficulty will not run.", "no core: the line names the cause")
    eq(#S.connects, 0, "no core: no connect")
    eq(#W.loadMapHooks, 0, "no core: no hook")
end

-- ---------------------------------------------------------------- connect's arguments, normal deploy
do
    boot()
    eq(#S.connects, 1, "connect called once")
    local c = S.connects[1]
    ok(c.mod == "Difficulty" and c.need == "0.4.0", "connect{ mod = 'Difficulty', need = '0.4.0' }", tostring(c.mod) .. " " .. tostring(c.need))
    eq(#W.printed, 0, "nothing printed during main.lua")
    eq(#W.loadMapHooks, 0, "no hook before connect succeeds")
    -- old core: connect logs the one ERROR line itself; onFail adds nothing and registers nothing.
    c.onFail("Nucleus 0.3.0 is not compatible; Difficulty needs 0.4.0 (^ rules). Update Nucleus.")
    eq(#W.printed, 0, "onFail adds no line (connect logged the cause)")
    eq(#W.loadMapHooks, 0, "onFail: no hook registered")
end
do -- connect itself raises: one ERROR line, no hook.
    boot{ connectThrows = true }
    eq(ours(), 1, "connect throws: exactly one line")
    eq(count("^%[Difficulty%] ERROR Nucleus's connect failed: .* Difficulty will not run%.$"), 1, "connect throws: the ERROR names it")
    eq(#W.loadMapHooks, 0, "connect throws: no hook")
end

-- ---------------------------------------------------------------- ready on the menu, then a hosted match
do
    boot()
    local core = newCore("0.4.0")
    ready(core)
    eq(#W.loadMapHooks, 1, "one LoadMap hook after connect")
    eq(count("^%[Difficulty%] WORLD host=false standalone=true map=NewMainMenu$"), 1, "the menu world evaluated at ready")
    eq(count("^%[Difficulty%] READY version=0%.1%.0 Nucleus=0%.4%.0 need=0%.4%.0$"), 1, "READY line")
    local iw, ir
    for i, l in ipairs(W.printed) do if l:find("WORLD", 1, true) then iw = iw or i end if l:find("READY", 1, true) then ir = i end end
    ok(iw and ir and iw < ir, "WORLD for the current world comes before READY")
    eq(count("WARN"), 0, "normal mode: no WARN")
    eq(count("running on"), 0, "normal mode: no pre-core WARN")
    -- The LoadMap hook for the same menu world (it can fire after ready): no second WORLD line.
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("WORLD host=false standalone=true map=NewMainMenu"), 1, "the same world again: still one WORLD line")
    -- A hosted match.
    W.loadMapHooks[1](nil, W.param(W.match))
    eq(count("^%[Difficulty%] WORLD host=true standalone=false map=SmallMap$"), 1, "hosted match: host=true once")
    W.loadMapHooks[1](nil, W.param(W.match))
    eq(count("WORLD host=true"), 1, "the match world again: still once")
    -- Back to the menu, then a client world.
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("WORLD host=false standalone=true map=NewMainMenu"), 2, "back to the menu: a new world, logged")
    W.loadMapHooks[1](nil, W.param(W.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "client")))
    eq(count("^%[Difficulty%] WORLD host=false standalone=false map=SmallMap$"), 1, "a client world: host=false")
    -- The hook body never throws out: a nil world is reported once.
    W.loadMapHooks[1](nil, nil)
    W.loadMapHooks[1](nil, nil)
    eq(count("WARN a LoadMap world could not be read"), 1, "a nil world: one WARN")
    eq(count("ERROR"), 0, "no ERROR")
end
do -- IsServer fails in the match: one WARN, isHost false for that world.
    boot()
    ready(newCore())
    W.serverFails = true
    W.loadMapHooks[1](nil, W.param(W.match))
    W.loadMapHooks[1](nil, W.param(W.match)) -- the same world again (as ready + LoadMap): still one WARN
    eq(count("^%[Difficulty%] WARN isHost for SmallMap: IsServer failed"), 1, "IsServer fails: one WARN")
    eq(count("^%[Difficulty%] WORLD host=false standalone=%? map=SmallMap$"), 1, "IsServer fails: host=false")
    eq(count("ERROR"), 0, "IsServer fails: no ERROR")
end
do -- No world at ready: nothing logged for it, the next LoadMap is evaluated.
    boot()
    FindFirstOf = function() return nil end
    ready(newCore())
    eq(count("WORLD"), 0, "no world at ready: no WORLD line")
    eq(count("READY"), 1, "no world at ready: still READY")
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("WORLD host=false standalone=true"), 1, "then the LoadMap evaluates it")
end
do -- RegisterLoadMapPostHook fails: one ERROR, no READY.
    boot()
    RegisterLoadMapPostHook = function() error("no") end
    ready(newCore())
    eq(count("^%[Difficulty%] ERROR could not register the LoadMap hook"), 1, "hook registration fails: one ERROR")
    eq(count("READY"), 0, "hook registration fails: no READY")
end
do -- A failing core logger falls back to print.
    boot()
    local core = newCore()
    core.log.info = function() error("logger broke") end
    ready(core)
    eq(count("^%[Difficulty%] READY "), 1, "logger fails: READY still printed")
end

-- ---------------------------------------------------------------- dev.lua and the dev core mode
do
    boot{ dev = "return { debug = true, preCore = true }" }
    eq(S.connects[1].need, "0.3.0", "preCore: connect with need 0.3.0")
    local env = S.devEnv
    ok(type(env) == "table" and next(env) == nil, "dev.lua loaded with an empty environment")
    local core = newCore("0.3.0")
    ready(core)
    eq(count("^%[Difficulty%] WARN running on Nucleus 0%.3%.0 before 0%.4%.0 %(dev only%): no UI$"), 1, "preCore: one pre-core WARN")
    eq(count("WARN"), 1, "preCore: no other WARN")
    ok(core.log.debugEnabled == true, "debug = true turns DEBUG lines on")
    eq(count("READY version=0%.1%.0 Nucleus=0%.3%.0 need=0%.3%.0$"), 1, "preCore: READY names need 0.3.0")
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("DEBUG WORLD again map=NewMainMenu"), 1, "debug: the repeat is a DEBUG line")
end
do -- dev.lua without preCore (what deploy -Test -PreCore writes on core 0.4.x) on core 0.4.0: connects, no pre-core WARN.
    boot{ dev = "return { debug = true }" }
    eq(S.connects[1].need, "0.4.0", "dev.lua without preCore: need 0.4.0")
    ok(ready(newCore("0.4.0")), "dev.lua without preCore on core 0.4.0: connects")
    eq(count("running on"), 0, "dev.lua without preCore: no pre-core WARN")
    eq(count("READY version=0%.1%.0 Nucleus=0%.4%.0 need=0%.4%.0$"), 1, "dev.lua without preCore: READY need 0.4.0")
end
do -- preCore on core 0.4.0 would need 0.3.0, which 0.4.0 doesn't satisfy (0.x caret: same minor): the fake connect refuses.
    boot{ dev = "return { debug = true, preCore = true }" }
    ok(not ready(newCore("0.4.0")), "preCore on core 0.4.0: connect refuses")
    eq(#W.loadMapHooks, 0, "preCore on core 0.4.0: no hook")
    eq(ours(), 1, "preCore on core 0.4.0: exactly one line")
end
do -- normal need 0.4.0 on core 0.3.0: refused with core's line (the old-core scenario).
    boot()
    ok(not ready(newCore("0.3.0")), "core 0.3.0, need 0.4.0: refused")
    eq(count("^%[Difficulty%] ERROR Nucleus 0%.3%.0 is not compatible; Difficulty needs 0%.4%.0 %(%^ rules%)%. Update Nucleus%. Difficulty will not run%.$"), 1, "old core: core's one line")
    eq(ours(), 1, "old core: exactly one line")
    eq(#W.loadMapHooks, 0, "old core: no hook")
end
do -- A broken dev.lua: ignored, one WARN after connect, normal need; nothing printed before connect.
    boot{ dev = "return {" }
    eq(#W.printed, 0, "broken dev.lua: nothing before connect")
    eq(S.connects[1].need, "0.4.0", "broken dev.lua: need 0.4.0")
    ready(newCore())
    eq(count("^%[Difficulty%] WARN dev%.lua could not be read"), 1, "broken dev.lua: one WARN")
    boot{ dev = "return 7" }
    ready(newCore())
    eq(count("WARN dev%.lua did not return a table"), 1, "dev.lua not a table: one WARN")
    boot{ dev = "os.exit(3)" }
    ready(newCore())
    eq(count("WARN dev%.lua did not return a table"), 1, "dev.lua can't reach os (empty environment)")
    boot{ dev = "return { preCore = 'yes' }" }
    eq(S.connects[1].need, "0.4.0", "preCore must be the boolean true")
end
do -- A failed connect with a broken dev.lua stays one line (the dev problem is never printed).
    boot{ dev = "return {" }
    S.connects[1].onFail("x")
    eq(#W.printed, 0, "failed connect: the dev.lua problem is not logged")
end

-- ---------------------------------------------------------------- story 3: hits wired in, dev.lua knobs
do
    local UFF = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:UpdateFriendlyFire"
    local HASPERK = "/Game/FirstPerson/Blueprints/BP_FirstPersonCharacter.BP_FirstPersonCharacter_C:HasPerk"
    boot{ dev = 'return { debug = true, knobs = "enemyDamage=17" }' }
    ready(newCore())
    eq(W.count("/Script/NuclearNightmare.NuclearNightmareCharacter:CallDamageEvent"), 1, "the natives hooked at ready")
    eq(W.count(HASPERK), 0, "the menu: no Blueprint hooks")
    W.loadMapHooks[1](nil, W.param(W.match))
    eq(W.count(HASPERK), 1, "a hosted match: HasPerk hooked")
    eq(W.count(UFF), 1, "a hosted match: UpdateFriendlyFire hooked")
    W.fire(UFF, W.p(nil))
    eq(count("^%[Difficulty%] MATCH start knobs=enemyDamage=17$"), 1, "dev.lua knobs reach the match start")
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(W.count(HASPERK), 0, "back to the menu: the Blueprint hooks are unregistered")
    eq(count("ERROR"), 0, "story 3 wiring: no ERROR")

    boot() -- a release: no dev.lua, so every knob is Default
    ready(newCore())
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[Difficulty%] MATCH start knobs=all Default$"), 1, "no dev.lua: every knob Default")

    boot{ dev = 'return { knobs = "bogus=1" }' }
    ready(newCore())
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[Difficulty%] WARN knobs: unknown knob 'bogus'; ignored$"), 1, "a bad dev.lua knob: one WARN")

    boot()
    RegisterHook = function() error("no UFunction") end
    ready(newCore())
    eq(count("^%[Difficulty%] ERROR could not hook ApplyLockedDamage, ApplyStalkerDamage, CommitLethalDamage, CallDamageEvent; hits stay stock$"), 1, "natives can't be hooked: one ERROR")
    eq(count("READY"), 1, "natives can't be hooked: still READY (isHost works)")
end

-- ---------------------------------------------------------------- the constants
do
    local src = assert(realOpen(MAIN, "r")):read("a")
    ok(src:find('local ME, CORE, NEED = "Difficulty", "Nucleus", "0.4.0"', 1, true), "main.lua: ME, CORE, NEED constants")
    ok(not src:find("HasAuthority", 1, true), "main.lua: isHost never from HasAuthority")
    ok(not src:find("LoopAsync", 1, true) and not src:find("ExecuteInGameThread%(") , "main.lua: no LoopAsync / ExecuteInGameThread")
end

loadfile, io.open = realLoadfile, realOpen
H.done()
