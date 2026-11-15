-- Difficulty 0.1.0 (spec-difficulty-v1, stories 1, 3 and 4). Connects to Nucleus (core) through the dependent
-- bootstrap (core's api-contract.md) and caches isHost per world. Story 3: enemy damage on the host and survivable
-- grabs for the host's own player (hits.lua). Story 4: cold, frostbite and reinforcement tokens on the host (env.lua,
-- tokens.lua, wired in hits.lua; one host poll started here). Until stories 6 and 7, the knob values come only from
-- dev.lua (deploy.ps1 -Test -Knobs), so a release (no dev.lua) leaves every knob Default and changes nothing.
-- Holds no UObject between callbacks (AGENTS.md): world.lua keeps only world names and booleans. Every hook body and
-- every call into core runs under pcall, with one log line per failure. Story 5: survivable grabs on modded clients
-- through core.net (core 0.12.0: host replicated state and player presence); the mod's own id comes from mod.json.
local ME, CORE, NEED = "Difficulty", "Nucleus", "0.12.0"
local VERSION = "0.1.0"
local PRE_NEED = "0.3.0" -- dev only (deploy.ps1 -Test -PreCore writes Scripts/dev.lua): core before 0.4.0, no UI

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scriptDir = source:match("^(.*)[/\\]") or "."

-- ---------------------------------------------------------------- the dependent bootstrap (core's api-contract.md)
local mods = source:match("^(.*)[/\\][^/\\]+[/\\][Ss]cripts[/\\]") or "."
package.path = scriptDir .. "/?.lua;" .. package.path .. ";" .. mods .. "/" .. CORE .. "/Scripts/?.lua"
local ok, client = pcall(require, CORE:lower() .. ".client")
if not ok then print(("[%s] %s is not installed. %s will not run.\n"):format(ME, CORE, ME)) return end

local world = require("world")
local hits = require("hits")
local net = require("net")

-- ---------------------------------------------------------------- mod.json (the id for core.net; never hard-coded)
-- Read once, bounded; data only. A problem is remembered and logged once connected (the host then spares only its own
-- player, and a client stays inactive).
local function loadManifest()
    local f = io.open(scriptDir .. "/../mod.json", "rb")
    if not f then return {}, "mod.json not found next to Scripts" end
    local text = f:read(net.MAX_MANIFEST + 1)
    f:close()
    if type(text) ~= "string" or #text > net.MAX_MANIFEST then return {}, "mod.json is empty or over " .. net.MAX_MANIFEST .. " bytes" end
    local m = net.manifest(text)
    if type(m.id) ~= "string" or not m.id:match("^[a-z0-9][a-z0-9%-]*%.[a-z0-9][a-z0-9%-]*$") or #m.id > 200 then
        return m, "mod.json has no usable id (" .. tostring(m.id) .. ")"
    end
    if m.netCompat ~= nil and not net.parse(m.netCompat) then return m, "mod.json netCompat " .. tostring(m.netCompat) .. " is not x.y.z" end
    return m
end
local manifest, manifestProblem = loadManifest()

-- ---------------------------------------------------------------- dev.lua (deploy.ps1 -Test; never shipped)
-- Optional. Data only: loaded with an empty environment; two booleans and the knobs string are read from it (the knobs
-- are parsed, bounded, at each match start: knobs.lua). A problem is only remembered here and logged once connected,
-- so a failed connect stays exactly one [Difficulty] line (CAP-7).
local function loadDev()
    local d = { debug = false, preCore = false, knobs = nil }
    local path = scriptDir .. "/dev.lua"
    local f = io.open(path, "r")
    if not f then return d end -- the normal case: no dev.lua
    f:close()
    local chunk, err = loadfile(path, "t", {})
    if not chunk then return d, "dev.lua could not be read (" .. tostring(err) .. "); ignored" end
    local okD, t = pcall(chunk)
    if not okD or type(t) ~= "table" then return d, "dev.lua did not return a table (" .. tostring(t) .. "); ignored" end
    d.debug = t.debug == true
    d.preCore = t.preCore == true
    d.knobs = t.knobs -- any type: knobs.parse rejects anything but a string of at most 1024 bytes
    return d
end
local dev, devProblem = loadDev()
local need = dev.preCore and PRE_NEED or NEED

-- ---------------------------------------------------------------- after connect
local function start(core)
    local L = core.log
    -- Calls into core's logger are guarded too: a failing logger falls back to print, once per line.
    local function say(level, fmt, ...)
        local okL = pcall(L[level], fmt, ...)
        if not okL then
            local okF, msg = pcall(string.format, fmt, ...)
            print(("[%s] %s%s\n"):format(ME, level == "info" and "" or (level:upper() .. " "), okF and msg or tostring(fmt)))
        end
    end
    pcall(function() L.debugEnabled = dev.debug end)
    local said = {}
    local function warnOnce(key, fmt, ...)
        if said[key] then return end
        said[key] = true
        say("warn", fmt, ...)
    end
    if devProblem then warnOnce("dev", "%s", devProblem) end
    if dev.preCore then
        say("warn", "running on %s %s before %s (dev only): no UI", CORE, tostring(core.version), NEED)
    end

    -- Story 5: core.net for client grabs and the host's spare decision. One line when it can't be used.
    local okNet, coreNet = pcall(function() return core.net end)
    if not okNet or type(coreNet) ~= "table" then coreNet = nil end
    local netMissing = net.missing(core.has)
    if not netMissing and not coreNet then netMissing = "net" end
    if not netMissing and manifestProblem then netMissing = "mod.json id" end
    if netMissing then
        -- WARN, except in the dev core mode (a core before 0.4.0 has no net at all; its one WARN is the pre-core line)
        say(dev.preCore and "info" or "warn", "%s %s has no %s%s: survivable grabs only for the host's own player; as a client, inactive", CORE,
            tostring(core.version), netMissing, manifestProblem and (" (" .. manifestProblem .. ")") or "")
    end

    local W = world.new()
    local currentName -- the full name of the world evaluated last (hits.lua asks W:isHost(currentName))
    -- core's microsecond clock (the poll's cost), when this core has it; os.clock otherwise.
    local micros
    local okM, m = pcall(function() return core.clock and core.clock.micros end)
    if okM and type(m) == "function" then micros = m end
    local H = hits.new{
        say = say, warnOnce = warnOnce, alive = world.alive,
        world = function() return currentName end,
        isHost = function() return W:isHost(currentName) end,
        knobs = function() return dev.knobs end,
        micros = micros,
        -- core's weak handles (the match's game state, re-found each poll without a scan), when this core has them.
        ref = type(core.ref) == "function" and core.ref or nil,
        deref = type(core.deref) == "function" and core.deref or nil,
        free = type(core.free) == "function" and core.free or nil,
        -- story 5: core.net, this mod's own id, version and netCompat (mod.json; nil: core's default)
        net = coreNet, modId = manifest.id, version = VERSION, netCompat = manifest.netCompat, netMissing = netMissing,
    }
    -- Evaluates one world: plain values from world.lua, cached by full name; one WORLD line per world.
    local function evaluate(w, how)
        local name, server, standalone, problem = world.read(w)
        if not name then warnOnce("noname", "a %s world could not be read: %s; isHost stays false", how, tostring(problem)) return end
        local e, fresh = W:onLoadMap(name, server, standalone)
        if not e then return end
        currentName = e.name
        if fresh then world.forget() end -- alive()'s cached KSL lookups are found again per world
        -- A fresh world is a new match state for hits.lua; its Blueprint hooks follow the world.
        local okW, errW = pcall(H.onWorld, H, e.name, e.host, fresh, e.server == false)
        if not okW then say("error", "hits for %s failed: %s", e.map, tostring(errW)) end
        if fresh and problem then say("warn", "isHost for %s: %s; host=false for this world", e.map, problem) end
        if fresh then
            say("info", "WORLD host=%s standalone=%s map=%s", tostring(e.host),
                e.standalone == nil and "?" or tostring(e.standalone), e.map)
        else
            say("debug", "WORLD again map=%s (%s)", e.map, how)
        end
    end

    local okH, errH = pcall(RegisterLoadMapPostHook, function(_, w)
        local okB, errB = pcall(evaluate, world.unwrap(w), "LoadMap")
        if not okB then say("error", "LoadMap hook failed: %s", tostring(errB)) end
    end)
    if not okH then say("error", "could not register the LoadMap hook: %s. %s will not run.", tostring(errH), ME) return end

    -- Enemy damage: the native hooks once, now; the Blueprint ones per host world (H.onWorld).
    local okI, okN, errN = pcall(H.install, H)
    if not okI then say("error", "enemy damage hooks failed: %s; hits stay stock", tostring(okN))
    elseif not okN then say("error", "%s; hits stay stock", tostring(errN)) end
    -- Cold and the token re-check: one game-thread poll for the session (idle unless a hosted match uses them).
    local okP, okS, errS = pcall(H.startPoll, H)
    if not okP then say("error", "the host poll failed to start: %s; cold stays stock", tostring(okS))
    elseif not okS then say("error", "the host poll could not start (%s); cold stays stock", tostring(errS)) end

    -- The world already loaded when connect succeeded (its LoadMap ran before this hook existed).
    local current = world.currentWorld()
    if current ~= nil then
        local okE, errE = pcall(evaluate, current, "ready")
        if not okE then say("error", "evaluating the current world failed: %s", tostring(errE)) end
    else
        say("debug", "no world at ready; isHost waits for the next LoadMap")
    end

    say("info", "READY version=%s %s=%s need=%s", VERSION, CORE, tostring(core.version), need)
end

local okC, errC = pcall(client.connect, {
    mod = ME, need = need,
    onReady = function(core)
        local okR, err = pcall(start, core)
        if not okR then print(("[%s] ERROR start failed: %s\n"):format(ME, tostring(err))) end
    end,
    -- connect has already logged the one line naming the cause (CAP-7: exactly one [Difficulty] line). Nothing to add.
    onFail = function() end,
})
if not okC then print(("[%s] ERROR %s's connect failed: %s. %s will not run.\n"):format(ME, CORE, tostring(errC), ME)) end
