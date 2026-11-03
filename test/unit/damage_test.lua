-- Unit tests for Scripts/damage.lua: knob-mechanics.md steps 1-5 and the grab decision, with the I/O matrix rows of
-- story 3 that are pure math, the 200-hit distribution (CAP-10) and the survivable cap (20 of 20 at 26 HP, Spread 50).
-- Run from the repo root:  texlua test/unit/damage_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("damage_test")
local ok, eq = H.ok, H.eq
local D = require("damage")
local function near(a, b, what, tol) ok(type(a) == "number" and math.abs(a - b) <= (tol or 1e-9), what, "got " .. tostring(a) .. ", want " .. tostring(b)) end

local NIGHTMARE, HARD, NORMAL, EASY = 0, 1, 2, 3

-- ---------------------------------------------------------------- scaling (steps 1-2)
near(D.scaled(50, { enemyDamage = 17 }, HARD, "meek"), 17, "Hard, base 17: Meek 50 -> 17")
near(D.scaled(50, { enemyDamage = 17 }, HARD, "stalker"), 17, "Hard, base 17: Stalker 50 -> 17")
near(D.scaled(100, { enemyDamage = 17 }, HARD, "apex"), 34, "Hard, base 17: Apex 100 -> 34")
near(D.scaled(25, { ["dmg.stalker"] = 200 }, NORMAL, "stalker"), 50, "Normal, Stalker 200%: 50")
near(D.scaled(25, { ["dmg.stalker"] = 200 }, NORMAL, "meek"), 25, "Normal, Stalker 200%: Meek 25")
near(D.scaled(100, { ["dmg.apex"] = 0 }, HARD, "apex"), 0, "Apex 0%: 0")
near(D.scaled(100, { enemyDamage = 25 }, NIGHTMARE, "meek"), 25, "Nightmare, base 25: 100 -> 25")
near(D.scaled(25, { enemyDamage = 25, ["dmg.leech"] = 300 }, NIGHTMARE, nil), 6.25, "unattributed: base ratio only (no row)")
near(D.scaled(45, {}, EASY, "monster"), 45, "all Default: ratio 1")
eq(D.scaled(50, { enemyDamage = 17 }, 7, "meek"), nil, "unknown difficulty: nil")
eq(D.scaled(50, { enemyDamage = 17 }, 1.5, "meek"), nil, "non-integer difficulty: nil")
near(D.expected({ enemyDamage = 25 }, NIGHTMARE, "meek"), 25, "E: Nightmare, base 25")
near(D.expected({ ["dmg.stalker"] = 50 }, NIGHTMARE, "stalker"), 50, "E: Nightmare, Stalker 50%")
near(D.expected({}, HARD, "meek"), 50, "E with Default values: the game's own standard")

-- acts: Default knobs leave the hit alone
eq(D.acts({}, "meek"), false, "acts: all Default -> false")
eq(D.acts({ ["dmg.stalker"] = 200 }, "meek"), false, "acts: another enemy's row -> false")
eq(D.acts({ ["dmg.stalker"] = 200 }, "stalker"), true, "acts: the enemy's row -> true")
eq(D.acts({ ["dmg.stalker"] = 200 }, nil), false, "acts: unattributed ignores rows")
eq(D.acts({ enemyDamage = 17 }, nil), true, "acts: Enemy Damage -> true")
eq(D.acts({ spread = 20 }, nil), true, "acts: Damage Spread -> true")
eq(D.acts({ spread = 0 }, "meek"), false, "acts: Spread 0 is no randomness (as Default)")
eq(D.acts(nil, "meek"), false, "acts: no values")

-- ---------------------------------------------------------------- the grab decision
do
    local g = D.grab(100, { enemyDamage = 25 }, NIGHTMARE, "meek", true)
    ok(g.game == "e" and g.decision == "s" and g.flip == 101, "flip: Nightmare, base 25, 100 HP, own player -> survivable, temp 101")
    g = D.grab(100, { enemyDamage = 25 }, NIGHTMARE, "meek", false)
    ok(g.game == "e" and g.decision == "e" and g.flip == nil, "remote victim: the game's decision, no flip")
    g = D.grab(100, { enemyDamage = 17 }, HARD, "meek", true)
    ok(g.game == "s" and g.decision == "s" and g.flip == nil, "same decision: no flip")
    g = D.grab(40, { enemyDamage = 100 }, NORMAL, "meek", true)
    ok(g.game == "s" and g.decision == "e" and g.flip == 0.01, "execution flip: temp 0.01")
    g = D.grab(25, {}, NORMAL, "meek", true)
    ok(g.game == "e" and g.decision == "e", "hp = standard: execution (game's own test, <= 0)")
    g = D.grab(50, { enemyDamage = 0 }, NIGHTMARE, "meek", true)
    ok(g.decision == "s" and g.flip == 101, "base 0: always survivable")
    eq(D.grab(100, {}, 9, "meek", true), nil, "unknown difficulty: no decision")
    eq(D.flipValue("s", EASY), 18, "flip value: standard + 1")
end

-- ---------------------------------------------------------------- applied, compensation (steps 4, 4a)
eq(D.applied("execution", 25, 100), 100, "execution: at least Health")
eq(D.applied("execution", 120, 100), 120, "execution: more than Health stays")
eq(D.applied("survivable", 30, 26), 25, "survivable: capped at Health - 1")
eq(D.applied("survivable", 30, 0.5), 0, "survivable below 1 HP: never negative")
eq(D.applied("hit", 120, 100), 120, "other hits: uncapped")
do
    local new, planned = D.compensate(100, 50, 17)
    ok(new == 133 and planned == 83, "compensate: Health 100, stock 50, applied 17 -> 133, planned 83")
    new, planned = D.compensate(100, 100, 0)
    ok(new == 200 and planned == 100, "zero: Health unchanged after the native")
    new, planned = D.compensate(20, 25, 50)
    ok(math.abs(new - 0.01) < 1e-9 and math.abs(planned - (0.01 - 25)) < 1e-9, "lowering: floor 0.01, the hit decides death")
    new, planned = D.compensate(100, 17, 34)
    ok(new == 83 and planned == 66, "lowering above the floor")
end
do -- the matrix rows end to end (no spread)
    local p = D.hit(50, { enemyDamage = 17 }, HARD, "meek", "hit", 100)
    ok(p.scaled == 17 and p.rolled == 17 and p.applied == 17 and p.planned == 83, "scaled hit: Health 83")
    p = D.hit(100, { enemyDamage = 17 }, HARD, "apex", "hit", 100)
    eq(p.applied, 34, "Apex: applied 34")
    p = D.hit(100, { ["dmg.apex"] = 0 }, HARD, "apex", "hit", 100)
    ok(p.applied == 0 and p.planned == 100, "zero: applied 0, Health unchanged")
    p = D.hit(100, { enemyDamage = 25 }, NIGHTMARE, "meek", "survivable", 100)
    ok(p.applied == 25 and p.planned == 75, "flip: about 75 HP")
    p = D.hit(25, { enemyDamage = 10 }, NORMAL, "meek", "execution", 20)
    ok(p.applied >= 20 and p.planned <= 0, "execution: dies")
    eq(D.hit(0, { enemyDamage = 17 }, HARD, "watcher", "hit", 100), nil, "stock 0 (imposter): nothing")
    eq(D.hit(50, { enemyDamage = 17 }, 5, "meek", "hit", 100), nil, "unknown difficulty: nothing")
end

-- ---------------------------------------------------------------- the roll (step 3)
do
    local seq = { 0.5, 0.25 }
    local i = 0
    local function rng() i = i + 1 return seq[(i - 1) % #seq + 1] end
    eq(D.roll(25, 0, rng), 25, "spread 0: no roll")
    eq(D.roll(25, nil, rng), 25, "spread Default: no roll")
    eq(i, 0, "spread 0: rng never called")
    eq(D.roll(0, 50, rng), 0, "scaled 0: 0")
    -- u1 = 1 - 0.5, u2 = 0.25: cos(pi/2) = 0 -> the mean.
    eq(D.roll(25, 20, rng), 25, "Box-Muller with cos 0: the mean")
    -- Always out of range -> clamped after the resamples.
    local calls = 0
    local function far() calls = calls + 1 return calls % 2 == 1 and 0.9999999 or 0 end -- u1 tiny, cos(0) = 1
    local x = D.roll(25, 20, far)
    eq(x, 35, "beyond 2 sigma 9 times: clamped to mean + 2 sigma")
    eq(calls, 2 * (D.SPREAD_RESAMPLES + 1), "8 resamples after the first draw")
    ok(D.roll(10, 50, function() return 0.123 end) >= 0, "never below 0")
    local r = D.roll(17, 30, math.random)
    eq(r, math.floor(r * 10 + 0.5) / 10, "rounded to 0.1 HP")
end

-- CAP-10: Damage Spread 20, scaled 25: 200 hits, mean 25 +- 1, sd 4..6, none outside 15..35.
do
    math.randomseed(12345)
    local n, sum, sq, out = 200, 0, 0, 0
    for _ = 1, n do
        local x = D.roll(25, 20, math.random)
        sum = sum + x
        sq = sq + x * x
        if x < 15 or x > 35 then out = out + 1 end
    end
    local mean = sum / n
    local sd = math.sqrt(sq / n - mean * mean)
    ok(math.abs(mean - 25) <= 1, "200 hits: mean 25 +- 1", mean)
    ok(sd >= 4 and sd <= 6, "200 hits: sd 4..6", sd)
    eq(out, 0, "200 hits: none outside 15..35")
    -- Several seeds, so the result isn't one lucky draw.
    local bad = 0
    for seed = 1, 20 do
        math.randomseed(seed)
        local s2, q2, o2 = 0, 0, 0
        for _ = 1, n do local x = D.roll(25, 20, math.random) s2 = s2 + x q2 = q2 + x * x if x < 15 or x > 35 then o2 = o2 + 1 end end
        local m2 = s2 / n
        local d2 = math.sqrt(q2 / n - m2 * m2)
        if math.abs(m2 - 25) > 1 or d2 < 4 or d2 > 6 or o2 > 0 then bad = bad + 1 end
    end
    eq(bad, 0, "200 hits: holds for 20 seeds")
end

-- CAP-10: a survivable grab at 26 HP with Spread 50 leaves the victim at 1 HP or more, 20 of 20 grabs.
do
    math.randomseed(777)
    local alive = 0
    for _ = 1, 20 do
        -- Nightmare, base 25: E = 25, 26 - 25 > 0 -> survivable; scaled 25 rolled with Spread 50 (up to 50).
        local g = D.grab(26, { enemyDamage = 25, spread = 50 }, NIGHTMARE, "meek", true)
        local p = D.hit(100, { enemyDamage = 25, spread = 50 }, NIGHTMARE, "meek", g.decision == "s" and "survivable" or "execution", 26, math.random)
        if 26 - p.applied >= 1 and p.planned >= 1 - 1e-9 then alive = alive + 1 end
    end
    eq(alive, 20, "survivable cap: 20 of 20 at 1 HP or more")
end

-- ---------------------------------------------------------------- fmt
eq(D.fmt(17), "17", "fmt 17")
eq(D.fmt(16.5), "16.5", "fmt 16.5")
eq(D.fmt(0.01), "0.01", "fmt 0.01")
eq(D.fmt(100), "100", "fmt 100")
eq(D.fmt(0), "0", "fmt 0")
eq(D.fmt(-0.001), "0", "fmt -0")
eq(D.fmt(nil), "?", "fmt nil")

H.done()
