-- Difficulty: cold exposure and frostbite on the host (spec-difficulty-v1 story 4; knob-mechanics.md "Cold exposure"
-- and "Frostbite damage"). Two parts: the math (pure, no UE4SS: unit-tested without the game) and the cold poll's
-- adapter (characters, liveness, the summary line, the cost). hits.lua owns the match state and calls both.
--   * cold: the knob is the freeze rate in % of Normal's. Stock rates are 200 / divisor (divisors 1 / 1.5 / 2 / 4 for
--     EDiffculty 0..3), so factor = cold / (200 / divisor[Diffculty]). Each poll, a character whose Temperature rose
--     since the last poll gets last + (cur - last) x factor, clamped to 0..1; a fall or a hold (warming, a reset) is
--     left alone.
--   * frostbite: a CallDamageEvent of 1 or 2 with no enemy context on a frozen, outdoor, non-infected player is a
--     frostbite tick; the knob is HP per second (stock 1), compensated as Health += amount x (1 - frostbite).
-- The poll keeps only paths and numbers between polls, never a character.
local damage = require("damage")
local M = {}

M.DIVISOR = { [0] = 1, [1] = 1.5, [2] = 2, [3] = 4 }
M.POLL_MS = 250       -- the host poll (LoopInGameThreadWithDelay)
M.SUMMARY_EVERY = 10  -- s between COLD summary lines
M.EPS = 1e-9          -- a written value this close to the read one is not written

local function num(v) if type(v) == "number" then return v end return tonumber(tostring(v)) end

-- factor(cold, d) -> the rise multiplier for the knob value cold (0..400, % of Normal) on EDiffculty d, or nil.
function M.factor(cold, d)
    if type(cold) ~= "number" or cold ~= cold or cold < 0 then return nil end
    local div = type(d) == "number" and M.DIVISOR[d] or nil
    if not div then return nil end
    return cold / (200 / div)
end

-- rise(last, cur, factor) -> new, raw, applied. new is the value to write (nil: leave Temperature as it is: first
-- seen, fell or held); raw the game's rise since the last poll, applied the rise after scaling (both 0 when new is nil).
function M.rise(last, cur, factor)
    if type(cur) ~= "number" or cur ~= cur or type(last) ~= "number" or type(factor) ~= "number" then return nil, 0, 0 end
    if cur <= last then return nil, 0, 0 end
    local new = last + (cur - last) * factor
    if new < 0 then new = 0 elseif new > 1 then new = 1 end
    return new, cur - last, new - last
end

-- isFrostbite(amount, s) -> true when a CallDamageEvent(amount) with no enemy context is a frostbite tick. s holds the
-- victim's temp (Temperature), can (CanTakeTemperature), inside (InsideEnoughToStopFreezing), infected (Infected) and
-- mimic (IsMimic?). Anything unreadable counts against it (the game's own gates, knob-mechanics.md).
function M.isFrostbite(amount, s)
    if amount ~= 1 and amount ~= 2 then return false end
    if type(s) ~= "table" or type(s.temp) ~= "number" or s.temp < 1 then return false end
    return s.can == true and s.inside ~= true and s.infected ~= true and s.mimic ~= true
end

-- frostbite(hp, amount, chosen) -> plan { stock, scaled, rolled, applied, new, planned } (damage.hit's shape, so
-- hits.lua's guard checks it like any hit): applied = amount x chosen, never rolled; Health compensated with
-- damage.compensate (lowered never below 0.01).
function M.frostbite(hp, amount, chosen)
    if type(hp) ~= "number" or type(amount) ~= "number" or type(chosen) ~= "number" then return nil end
    local applied = amount * chosen
    local new, planned = damage.compensate(hp, amount, applied)
    return { stock = amount, scaled = applied, rolled = applied, applied = applied, new = new, planned = planned }
end

-- ---------------------------------------------------------------- the cold poll's adapter (one per match)
local P = {}
P.__index = P

-- newPoll(o): o.say(level, fmt, ...), o.clock() (s, for the summary period), o.micros() (optional: microseconds,
-- for the per-part timing on the DEBUG line).
function M.newPoll(o)
    return setmetatable({ o = o, last = {}, raw = 0, applied = 0, writes = 0, polls = 0, us = 0, timed = 0,
                          nextSummary = nil, players = 0,
                          t = { disc = 0, discs = 0, deref = 0, derefs = 0, read = 0, write = 0, reads = 0, writes = 0 } }, P)
end
local function us(self)
    local m = self.o.micros
    if not m then return nil end
    local ok, v = pcall(m)
    if ok and type(v) == "number" then return v end
    return nil
end

-- tick(chars, cold, d): chars is this poll's list of { obj, path } (alive, found this poll); cold the knob value; d
-- the live EDiffculty. Writes the scaled Temperature where it rose; forgets paths not seen this poll.
function P:tick(chars, cold, d)
    local factor = M.factor(cold, d)
    if not factor then return end
    self.factor = factor
    local seen = {}
    for _, c in ipairs(chars) do
        seen[c.path] = true
        local r0 = us(self)
        local okT, t = pcall(function() return c.obj.Temperature end)
        local cur = okT and num(t) or nil
        local r1 = us(self)
        if r0 and r1 then self.t.read, self.t.reads = self.t.read + (r1 - r0), self.t.reads + 1 end
        if cur ~= nil and cur == cur then
            local new, raw, applied = M.rise(self.last[c.path], cur, factor)
            if new then
                if math.abs(new - cur) > M.EPS then
                    local okW, err = pcall(function() c.obj.Temperature = new end)
                    if not okW then error("could not write Temperature on " .. c.path .. ": " .. tostring(err)) end
                    self.writes = self.writes + 1
                    local w1 = us(self)
                    if r1 and w1 then self.t.write, self.t.writes = self.t.write + (w1 - r1), self.t.writes + 1 end
                end
                self.raw, self.applied = self.raw + raw, self.applied + applied
                self.last[c.path] = new
            else
                self.last[c.path] = cur
            end
        end
    end
    for p in pairs(self.last) do if not seen[p] then self.last[p] = nil end end
    self.players = #chars
end

-- cost(total, find, discovered): one poll's measured time in microseconds (nil: not measured), and the part of it
-- spent getting the game state and the characters: a discovery (PlayerArray walk, liveness, paths, handles) or,
-- between discoveries, the handles' derefs.
function P:cost(total, find, discovered)
    self.polls = self.polls + 1
    if type(total) == "number" and total >= 0 then self.us, self.timed = self.us + total, self.timed + 1 end
    if type(find) == "number" and find >= 0 then
        if discovered then self.t.disc, self.t.discs = self.t.disc + find, self.t.discs + 1
        else self.t.deref, self.t.derefs = self.t.deref + find, self.t.derefs + 1 end
    end
end

-- summary(clockName): one COLD line every SUMMARY_EVERY s (sums since the match start).
function P:summary(clockName)
    local now = self.o.clock()
    if not self.nextSummary then self.nextSummary = now + M.SUMMARY_EVERY return end
    if now < self.nextSummary then return end
    self.nextSummary = now + M.SUMMARY_EVERY
    local avg = self.timed > 0 and string.format("%.3f", self.us / self.timed / 1000) or "?"
    self.o.say("info", "COLD raw=%.4f applied=%.4f factor=%s polls=%d writes=%d players=%d avg_ms=%s clock=%s",
        self.raw, self.applied, damage.fmt(self.factor), self.polls, self.writes, self.players, avg, clockName or "?")
    -- Where the time goes (DEBUG): per discovery poll (game state, PlayerArray, pawns, liveness, paths, handles), per
    -- poll between discoveries (the derefs), per character read and per write.
    local t = self.t
    local function ms(v, n) return n > 0 and string.format("%.4f", v / n / 1000) or "?" end
    self.o.say("debug", "COLD timing discover_ms=%s (n=%d) deref_ms=%s (n=%d) read_ms=%s write_ms=%s reads=%d",
        ms(t.disc, t.discs), t.discs, ms(t.deref, t.derefs), t.derefs, ms(t.read, t.reads), ms(t.write, t.writes), t.reads)
end

return M
