local random = require "ccryptolib.random"

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
    init = random.init,
    random = random.random,
    uuid4 = uuid4,
}
