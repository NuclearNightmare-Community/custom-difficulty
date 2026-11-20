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
-- Core's rule (Nucleus lua/pkg/semver.lua check, since 0.5.0): ">=X.Y.Z", "^X.Y.Z" or "X.Y.Z" is a minimum; the only
-- version refusal is "core-too-old" (have < need). A need that doesn't parse is refused too ("bad-need").
local function parseV(v) local a, b, c = tostring(v):match("^(%d+)%.(%d+)%.(%d+)$"); if a then return { tonumber(a), tonumber(b), tonumber(c) } end end
local function check(have, need)
    local body = tostring(need):match("^>=(.*)$") or tostring(need):match("^%^(.*)$") or tostring(need)
    local n, h = parseV(body), parseV(have)
    if not n then return false, "bad-need" end
    if not h then return false, "bad-have" end
    for i = 1, 3 do if h[i] ~= n[i] then if h[i] < n[i] then return false, "core-too-old" end return true end end
    return true
end

local function boot(opts)
    opts = opts or {}
    W = F.new()
    F.install(W)
    S = { dev = opts.dev, connects = {} }
    for _, m in ipairs({ "world", "hits", "damage", "knobs", "env", "tokens", "net", "presets", "sidecar", "rows", "nucleus.client" }) do package.loaded[m] = nil end
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
        -- opts.manifest: the text of mod.json (false: no file); nil: the repo's own mod.json
        if opts.manifest ~= nil and tostring(path):match("[/\\]mod%.json$") then
            if opts.manifest == false then return nil, path .. ": No such file or directory" end
            local text = opts.manifest
            return { read = function() return text end, close = function() end }
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
    local N = F.net()
    return { name = "Nucleus", version = version or "0.15.0", log = newLog("CustomDifficulty"), net = N, has = N.has, ui = F.ui() }
end
-- As core's connect: onReady only when the core satisfies need; otherwise core's one ERROR line and onFail.
local function ready(core)
    local c = S.connects[1]
    local okV, kind = check(core.version, c.need)
    if not okV then
        assert(kind == "core-too-old", "the fake connect only words core-too-old, got " .. tostring(kind))
        local msg = ("%s %s is older than %s needs (%s). Update %s."):format(core.name, core.version, c.mod, c.need, core.name)
        print("[" .. c.mod .. "] ERROR " .. msg .. " " .. c.mod .. " will not run.\n")
        c.onFail(msg)
        return false
    end
    c.onReady(core)
    return true
end
local function lines(pat) local r = {} for _, l in ipairs(W.printed) do if l:find(pat) then r[#r + 1] = l end end return r end
local function count(pat) return #lines(pat) end
local function ours() return count("^%[CustomDifficulty%]") end

-- ---------------------------------------------------------------- no core (CAP-7)
do
    boot{ client = false }
    eq(#W.printed, 1, "no core: exactly one line")
    eq(W.printed[1], "[CustomDifficulty] Nucleus is not installed. CustomDifficulty will not run.", "no core: the line names the cause")
    eq(#S.connects, 0, "no core: no connect")
    eq(#W.loadMapHooks, 0, "no core: no hook")
end

-- ---------------------------------------------------------------- connect's arguments, normal deploy
do
    boot()
    eq(#S.connects, 1, "connect called once")
    local c = S.connects[1]
    ok(c.mod == "CustomDifficulty" and c.need == "0.15.0", "connect{ mod = 'CustomDifficulty', need = '0.15.0' }", tostring(c.mod) .. " " .. tostring(c.need))
    eq(#W.printed, 0, "nothing printed during main.lua")
    eq(#W.loadMapHooks, 0, "no hook before connect succeeds")
    -- old core: connect logs the one ERROR line itself; onFail adds nothing and registers nothing.
    c.onFail("Nucleus 0.3.0 is older than CustomDifficulty needs (0.15.0). Update Nucleus.")
    eq(#W.printed, 0, "onFail adds no line (connect logged the cause)")
    eq(#W.loadMapHooks, 0, "onFail: no hook registered")
end
do -- connect itself raises: one ERROR line, no hook.
    boot{ connectThrows = true }
    eq(ours(), 1, "connect throws: exactly one line")
    eq(count("^%[CustomDifficulty%] ERROR Nucleus's connect failed: .* CustomDifficulty will not run%.$"), 1, "connect throws: the ERROR names it")
    eq(#W.loadMapHooks, 0, "connect throws: no hook")
end

-- ---------------------------------------------------------------- ready on the menu, then a hosted match
do
    boot()
    local core = newCore("0.15.0")
    ready(core)
    eq(#W.loadMapHooks, 1, "one LoadMap hook after connect")
    eq(count("^%[CustomDifficulty%] WORLD host=false standalone=true map=NewMainMenu$"), 1, "the menu world evaluated at ready")
    eq(count("^%[CustomDifficulty%] READY version=0%.2%.0 Nucleus=0%.15%.0 need=0%.15%.0$"), 1, "READY line")
    local iw, ir
    for i, l in ipairs(W.printed) do if l:find("WORLD", 1, true) then iw = iw or i end if l:find("READY", 1, true) then ir = i end end
    ok(iw and ir and iw < ir, "WORLD for the current world comes before READY")
    eq(count("WARN"), 0, "normal mode: no WARN")
    eq(count("running on"), 0, "normal mode: no pre-core WARN")
    local loops = 0
    for _, e in ipairs(W.later) do if e.loop and e.ms == 250 then loops = loops + 1 end end
    eq(loops, 1, "ready: the host poll started (one 250 ms game-thread loop)")
    -- The LoadMap hook for the same menu world (it can fire after ready): no second WORLD line.
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("WORLD host=false standalone=true map=NewMainMenu"), 1, "the same world again: still one WORLD line")
    -- A hosted match.
    W.loadMapHooks[1](nil, W.param(W.match))
    eq(count("^%[CustomDifficulty%] WORLD host=true standalone=false map=SmallMap$"), 1, "hosted match: host=true once")
    W.loadMapHooks[1](nil, W.param(W.match))
    eq(count("WORLD host=true"), 1, "the match world again: still once")
    -- Back to the menu, then a client world.
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("WORLD host=false standalone=true map=NewMainMenu"), 2, "back to the menu: a new world, logged")
    W.loadMapHooks[1](nil, W.param(W.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "client")))
    eq(count("^%[CustomDifficulty%] WORLD host=false standalone=false map=SmallMap$"), 1, "a client world: host=false")
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
    eq(count("^%[CustomDifficulty%] WARN isHost for SmallMap: IsServer failed"), 1, "IsServer fails: one WARN")
    eq(count("^%[CustomDifficulty%] WORLD host=false standalone=%? map=SmallMap$"), 1, "IsServer fails: host=false")
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
    eq(count("^%[CustomDifficulty%] ERROR could not register the LoadMap hook"), 1, "hook registration fails: one ERROR")
    eq(count("READY"), 0, "hook registration fails: no READY")
end
do -- main.lua passes core's weak handles and clock into hits: a hosted cold match refs the game state and the COLD
   -- line says clock=core.
    boot{ dev = 'return { knobs = "cold=50" }' }
    local now = 1000
    local realClock = os.clock
    os.clock = function() return now end
    local core = newCore("0.15.0")
    local refs, us = 0, 0
    local handles = {}
    core.ref = function(o) refs = refs + 1 handles[refs] = o return refs end
    core.deref = function(h) return handles[h] end
    core.free = function(h) handles[h] = nil end
    core.clock = { micros = function() us = us + 5 return us end }
    local function obj(class, path, fields)
        local o = { _full = class .. " " .. path }
        for k, v in pairs(fields or {}) do o[k] = v end
        o.IsValid = function() return true end
        o.GetFullName = function(s) return s._full end
        o.GetClass = function() return { GetFName = function() return { ToString = function() return class end } end } end
        return o
    end
    local ch = obj("BP_FirstPersonCharacter_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.BP_FirstPersonCharacter_C_1", { Temperature = 0.1 })
    local ps = obj("BP_NNPlayerState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.PS_1", { PawnPrivate = ch })
    local gs = obj("BP_FirstPersonGameState_C", "/Game/Maps/SmallMap.SmallMap:PersistentLevel.GS_1", { Diffculty = 0, PlayerArray = { ps } })
    W.all.BP_FirstPersonGameState_C = { gs }
    ready(core)
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire("/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:UpdateFriendlyFire", W.p(gs))
    local loop
    for _, e in ipairs(W.later) do if e.loop and e.ms == 250 then loop = e.fn end end
    eq(refs, 1, "wiring: core.ref took the game state's handle at the match start")
    loop() ch.Temperature = 0.14 loop()
    ok(math.abs(ch.Temperature - 0.11) < 1e-9, "wiring: the poll scales through main.lua's hits", ch.Temperature)
    now = now + 11 loop()
    eq(count("^%[CustomDifficulty%] COLD raw=.* clock=core$"), 1, "wiring: the COLD line says clock=core")
    ok(refs >= 2, "wiring: the characters are held through core.ref too")
    os.clock = realClock
end
do -- The poll can't start: one ERROR, READY still.
    boot()
    LoopInGameThreadWithDelay = function() error("no loop") end
    ready(newCore())
    eq(count("^%[CustomDifficulty%] ERROR the host poll could not start %(.*no loop%); cold stays stock$"), 1, "poll fails to start: one ERROR")
    eq(count("READY"), 1, "poll fails to start: still READY")
end
do -- A failing core logger falls back to print.
    boot()
    local core = newCore()
    core.log.info = function() error("logger broke") end
    ready(core)
    eq(count("^%[CustomDifficulty%] READY "), 1, "logger fails: READY still printed")
end

-- ---------------------------------------------------------------- dev.lua and the dev core mode
do
    boot{ dev = "return { debug = true, preCore = true }" }
    eq(S.connects[1].need, "0.3.0", "preCore: connect with need 0.3.0")
    local env = S.devEnv
    ok(type(env) == "table" and next(env) == nil, "dev.lua loaded with an empty environment")
    local core = newCore("0.3.0")
    ready(core)
    eq(count("^%[CustomDifficulty%] WARN running on Nucleus 0%.3%.0 before 0%.4%.0 %(dev only%): no UI$"), 1, "preCore: one pre-core WARN")
    eq(count("WARN"), 1, "preCore: no other WARN")
    ok(core.log.debugEnabled == true, "debug = true turns DEBUG lines on")
    eq(count("READY version=0%.2%.0 Nucleus=0%.3%.0 need=0%.3%.0$"), 1, "preCore: READY names need 0.3.0")
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(count("DEBUG WORLD again map=NewMainMenu"), 1, "debug: the repeat is a DEBUG line")
end
do -- dev.lua without preCore (what deploy -Test -PreCore writes on core 0.4.x) on core 0.15.0: connects, no pre-core WARN.
    boot{ dev = "return { debug = true }" }
    eq(S.connects[1].need, "0.15.0", "dev.lua without preCore: need 0.15.0")
    ok(ready(newCore("0.15.0")), "dev.lua without preCore on core 0.15.0: connects")
    eq(count("running on"), 0, "dev.lua without preCore: no pre-core WARN")
    eq(count("READY version=0%.2%.0 Nucleus=0%.15%.0 need=0%.15%.0$"), 1, "dev.lua without preCore: READY need 0.15.0")
end
do -- preCore on core 0.15.0 needs 0.3.0, a minimum 0.15.0 meets (core's rule since 0.5.0): connect accepts (DW-86).
    boot{ dev = "return { debug = true, preCore = true }" }
    ok(ready(newCore("0.15.0")), "preCore on core 0.15.0: connect accepts")
    eq(count("ERROR"), 0, "preCore on core 0.15.0: no ERROR line")
    eq(count("READY version=0%.2%.0 Nucleus=0%.15%.0 need=0%.3%.0$"), 1, "preCore on core 0.15.0: READY names need 0.3.0")
    eq(count("^%[CustomDifficulty%] WARN running on Nucleus 0%.15%.0 before 0%.4%.0 %(dev only%): no UI$"), 1, "preCore on core 0.15.0: the pre-core WARN")
end
do -- normal need 0.15.0 on core 0.3.0: refused with core's line (the old-core scenario).
    boot()
    ok(not ready(newCore("0.3.0")), "core 0.3.0, need 0.15.0: refused")
    eq(count("^%[CustomDifficulty%] ERROR Nucleus 0%.3%.0 is older than CustomDifficulty needs %(0%.15%.0%)%. Update Nucleus%. CustomDifficulty will not run%.$"), 1, "old core: core's one line")
    eq(ours(), 1, "old core: exactly one line")
    eq(#W.loadMapHooks, 0, "old core: no hook")
end
do -- A broken dev.lua: ignored, one WARN after connect, normal need; nothing printed before connect.
    boot{ dev = "return {" }
    eq(#W.printed, 0, "broken dev.lua: nothing before connect")
    eq(S.connects[1].need, "0.15.0", "broken dev.lua: need 0.15.0")
    ready(newCore())
    eq(count("^%[CustomDifficulty%] WARN dev%.lua could not be read"), 1, "broken dev.lua: one WARN")
    boot{ dev = "return 7" }
    ready(newCore())
    eq(count("WARN dev%.lua did not return a table"), 1, "dev.lua not a table: one WARN")
    boot{ dev = "os.exit(3)" }
    ready(newCore())
    eq(count("WARN dev%.lua did not return a table"), 1, "dev.lua can't reach os (empty environment)")
    boot{ dev = "return { preCore = 'yes' }" }
    eq(S.connects[1].need, "0.15.0", "preCore must be the boolean true")
end
do -- A failed connect with a broken dev.lua stays one line (the dev problem is never printed).
    boot{ dev = "return {" }
    S.connects[1].onFail("x")
    eq(#W.printed, 0, "failed connect: the dev.lua problem is not logged")
end

-- ---------------------------------------------------------------- story 6: presets wired in, the knob source
do
    local UFF = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:UpdateFriendlyFire"
    local P = require("presets")
    -- io.open is boot's fake: the sidecar path isn't dev.lua or mod.json, so it goes to the real io.open, which can't
    -- open C:/nn/...; a missing directory only makes the write fail with one WARN. Point the saved dir at a temp dir.
    local base = os.tmpname()
    os.remove(base)
    local dir = base .. "_nnmain"
    local isWin = package.config:sub(1, 1) == "\\"
    if isWin then os.execute('mkdir "' .. (dir .. "/SaveGames"):gsub("/", "\\") .. '" >NUL 2>NUL') else os.execute('mkdir -p "' .. dir .. '/SaveGames"') end

    boot() -- a release (no dev.lua)
    W.savedDir = dir .. "/"
    ready(newCore())
    for _, k in ipairs(P.ORDER) do eq(W.count(P.PATHS[k]), 1, "ready: preset hook registered: " .. k) end
    local S = F.screen(W, { "A" })
    S:open()
    eq(count("^%[CustomDifficulty%] PRESETS open presets=1 entries=0 changed=true$"), 1, "open through main.lua")
    S:capture()
    eq(count("^%[CustomDifficulty%] PRESETS capture knobs=all Default$"), 1, "no preset selected: capture all Default")
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[CustomDifficulty%] MATCH start knobs=all Default$"), 1, "release, no preset selected: MATCH start all Default")
    eq(W.count(P.PATHS.construct), 1, "LoadMap: preset hooks not registered twice")
    eq(count("WARN"), 0, "presets wiring: no WARN")
    eq(count("ERROR"), 0, "presets wiring: no ERROR")

    -- A preset whose sidecar entry has values (a hand-edited file before story 7): select, capture, match start.
    local f = io.open(dir .. "/SaveGames/CustomDifficulty_WorldPresets.txt", "wb")
    f:write("# CustomDifficulty world presets, format 2\n0\tA\tenemyDamage=17\n")
    f:close()
    boot()
    W.savedDir = dir .. "/"
    ready(newCore())
    S = F.screen(W, { "A" })
    S:open()
    S:select(1)
    S:capture()
    eq(count("^%[CustomDifficulty%] PRESETS capture knobs=enemyDamage=17$"), 1, "the selected preset's values captured")
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[CustomDifficulty%] MATCH start knobs=enemyDamage=17$"), 1, "the capture reaches the match start")

    -- dev.lua knobs win over the capture.
    boot{ dev = 'return { knobs = "cold=50" }' }
    W.savedDir = dir .. "/"
    ready(newCore())
    S = F.screen(W, { "A" })
    S:open()
    S:select(1)
    S:capture()
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[CustomDifficulty%] MATCH start knobs=cold=50$"), 1, "dev.lua knobs win over the capture")
    if isWin then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" >NUL 2>NUL') else os.execute('rm -rf "' .. dir .. '"') end
end

-- ---------------------------------------------------------------- story 7: the rows wired in
do
    local UFF = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:UpdateFriendlyFire"
    boot()
    W.savedDir = "" -- the sidecar isn't needed here (one WARN per open, counted below)
    local core = newCore()
    local U = core.ui
    ready(core)
    eq(#U.order, 21, "ready: 21 rows declared")
    eq(#U.watchers, 1, "ready: one createServer watcher")
    eq(U.watchers[1] and U.watchers[1].host, "createServer", "the watcher is on createServer")
    eq(count("^%[CustomDifficulty%] ROWS declared 21$"), 1, "one ROWS declared line")
    local S = F.screen(W, {})
    S:open()
    U.open(F.tree({ "Overlay_28", "Overlay_738" }))
    eq(U.sliders["s-enemyDamage"].hint, "25", "opened on Normal: hint 25")
    U.input("s-enemyDamage", 57)
    eq(count("^%[CustomDifficulty%] ROWS change enemyDamage=57 rows=enemyDamage=57$"), 1, "a typed 57: the change line")
    S:pick(0)
    eq(U.sliders["s-cold"].hint, "200", "the Difficulty picker: Cold's hint follows Nightmare")
    S:capture()
    eq(count("^%[CustomDifficulty%] PRESETS capture knobs=enemyDamage=57$"), 1, "the capture takes the slider's value")
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[CustomDifficulty%] MATCH start knobs=enemyDamage=57$"), 1, "the match starts with it")
    eq(count("ERROR"), 0, "rows wiring: no ERROR")
    eq(count("WARN"), 1, "rows wiring: only the sidecar's WARN")
    -- a second ready in the same Lua state never happens; the declare guard is rows_test's.

    boot{ dev = "return { preCore = true }" } -- the dev core mode: no rows
    core = newCore("0.3.0")
    ready(core)
    eq(#core.ui.order, 0, "preCore: no rows")
    eq(#core.ui.watchers, 0, "preCore: no watcher")
    eq(count("ROWS"), 0, "preCore: no ROWS line")

    boot() -- a core without ui: one WARN, the rest runs
    core = newCore()
    core.ui = nil
    ready(core)
    eq(count("^%[CustomDifficulty%] WARN Nucleus 0%.15%.0 has no ui: the rows are not shown$"), 1, "no ui: one WARN")
    eq(count("READY"), 1, "no ui: still READY")

    boot() -- core.ui.row.create raises: one ERROR, READY still
    core = newCore()
    core.ui.fails["row.create"] = true
    ready(core)
    eq(count("^%[CustomDifficulty%] ERROR ROWS enemyDamage could not be declared"), 1, "row.create fails: one ERROR")
    eq(count("READY"), 1, "row.create fails: still READY")
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
    eq(count("^%[CustomDifficulty%] MATCH start knobs=enemyDamage=17$"), 1, "dev.lua knobs reach the match start")
    W.loadMapHooks[1](nil, W.param(W.menu))
    eq(W.count(HASPERK), 0, "back to the menu: the Blueprint hooks are unregistered")
    eq(count("ERROR"), 0, "story 3 wiring: no ERROR")
    -- Story 5: main.lua passes the client flag (IsServer false) to hits.onWorld: a client match world gets the grab
    -- hooks, never the match start; a world whose IsServer fails gets none.
    W.loadMapHooks[1](nil, W.param(W.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "client")))
    eq(W.count(HASPERK), 1, "a client match world: HasPerk hooked")
    eq(W.count(UFF), 0, "a client match world: no UpdateFriendlyFire hook")
    W.loadMapHooks[1](nil, W.param(W.menu))
    W.serverFails = true
    W.loadMapHooks[1](nil, W.param(W.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "client")))
    eq(W.count(HASPERK), 0, "IsServer fails: no grab hooks")
    W.serverFails = false

    boot() -- a release: no dev.lua, so every knob is Default
    ready(newCore())
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[CustomDifficulty%] MATCH start knobs=all Default$"), 1, "no dev.lua: every knob Default")

    boot{ dev = 'return { knobs = "bogus=1" }' }
    ready(newCore())
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF, W.p(nil))
    eq(count("^%[CustomDifficulty%] WARN knobs: unknown knob 'bogus'; ignored$"), 1, "a bad dev.lua knob: one WARN")

    boot()
    RegisterHook = function() error("no UFunction") end
    ready(newCore())
    eq(count("^%[CustomDifficulty%] ERROR could not hook ApplyLockedDamage, ApplyStalkerDamage, CommitLethalDamage, CallDamageEvent, CallFrostbiteDamageEvent; hits stay stock$"), 1, "natives can't be hooked: one ERROR")
    eq(count("READY"), 1, "natives can't be hooked: still READY (isHost works)")
end

-- ---------------------------------------------------------------- story 5: core.net, the version gate, mod.json's id
local UFF5 = "/Game/FirstPerson/Blueprints/BP_FirstPersonGameState.BP_FirstPersonGameState_C:UpdateFriendlyFire"
do -- a full core: no net line; the host publishes under mod.json's own id at the match start
    boot{ dev = 'return { knobs = "enemyDamage=25" }' }
    local core = newCore()
    ready(core)
    eq(count("has no net"), 0, "full core: no missing-feature line")
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF5, W.p(nil))
    local keys = {}
    for _, kv in ipairs(core.net.published) do keys[#keys + 1] = kv[1] .. "=" .. tostring(kv[2]) end
    eq(table.concat(keys, ","), "nuclearnightmare-community.custom-difficulty.enemyDamage=25,nuclearnightmare-community.custom-difficulty.ver=2000,nuclearnightmare-community.custom-difficulty.compat=2000",
        "publish: ver, compat and the set knob under mod.json's id")
    eq(count("^%[CustomDifficulty%] NET published enemyDamage=25 ver=2000 compat=2000$"), 1, "publish: one NET line")
end
for _, missing in ipairs({ "net.publish", "net.read", "net.presence", "net.compatible", "net.versionsCompatible" }) do
    boot{ dev = 'return { knobs = "enemyDamage=25" }' }
    local core = newCore()
    local feats = { ["net.publish"] = true, ["net.read"] = true, ["net.presence"] = true, ["net.compatible"] = true, ["net.versionsCompatible"] = true }
    feats[missing] = nil
    core.has = function(n) return feats[n] == true end
    ready(core)
    eq(count("^%[CustomDifficulty%] WARN Nucleus 0%.15%.0 has no " .. missing:gsub("%.", "%%.") .. ": survivable grabs only for the host's own player; as a client, inactive$"), 1, "no " .. missing .. ": one line naming it")
    eq(count("WARN"), 1, "no " .. missing .. ": nothing else")
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF5, W.p(nil))
    eq(#core.net.published, 0, "no " .. missing .. ": nothing published")
    eq(count("^%[CustomDifficulty%] MATCH start "), 1, "no " .. missing .. ": the host's match still starts")
end
do -- core without has() at all, or without core.net
    boot()
    local core = newCore()
    core.has = nil
    ready(core)
    eq(count("WARN Nucleus 0%.15%.0 has no net%.publish: "), 1, "no core.has: the first feature named")
    boot()
    core = newCore()
    core.net = nil
    ready(core)
    eq(count("WARN Nucleus 0%.15%.0 has no net: "), 1, "no core.net: named")
end
do -- the dev core mode on a core without net: the net line is INFO (the pre-core WARN stays the only WARN)
    boot{ dev = "return { preCore = true }" }
    local core = newCore("0.3.0")
    core.has, core.net = nil, nil
    ready(core)
    eq(count("WARN"), 1, "preCore without net: one WARN (the pre-core line)")
    eq(count("^%[CustomDifficulty%] Nucleus 0%.3%.0 has no net%.publish: "), 1, "preCore without net: the net line as INFO")
end
do -- mod.json without a usable id: named once; nothing published (the host spares only itself)
    for _, case in ipairs({ { false, "mod%.json not found" }, { '{ "id": "CustomDifficulty", "version": "0.1.0" }', "no usable id %(CustomDifficulty%)" },
                            { '{ "version": "0.1.0" }', "no usable id %(nil%)" },
                            { '{ "id": "a.b", "version": "0.1.0", "netCompat": "x" }', "netCompat x is not x%.y%.z" } }) do
        boot{ dev = 'return { knobs = "enemyDamage=25" }', manifest = case[1] }
        local core = newCore()
        ready(core)
        ok(count("WARN Nucleus 0%.15%.0 has no mod%.json id %(.*" .. case[2]) == 1, "mod.json " .. tostring(case[1]) .. ": one line", table.concat(W.printed, " | "))
        W.loadMapHooks[1](nil, W.param(W.match))
        W.fire(UFF5, W.p(nil))
        eq(#core.net.published, 0, "mod.json " .. tostring(case[1]) .. ": nothing published")
    end
end
do -- a netCompat in mod.json is published as compat; a nested "id" is not taken for the mod's own
    boot{ manifest = '{ "settings": { "x": { "id": "no" } }, "id": "nuclearnightmare-community.custom-difficulty", "version": "0.1.0", "netCompat": "0.0.9" }' }
    local core = newCore()
    ready(core)
    W.loadMapHooks[1](nil, W.param(W.match))
    W.fire(UFF5, W.p(nil))
    eq(core.net.published[1] and core.net.published[1][1], "nuclearnightmare-community.custom-difficulty.ver", "a nested id is not taken")
    eq(core.net.published[2] and core.net.published[2][2], 9, "netCompat 0.0.9: compat=9")
end

-- ---------------------------------------------------------------- the constants
do
    local src = assert(realOpen(MAIN, "r")):read("a")
    ok(src:find('local ME, CORE, NEED = "CustomDifficulty", "Nucleus", "0.15.0"', 1, true), "main.lua: ME, CORE, NEED constants")
    ok(not src:find("HasAuthority", 1, true), "main.lua: isHost never from HasAuthority")
    ok(not src:find("LoopAsync", 1, true) and not src:find("ExecuteInGameThread%(") , "main.lua: no LoopAsync / ExecuteInGameThread")
    ok(not src:find("ui%.[%a]+%.[%a]+%(") and not src:find("ui%.place%("), "main.lua: no core.ui call (rows.lua is the only file that calls core.ui)")
    local rsrc = assert(realOpen(ROOT .. "/Scripts/rows.lua", "r")):read("a")
    ok(not rsrc:find("StaticFindObject", 1, true) and not rsrc:find("FindAllOf", 1, true), "rows.lua: no StaticFindObject or FindAllOf")
    ok(not rsrc:lower():find("infection", 1, true), "rows.lua: no Infection Chance")
end

loadfile, io.open = realLoadfile, realOpen
H.done()
