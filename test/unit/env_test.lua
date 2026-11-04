-- Unit tests for Scripts/env.lua: the cold factor and rise scaling, the frostbite rule and its compensation (story 4's
-- matrix rows: cold scaled, cold faster, cold zero, warming, frostbite, frostbite zero, perk tick, not frostbite), and
-- the cold poll's adapter on fake characters (first sight, writes, forgetting, summary, cost).
-- Run from the repo root:  texlua test/unit/env_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("env_test")
local ok, eq = H.ok, H.eq
local env = require("env")
local function near(a, b, what, tol) ok(type(a) == "number" and math.abs(a - b) <= (tol or 1e-9), what, "got " .. tostring(a) .. ", want " .. tostring(b)) end

-- ---------------------------------------------------------------- factor
near(env.factor(50, 0), 0.25, "factor: Nightmare, cold 50 -> a quarter of Nightmare's rate")
near(env.factor(200, 0), 1, "factor: Nightmare, cold 200 = Nightmare's own rate")
near(env.factor(100, 2), 1, "factor: Normal, cold 100 = stock")
near(env.factor(200, 2), 2, "factor: Normal, cold 200 -> twice")
near(env.factor(100, 1), 0.75, "factor: Hard, cold 100 (Hard is 133%)")
near(env.factor(100, 3), 2, "factor: Easy, cold 100 (Easy is 50%)")
near(env.factor(0, 0), 0, "factor: cold 0 -> 0")
eq(env.factor(50, 4), nil, "factor: Diffculty 4 -> nil")
eq(env.factor(50, nil), nil, "factor: no difficulty -> nil")
eq(env.factor(nil, 0), nil, "factor: Default -> nil")
eq(env.factor(-1, 0), nil, "factor: negative -> nil")
eq(env.factor(0 / 0, 0), nil, "factor: NaN -> nil")

-- ---------------------------------------------------------------- rise
do
    local new, raw, applied = env.rise(0.10, 0.14, 0.25)
    near(new, 0.11, "cold scaled: rise 0.04 at factor 0.25 -> written 0.11")
    near(raw, 0.04, "cold scaled: raw 0.04")
    near(applied, 0.01, "cold scaled: applied 0.01")
    new, raw, applied = env.rise(0.50, 0.51, 2)
    near(new, 0.52, "cold faster: Normal, cold 200, rise 0.01 -> 0.02")
    new, raw, applied = env.rise(0.995, 1.0, 2)
    eq(new, 1, "cold faster: clamped at 1")
    near(applied, 0.005, "cold faster: the applied rise stops at 1")
    new = env.rise(0.30, 0.35, 0)
    near(new, 0.30, "cold zero: no rise")
    new, raw, applied = env.rise(0.50, 0.40, 0.25)
    ok(new == nil and raw == 0 and applied == 0, "warming: a fall is left alone")
    new = env.rise(0.50, 0.50, 0.25)
    eq(new, nil, "a hold is left alone")
    new = env.rise(nil, 0.30, 0.25)
    eq(new, nil, "first sight: nothing to compare, nothing written")
    eq(env.rise(0.1, "x", 0.25), nil, "unreadable Temperature: nothing written")
    eq(env.rise(0.1, 0 / 0, 0.25), nil, "NaN Temperature: nothing written")
end

-- ---------------------------------------------------------------- the frostbite rule
local frozen = { temp = 1, can = true, inside = false, infected = false, mimic = false }
local function with(k, v) local s = {} for a, b in pairs(frozen) do s[a] = b end s[k] = v return s end
ok(env.isFrostbite(1, frozen), "frostbite: amount 1, frozen outdoors")
ok(env.isFrostbite(2, frozen), "frostbite: amount 2 (perk tick)")
ok(env.isFrostbite(1, with("temp", 1.5)), "frostbite: Temperature above 1 (driver's hold)")
ok(not env.isFrostbite(3, frozen), "not frostbite: amount 3")
ok(not env.isFrostbite(1.5, frozen), "not frostbite: amount 1.5")
ok(not env.isFrostbite(1, with("temp", 0.99)), "not frostbite: Temperature < 1")
ok(not env.isFrostbite(1, with("temp", nil)), "not frostbite: Temperature unreadable")
ok(not env.isFrostbite(1, with("can", false)), "not frostbite: CanTakeTemperature false (vehicle)")
ok(not env.isFrostbite(1, with("can", nil)), "not frostbite: CanTakeTemperature unreadable")
ok(not env.isFrostbite(1, with("inside", true)), "not frostbite: inside")
ok(not env.isFrostbite(1, with("infected", true)), "not frostbite: infected")
ok(not env.isFrostbite(1, with("mimic", true)), "not frostbite: the imposter")
ok(not env.isFrostbite(1, nil), "not frostbite: no state")

-- ---------------------------------------------------------------- frostbite compensation
do
    local p = env.frostbite(100, 1, 3)
    ok(p.applied == 3 and p.new == 98 and p.planned == 97 and p.rolled == 3 and p.scaled == 3 and p.stock == 1,
        "frostbite 3, amount 1: applied 3, Health 100 -> 98 before the native's 1, 97 after")
    p = env.frostbite(100, 2, 3)
    ok(p.applied == 6 and p.new == 96 and p.planned == 94, "perk tick: amount 2, frostbite 3 -> applied 6")
    p = env.frostbite(100, 1, 0)
    ok(p.applied == 0 and p.new == 101 and p.planned == 100, "frostbite zero: applied 0, Health unchanged after the native")
    p = env.frostbite(100, 1, 1)
    ok(p.applied == 1 and p.new == 100 and p.planned == 99, "frostbite 1 (stock): nothing compensated")
    p = env.frostbite(2, 1, 5)
    ok(p.new == 0.01 and math.abs(p.planned + 0.99) < 1e-9, "frostbite: lowering floors at 0.01 (the tick decides death)")
    p = env.frostbite(50, 1, 0.5)
    ok(p.applied == 0.5 and p.new == 50.5, "frostbite 0.5 (the knob's step)")
    eq(env.frostbite(nil, 1, 3), nil, "frostbite: no Health -> nil")
end

-- ---------------------------------------------------------------- the poll adapter
do
    local now, lines = 0, {}
    local dbg = {}
    local P = env.newPoll{ say = function(level, fmt, ...) local t = level == "debug" and dbg or lines t[#t + 1] = string.format(fmt, ...) end, clock = function() return now end }
    local function ch(path, t) return { path = path, obj = { Temperature = t, w = 0 } } end
    local a, b = ch("/A", 0.10), ch("/B", 0.50)
    -- Temperature writes are counted on the fake objects.
    local function wrap(c)
        local raw = c.obj
        c.obj = setmetatable({}, { __index = raw, __newindex = function(_, k, v) raw.w = raw.w + 1 raw[k] = v end })
        c.raw = raw
        return c
    end
    a, b = wrap(a), wrap(b)
    P:tick({ a, b }, 50, 0)
    ok(a.raw.w == 0 and b.raw.w == 0, "poll: first sight writes nothing")
    a.raw.Temperature, b.raw.Temperature = 0.14, 0.45
    P:tick({ a, b }, 50, 0)
    near(a.raw.Temperature, 0.11, "poll: A's rise scaled to a quarter")
    eq(b.raw.w, 0, "poll: B warmed, untouched")
    eq(b.raw.Temperature, 0.45, "poll: B keeps the stock warming")
    a.raw.Temperature = 0.15
    P:tick({ a }, 50, 0)
    near(a.raw.Temperature, 0.12, "poll: A again, from the written value")
    eq(P.last["/B"], nil, "poll: B not seen this poll -> forgotten")
    b.raw.Temperature = 0.90
    P:tick({ a, b }, 50, 0)
    eq(b.raw.Temperature, 0.90, "poll: B seen again is a first sight (no write)")
    near(P.raw, 0.08, "poll: raw sums the game's rises")
    near(P.applied, 0.02, "poll: applied sums the written rises")
    -- Factor 1 (cold 200 on Nightmare): a rise is kept as it is, no write.
    local w = a.raw.w
    a.raw.Temperature = 0.2
    P:tick({ a }, 200, 0)
    eq(a.raw.w, w, "poll: factor 1 writes nothing")
    -- An unknown difficulty: nothing at all.
    a.raw.Temperature = 0.3
    P:tick({ a }, 50, 7)
    eq(a.raw.Temperature, 0.3, "poll: unknown difficulty -> untouched")
    -- A failed write raises (the guard backs off).
    local bad = { path = "/C", obj = setmetatable({}, { __index = function() return 0.5 end, __newindex = function() error("read-only") end }) }
    P:tick({ bad }, 50, 0)
    bad.obj = setmetatable({}, { __index = function() return 0.6 end, __newindex = function() error("read-only") end })
    ok(not pcall(P.tick, P, { bad }, 50, 0), "poll: a failed Temperature write raises")
    -- The summary: none at the first call, then one every 10 s, with the average cost.
    P:cost(40) P:cost(60) P:cost(nil)
    P:summary("core")
    eq(#lines, 0, "summary: not at the first call")
    now = 5 P:summary("core")
    eq(#lines, 0, "summary: not before 10 s")
    now = 10.1 P:summary("core")
    eq(#lines, 1, "summary: one line after 10 s")
    ok(lines[1] and lines[1]:find("^COLD raw=0%.%d%d%d%d applied=0%.%d%d%d%d factor=0%.25 polls=3 writes=%d+ players=1 avg_ms=0%.050 clock=core$"), "summary: the COLD line", lines[1])
    now = 15 P:summary("core")
    eq(#lines, 1, "summary: not again within 10 s")
    ok(dbg[1] and dbg[1]:find("^COLD timing find_ms=%? read_ms=%? write_ms=%? "), "summary: the DEBUG timing line (not measured without micros)", dbg[1])
    -- With micros: per-part averages.
    local t = 0
    local Q = env.newPoll{ say = function(level, fmt, ...) if level == "debug" then dbg[#dbg + 1] = string.format(fmt, ...) end end,
        clock = function() return now end, micros = function() t = t + 10 return t end }
    local q = wrap(ch("/Q", 0.1))
    Q:tick({ q }, 50, 0) q.raw.Temperature = 0.2 Q:tick({ q }, 50, 0)
    Q:cost(100, 40) Q:cost(100, 60)
    Q:summary("core") now = now + 11 Q:summary("core")
    ok(dbg[#dbg]:find("^COLD timing find_ms=0%.0500 read_ms=0%.0100 write_ms=0%.0100 .* reads=2$"), "summary: find, read and write averages", dbg[#dbg])
end

-- ---------------------------------------------------------------- the source: rules from AGENTS.md
do
    local f = assert(io.open(ROOT .. "/Scripts/env.lua", "r"))
    local src = f:read("a"):gsub("%-%-[^\r\n]*", "")
    f:close()
    ok(not src:find("ExecuteInGameThread") and not src:find("LoopAsync") and not src:find("StaticFindObject"), "env.lua: no ExecuteInGameThread, LoopAsync or StaticFindObject")
    ok(not src:find("Diffculty%s*=[^=]") and not src:find("HasAuthority", 1, true), "env.lua: never writes Diffculty, never HasAuthority")
end

H.done()
