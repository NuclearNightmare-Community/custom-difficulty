-- Unit tests for Scripts/sidecar.lua (story 6): name encoding, the bounded format-2 parse, serialize and reconcile,
-- covering the pure rows of the story's I/O matrix (presets_test.lua covers the file and hook rows).
-- Run from the repo root:  texlua test/unit/sidecar_test.lua
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]test[/\\]unit[/\\][^/\\]+$") or "."
package.path = ROOT .. "/test/unit/?.lua;" .. ROOT .. "/Scripts/?.lua;" .. package.path
local F = require("fakeue")
local H = F.harness("sidecar_test")
local ok, eq = H.ok, H.eq
local sc = require("sidecar")
local knobs = require("knobs")
local HDR = "# CustomDifficulty world presets, format 2\n"

-- ---------------------------------------------------------------- knobs.encode (the values field)
do
    eq(knobs.encode({}), "", "encode: all Default is empty")
    eq(knobs.encode(nil), "", "encode: nil is empty")
    eq(knobs.encode({ ["dmg.stalker"] = 200, enemyDamage = 17, frostbite = 0.5 }), "enemyDamage=17;frostbite=0.5;dmg.stalker=200", "encode: KNOBS order, no trailing zeros")
    eq(knobs.encode({ bogus = 1, cold = "x" }), "", "encode: unknown keys and non-numbers are skipped")
    local v = knobs.parse(knobs.encode({ cold = 50, spread = 20, revives = 0 }))
    ok(v.cold == 50 and v.spread == 20 and v.revives == 0, "encode then parse round-trips")
    -- Story 12: a sidecar written before the two new keys reads them as Default; one written with them reads them.
    local e = sc.parse(HDR .. "0\tOld\trevives=2;cold=50\n1\tNew\trevives=2;classifiedTokens=2;classifiedTokensMax=3\n")
    ok(e[1] and e[1].values.classifiedTokens == nil and e[1].values.revives == 2, "an old entry: the new keys Default")
    ok(e[2] and e[2].values.classifiedTokens == 2 and e[2].values.classifiedTokensMax == 3, "a new entry: both keys read")
end

-- ---------------------------------------------------------------- story 14: the Insta-kill boxes in the sidecar
do
    local entries = { { index = 0, name = "A", values = { ["kill.meek"] = 1, enemyDamage = 25 } }, { index = 1, name = "B", values = {} } }
    local text = sc.serialize(entries, "CustomDifficulty")
    ok(text:find("0\tA\tenemyDamage=25;kill.meek=1\n", 1, true), "serialize: kill.meek=1 written", text)
    local e, p = sc.parse(text)
    ok(#p == 0 and e[1].values["kill.meek"] == 1 and e[1].values.enemyDamage == 25 and next(e[2].values) == nil, "round trip: A ticked, B unticked")
    e, p = sc.parse(HDR .. "0\tOld\tdmg.meek=50\n")
    eq(e[1].values["kill.meek"], nil, "a preset saved before the boxes: unticked")
    eq(#p, 0, "a preset saved before the boxes: no problem")
    e, p = sc.parse(HDR .. "0\tX\tkill.meek=2;cold=50\n1\tY\tkill.meek=yes\n2\tZ\tkill.meek=0\n")
    ok(e[1].values["kill.meek"] == nil and e[1].values.cold == 50, "kill.meek=2: Default, the rest kept")
    ok(e[2] and e[2].values["kill.meek"] == nil, "kill.meek=yes: Default")
    ok(e[3] and e[3].values["kill.meek"] == nil, "kill.meek=0: unticked (Default)")
    eq(#p, 2, "kill.meek=2 and =yes: one problem each; 0 none")
end

-- ---------------------------------------------------------------- name encoding
do
    local name = "a%b\tc\nd\re\1f%41 ok"
    local e = sc.encodeName(name)
    ok(not e:find("[\t\r\n%c]"), "encoded name has no tab, CR, LF or control byte", e)
    eq(e, "a%25b%09c%0Ad%0De%01f%2541 ok", "encoded form")
    eq(sc.decodeName(e), name, "name encoding round-trips exactly")
    local entries = sc.parse(HDR .. "0\t" .. e .. "\t\n")
    eq(entries[1] and entries[1].name, name, "a name with %, tab, LF, CR and 0x01 round-trips through the file")
    eq(sc.encodeName("Ünïcode name"), "Ünïcode name", "bytes >= 0x20 stay as they are")
end

-- ---------------------------------------------------------------- parse
do
    local e, p = sc.parse(nil)
    ok(#e == 0 and #p == 0, "no file: no entries, no problem")
    e, p = sc.parse(HDR .. "0\tA\tcold=50;spread=20\n1\tB\t\n")
    eq(#e, 2, "two entries")
    eq(#p, 0, "a good file: no problem")
    ok(e[1].index == 0 and e[1].name == "A" and e[1].values.cold == 50 and e[1].values.spread == 20, "entry A")
    ok(e[2].index == 1 and e[2].name == "B" and next(e[2].values) == nil, "entry B all Default")
    e, p = sc.parse(HDR:gsub("\n", "\r\n") .. "0\tA\tcold=50\r\n")
    ok(#e == 1 and e[1].values.cold == 50 and #p == 0, "CRLF lines")
end
do -- bad lines: non-numeric index, unknown key, cold=999, a 2000-byte line
    local long = "2\tL\t" .. ("x"):rep(2000)
    local e, p = sc.parse(HDR .. "x\tA\tcold=50\n1\tB\tbogus=1;cold=40\n2\tC\tcold=999;spread=10\n" .. long .. "\n3\tD\tfrostbite=2\n")
    local byName = {}
    for _, x in ipairs(e) do byName[x.name] = x end
    ok(byName.A == nil, "non-numeric index: the line is Default (no entry)")
    ok(byName.B and byName.B.values.cold == 40 and byName.B.values.bogus == nil, "unknown key ignored, the valid key on the line kept")
    ok(byName.C and byName.C.values.cold == nil and byName.C.values.spread == 10, "cold=999 Default, spread=10 kept")
    ok(byName.L == nil, "a 2000-byte line is Default")
    ok(byName.D and byName.D.values.frostbite == 2, "a good line after the bad ones")
    eq(#p, 4, "four problems (index, unknown key, range, long line)")
    ok(p[1]:find("index 'x'", 1, true) ~= nil, "the first problem names the bad index", p[1])
end
do -- oversized: 300 entries, and a 300 KiB file
    local t = { HDR }
    for i = 0, 299 do t[#t + 1] = ("%d\tP%d\tcold=%d\n"):format(i, i, i % 400) end
    local e, p = sc.parse(table.concat(t))
    eq(#e, 256, "300 entries: the first 256 only")
    eq(e[256].name, "P255", "the 256th entry is P255")
    eq(#p, 1, "300 entries: one problem")
    local big = ("0\tBig\tcold=1\n"):rep(math.ceil(300 * 1024 / 14))
    e, p = sc.parse(HDR .. big)
    eq(#e, 256, "300 KiB: at most 256 entries")
    ok(p[1]:find("over 262144 bytes", 1, true) ~= nil, "300 KiB: the first problem is the size", p[1])
end
do -- other format
    local e, p = sc.parse("# CustomDifficulty world presets, format 3\n0\tA\tcold=50\n")
    eq(#e, 0, "format 3: every entry Default")
    eq(#p, 1, "format 3: one problem")
    ok(p[1]:find("not format 2", 1, true) ~= nil, "format 3: the problem says so", p[1])
    e, p = sc.parse("0\tA\tcold=50\n")
    ok(#e == 1 and #p == 1 and p[1]:find("no format 2 header", 1, true), "no header: entries read, one problem")
end
do -- the stale line the driver appends is well-formed: no problem
    local e, p = sc.parse(HDR .. "0\tA\t\n99\tDT6-gone\tcold=50\n")
    ok(#e == 2 and #p == 0, "a stale but well-formed line raises no problem")
end

-- ---------------------------------------------------------------- serialize
do
    local text, skipped = sc.serialize({ { index = 0, name = "A", values = { cold = 50 } }, { index = 1, name = "B\tx", values = {} } }, "CustomDifficulty")
    eq(text, HDR .. "0\tA\tcold=50\n1\tB%09x\t\n", "serialize: header, encoded names, empty Default")
    eq(#skipped, 0, "nothing skipped")
    local long = ("\1"):rep(50) -- 150 bytes encoded
    text, skipped = sc.serialize({ { index = 0, name = long, values = { cold = 5 } }, { index = 1, name = "B", values = {} } }, "CustomDifficulty")
    eq(text, HDR .. "1\tB\t\n", "long name: entry not written")
    eq(#skipped, 1, "long name: listed as skipped")
    local e = sc.parse(text)
    ok(#e == 1 and e[1].name == "B", "long name: Default on the next read (no entry)")
end

-- ---------------------------------------------------------------- reconcile
local function rec(names, file) local e = sc.parse(file) return sc.reconcile(names, e, "CustomDifficulty") end
do
    local e, text = rec({ "A", "B" }, nil)
    eq(text, HDR .. "0\tA\t\n1\tB\t\n", "no file, 2 presets: 2 Default entries")
    ok(#e == 2 and next(e[1].values) == nil, "entries Default")
    local file = HDR .. "0\tA\tcold=50\n1\tB\tspread=3\n"
    e, text = rec({ "A", "B" }, file)
    eq(text, file, "matching file: the same text (no write)")
    e, text = rec({ "A", "B" }, HDR .. "0\tB\tcold=50\n")
    eq(text, HDR .. "0\tA\t\n1\tB\tcold=50\n", "moved preset: B's values at index 1, A Default")
    e, text = rec({ "A" }, HDR .. "0\tA\tcold=1\n1\tGone\tcold=2\n")
    eq(text, HDR .. "0\tA\tcold=1\n", "stale entry dropped")
    e, text = rec({ "X", "X" }, HDR .. "0\tX\tcold=1\n1\tX\tcold=2\n")
    eq(text, HDR .. "0\tX\tcold=1\n1\tX\tcold=2\n", "duplicate names: each keeps its own entry by index")
    e, text = rec({ "X", "Y", "X" }, HDR .. "0\tX\tcold=1\n2\tX\tcold=2\n")
    eq(text, HDR .. "0\tX\tcold=1\n1\tY\t\n2\tX\tcold=2\n", "duplicate names apart: by index first")
    e, text = rec({ "A" }, "# CustomDifficulty world presets, format 3\n0\tA\tcold=50\n")
    eq(text, HDR .. "0\tA\t\n", "other format: all Default, rewritten as format 2")
    e, text = rec({ "A", "B" }, HDR .. "0\tA\tcold=1\n99\tDT6-gone\tcold=50\n1\tB\t\n")
    eq(text, HDR .. "0\tA\tcold=1\n1\tB\t\n", "a stale appended line is dropped")
    e, text = rec({}, HDR .. "0\tA\tcold=1\n")
    eq(text, HDR, "no presets: an empty file")
end

H.done()
