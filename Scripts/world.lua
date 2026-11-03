-- Difficulty: which machine decides (AGENTS.md "Networking"). isHost = KismetSystemLibrary:IsServer(world) and not
-- IsStandalone(world), evaluated when a world loads (the LoadMap post-hook, or at ready for the world that was already
-- loaded) and cached per world, keyed by the world's full name. Never from HasAuthority: every machine has authority
-- over the actors it spawns.
-- Two parts: the cache (pure, no UE4SS: unit-tested without the game) and the game adapter (reads KSL for one world
-- and hands back plain values; it never keeps the world or any other UObject).
local M = {}

M.MAX_WORLDS = 16 -- the cache keeps the most recent worlds only (a session loads a handful)
M.MAX_NAME = 512  -- a longer world name is cut (it only comes from the engine, but stay bounded)

-- The map's short name for the log: "World /Game/Maps/NewMainMenu.NewMainMenu" -> "NewMainMenu". Only word
-- characters and '-', at most 64 of them; "?" when nothing is left.
function M.short(name)
    if type(name) ~= "string" then return "?" end
    local s = name:match("([^%./:%s]+)%s*$") or name
    s = s:gsub("[^%w_%-]", ""):sub(1, 64)
    return s ~= "" and s or "?"
end

-- ---------------------------------------------------------------- the cache
local Cache = {}
Cache.__index = Cache

function M.new() return setmetatable({ worlds = {}, order = {}, last = nil }, Cache) end

-- onLoadMap(worldName, isServer, isStandalone) -> entry, fresh.
-- entry = { name, map, server, standalone, host }. isServer / isStandalone are booleans, or nil when the call failed:
-- host is then false (the safe side: a host-only knob stays stock). fresh is false only when the same world was just
-- evaluated with the same answer (the ready evaluation and the LoadMap hook seeing one world), so the WORLD line is
-- logged once per world.
function Cache:onLoadMap(worldName, isServer, isStandalone)
    if type(worldName) ~= "string" or worldName == "" then return nil, false end
    local name = worldName:sub(1, M.MAX_NAME)
    local server, standalone
    if type(isServer) == "boolean" then server = isServer end
    if type(isStandalone) == "boolean" then standalone = isStandalone end
    local entry = { name = name, map = M.short(name), server = server, standalone = standalone,
                    host = server == true and standalone == false }
    local old = self.worlds[name]
    local fresh = not (self.last == name and old and old.server == entry.server and old.standalone == entry.standalone)
    if not old then
        self.order[#self.order + 1] = name
        while #self.order > M.MAX_WORLDS do self.worlds[table.remove(self.order, 1)] = nil end
    end
    self.worlds[name] = entry
    self.last = name
    return entry, fresh
end

-- isHost(worldName) -> true only for a world evaluated as a hosted (listen-server, not standalone) world.
function Cache:isHost(worldName)
    local e = type(worldName) == "string" and self.worlds[worldName:sub(1, M.MAX_NAME)] or nil
    return e ~= nil and e.host == true
end

function Cache:entry(worldName) return type(worldName) == "string" and self.worlds[worldName:sub(1, M.MAX_NAME)] or nil end

-- ---------------------------------------------------------------- the game adapter (UE4SS globals)
local KSL_CDO = "/Script/Engine.Default__KismetSystemLibrary"
local KSL_ISVALID = "/Script/Engine.KismetSystemLibrary:IsValid"

local function ksl()
    local k = StaticFindObject(KSL_CDO)
    if k == nil or not k:IsValid() then error("KismetSystemLibrary's default object not found") end
    return k
end

-- alive(obj): Unreal's IsValid as a UFunction (checks the garbage flag), never UE4SS's obj:IsValid() alone.
function M.alive(obj)
    if obj == nil then return false end
    local ok, r = pcall(function()
        if not obj:IsValid() then return false end
        local fn = StaticFindObject(KSL_ISVALID)
        return fn(ksl(), obj) == true
    end)
    return ok and r == true
end

-- The world a LoadMap post-hook names (a RemoteUnrealParam: world:get()), or the object itself.
function M.unwrap(world)
    if world == nil then return nil end
    local ok, w = pcall(function() return world:get() end)
    if ok and w ~= nil then return w end
    return world
end

-- The world loaded right now (for the evaluation at ready): the local player controller's, if it is alive.
function M.currentWorld()
    local ok, w = pcall(function()
        local pc = FindFirstOf("PlayerController")
        if not M.alive(pc) then return nil end
        return pc:GetWorld()
    end)
    if ok then return w end
    return nil
end

-- read(world) -> name, isServer, isStandalone, problem. Plain values only; the world is not kept. isServer /
-- isStandalone are nil when their call failed, and problem then says why.
function M.read(world)
    local okN, name = pcall(function() return world:GetFullName() end)
    if not okN or type(name) ~= "string" or name == "" then return nil, nil, nil, "the world has no name (" .. tostring(name) .. ")" end
    local okK, k = pcall(ksl)
    if not okK then return name, nil, nil, tostring(k) end
    local okS, server = pcall(function() return k:IsServer(world) end)
    if not okS or type(server) ~= "boolean" then return name, nil, nil, "IsServer failed (" .. tostring(server) .. ")" end
    local okA, standalone = pcall(function() return k:IsStandalone(world) end)
    if not okA or type(standalone) ~= "boolean" then return name, server, nil, "IsStandalone failed (" .. tostring(standalone) .. ")" end
    return name, server, standalone, nil
end

return M
