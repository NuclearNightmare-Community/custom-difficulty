-- Unit tests for Scripts/net.lua (story 5): the published keys, encode / decode with knobs.BY_KEY's bounds, the
-- version codes, core's default netCompat, the missing-feature check and the mod.json scan.
-- Run from the repo root:  texlua test/unit/net_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("net_test")
local ok, eq = H.ok, H.eq
local net = require("net")
local knobs = require("knobs")

-- ---------------------------------------------------------------- the keys
do
    eq(table.concat(net.KEYS, ","), "ver,compat,enemyDamage,dmg_meek,dmg_mimic,dmg_psycho,dmg_husk,dmg_watcher,dmg_stalker", "keys: the 9 published names")
    ok(#net.KEYS <= 16, "keys: within core's 16 per mod")
    for _, k in ipairs(net.KEYS) do ok(k:match("^[A-Za-z0-9_]+$") and #k <= 32, "key " .. k .. ": core's name rule") end
    -- The published knobs are exactly mod.json's scope "all" settings.
    local f = assert(io.open(ROOT .. "/mod.json", "r"))
    local text = f:read("a")
    f:close()
    local all = {}
    for key, body in text:gmatch('\n%s*"([%w%.]+)"%s*:%s*({[^\n]*})') do -- one setting per line
        if body:find('"scope"%s*:%s*"all"') then all[#all + 1] = key end
    end
    table.sort(all)
    local ours = {}
    for _, k in ipairs(net.KNOBS) do ours[#ours + 1] = k.knob ok(knobs.BY_KEY[k.knob] ~= nil, "knob " .. k.knob .. " is in knobs.BY_KEY") end
    table.sort(ours)
    eq(table.concat(ours, ","), table.concat(all, ","), "keys: exactly mod.json's scope \"all\" knobs")
end

-- ---------------------------------------------------------------- version codes
do
    eq(net.verCode("0.1.0"), 1000, "verCode 0.1.0")
    eq(net.verCode("1.2.3"), 1002003, "verCode 1.2.3")
    eq(net.verCode("999.999.999"), 999999999, "verCode max")
    for _, bad in ipairs({ "0.1", "0.1.0.0", "01.1.0", "0.1000.0", "a.b.c", "", " 0.1.0", 1000, nil, "0.-1.0" }) do
        eq(net.verCode(bad), nil, "verCode rejects " .. tostring(bad))
    end
    eq(net.verString(1000), "0.1.0", "verString 1000")
    eq(net.verString(1002003), "1.2.3", "verString 1002003")
    eq(net.verString(0), "0.0.0", "verString 0")
    for _, bad in ipairs({ -1, 1000000000, 1.5, "1000", nil, 0 / 0 }) do eq(net.verString(bad), nil, "verString rejects " .. tostring(bad)) end
    eq(net.verString(1000.0), "0.1.0", "verString takes an integral float")
    eq(net.defaultNetCompat("0.1.7"), "0.1.0", "default netCompat 0.x: 0.<minor>.0")
    eq(net.defaultNetCompat("2.3.4"), "2.0.0", "default netCompat from 1.0: <major>.0.0")
    eq(net.defaultNetCompat("x"), nil, "default netCompat of a bad version")
end

-- ---------------------------------------------------------------- encode
do
    local pairs_, problems = net.encode({ enemyDamage = 25.0, ["dmg.meek"] = 50.0, spread = 20, cold = 0, revives = 8 }, "0.1.0")
    local t = {}
    for _, kv in ipairs(pairs_) do t[#t + 1] = kv[1] .. "=" .. tostring(kv[2]) ok(math.type(kv[2]) == "integer", "encode: " .. kv[1] .. " is an integer") end
    eq(table.concat(t, ","), "ver=1000,compat=1000,enemyDamage=25,dmg_meek=50", "encode: ver, compat, then only the set grab knobs")
    eq(#problems, 0, "encode: no problem")
    pairs_ = net.encode({}, "0.1.0")
    eq(#pairs_, 2, "encode: all Default -> ver and compat only")
    pairs_ = net.encode({}, "0.1.3", "0.1.1")
    eq(pairs_[2][2], 1001, "encode: an explicit netCompat")
    local p2, pr2 = net.encode({ enemyDamage = 25.5 }, "0.1.0")
    eq(#p2, 2, "encode: a non-integer knob is left out")
    eq(#pr2, 1, "encode: one problem for it")
    local p3, pr3 = net.encode({ enemyDamage = 25 }, "0.1")
    eq(#p3, 0, "encode: a bad version publishes nothing")
    eq(#pr3, 1, "encode: one problem for the version")
end

-- ---------------------------------------------------------------- decode
local function reader(values, reason)
    local calls = {}
    return function(name, lo, hi)
        calls[#calls + 1] = { name, lo, hi }
        if reason then return nil, reason end
        local v = values[name]
        if v == nil then return nil, "absent" end
        if v < lo or v > hi then return nil, "out-of-bounds" end
        return v
    end, calls
end
do
    local r, calls = reader({ ver = 1000, compat = 1000, enemyDamage = 25, dmg_stalker = 200 })
    local v, hv, hc = net.decode(r)
    ok(type(v) == "table", "decode: values")
    eq(v.enemyDamage, 25, "decode: enemyDamage")
    eq(v["dmg.stalker"], 200, "decode: dmg_stalker -> dmg.stalker")
    eq(v["dmg.meek"], nil, "decode: an absent knob is Default")
    eq(hv, "0.1.0", "decode: the host's version")
    eq(hc, "0.1.0", "decode: the host's netCompat")
    eq(#calls, 9, "decode: every key read")
    -- The bounds are knobs.BY_KEY's.
    for _, c in ipairs(calls) do
        local k
        for _, kk in ipairs(net.KNOBS) do if kk.net == c[1] then k = knobs.BY_KEY[kk.knob] end end
        if k then ok(c[2] == k.min and c[3] == k.max, "decode: " .. c[1] .. " read with the knob's bounds", c[2] .. ".." .. c[3]) end
    end
    for _, case in ipairs({ { {}, "absent", "ver" }, { { ver = 1000 }, "absent", "compat" } }) do
        local v2, why, key = net.decode(reader(case[1]))
        ok(v2 == nil and why == case[2] and key == case[3], "decode: " .. case[3] .. " " .. case[2], tostring(why) .. " " .. tostring(key))
    end
    for _, reason in ipairs({ "no-state", "version" }) do
        local v2, why = net.decode(reader({}, reason))
        ok(v2 == nil and why == reason, "decode: reason " .. reason .. " passed on", why)
    end
    local v3, why3, key3 = net.decode(reader({ ver = 1000, compat = 1000, dmg_meek = 9999 }))
    ok(v3 == nil and why3 == "out-of-bounds" and key3 == "dmg_meek", "decode: an out-of-bounds knob -> no values", tostring(why3) .. " " .. tostring(key3))
    local v4, why4 = net.decode(function() error("boom") end)
    ok(v4 == nil and why4 == "error", "decode: a raising read is 'error'")
    -- A read handing back something that isn't an integer in bounds (a broken core) is out-of-bounds.
    local v5, why5, key5 = net.decode(function(name) if name == "ver" then return 1000 elseif name == "compat" then return 1000 elseif name == "enemyDamage" then return 25.5 end return nil, "absent" end)
    ok(v5 == nil and why5 == "out-of-bounds" and key5 == "enemyDamage", "decode: a non-integer is out-of-bounds")
    local v6, why6 = net.decode(function(name) if name == "ver" then return "1000" end return nil, "absent" end)
    ok(v6 == nil and why6 == "out-of-bounds", "decode: a string is out-of-bounds")
end

-- ---------------------------------------------------------------- missing features
do
    eq(net.missing(function() return true end), nil, "missing: all there")
    eq(net.missing(function(n) return n ~= "net.compatible" end), "net.compatible", "missing: names the first absent")
    eq(net.missing(nil), "net.publish", "missing: no has() at all")
    eq(net.missing(function() error("x") end), "net.publish", "missing: a raising has() counts as missing")
    eq(net.missing(function() return 1 end), "net.publish", "missing: only true counts")
end

-- ---------------------------------------------------------------- the mod.json scan
do
    local m = net.manifest('{ "id": "a.b", "version": "0.1.0", "netCompat": "0.1.0" }')
    ok(m.id == "a.b" and m.version == "0.1.0" and m.netCompat == "0.1.0", "manifest: the three fields")
    m = net.manifest('{ "settings": { "id": "x", "version": "9.9.9" }, "list": [ { "id": "y" } ], "id": "real.id" }')
    ok(m.id == "real.id" and m.version == nil, "manifest: nested fields are skipped", tostring(m.id))
    m = net.manifest('{ "name": "a \\" id", "id": "q.r" }')
    eq(m.id, "q.r", "manifest: an escaped quote inside a value")
    m = net.manifest('{ "id": 5 }')
    eq(m.id, nil, "manifest: a non-string id is not taken")
    eq(next(net.manifest(nil)), nil, "manifest: nil text")
    eq(next(net.manifest(string.rep(" ", net.MAX_MANIFEST + 1))), nil, "manifest: over the bound")
    m = net.manifest('{ "id": "a.b", "id": "c.d" }')
    eq(m.id, "a.b", "manifest: the first wins")
    local f = assert(io.open(ROOT .. "/mod.json", "r"))
    m = net.manifest(f:read("a"))
    f:close()
    eq(m.id, "nuclearnightmare-community.difficulty", "manifest: the repo's own id")
    eq(m.version, "0.1.0", "manifest: the repo's own version")
end

-- ---------------------------------------------------------------- the source: pure
do
    local f = assert(io.open(ROOT .. "/Scripts/net.lua", "r"))
    local src = f:read("a"):gsub("%-%-[^\r\n]*", "")
    f:close()
    for _, g in ipairs({ "StaticFindObject", "FindAllOf", "RegisterHook", "ExecuteInGameThread", "LoopAsync", "io%.open", "os%." }) do
        ok(not src:find(g), "net.lua: no " .. g)
    end
end

H.done()
