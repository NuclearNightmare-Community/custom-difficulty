-- Difficulty: the knob rows on the create-world screen (spec-difficulty-v1 story 7; presets-and-ui.md "Our rows").
-- Two parts:
--   * pure data and functions, unit-tested without the game: LABELS and HELP per knob key (the labels are mod.json's,
--     the ranges and steps knobs.lua's), ORDER (the screen's order) and defaults(diff, cm), the value each knob has
--     on a difficulty (EDiffculty 0..3 = Nightmare, Hard, Normal, Easy; tokens follow Classified Minimum instead);
--   * the adapter (new): 19 game-style rows, each holding a slider with a number box, declared once per Lua state
--     through core's public UI (core.ui.row, core.ui.slider, core.ui.place; core 0.15.0). It is the only file that
--     calls core.ui. Core rebuilds the rows on every open of the screen.
-- The presets model (presets.lua, model.rows) is the only truth: a slider's onChange writes it, refresh() pushes it
-- back into the sliders (after an open or a preset select), follow(diff, cm) moves every Default slider (and its hint)
-- to the screen's own Difficulty and Classified Minimum. Holds no UObject: opened(screen) reads the screen only
-- during the call. Every callback runs under pcall with one log line per failure.
local knobs = require("knobs")
local env = require("env")
local tokens = require("tokens")

local M = {}
M.HOST, M.BOX, M.LIKE = "createServer", "VerticalBox_202", "Overlay_28"
M.KNOB_AFTER = "Overlay_28"   -- the Difficulty row: the five knob rows go right after it
M.ENEMY_AFTER = "Overlay_738" -- the enemy slots: the fourteen per-enemy rows go right after them
M.NORMAL = 2                  -- an unknown difficulty index uses Normal
M.MAX_HELP_LINES, M.MAX_HELP_BYTES, M.MAX_LABEL = 8, 512, 64
M.WALK_MAX, M.WALK_DEPTH = 1024, 16 -- the bounded walk for the enemy-slot anchor (about 263 widgets on V8.2.3)

M.KNOB_KEYS = { "enemyDamage", "spread", "revives", "cold", "frostbite" }
-- Every row in the screen's order: the five knob rows, then the per-enemy rows (knobs.ROWS).
M.ORDER = {}
for _, k in ipairs(M.KNOB_KEYS) do M.ORDER[#M.ORDER + 1] = k end
for _, r in ipairs(knobs.ROWS) do M.ORDER[#M.ORDER + 1] = "dmg." .. r end
M.IS_KNOB = {}
for _, k in ipairs(M.KNOB_KEYS) do M.IS_KNOB[k] = true end

-- The labels (mod.json's settings labels; modjson_test checks they agree).
M.ENEMY = { meek = "Meek", mimic = "Mimic", psycho = "Psycho", husk = "Husk", watcher = "Watcher", stalker = "Stalker",
            slugQueen = "Slug Queen", apex = "Apex Predator", worm = "Worm", leech = "Leech", bat = "Bat",
            infectedDog = "Infected Dog", infectedPlayer = "Infected Player", monster = "Playable Monster" }
M.LABELS = { enemyDamage = "Enemy Damage", spread = "Damage Spread", revives = "Reinforcement Tokens",
             cold = "Cold Exposure", frostbite = "Frostbite Damage" }
for _, r in ipairs(knobs.ROWS) do M.LABELS["dmg." .. r] = "Damage: " .. M.ENEMY[r] end

-- A number as text: at most two decimals, no trailing zeros ("17", "0.5").
local function num(v) return (string.format("%.2f", v):gsub("%.?0+$", "")) end
M.num = num
local function range(key)
    local k = knobs.BY_KEY[key]
    local s = "Range " .. num(k.min) .. "-" .. num(k.max)
    if k.step ~= 1 then s = s .. ", in steps of " .. num(k.step) end
    return s .. "."
end

-- The stock hit of each enemy (knob-mechanics.md; presets-and-ui.md "Our rows").
local STOCK = {
    scaled = "Stock hit: Nightmare 100, Hard 50, Normal 25, Easy 17.",
    exec = "Stock hit: Nightmare 100, Hard 50, Normal 25, Easy 17; execution 100.",
    hundred = "Stock hit: 100 on every difficulty.",
    leech = "Stock hit: 25 on every difficulty.",
    monster = "Stock hit: 45 on every difficulty.",
    seen = "Stock hit: 100 on Nightmare.",
}
local ENEMY_STOCK = { meek = "exec", mimic = "scaled", psycho = "scaled", husk = "scaled", watcher = "scaled",
                      stalker = "exec", slugQueen = "hundred", apex = "hundred", worm = "hundred",
                      infectedPlayer = "hundred", leech = "leech", monster = "monster", bat = "seen", infectedDog = "seen" }

local FOLLOW = "Empty = follow Difficulty."
M.HELP = {
    enemyDamage = table.concat({ "HP taken from a standard enemy hit. Other enemies scale by the same ratio.",
        "Default: Nightmare 100, Hard 50, Normal 25, Easy 17.", range("enemyDamage"), FOLLOW }, "\n"),
    spread = table.concat({ "Random spread of every enemy hit: the width of a bell curve, in % of the hit.",
        "Default: 0 on every difficulty.", range("spread"), FOLLOW }, "\n"),
    revives = table.concat({ "Reinforcement tokens the team can use in a match.",
        "Default follows Classified Minimum: Nightmare 2, Hard 4, Normal 6, Easy 8.", range("revives"),
        "Empty = follow Difficulty (Classified Minimum)." }, "\n"),
    cold = table.concat({ "How fast players freeze, in % of Normal's rate. 0 = never freezes.",
        "Default: Nightmare 200, Hard 133, Normal 100, Easy 50.", range("cold"), FOLLOW }, "\n"),
    frostbite = table.concat({ "HP lost per second at a full freeze meter.",
        "Default: 1 on every difficulty.", range("frostbite"), FOLLOW }, "\n"),
}
for _, r in ipairs(knobs.ROWS) do
    M.HELP["dmg." .. r] = table.concat({ "Damage of the " .. M.ENEMY[r] .. "'s hits, in % after Enemy Damage.",
        STOCK[ENEMY_STOCK[r]], range("dmg." .. r), "Empty = 100." }, "\n")
end

-- An index 0..3, or nil.
local function index(v)
    if math.type(v) == "integer" then return (v >= 0 and v <= 3) and v or nil end
    if type(v) == "number" and v == math.floor(v) and v >= 0 and v <= 3 then return math.tointeger(v) end
    return nil
end
M.index = index

-- defaults(diff, cm) -> { key = value } for every row, and a list of problems (an index that isn't 0..3 uses Normal).
-- diff and cm are the screen's Diffculty and Minium Classified (EDiffculty 0..3 = Nightmare, Hard, Normal, Easy).
function M.defaults(diff, cm)
    local problems = {}
    local d, c = index(diff), index(cm)
    if d == nil then d = M.NORMAL problems[#problems + 1] = ("Difficulty %s is not 0..3; Normal used"):format(tostring(diff)) end
    if c == nil then c = M.NORMAL problems[#problems + 1] = ("Classified Minimum %s is not 0..3; Normal used"):format(tostring(cm)) end
    local t = {
        enemyDamage = knobs.STANDARD[d],
        cold = math.floor(200 / env.DIVISOR[d] + 0.5),
        revives = tokens.LIMIT[c],
        spread = 0,
        frostbite = 1,
    }
    for _, r in ipairs(knobs.ROWS) do t["dmg." .. r] = 100 end
    return t, problems
end

-- A slider value the model accepts: nil (Default) or a finite number inside the knob's range.
local function acceptable(key, v)
    if v == nil then return true end
    local k = knobs.BY_KEY[key]
    return type(v) == "number" and v == v and v >= k.min and v <= k.max
end
M.acceptable = acceptable

-- ---------------------------------------------------------------- the adapter
local A = {}
A.__index = A

-- opts: ui (core.ui), model (presets' adapter: model.rows is read and written at each call), say(level, fmt, ...),
-- warnOnce(key, fmt, ...), levels (screen -> diff, cm; presets.levels), hasAnchor (screen, name -> true | false | nil;
-- the bounded walk below by default).
function M.new(opts)
    return setmetatable({ o = opts, ui = opts.ui, model = opts.model, rowH = {}, sliderH = {}, declared = false,
                          enemyAt = M.ENEMY_AFTER, diff = nil, cm = nil }, A)
end

function A:say(level, fmt, ...) self.o.say(level, fmt, ...) end

local function intent(after) return { host = M.HOST, container = M.BOX, after = after } end

-- The slider's onChange: the model's value for key (nil = Default). Logged so the driver (another Lua state) can read
-- the model and the text a capture would encode.
function A:onChange(key, v)
    local ok, err = pcall(function()
        if not acceptable(key, v) then error(("value %s is not nil or a number in %s's range"):format(tostring(v), key), 0) end
        self.model.rows[key] = v
    end)
    if not ok then self:say("error", "ROWS %s change failed: %s; not written", key, tostring(err)) return end
    self:say("info", "ROWS change %s=%s rows=%s", key, v == nil and "default" or num(v), knobs.encode(self.model.rows))
end

-- Declares the 19 rows and sliders once per Lua state (core rebuilds them on every open). Returns true when all were
-- declared; a failure is one ERROR line and the rows declared so far stay.
function A:declare()
    if self.declared then return true end
    self.declared = true
    local U = self.ui
    local defs = M.defaults(M.NORMAL, M.NORMAL)
    for _, key in ipairs(M.ORDER) do
        local k = knobs.BY_KEY[key]
        local ok, err = pcall(function()
            local rh = U.row.create{ id = "r-" .. key, like = M.LIKE, label = M.LABELS[key], help = M.HELP[key],
                                     place = intent(M.IS_KNOB[key] and M.KNOB_AFTER or M.ENEMY_AFTER) }
            self.rowH[key] = rh
            self.sliderH[key] = U.slider.create{ id = "s-" .. key, min = k.min, max = k.max, step = k.step,
                value = self.model.rows[key], defaultValue = defs[key], hint = num(defs[key]),
                onChange = function(_, v) self:onChange(key, v) end, place = { row = rh } }
        end)
        if not ok then self:say("error", "ROWS %s could not be declared: %s", key, tostring(err)) return false end
    end
    self:say("info", "ROWS declared %d", #M.ORDER)
    return true
end

-- Every slider shows the model's value (nil: Default).
function A:refresh()
    for _, key in ipairs(M.ORDER) do
        local h = self.sliderH[key]
        if h then
            local v = self.model.rows[key]
            if not acceptable(key, v) then v = nil end
            local ok, err = pcall(self.ui.slider.set, h, v)
            if not ok then self.o.warnOnce("rows-set-" .. key, "ROWS %s could not be set: %s", key, tostring(err)) end
        end
    end
end

-- Every slider's default and hint follow diff and cm (core moves only the Default ones).
function A:follow(diff, cm)
    local defs, problems = M.defaults(diff, cm)
    for _, p in ipairs(problems) do self.o.warnOnce("rows-index", "ROWS %s", p) end
    for _, key in ipairs(M.ORDER) do
        local h = self.sliderH[key]
        if h then
            local ok, err = pcall(self.ui.slider.setDefault, h, defs[key], num(defs[key]))
            if not ok then self.o.warnOnce("rows-default-" .. key, "ROWS %s default could not be set: %s", key, tostring(err)) end
        end
    end
    if diff ~= self.diff or cm ~= self.cm then
        self.diff, self.cm = diff, cm
        self:say("info", "ROWS follow difficulty=%s classified=%s enemyDamage=%s cold=%s revives=%s", tostring(diff), tostring(cm),
            num(defs.enemyDamage), num(defs.cold), num(defs.revives))
    end
end

-- presets' onRows: after an open, a preset select (index > 0) and a picker change.
function A:sync(diff, cm)
    self:refresh()
    self:follow(diff, cm)
end

-- ---------------------------------------------------------------- the screen (read during the call only)
local function nameOf(w)
    local ok, n = pcall(function() return w:GetFName():ToString() end)
    return ok and type(n) == "string" and n or nil
end
local function childCount(w)
    local ok, n = pcall(function() return w:GetChildrenCount() end)
    n = ok and tonumber(n) or 0
    return n
end
local function childAt(w, i)
    local ok, c = pcall(function() return w:GetChildAt(i) end)
    if ok and c ~= nil then
        local okV, v = pcall(function() return c:IsValid() end)
        if okV and v then return c end
    end
    return nil
end

-- Whether the open screen's widget tree has a widget named name: a bounded depth-first walk from the root (at most
-- WALK_MAX widgets, WALK_DEPTH levels). nil when the tree can't be read.
function M.hasNamed(screen, name)
    local ok, root = pcall(function() return screen.WidgetTree.RootWidget end)
    if not ok or root == nil then return nil end
    local ws, ds, seen = { root }, { 0 }, 0
    while #ws > 0 and seen < M.WALK_MAX do
        local w, d = ws[#ws], ds[#ds]
        ws[#ws], ds[#ds] = nil, nil
        seen = seen + 1
        if nameOf(w) == name then return true end
        if d < M.WALK_DEPTH then
            for i = childCount(w) - 1, 0, -1 do
                local c = childAt(w, i)
                if c then ws[#ws + 1], ds[#ds + 1] = c, d + 1 end
            end
        end
    end
    return false
end

-- The game.watch callback's opened: the enemy-slot anchor checked (missing: the per-enemy rows follow the knob rows,
-- one WARN per Lua state), then every Default slider follows the screen's Difficulty and Classified Minimum.
function A:opened(screen)
    local has = self.o.hasAnchor or M.hasNamed
    local okA, found = pcall(has, screen, M.ENEMY_AFTER)
    if okA and found ~= nil then
        local want = found and M.ENEMY_AFTER or M.KNOB_AFTER
        if not found then
            self.o.warnOnce("rows-anchor", "ROWS %s is missing from the create-world screen; the per-enemy rows follow the knob rows", M.ENEMY_AFTER)
        end
        if want ~= self.enemyAt then
            for _, r in ipairs(knobs.ROWS) do
                local h = self.rowH["dmg." .. r]
                if h then
                    local ok, err = pcall(self.ui.place, h, intent(want))
                    if not ok then self.o.warnOnce("rows-place", "ROWS the per-enemy rows could not be moved: %s", tostring(err)) end
                end
            end
            self.enemyAt = want
        end
    elseif not okA then
        self.o.warnOnce("rows-anchor-read", "ROWS the screen's tree could not be read: %s", tostring(found))
    end
    local diff, cm = self.o.levels(screen)
    self:follow(diff, cm)
end

-- Watches the create-world screen (once per Lua state): each opened runs opened(screen) under pcall. Returns true
-- when the watcher is registered; a failure is one ERROR line.
function A:watch()
    if self.watching then return true end
    local ok, err = pcall(function() return self.ui.game.watch(M.HOST, function(screen, info)
        if type(info) ~= "table" or info.event ~= "opened" then return end
        local okO, errO = pcall(self.opened, self, screen)
        if not okO then self:say("error", "ROWS opened failed: %s", tostring(errO)) end
    end) end)
    if not ok then
        self:say("error", "ROWS could not watch the create-world screen: %s; the rows don't follow its first state", tostring(err))
        return false
    end
    self.watching = true
    return true
end

return M
