-- A fake UE4SS for Difficulty's unit tests: worlds, a player controller, KismetSystemLibrary (IsServer, IsStandalone,
-- IsValid as a UFunction) and the globals main.lua, world.lua and hits.lua use (StaticFindObject, FindFirstOf,
-- FindAllOf, RegisterLoadMapPostHook, RegisterHook / UnregisterHook, ExecuteInGameThreadWithDelay,
-- LoopInGameThreadWithDelay, print). Plus a tiny test harness.
-- RegisterHook keeps every registration in W.hooks[path] (a list of { pre, post, id }); W.fire(path, ...) calls the
-- live pre callbacks, W.firePost(path, ...) the post ones. A path listed in W.missing fails to register (an unloaded
-- class). W.later holds the delayed game-thread callbacks; W.runLater() runs them.
local F = {}

local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return not self._gone end
function Obj:GetFullName() if self._badName then error("GetFullName: boom") end return self._full end
function Obj:GetWorld() return self._world end

function F.new()
    local W = { byPath = {}, printed = {}, loadMapHooks = {}, kslCalls = 0, hooks = {}, missing = {}, all = {},
                later = {}, unregistered = 0, nextId = 0 }
    -- A world: role = "standalone" (the menu), "host" (listen server) or "client".
    function W.world(path, role)
        local w = setmetatable({ _full = "World " .. path, _role = role or "standalone" }, Obj)
        return w
    end
    -- What the LoadMap post-hook receives: a RemoteUnrealParam (world:get()).
    function W.param(w) return { get = function() return w end } end
    W.menu = W.world("/Game/Maps/NewMainMenu.NewMainMenu", "standalone")
    W.match = W.world("/Game/Maps/SmallLoweIsland/SmallMap.SmallMap", "host")
    W.pc = setmetatable({ _full = "BP_NNFirstPersonPlayerController_C /Game/Maps/NewMainMenu.NewMainMenu:PersistentLevel.PC_1", _world = W.menu }, Obj)

    local K = setmetatable({ _full = "KismetSystemLibrary /Script/Engine.Default__KismetSystemLibrary" }, Obj)
    function K:IsServer(w)
        W.kslCalls = W.kslCalls + 1
        if W.serverFails then error("IsServer: boom") end
        return w._role ~= "client"
    end
    function K:IsStandalone(w)
        W.kslCalls = W.kslCalls + 1
        if W.standaloneFails then error("IsStandalone: boom") end
        return w._role == "standalone"
    end
    W.ksl = K
    W.byPath["/Script/Engine.Default__KismetSystemLibrary"] = K
    W.byPath["/Script/Engine.KismetSystemLibrary:IsValid"] = setmetatable({}, {
        __call = function(_, cdo, o) return not (o._gone or o._garbage) end,
        __index = { IsValid = function() return true end } })

    W.env = {
        StaticFindObject = function(p)
            local o = W.byPath[p]
            if o then return o end
            return setmetatable({ _gone = true, _full = "None" }, Obj)
        end,
        FindFirstOf = function(short) if short == "PlayerController" then return W.pc end return nil end,
        RegisterLoadMapPostHook = function(fn) W.loadMapHooks[#W.loadMapHooks + 1] = fn end,
        FindAllOf = function(short) return W.all[short] end,
        RegisterHook = function(path, pre, post)
            if W.missing[path] then error("Tried to register a hook with Lua function 'RegisterHook' but no UFunction with the specified name was found.") end
            W.nextId = W.nextId + 1
            local list = W.hooks[path] or {}
            W.hooks[path] = list
            list[#list + 1] = { pre = pre, post = post, id = W.nextId }
            return W.nextId, W.nextId + 100000
        end,
        UnregisterHook = function(path, pre)
            local list = W.hooks[path] or {}
            for i = #list, 1, -1 do if list[i].id == pre then table.remove(list, i) W.unregistered = W.unregistered + 1 end end
        end,
        ExecuteInGameThreadWithDelay = function(ms, fn) W.later[#W.later + 1] = { ms = ms, fn = fn } end,
        LoopInGameThreadWithDelay = function(ms, fn) W.later[#W.later + 1] = { ms = ms, fn = fn, loop = true } return #W.later end,
        CancelDelayedAction = function() end,
    }
    -- A UE4SS hook parameter (RemoteUnrealParam).
    function W.p(v) return { get = function() return v end } end
    function W.fire(path, ...)
        local n = 0
        for _, h in ipairs(W.hooks[path] or {}) do n = n + 1 h.pre(...) end
        return n
    end
    function W.firePost(path, ...) for _, h in ipairs(W.hooks[path] or {}) do if h.post then h.post(...) end end end
    function W.count(path) return #(W.hooks[path] or {}) end
    function W.runLater()
        local l = W.later
        W.later = {}
        for _, e in ipairs(l) do e.fn() end
        return #l
    end
    return W
end

-- Installs W's globals into _G. UE4SS's async helpers fail loudly: Difficulty must not use them.
function F.install(W)
    for k, v in pairs(W.env) do _G[k] = v end
    _G.LoopAsync = function() error("Difficulty must not use LoopAsync") end
    _G.ExecuteInGameThread = function() error("Difficulty must not use ExecuteInGameThread") end
    _G.print = function(s) W.printed[#W.printed + 1] = (tostring(s):gsub("\n$", "")) end
end

-- A fake core.net (core stories 22 and 23) and core.has for story 5. N.values: full key -> int (what the host
-- published, as a client reads it); N.status: a reason every read returns ("no-state", "version"); N.compat: PlayerState
-- object -> true or a reason (what compatible() answers on the host, default "absent"); N.role: what publish sees
-- ("host", "standalone", "client"). versionsCompatible applies core's netCompat rule (net/presence.lua).
function F.net(o)
    o = o or {}
    local N = { values = o.values or {}, status = o.status, compat = o.compat or {}, role = o.role or "host",
                published = {}, reads = 0, compatCalls = {}, features = o.features }
    local function parse(v)
        if type(v) ~= "string" then return nil end
        local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
        if not a then return nil end
        return { tonumber(a), tonumber(b), tonumber(c) }
    end
    local function cmp(x, y) for i = 1, 3 do if x[i] ~= y[i] then return x[i] < y[i] and -1 or 1 end end return 0 end
    local function eff(v, nc) if nc then return parse(nc) end local p = parse(v) return p[1] == 0 and { 0, p[2], 0 } or { p[1], 0, 0 } end
    function N.publish(key, v)
        if N.role == "client" then error("nucleus.net.publish: only the host publishes (this machine is a client)", 0) end
        if N.role == "standalone" then return false, "standalone" end
        if type(key) ~= "string" or not key:match("^.+%.[A-Za-z0-9_]+$") or math.tointeger(v) == nil then error("nucleus.net.publish: bad key or value", 0) end
        N.published[#N.published + 1] = { key, v }
        N.values[key] = v
        return true
    end
    function N.read(key, lo, hi)
        N.reads = N.reads + 1
        if N.status then return nil, N.status end
        local v = N.values[key]
        if v == nil then return nil, "absent" end
        if v < lo or v > hi then return nil, "out-of-bounds" end
        return v
    end
    function N.compatible(ps, modId)
        if N.role == "client" then error("nucleus.net.compatible: only the host knows presence (this machine is a client)", 0) end
        N.compatCalls[#N.compatCalls + 1] = modId
        local r = N.compat[ps]
        if r == true then return true end
        return false, r or "absent"
    end
    function N.versionsCompatible(aV, aNC, bV, bNC)
        local a, b = parse(aV), parse(bV)
        if not a or not b or (aNC and not parse(aNC)) or (bNC and not parse(bNC)) then error("nucleus.net.versionsCompatible: not x.y.z", 0) end
        if (aNC and cmp(parse(aNC), a) > 0) or (bNC and cmp(parse(bNC), b) > 0) then error("nucleus.net.versionsCompatible: netCompat above version", 0) end
        return cmp(a, eff(bV, bNC)) >= 0 and cmp(b, eff(aV, aNC)) >= 0
    end
    function N.has(name)
        if N.features then return N.features[name] == true end
        return name:match("^net%.") ~= nil
    end
    return N
end

function F.harness(name)
    local H = { passed = 0, failed = 0 }
    function H.ok(cond, what, detail)
        if cond then H.passed = H.passed + 1 else H.failed = H.failed + 1; io.stdout:write("FAIL " .. what .. (detail ~= nil and (" -- " .. tostring(detail)) or "") .. "\n") end
    end
    function H.eq(got, want, what) H.ok(got == want, what, "got " .. tostring(got) .. ", want " .. tostring(want)) end
    function H.done()
        io.stdout:write(("%s: %d passed, %d failed\n"):format(name, H.passed, H.failed))
        os.exit(H.failed == 0 and 0 or 1)
    end
    return H
end

return F
