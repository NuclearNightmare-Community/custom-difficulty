-- Difficulty 0.1.0 (spec-difficulty-v1, story 1): the skeleton. Connects to Nucleus (core) through the dependent
-- bootstrap (core's api-contract.md) and caches isHost per world. No knob acts yet (stories 3-8).
-- Holds no UObject between callbacks (AGENTS.md): world.lua keeps only world names and booleans. Every hook body and
-- every call into core runs under pcall, with one log line per failure.
local ME, CORE, NEED = "Difficulty", "Nucleus", "0.4.0"
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

-- ---------------------------------------------------------------- dev.lua (deploy.ps1 -Test; never shipped)
-- Optional. Data only: loaded with an empty environment, and only two booleans are read from it. A problem is only
-- remembered here and logged once connected, so a failed connect stays exactly one [Difficulty] line (CAP-7).
local function loadDev()
    local d = { debug = false, preCore = false }
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

    local W = world.new()
    -- Evaluates one world: plain values from world.lua, cached by full name; one WORLD line per world.
    local function evaluate(w, how)
        local name, server, standalone, problem = world.read(w)
        if not name then warnOnce("noname", "a %s world could not be read: %s; isHost stays false", how, tostring(problem)) return end
        local e, fresh = W:onLoadMap(name, server, standalone)
        if not e then return end
        if problem then say("warn", "isHost for %s: %s; host=false for this world", e.map, problem) end
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
