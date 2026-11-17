-- Difficulty: world-preset sync (spec-difficulty-v1 story 6, presets-and-ui.md "Preset lifecycle" and "The sidecar").
-- The UE4SS adapter around sidecar.lua: a Lua "rows" model (every knob Default on each open; story 7 shows and edits
-- it), hooks on the create-world screen CreateServer_C (open, select, save, update, delete) and on
-- BP_GameInstance_C:CreateSteamSession (the capture), and atomic writes of the sidecar file.
--
-- UE4SS hooks on Blueprint functions are post-only (docs/blueprint-mods.md Q2): each callback runs after the
-- function's body. So the "before" state of a save or delete isn't read in a pre-hook; it is this model's own: the
-- entries match the game's presets one to one since the last open (count), and the selector index is re-read at the
-- end of every callback (the selection the Delete button acts on). After each change the entries are reconciled with
-- the game's names again, so anything the model missed falls back to matching by index and name, as on open.
--
-- Holds no UObject: the screen comes from each hook's context; the model is plain Lua data. Every hook body runs under
-- pcall with one log line per failure. File IO goes through opts.fs (io/os by default) so the tests can inject
-- failures.
local knobs = require("knobs")
local sidecar = require("sidecar")

local M = {}
M.CS = "/Game/Graphics/MainMenu/CreateServer.CreateServer_C"
M.GI = "/Game/FirstPerson/Blueprints/BP_GameInstance.BP_GameInstance_C"
M.PATHS = {
    construct = M.CS .. ":Construct",
    select = M.CS .. ":BndEvt__CreateServer_MultipleSelectBox_11_K2Node_ComponentBoundEvent_31_OnSelectionChanged__DelegateSignature",
    save = M.CS .. ":BndEvt__CreateServer_Create_1_K2Node_ComponentBoundEvent_33_OnButtonClickedEvent__DelegateSignature",
    update = M.CS .. ":BndEvt__CreateServer_Create_2_K2Node_ComponentBoundEvent_34_OnButtonClickedEvent__DelegateSignature",
    delete = M.CS .. ":BndEvt__CreateServer_Create_4_K2Node_ComponentBoundEvent_35_OnButtonClickedEvent__DelegateSignature",
    capture = M.GI .. ":CreateSteamSession",
}
M.ORDER = { "construct", "select", "save", "update", "delete", "capture" }
M.PATHS_LIB = "/Script/Engine.Default__BlueprintPathsLibrary"
M.HOOK_RETRY_MS, M.HOOK_RETRIES = 3000, 3
M.MAX_DIR = 1024  -- bytes of ProjectSavedDir
M.MAX_GAME_NAME = 1024 -- a preset name longer than this is cut (it can't be written anyway: sidecar.MAX_NAME)

-- The knob text a match starts with: dev.lua's when it sets one (tests), else the text captured at CreateSteamSession,
-- else nil (every knob Default).
function M.source(devKnobs, captured)
    if devKnobs ~= nil then return devKnobs end
    return captured
end

-- ---------------------------------------------------------------- default file IO
local FS = {}
function FS.read(path, max)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local ok, s = pcall(f.read, f, max)
    f:close()
    if not ok then return nil, s end
    return s or ""
end
function FS.write(path, text)
    local f, err = io.open(path, "wb")
    if not f then return nil, err end
    local okW, errW = f:write(text)
    local okC, errC = f:close()
    if not okW then return nil, errW end
    if not okC then return nil, errC end
    return true
end
function FS.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end
function FS.rename(a, b) return os.rename(a, b) end
function FS.remove(p) return os.remove(p) end
M.FS = FS

-- ---------------------------------------------------------------- reading the screen (never kept)
local function get(p)
    if type(p) == "table" or type(p) == "userdata" then
        local ok, v = pcall(function() return p:get() end)
        if ok then return v end
    end
    return p
end
local function str(v)
    if type(v) == "string" then return v end
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return nil
end
local function selector(screen) return screen.MultipleSelectBox_11 end
local function selIndex(screen)
    local ok, i = pcall(function() local s = selector(screen) return s:GetSelectedIndex() end)
    if ok and math.type(i) == "integer" then return i end
    if ok and type(i) == "number" and i == math.floor(i) then return math.tointeger(i) end
    return nil
end
local function presetCount(screen)
    local ok, n = pcall(function() return screen.PresetsSavObj.Presets:GetArrayNum() end)
    if ok and type(n) == "number" and n >= 0 then return math.tointeger(n) end
    return nil
end
-- The game's preset names from the selector: Items[1] is "None", Items[i + 1] is preset i - 1.
local function presetNames(screen, count)
    local items = selector(screen).Items
    local n = items:GetArrayNum()
    if n ~= count + 1 then return nil, ("the selector has %s items for %d presets"):format(tostring(n), count) end
    local names = {}
    for i = 2, math.min(n, sidecar.MAX_ENTRIES + 1) do
        local s = str(items[i])
        if s == nil then return nil, ("selector item %d is not text"):format(i) end
        if #s > M.MAX_GAME_NAME then s = s:sub(1, M.MAX_GAME_NAME) end
        names[#names + 1] = s
    end
    return names
end

-- ---------------------------------------------------------------- the adapter
local A = {}
A.__index = A

-- opts: say(level, fmt, ...), warnOnce(key, fmt, ...), name (the mod's name constant), fs (FS's shape, optional),
-- savedDir (a function returning ProjectSavedDir, optional: the engine's by default).
function M.new(opts)
    local self = setmetatable({ o = opts, fs = opts.fs or FS, rows = {}, session = nil, entries = nil, path = nil,
                                sel = nil, hooked = {} }, A)
    return self
end

function A:say(level, fmt, ...) self.o.say(level, fmt, ...) end

-- The engine's ProjectSavedDir (follows -userdir), as text, or nil and why.
function A:savedDir()
    local ok, d
    if self.o.savedDir then ok, d = pcall(self.o.savedDir)
    else ok, d = pcall(function() return StaticFindObject(M.PATHS_LIB):ProjectSavedDir() end) end
    if not ok then return nil, tostring(d) end
    d = str(d)
    if type(d) ~= "string" or d == "" then return nil, "empty" end
    if #d > M.MAX_DIR or d:find("[%c]") then return nil, "not a usable path" end
    if not d:match("[/\\]$") then d = d .. "/" end
    return d
end

function A:file() return self.path end

-- Atomic replace: <file>.tmp, the old file to <file>.bak, .tmp to the file, .bak removed. On any failure the previous
-- file is restored or kept, with one WARN.
function A:writeFile(text)
    local fs, path = self.fs, self.path
    local tmp, bak = path .. ".tmp", path .. ".bak"
    local ok, err = fs.write(tmp, text)
    if not ok then
        pcall(fs.remove, tmp)
        self:say("warn", "sidecar: could not write %s (%s); the previous file is kept", tmp, tostring(err))
        return false
    end
    local had = fs.exists(path)
    if had then
        pcall(fs.remove, bak)
        ok, err = fs.rename(path, bak)
        if not ok then
            pcall(fs.remove, tmp)
            self:say("warn", "sidecar: could not move %s aside (%s); the previous file is kept", path, tostring(err))
            return false
        end
    end
    ok, err = fs.rename(tmp, path)
    if not ok then
        local back = had and fs.rename(bak, path)
        pcall(fs.remove, tmp)
        self:say("warn", "sidecar: could not replace %s (%s); the previous file is %s", path, tostring(err),
            (not had) and "absent, as before" or (back and "restored" or "kept as .bak"))
        return false
    end
    if had or fs.exists(bak) then pcall(fs.remove, bak) end -- also a .bak an interrupted write left
    self.lastText = text
    return true
end

-- Rebuilds the entries in the game's order (reconcile) and writes when the text differs from the last known file.
function A:sync(names, force)
    local entries, text = sidecar.reconcile(names, self.entries, self.o.name)
    self.entries = entries
    if force or text ~= self.lastText then return self:writeFile(text), true end
    return true, false
end

local function enc(s) return sidecar.encodeName(s) end

-- Construct (after the body): the rows start at Default; read and reconcile the sidecar.
function A:onOpen(screen)
    self.rows, self.entries, self.path, self.lastText = {}, nil, nil, nil
    self.sel = selIndex(screen)
    local dir, why = self:savedDir()
    if not dir then self:say("warn", "sidecar: ProjectSavedDir is %s; presets not synced for this open", tostring(why)) return end
    local count = presetCount(screen)
    if not count then self:say("warn", "sidecar: the screen's presets can't be read; presets not synced for this open") return end
    local names, whyN = presetNames(screen, count)
    if not names then self:say("warn", "sidecar: %s; presets not synced for this open", tostring(whyN)) return end
    self.path = dir .. "SaveGames/" .. self.o.name .. "_WorldPresets.txt"
    local text = self.fs.read(self.path, sidecar.MAX_BYTES + 1)
    local fromBak = false
    if text == nil then
        text = self.fs.read(self.path .. ".bak", sidecar.MAX_BYTES + 1)
        fromBak = text ~= nil
        if fromBak then self:say("info", "PRESETS sidecar taken from %s.bak (an interrupted write)", self.path) end
    end
    local entries, problems = sidecar.parse(text)
    if #problems > 0 then
        self:say("warn", "sidecar %s: %d problem(s), every one Default; first: %s", self.path, #problems, problems[1])
    end
    self.entries = entries
    self.lastText = (not fromBak) and text or nil
    local changed
    if text == nil and #names == 0 then
        changed = false -- no file and no preset: nothing to write yet
        self.entries = {}
    else
        local _
        _, changed = self:sync(names)
    end
    self:say("info", "PRESETS open presets=%d entries=%d changed=%s", count, #entries, tostring(changed))
end

-- OnSelectionChanged (after the body): index > 0 -> rows = that preset's entry; 0 ("None") -> rows unchanged.
function A:onSelect(screen)
    local idx = selIndex(screen)
    self.sel = idx
    if not idx or idx <= 0 then self:say("info", "PRESETS select none (rows unchanged)") return end
    local e = self.entries and self.entries[idx]
    self.rows = sidecar.copy(e and e.values)
    if not e then self:say("debug", "PRESETS select index=%d has no entry (not synced); rows Default", idx - 1) end
    self:say("info", "PRESETS select index=%d name=%s knobs=%s", idx - 1, e and enc(e.name) or "?", knobs.describe(self.rows))
end

-- Save (after the body): when the game's count grew by one, append an entry with the rows' values and PresetName.
function A:onSave(screen)
    if not self.entries then return end
    local count = presetCount(screen)
    local before = #self.entries
    if count ~= before + 1 then
        self:say("debug", "PRESETS save: %s presets, %d before; nothing saved", tostring(count), before)
        self.sel = selIndex(screen)
        return
    end
    local names, why = presetNames(screen, count)
    if not names then self:say("warn", "sidecar: %s; save not synced", tostring(why)) self.entries = nil return end
    local name = str(screen.PresetName) or names[#names]
    if #name > M.MAX_GAME_NAME then name = name:sub(1, M.MAX_GAME_NAME) end
    self.entries[#self.entries + 1] = { index = before, name = name, values = sidecar.copy(self.rows) }
    if #enc(name) > sidecar.MAX_NAME then
        self:say("warn", "sidecar: preset %d's name is over %d bytes encoded; its values are not saved (Default)", before, sidecar.MAX_NAME)
    end
    self:sync(names, true)
    self.sel = selIndex(screen)
    self:say("info", "PRESETS save index=%d name=%s knobs=%s", before, enc(name), knobs.describe(self.rows))
end

-- Update (after the body; the selection is unchanged): entry idx-1 = the rows' values.
function A:onUpdate(screen)
    if not self.entries then return end
    local idx = selIndex(screen) or self.sel
    if not idx or idx <= 0 or not self.entries[idx] then
        self:say("debug", "PRESETS update: selector index %s has no entry; nothing updated", tostring(idx))
        return
    end
    local count = presetCount(screen)
    local names, why = count and presetNames(screen, count)
    if not names then self:say("warn", "sidecar: %s; update not synced", tostring(why or "no preset count")) return end
    local e = self.entries[idx]
    e.values = sidecar.copy(self.rows)
    self:sync(names, true)
    self:say("info", "PRESETS update index=%d name=%s knobs=%s", idx - 1, enc(e.name), knobs.describe(self.rows))
end

-- Delete (after the body; the game reset the selection to None): when the count shrank by one, remove the entry the
-- selection pointed at before the click (self.sel). If that doesn't leave the game's names, the first name that
-- differs is the one removed.
function A:onDelete(screen)
    if not self.entries then return end
    local count = presetCount(screen)
    local before = #self.entries
    local idx = self.sel
    self.sel = selIndex(screen)
    if count ~= before - 1 then
        self:say("debug", "PRESETS delete: %s presets, %d before; nothing deleted", tostring(count), before)
        return
    end
    local names, why = presetNames(screen, count)
    if not names then self:say("warn", "sidecar: %s; delete not synced", tostring(why)) self.entries = nil return end
    local function leaves(i)
        if not i or i <= 0 or i > before then return false end
        local k = 0
        for j, e in ipairs(self.entries) do
            if j ~= i then k = k + 1 if names[k] ~= e.name then return false end end
        end
        return true
    end
    if not leaves(idx) then
        idx = nil
        for j = 1, before do if leaves(j) then idx = j break end end
    end
    local removed
    if idx then removed = table.remove(self.entries, idx) end
    self:sync(names, true) -- re-indexes; matches by name when idx was not found
    self:say("info", "PRESETS delete index=%s name=%s", idx and tostring(idx - 1) or "?", removed and enc(removed.name) or "?")
end

-- CreateSteamSession (after the body; before the travel): the rows become the session's live values.
function A:onCapture()
    self.session = knobs.encode(self.rows)
    self:say("info", "PRESETS capture knobs=%s", knobs.describe(self.rows))
end

function A:sessionText() return self.session end

-- ---------------------------------------------------------------- hooks
local BODY = {
    construct = function(self, ctx) self:onOpen(get(ctx)) end,
    select = function(self, ctx) self:onSelect(get(ctx)) end,
    save = function(self, ctx) self:onSave(get(ctx)) end,
    update = function(self, ctx) self:onUpdate(get(ctx)) end,
    delete = function(self, ctx) self:onDelete(get(ctx)) end,
    capture = function(self) self:onCapture() end,
}

-- Registers the hooks not yet registered; returns how many are still missing. A failed RegisterHook costs a full
-- object scan, so this runs only at ready and a bounded number of times after each LoadMap.
function A:tryHooks()
    local missing = 0
    for _, key in ipairs(M.ORDER) do
        local path = M.PATHS[key]
        if not self.hooked[key] then
            local body = BODY[key]
            local okR = pcall(RegisterHook, path, function(ctx)
                local ok, err = pcall(body, self, ctx)
                if not ok then self:say("error", "PRESETS %s hook failed: %s", key, tostring(err)) end
            end)
            if okR then self.hooked[key] = true else missing = missing + 1 end
        end
    end
    return missing
end

function A:retryHooks(left)
    if self:tryHooks() == 0 then return end
    if left <= 0 then self:say("debug", "PRESETS some hooks still missing; retried at the next LoadMap") return end
    pcall(ExecuteInGameThreadWithDelay, M.HOOK_RETRY_MS, function()
        local ok, err = pcall(self.retryHooks, self, left - 1)
        if not ok then self.o.warnOnce("presets-retry", "PRESETS hook retry failed: %s", tostring(err)) end
    end)
end

-- At ready and after every LoadMap: register what's missing, retried a few times.
function A:onLoadMap() self:retryHooks(M.HOOK_RETRIES) end

return M
