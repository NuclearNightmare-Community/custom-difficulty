-- Unit tests for Scripts/presets.lua (story 6): the hook flows on a fake CreateServer_C (open, save, select, None,
-- update, delete, a refused save, the capture), the knob source order, a failing hook body, hooks retried while
-- CreateServer_C is missing, the sidecar path, and the atomic write with failures injected (in memory, and on a real
-- temp directory with io/os).
-- Run from the repo root:  texlua test/unit/presets_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("presets_test")
local ok, eq = H.ok, H.eq
local presets = require("presets")
local sc = require("sidecar")
local HDR = "# CustomDifficulty world presets, format 2\n"
local FILE = "C:/nn/copy/_userdir/Saved/SaveGames/CustomDifficulty_WorldPresets.txt"

local W, D, P, logs
local function setup(o)
    o = o or {}
    W = F.new()
    F.install(W)
    D = F.fs()
    logs = {}
    local function say(level, fmt, ...) logs[#logs + 1] = (level == "info" and "" or (level:upper() .. " ")) .. string.format(fmt, ...) end
    local said = {}
    P = presets.new{ say = say, name = "CustomDifficulty", fs = D,
                     warnOnce = function(k, fmt, ...) if not said[k] then said[k] = true say("warn", fmt, ...) end end }
    if o.missing then for _, k in ipairs(o.missing) do W.missing[presets.PATHS[k]] = true end end
    P:onLoadMap()
    return P
end
local function count(pat) local n = 0 for _, l in ipairs(logs) do if l:find(pat) then n = n + 1 end end return n end
local function last(pat) local r for _, l in ipairs(logs) do if l:find(pat) then r = l end end return r end
local function writes() local n = 0 for _, l in ipairs(D.log) do if l == "write " .. FILE .. ".tmp" then n = n + 1 end end return n end

-- ---------------------------------------------------------------- hooks
do
    setup()
    for _, k in ipairs(presets.ORDER) do eq(W.count(presets.PATHS[k]), 1, "hooked once: " .. k) end
    P:onLoadMap()
    for _, k in ipairs(presets.ORDER) do eq(W.count(presets.PATHS[k]), 1, "a second LoadMap: still once: " .. k) end
    eq(#W.later, 0, "all hooked: no retry scheduled")
end
do -- CreateServer_C not loaded yet: retried a bounded number of times, then at the next LoadMap
    setup{ missing = { "construct", "select", "save", "update", "delete" } }
    eq(W.count(presets.PATHS.capture), 1, "the game instance's hook registers at once")
    eq(W.count(presets.PATHS.construct), 0, "CreateServer_C missing: no Construct hook")
    local n = 0
    while #W.later > 0 and n < 10 do n = n + W.runLater() end
    eq(n, presets.HOOK_RETRIES, "bounded retries after one LoadMap")
    W.missing = {}
    P:onLoadMap()
    eq(W.count(presets.PATHS.construct), 1, "the class loaded: hooked at the next LoadMap")
    eq(W.count(presets.PATHS.capture), 1, "the capture hook not registered twice")
    eq(count("^WARN"), 0, "retries: no WARN")
end

-- ---------------------------------------------------------------- the knob source
do
    eq(presets.source("cold=50", "enemyDamage=17"), "cold=50", "dev.lua knobs win over the capture")
    eq(presets.source(nil, "enemyDamage=17"), "enemyDamage=17", "no dev knobs: the capture")
    eq(presets.source(nil, nil), nil, "neither: nil (every knob Default)")
    eq(presets.source("", "enemyDamage=17"), "", "dev knobs set to empty still win")
end

-- ---------------------------------------------------------------- open: no file, two presets
do
    setup()
    local S = F.screen(W, { "A", "B" })
    S:open()
    eq(D.files[FILE], HDR .. "0\tA\t\n1\tB\t\n", "no file, 2 presets: written with 2 Default entries")
    eq(last("^PRESETS open"), "PRESETS open presets=2 entries=0 changed=true", "open line")
    ok(D.files[FILE .. ".tmp"] == nil and D.files[FILE .. ".bak"] == nil, "no .tmp or .bak left")
    local w = writes()
    S:open()
    eq(writes(), w, "matching file: no write")
    eq(last("^PRESETS open"), "PRESETS open presets=2 entries=2 changed=false", "matching file: changed=false")
    eq(count("^WARN"), 0, "no WARN")
end
do -- no file, no preset: nothing written
    setup()
    local S = F.screen(W, {})
    S:open()
    eq(D.files[FILE], nil, "no file and no preset: nothing written")
    eq(last("^PRESETS open"), "PRESETS open presets=0 entries=0 changed=false", "open line")
    S:save("A")
    eq(D.files[FILE], HDR .. "0\tA\t\n", "then a save writes the file")
end
do -- moved, stale, other format, bad lines: one WARN per read
    setup()
    D.files[FILE] = HDR .. "0\tB\tcold=50\n1\tGone\tcold=2\n"
    local S = F.screen(W, { "A", "B" })
    S:open()
    eq(D.files[FILE], HDR .. "0\tA\t\n1\tB\tcold=50\n", "moved preset and stale entry: rewritten in the game's order")
    eq(last("^PRESETS open"), "PRESETS open presets=2 entries=2 changed=true", "changed=true")
    D.files[FILE] = "# CustomDifficulty world presets, format 3\n0\tA\tcold=1\n"
    S:open()
    eq(D.files[FILE], HDR .. "0\tA\t\n1\tB\t\n", "other format: rewritten as format 2, all Default")
    eq(count("^WARN sidecar .*1 problem%(s%).*not format 2"), 1, "other format: one WARN")
    D.files[FILE] = HDR .. "x\tA\tcold=1\n1\tB\tbogus=1;cold=999;spread=4\n"
    S:open()
    eq(count("^WARN sidecar .*: 3 problem%(s%), every one Default; first: line 2: index 'x'"), 1, "bad lines: one WARN with the count and the first")
    eq(D.files[FILE], HDR .. "0\tA\t\n1\tB\tspread=4\n", "bad lines: Default, valid keys kept")
end

-- ---------------------------------------------------------------- the story's flow
do
    setup()
    D.files[FILE] = HDR .. "0\tMine\tcold=70\n"
    local S = F.screen(W, { "Mine" })
    S:open()
    eq(last("^PRESETS open"), "PRESETS open presets=1 entries=1 changed=false", "baseline preset kept")
    S:save("DT6-A")
    eq(last("^PRESETS save"), "PRESETS save index=1 name=DT6-A knobs=all Default", "save A")
    S:save("DT6-B")
    eq(last("^PRESETS save"), "PRESETS save index=2 name=DT6-B knobs=all Default", "save B")
    eq(D.files[FILE], HDR .. "0\tMine\tcold=70\n1\tDT6-A\t\n2\tDT6-B\t\n", "after two saves")
    S:select(1)
    eq(last("^PRESETS select"), "PRESETS select index=0 name=Mine knobs=cold=70", "select the baseline: rows = its entry")
    ok(P.rows.cold == 70, "rows.cold = 70")
    S:select(2)
    eq(last("^PRESETS select"), "PRESETS select index=1 name=DT6-A knobs=all Default", "select A")
    ok(next(P.rows) == nil, "rows all Default")
    -- Story 7's sliders set the rows (rows_test.lua); here the test sets them to prove update writes the rows.
    P.rows = { enemyDamage = 17 }
    S:update()
    eq(last("^PRESETS update"), "PRESETS update index=1 name=DT6-A knobs=enemyDamage=17", "update A")
    eq(D.files[FILE], HDR .. "0\tMine\tcold=70\n1\tDT6-A\tenemyDamage=17\n2\tDT6-B\t\n", "update changes only A")
    S:select(0)
    eq(last("^PRESETS select"), "PRESETS select none (rows unchanged)", "select None")
    ok(P.rows.enemyDamage == 17, "None: rows unchanged")
    S:capture()
    eq(last("^PRESETS capture"), "PRESETS capture knobs=enemyDamage=17", "capture line")
    eq(P:sessionText(), "enemyDamage=17", "the capture is the session text")
    S:select(2)
    S:delete()
    eq(last("^PRESETS delete"), "PRESETS delete index=1 name=DT6-A", "delete A")
    eq(D.files[FILE], HDR .. "0\tMine\tcold=70\n1\tDT6-B\t\n", "delete A leaves B and the baseline")
    -- A selection changed without the handler (SetSelectedOption alone): the names find the deleted preset.
    S:setOption(2)
    S:delete()
    eq(last("^PRESETS delete"), "PRESETS delete index=1 name=DT6-B", "delete B (selection not seen): found by name")
    eq(D.files[FILE], HDR .. "0\tMine\tcold=70\n", "only the baseline left")
    -- Reopen: rows back to Default.
    S:open()
    ok(next(P.rows) == nil, "open: rows Default")
    eq(count("^WARN"), 0, "the flow: no WARN")
    eq(count("^ERROR"), 0, "the flow: no ERROR")
end
do -- refused save (empty PresetName), delete with None selected, update with None
    setup()
    local S = F.screen(W, { "A" })
    S:open()
    local w = writes()
    S:save("")
    eq(count("^PRESETS save"), 0, "empty name: no save line")
    eq(writes(), w, "empty name: no write")
    S:select(0)
    S:delete()
    eq(count("^PRESETS delete"), 0, "delete with None: nothing")
    S:update()
    eq(count("^PRESETS update"), 0, "update with None: nothing")
    eq(writes(), w, "no write")
end
do -- duplicate names: the game acts on the first match; the entries follow by index
    setup()
    D.files[FILE] = HDR .. "0\tX\tcold=1\n1\tX\tcold=2\n"
    local S = F.screen(W, { "X", "X" })
    S:open()
    eq(last("^PRESETS open"), "PRESETS open presets=2 entries=2 changed=false", "duplicates: each keeps its entry")
    S:select(2) -- SetSelectedOption(2) is "X": GetSelectedIndex finds the first
    eq(last("^PRESETS select"), "PRESETS select index=0 name=X knobs=cold=1", "duplicates: select resolves to the first, as the game")
    S:delete()
    eq(D.files[FILE], HDR .. "0\tX\tcold=2\n", "duplicates: deleting removes the first entry, as the game removes the first preset")
end
do -- a long name: not written, one WARN at save
    setup()
    local S = F.screen(W, {})
    S:open()
    local long = ("%"):rep(50) -- 150 bytes encoded
    S:save(long)
    eq(count("^WARN sidecar: preset 0's name is over 128 bytes encoded"), 1, "long name: one WARN at save")
    eq(D.files[FILE], HDR, "long name: entry not written")
    S:save("B")
    eq(D.files[FILE], HDR .. "1\tB\t\n", "the next preset keeps its index")
    S:open()
    eq(count("^WARN"), 1, "reopen: no new WARN for the long name")
end

-- ---------------------------------------------------------------- story 7: onRows and the two pickers
do
    setup()
    local calls = {}
    P.o.onRows = function(d, cm) calls[#calls + 1] = tostring(d) .. "/" .. tostring(cm) end
    eq(W.count(presets.PATHS.difficulty), 1, "the Difficulty picker's handler hooked")
    eq(W.count(presets.PATHS.classified), 1, "the Classified Minimum picker's handler hooked")
    ok(presets.PATHS.difficulty:find("MultipleSelectBox_6_K2Node_ComponentBoundEvent_5_OnSelectionChanged", 1, true), "Difficulty: MultipleSelectBox_6's handler")
    ok(presets.PATHS.classified:find("CreateServer_MultipleSelectBox_K2Node_ComponentBoundEvent_16_OnSelectionChanged", 1, true), "Classified: MultipleSelectBox's handler")
    D.files[FILE] = HDR .. "0\tA\tenemyDamage=17\n"
    local S = F.screen(W, { "A" })
    S.levels[1] = { 0, 3 }
    S:open()
    eq(table.concat(calls, ","), "2/2", "open: onRows once, with the screen's Normal / Normal")
    S:select(1)
    eq(calls[#calls], "0/3", "select A: onRows with the preset's Difficulty and Classified")
    eq(P.rows.enemyDamage, 17, "select A: rows set before onRows")
    local n = #calls
    S:select(0)
    eq(#calls, n, "select None: no onRows (rows unchanged)")
    S:pick(1)
    eq(calls[#calls], "1/3", "Difficulty picker: onRows with the new Difficulty")
    S:pickClassified(0)
    eq(calls[#calls], "1/0", "Classified picker: onRows with the new Classified Minimum")
    S.Diffculty = "x"
    S:pick("x")
    eq(calls[#calls], "nil/0", "unreadable Diffculty: nil (rows.lua uses Normal)")
    eq(count("^ERROR"), 0, "onRows flow: no ERROR")
    -- the sidecar can't be synced: the rows still start Default and onRows still runs
    W.savedDir = ""
    P.rows = { cold = 5 }
    n = #calls
    S:open()
    eq(#calls, n + 1, "open without a sidecar: onRows still runs")
    ok(next(P.rows) == nil, "open without a sidecar: rows Default")
    -- onOpen throwing: rows Default, onRows runs, one ERROR from the hook
    W.savedDir = "C:/nn/copy/_userdir/Saved/"
    S.countFails = true
    D.files[FILE] = nil
    P.rows = { cold = 5 }
    local realOpen = P.onOpen
    P.onOpen = function() error("open broke") end
    S:open()
    P.onOpen = realOpen
    ok(next(P.rows) == nil, "onOpen throws: rows Default")
    eq(#calls, n + 2, "onOpen throws: onRows still runs")
    eq(count("^ERROR PRESETS construct hook failed: .*open broke$"), 1, "onOpen throws: one ERROR")
    eq(select(1, presets.levels({ Diffculty = 3, ["Minium Classified"] = 1 })), 3, "levels: Diffculty")
    eq(select(2, presets.levels({ Diffculty = 3, ["Minium Classified"] = 1 })), 1, "levels: Minium Classified")
    eq(select(1, presets.levels(setmetatable({}, { __index = function() error("gone") end }))), nil, "levels: unreadable -> nil")
    eq(select(1, presets.levels({ Diffculty = 1.5 })), nil, "levels: not an integer -> nil")
end

-- ---------------------------------------------------------------- failures
do -- the directory
    setup()
    W.savedDir = ""
    local S = F.screen(W, { "A" })
    S:open()
    eq(count("^WARN sidecar: ProjectSavedDir is empty; presets not synced for this open"), 1, "empty dir: one WARN")
    eq(#D.log, 0, "empty dir: no file touched")
    S:save("B")
    eq(count("^PRESETS save"), 0, "not synced: no save")
    W.savedDir = "C:/nn/copy/_userdir/Saved"
    S:open()
    ok(D.files[FILE] ~= nil, "a dir without a trailing slash works")
    W.savedDirFails = true
    S:open()
    eq(count("^WARN sidecar: ProjectSavedDir is .*boom"), 1, "ProjectSavedDir throws: one WARN")
end
do -- a failing hook body: caught, one ERROR line per failure
    setup()
    local S = F.screen(W, { "A" })
    S.countFails = true
    S:open()
    eq(count("^WARN sidecar: the screen's presets can't be read"), 1, "unreadable presets: one WARN")
    S.countFails = false
    S:open()
    S.selectFails = true
    S:select(1)
    eq(count("^PRESETS select none"), 1, "GetSelectedIndex fails: treated as none")
    S.selectFails = false
    P.onSave = function() error("boom") end
    S:save("B")
    eq(count("^ERROR PRESETS save hook failed: .*boom"), 1, "a failing hook body: one ERROR")
    S:save("C")
    eq(count("^ERROR PRESETS save hook failed"), 2, "each failure its own line")
end
do -- write failures: the previous file intact, one WARN
    setup()
    D.files[FILE] = HDR .. "0\tA\tcold=5\n"
    local S = F.screen(W, { "A" })
    S:open()
    D.fail.write = "%.tmp$"
    S:save("B")
    eq(D.files[FILE], HDR .. "0\tA\tcold=5\n", ".tmp can't be written: previous file intact")
    eq(count("^WARN sidecar: could not write"), 1, ".tmp failure: one WARN")
    ok(D.files[FILE .. ".tmp"] == nil, "no .tmp left")
    D.fail.write = nil
    D.fail.rename = "%.tmp$"
    S:select(2)
    S:update()
    eq(D.files[FILE], HDR .. "0\tA\tcold=5\n", "rename .tmp fails: previous file restored")
    eq(count("^WARN sidecar: could not replace .*restored"), 1, "rename failure: one WARN, restored")
    ok(D.files[FILE .. ".bak"] == nil and D.files[FILE .. ".tmp"] == nil, "no .bak or .tmp left")
    D.fail.rename = "Presets%.txt$"
    S:update()
    eq(D.files[FILE], HDR .. "0\tA\tcold=5\n", "moving the old file aside fails: previous file kept")
    eq(count("^WARN sidecar: could not move"), 1, "move-aside failure: one WARN")
    D.fail.rename = nil
    S:update()
    eq(D.files[FILE], HDR .. "0\tA\tcold=5\n1\tB\t\n", "once IO works again the next write has everything")
end
do -- an interrupted write left only the .bak: it is read and the file restored
    setup()
    D.files[FILE .. ".bak"] = HDR .. "0\tA\tcold=9\n"
    local S = F.screen(W, { "A" })
    S:open()
    eq(D.files[FILE], HDR .. "0\tA\tcold=9\n", ".bak only: its values kept, the file written again")
    ok(D.files[FILE .. ".bak"] == nil, "the .bak removed after the write")
end

do -- the sidecar exists but can't be read (locked, denied): one WARN, no write, the file intact
    setup()
    D.files[FILE] = HDR .. "0\tA\tcold=5\n"
    D.fail.read = "Presets%.txt$"
    local S = F.screen(W, { "A", "B" })
    S:open()
    eq(count("^WARN sidecar: .* can't be read %(.*Permission denied%); presets not synced for this open$"), 1, "unreadable file: one WARN")
    eq(writes(), 0, "unreadable file: no write")
    eq(D.files[FILE], HDR .. "0\tA\tcold=5\n", "unreadable file: intact")
    S:save("C")
    S:select(1)
    S:update()
    S:delete()
    eq(writes(), 0, "unreadable file: later hooks in the same open write nothing")
    eq(D.files[FILE], HDR .. "0\tA\tcold=5\n", "unreadable file: still intact")
end
do -- the selector out of step with Presets (an extra item, a dropped one, a non-text item) at open
    for _, case in ipairs({ { "itemsDelta", 1, "the selector has 4 items for 2 presets" }, { "itemsDelta", -1, "the selector has 2 items for 2 presets" },
                            { "badItem", 2, "selector item 2 is not text" } }) do
        setup()
        local S = F.screen(W, { "A", "B" })
        S[case[1]] = case[2]
        S:open()
        eq(count("^WARN sidecar: " .. case[3]:gsub("%p", "%%%0") .. "; presets not synced for this open$"), 1, case[3] .. ": one WARN at open")
        eq(writes(), 0, case[3] .. ": no write at open")
        S:save("C")
        S:select(1)
        S:update()
        S:delete()
        eq(writes(), 0, case[3] .. ": the later hooks of the open write nothing")
        eq(count("^PRESETS save"), 0, case[3] .. ": no save line")
    end
end
do -- a save, then a delete, that find the selector out of step: not synced, and nothing more for that open
    setup()
    local S = F.screen(W, { "A" })
    S:open()
    local w = writes()
    S.itemsDelta = 1
    S:save("B")
    eq(count("^WARN sidecar: the selector has 4 items for 2 presets; save not synced$"), 1, "save out of step: one WARN")
    eq(writes(), w, "save out of step: no write")
    S.itemsDelta = nil
    S:save("C")
    S:select(1)
    S:update()
    S:delete()
    eq(writes(), w, "after a save not synced: the open's later hooks write nothing")

    setup()
    S = F.screen(W, { "A", "B" })
    S:open()
    w = writes()
    S:select(1)
    S.badItem = 2
    S:delete()
    eq(count("^WARN sidecar: selector item 2 is not text; delete not synced$"), 1, "delete out of step: one WARN")
    eq(writes(), w, "delete out of step: no write")
    S.badItem = nil
    S:save("C")
    S:select(1)
    S:update()
    eq(writes(), w, "after a delete not synced: the open's later hooks write nothing")
end
do -- the retry can't be scheduled: one WARN naming the error
    setup{ missing = { "construct" } }
    W.later = {}
    ExecuteInGameThreadWithDelay = function() error("no delay: boom") end
    P:onLoadMap()
    P:onLoadMap()
    eq(count("^WARN PRESETS hook retry could not be scheduled: .*no delay: boom"), 1, "retry not scheduled: one WARN")
    F.install(W)
end

-- ---------------------------------------------------------------- the real file system (io/os), temp dir
do
    local base = os.tmpname()
    os.remove(base)
    local dir = base .. "_nnd6"
    local isWin = package.config:sub(1, 1) == "\\"
    local function mkdir(p) if isWin then os.execute('mkdir "' .. p:gsub("/", "\\") .. '" >NUL 2>NUL') else os.execute('mkdir -p "' .. p .. '"') end end
    mkdir(dir .. "/SaveGames")
    W = F.new()
    F.install(W)
    W.savedDir = dir .. "/"
    logs = {}
    P = presets.new{ say = function(level, fmt, ...) logs[#logs + 1] = (level == "info" and "" or (level:upper() .. " ")) .. string.format(fmt, ...) end,
                     warnOnce = function() end, name = "CustomDifficulty" }
    P:onLoadMap()
    local file = dir .. "/SaveGames/CustomDifficulty_WorldPresets.txt"
    local function readAll(p) local f = io.open(p, "rb") if not f then return nil end local s = f:read("a") f:close() return s end
    local S = F.screen(W, { "A", "B" })
    S:open()
    eq(readAll(file), HDR .. "0\tA\t\n1\tB\t\n", "real fs: the file written")
    S:save("C")
    eq(readAll(file), HDR .. "0\tA\t\n1\tB\t\n2\tC\t\n", "real fs: replaced (the old file existed)")
    ok(readAll(file .. ".bak") == nil and readAll(file .. ".tmp") == nil, "real fs: no .bak or .tmp left")
    -- .tmp can't be written: a directory in its place.
    mkdir(file .. ".tmp")
    S:save("D")
    eq(readAll(file), HDR .. "0\tA\t\n1\tB\t\n2\tC\t\n", "real fs: .tmp unwritable, previous file intact")
    eq(count("^WARN sidecar: could not write"), 1, "real fs: one WARN")
    if isWin then os.execute('rmdir /s /q "' .. dir:gsub("/", "\\") .. '" >NUL 2>NUL') else os.execute('rm -rf "' .. dir .. '"') end
end

H.done()
