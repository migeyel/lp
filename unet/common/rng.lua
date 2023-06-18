local random = require "ccryptolib.random"

local h = http.post("https://krist.dev/ws/start", "")
local s = h.readAll()
h.close()

local o = textutils.unserializeJSON(s)
assert(type(o) == "table" and o.ok)

http.websocket(o.url).close()
random.init(o.url)

--- Returns a random UUID4
--- @return string
local function uuid4()
    local bytes = { random.random(16):byte(1, 16) }
    bytes[7] = bit32.bor(bit32.band(bytes[7], 0x0f), 0x40)
    bytes[9] = bit32.bor(bit32.band(bytes[9], 0x3f), 0x80)
    return ("xxxx-xx-xx-xx-xxxxxx")
        :gsub("x", "%%02x")
        :format(unpack(bytes, 1, 16))
end

return {
    random = random.random,
    uuid4 = uuid4,
}
