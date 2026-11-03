-- A minimal JSON decoder for the unit tests (objects, arrays, strings with escapes, numbers, true/false/null).
-- Objects keep their key order in a "__keys" list; null decodes to the sentinel json.null.
local J = { null = setmetatable({}, { __tostring = function() return "null" end }) }

function J.decode(s)
    local i = 1
    local function err(m) error(("json: %s at byte %d"):format(m, i), 0) end
    local function ws() i = s:find("[^ \t\r\n]", i) or (#s + 1) end
    local value
    local function str()
        i = i + 1
        local out = {}
        while true do
            local c = s:sub(i, i)
            if c == "" then err("unterminated string") end
            if c == '"' then i = i + 1 break end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[e] then out[#out + 1] = map[e]; i = i + 2
                elseif e == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)); i = i + 6
                else err("bad escape") end
            else out[#out + 1] = c; i = i + 1 end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            i = i + 1
            local o = { __keys = {} }
            ws()
            if s:sub(i, i) == "}" then i = i + 1 return o end
            while true do
                ws()
                if s:sub(i, i) ~= '"' then err("expected a key") end
                local k = str()
                ws()
                if s:sub(i, i) ~= ":" then err("expected ':'") end
                i = i + 1
                if o[k] ~= nil then err("duplicate key " .. k) end
                o[k] = value()
                o.__keys[#o.__keys + 1] = k
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "}" then return o end
                if d ~= "," then err("expected ',' or '}'") end
            end
        elseif c == "[" then
            i = i + 1
            local a = {}
            ws()
            if s:sub(i, i) == "]" then i = i + 1 return a end
            while true do
                a[#a + 1] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "]" then return a end
                if d ~= "," then err("expected ',' or ']'") end
            end
        elseif c == '"' then return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4 return J.null
        else
            local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            if not n or n == "" then err("unexpected '" .. c .. "'") end
            i = i + #n
            return tonumber(n)
        end
    end
    local v = value()
    ws()
    if i <= #s then err("trailing text") end
    return v
end

return J
