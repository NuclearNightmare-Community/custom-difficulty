-- Difficulty: the enemy-damage math (spec-difficulty-v1, knob-mechanics.md "The hit the mod applies" steps 1-5 and
-- "Survivable grabs"). Pure Lua, no UE4SS: unit-tested without the game. values is a parsed knob table
-- (knobs.parse): nil means Default.
local knobs = require("knobs")
local M = {}

local STANDARD = knobs.STANDARD
M.STANDARD = STANDARD
M.SPREAD_RESAMPLES = 8

-- standard(d) -> the standard hit for EDiffculty d (0..3), or nil for anything else.
function M.standard(d)
    if type(d) ~= "number" or d ~= math.floor(d) then return nil end
    return STANDARD[d]
end

-- ratio(values, d) = base / standard[d], base = Enemy Damage (Default: the standard hit, ratio 1).
function M.ratio(values, d)
    local s = M.standard(d)
    if not s then return nil end
    local base = values and values.enemyDamage
    if base == nil then return 1 end
    return base / s
end

-- pct(values, row) -> the enemy's % (Default and unattributed: 100).
function M.pct(values, row)
    if row == nil then return 100 end
    local v = values and values["dmg." .. row]
    if v == nil then return 100 end
    return v
end

-- acts(values, row) -> true when any knob a hit by this enemy depends on is not Default (Enemy Damage, Damage
-- Spread, the enemy's row). When it is false, the mod leaves the hit and the grab alone.
function M.acts(values, row)
    if not values then return false end
    if values.enemyDamage ~= nil or (values.spread ~= nil and values.spread > 0) then return true end
    return row ~= nil and values["dmg." .. row] ~= nil
end

-- scaled(stock, values, d, row) = stock x base/standard[d] x pct/100 (step 2).
function M.scaled(stock, values, d, row)
    local r = M.ratio(values, d)
    if not r or type(stock) ~= "number" then return nil end
    return stock * r * M.pct(values, row) / 100
end

-- expected(values, d, row): E, the hit a grab is decided with (no roll).
function M.expected(values, d, row)
    local s = M.standard(d)
    if not s then return nil end
    return M.scaled(s, values, d, row)
end

-- decide(hp, E) -> "s" (survivable) when hp - E > 0, else "e" (execution). The game's own test is decide(hp, standard).
function M.decide(hp, E) return (hp - E > 0) and "s" or "e" end

-- flipValue(decision, d): the temporary Health that makes the game's test pick decision.
function M.flipValue(decision, d)
    local s = M.standard(d)
    if not s then return nil end
    return decision == "s" and (s + 1) or 0.01
end

local function round1(x) return math.floor(x * 10 + 0.5) / 10 end

-- roll(scaled, spread, rng) (step 3): with spread s > 0, a normal draw, mean scaled, sigma = s% x scaled, truncated to
-- mean +- 2 sigma (8 resamples, then clamped), never below 0, rounded to 0.1 HP. rng() returns a uniform number in
-- [0, 1) (math.random). With s = 0 (or nil), rolled = scaled.
function M.roll(scaled, spread, rng)
    if not spread or spread <= 0 or scaled <= 0 then return scaled end
    local sigma = spread / 100 * scaled
    local lo, hi = scaled - 2 * sigma, scaled + 2 * sigma
    local x
    for _ = 1, M.SPREAD_RESAMPLES + 1 do
        local u1, u2 = 1 - rng(), rng() -- u1 in (0, 1]
        x = scaled + sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
        if x >= lo and x <= hi then break end
    end
    if x < lo then x = lo elseif x > hi then x = hi end
    if x < 0 then x = 0 end
    return round1(x)
end

-- applied(kind, rolled, hp) (steps 4 and 4a): an execution takes at least hp; a survivable grab's hit is capped at
-- hp - 1 (never below 0); any other hit is the roll.
function M.applied(kind, rolled, hp)
    if kind == "execution" then return math.max(rolled, hp) end
    if kind == "survivable" then return math.max(0, math.min(rolled, hp - 1)) end
    return rolled
end

-- compensate(hp, stock, applied) -> newHealth, planned. Health is raised (or lowered, never below 0.01) before the
-- native call so that the native's own "Health - stock" leaves "hp - applied"; planned is what Health must read after
-- the native (the guard). With the 0.01 floor, planned is 0.01 - stock (the hit itself decides death).
function M.compensate(hp, stock, applied)
    local new = hp + stock - applied
    if new < hp and new < 0.01 then new = 0.01 end
    return new, new - stock
end

-- hit(stock, values, d, row, kind, hp, rng) -> plan { stock, scaled, rolled, applied, new, planned } or nil when the
-- difficulty is unknown or the stock amount isn't a positive number.
function M.hit(stock, values, d, row, kind, hp, rng)
    if type(stock) ~= "number" or stock <= 0 or type(hp) ~= "number" then return nil end
    local scaled = M.scaled(stock, values, d, row)
    if not scaled then return nil end
    local rolled = M.roll(scaled, values and values.spread, rng or math.random)
    local applied = M.applied(kind, rolled, hp)
    local new, planned = M.compensate(hp, stock, applied)
    return { stock = stock, scaled = scaled, rolled = rolled, applied = applied, new = new, planned = planned }
end

-- grab(hp, values, d, row, mine) -> { E, game, decision, flip } or nil (unknown difficulty). mine: the victim is
-- this machine's own player (the only victim whose decision the host changes in v1); for any other victim the
-- recorded decision is the game's. flip is the temporary Health, or nil when no change is needed.
function M.grab(hp, values, d, row, mine)
    local s = M.standard(d)
    local E = M.expected(values, d, row)
    if not s or not E or type(hp) ~= "number" then return nil end
    local game = M.decide(hp, s)
    local wanted = M.decide(hp, E)
    local decision = mine and wanted or game
    local flip = (decision ~= game) and M.flipValue(decision, d) or nil
    return { E = E, game = game, decision = decision, flip = flip }
end

-- fmt(x): a number for the log, at most two decimals, no trailing zeros ("17", "16.5", "0.01").
function M.fmt(x)
    if type(x) ~= "number" then return "?" end
    local s = string.format("%.2f", x):gsub("%.?0+$", "")
    if s == "-0" or s == "" then s = "0" end
    return s
end

return M
