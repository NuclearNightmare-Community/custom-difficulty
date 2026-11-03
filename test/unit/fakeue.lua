-- A fake UE4SS for Difficulty's unit tests: worlds, a player controller, KismetSystemLibrary (IsServer, IsStandalone,
-- IsValid as a UFunction) and the globals main.lua and world.lua use (StaticFindObject, FindFirstOf,
-- RegisterLoadMapPostHook, print). Plus a tiny test harness.
local F = {}

local Obj = {}
Obj.__index = Obj
function Obj:IsValid() return not self._gone end
function Obj:GetFullName() if self._badName then error("GetFullName: boom") end return self._full end
function Obj:GetWorld() return self._world end

function F.new()
    local W = { byPath = {}, printed = {}, loadMapHooks = {}, kslCalls = 0 }
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
    }
    return W
end

-- Installs W's globals into _G. UE4SS's async helpers fail loudly: Difficulty must not use them.
function F.install(W)
    for k, v in pairs(W.env) do _G[k] = v end
    _G.LoopAsync = function() error("Difficulty must not use LoopAsync") end
    _G.ExecuteInGameThread = function() error("Difficulty must not use ExecuteInGameThread") end
    _G.print = function(s) W.printed[#W.printed + 1] = (tostring(s):gsub("\n$", "")) end
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
