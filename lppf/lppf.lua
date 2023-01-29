--- A single file bundled API for listening to the LP price feed.
--
-- @module lppf
--

local expect = require "cc.expect".expect

--#region sha256

local rol = bit32.lrotate
local shr = bit32.rshift
local bxor = bit32.bxor
local bnot = bit32.bnot
local band = bit32.band
local unpack = unpack or table.unpack

local function primes(n, exp)
    local out = {}
    local p = 2
    for i = 1, n do
        out[i] = bxor(p ^ exp % 1 * 2 ^ 32)
        repeat p = p + 1 until 2 ^ p % p == 2
    end
    return out
end

local K = primes(64, 1 / 3)
local H0 = primes(8, 1 / 2)

local function sha256(data)
    expect(1, data, "string")

    -- Pad input
    local bitlen = #data * 8
    local padlen = -(#data + 9) % 64
    data = data .. "\x80" .. ("\0"):rep(padlen) .. (">I8"):pack(bitlen)

    -- Digest
    local K = K
    local h0, h1, h2, h3, h4, h5, h6, h7 = unpack(H0)
    for i = 1, #data, 64 do
        local w = { (">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4"):unpack(data, i) }

        -- Message schedule
        for j = 17, 64 do
            local wf = w[j - 15]
            local w2 = w[j - 2]
            local s0 = bxor(rol(wf, 25), rol(wf, 14), shr(wf, 3))
            local s1 = bxor(rol(w2, 15), rol(w2, 13), shr(w2, 10))
            w[j] = w[j - 16] + s0 + w[j - 7] + s1
        end

        -- Block
        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for j = 1, 64 do
            local s1 = bxor(rol(e, 26), rol(e, 21), rol(e, 7))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = h + s1 + ch + K[j] + w[j]
            local s0 = bxor(rol(a, 30), rol(a, 19), rol(a, 10))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = s0 + maj

            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2
        end

        -- Feed-forward
        h0 = (h0 + a) % 2 ^ 32
        h1 = (h1 + b) % 2 ^ 32
        h2 = (h2 + c) % 2 ^ 32
        h3 = (h3 + d) % 2 ^ 32
        h4 = (h4 + e) % 2 ^ 32
        h5 = (h5 + f) % 2 ^ 32
        h6 = (h6 + g) % 2 ^ 32
        h7 = (h7 + h) % 2 ^ 32
    end

    return (">I4I4I4I4I4I4I4I4"):pack(h0, h1, h2, h3, h4, h5, h6, h7)
end

--#endregion sha256

--#region cjson

local function patch(obj)
    if type(obj) ~= "table" then return end

    local keys = {}
    for k, v in pairs(obj) do
        patch(v)
        keys[#keys + 1] = k
    end

    table.sort(keys)
    local knext = {}
    for i = 1, #keys do
        knext[keys[i]] = keys[i + 1]
    end

    setmetatable(obj, {
        __pairs = function(t)
            return function(_, i)
                if i ~= nil then
                    return knext[i], t[knext[i]]
                else
                    return keys[1], t[keys[1]]
                end
            end, t, nil
        end,
    })
end

local function serializeCJSON(obj)
    obj = textutils.unserializeJSON(textutils.serializeJSON(obj))
    patch(obj)
    return textutils.serializeJSON(obj)
end

--#endregion cjson

--#region rabin

local function modpow(b, e, p)
    local o, m = 1, b
    while e > 0 do
        if e % 2 == 1 then
            o = o * m % p
            e = e - 1
        end
        m = m * m % p
        e = e / 2
    end
    return o
end

local ps = {}
for i = 1, 1223 do
    local pi = 2 ^ 26 - i
    if modpow(2, pi, pi) == 2 then
        ps[#ps + 1] = pi
    end
end

local function fdh(data)
    local h = sha256(data)
    local out = ""
    for i = 0, 3 do
        out = out .. sha256(("<I4"):pack(i) .. h)
    end
    return out
end

local fmt = "<" .. ("I3"):rep(42) .. "I2"

local function verifier(pk)
    expect(1, pk, "string")
    assert(#pk == 128, "public key size must be 128")

    local nw = {fmt:unpack(pk)}
    local n = {}
    for i = 1, #ps do
        local pi = ps[i]
        local ni = nw[43]
        for j = 42, 1, -1 do
            ni = (ni * 2 ^ 24 + nw[j]) % pi
        end
        n[i] = ni
    end

    return function(msg, sig)
        expect(1, msg, "string")
        expect(2, sig, "string")
        if #sig ~= 272 then return false end

        local hw = {fmt:unpack(fdh(sig:sub(1, 16) .. msg))}
        local xw = {fmt:unpack(sig, 17)}
        local tw = {fmt:unpack(sig, 145)}

        for i = 1, #ps do
            local pi = ps[i]
            local ni = n[i]
            local hi, xi, ti = hw[43], xw[43], tw[43]
            for j = 42, 1, -1 do
                hi = (hi * 2 ^ 24 + hw[j]) % pi
                xi = (xi * 2 ^ 24 + xw[j]) % pi
                ti = (ti * 2 ^ 24 + tw[j]) % pi
            end
            if (xi * xi % pi - ni * ti % pi) % pi ~= hi then return false end
        end

        return true
    end
end

--#endregion

--#region listener

local function fromHex(s)
    return s:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
end

local function mCeil(n)
    return math.ceil(n * 1000) / 1000
end

local function mFloor(n)
    return math.floor(n * 1000) / 1000
end

local verify = verifier(fromHex(
    "195b2a3965a7cbd43bf256f773818d07a3cfaab42a5588f229f1bee37440235c" ..
    "d586750a8a7b560b368898af409e0858d85b1b8c9b44b039fb24f4de7dcb0b27" ..
    "0e0530ecd957b86669fa277b4015219686b6f5e22fa74dcff2b871bfcd4ab5b2" ..
    "76943c144f72a95b14491888112a4aeef3c27adc868b1723cd23ddafbb033fa0"
))

local lastValidTimestamp = os.epoch("utc")

local function ratio(item)
    -- We only list a single price because the pool can't allocate two units of
    -- currency for the same item. It makes no sense for more than one price
    -- entry to exist.
    local price = assert(item.prices[1])
    local midPrice = price.value
    local allocatedItems = item.stock
    local allocatedCurrency = midPrice * allocatedItems
    return allocatedItems, allocatedCurrency, price
end

local function buyPrice(item, amount)
    local allocatedItems, allocatedCurrency, price = ratio(item)
    if amount >= allocatedItems then return price.currency, 1 / 0 end
    local raw = mCeil(amount * allocatedCurrency / (allocatedItems - amount))
    local fee = raw * (price._fee or 0)
    return price.currency, mCeil(raw + fee)
end

local function sellPrice(item, amount)
    local allocatedItems, allocatedCurrency, price = ratio(item)
    local raw = mFloor(amount * allocatedCurrency / (allocatedItems + amount))
    local fee = raw * (price._fee or 0)
    return price.currency, mFloor(raw + fee)
end

--- Computes the adjusted transfer amount for trading a given item entry.
--
-- The amount is either for selling or buying, depending on whether the entry
-- is a "normal" item entry or a "reverse" item entry. You can check for entry
-- type using the field item.shopBuysItem.
--
-- @param item A ShopSync item entry recovered from a broadcast.
-- @param amount The amount of items to sell or buy.
-- @treturn string The currency transferred. Most often "KST".
-- @treturn number The amount of currency needed or earned in the transaction.
--
local function getPrice(item, amount)
    expect(0, item, "table")
    expect(1, amount, "number")
    if item.shopBuysItem then
        return sellPrice(item, amount)
    else
        return buyPrice(item, amount)
    end
end

local function handleMsg(channel, reply, body)
    -- Basic checks
    if channel ~= 9773 then return end
    if type(body) ~= "table" then return end
    if body._lpx_version ~= 0 then return end

    -- Reject old messages
    local timestamp = body._timestamp
    if type(timestamp) ~= "number" then return end
    if timestamp <= lastValidTimestamp then return end

    -- Check signature
    local sig = body._signature
    body._signature = nil
    if type(sig) ~= "string" then return end
    local valid = verify(serializeCJSON(body), sig)
    if not valid then return end

    lastValidTimestamp = timestamp
    os.queueEvent("lppf_price_update", body)
end

--- Listens for price feed broadcasts.
--
-- Queues the event `"lppf_price_update", t`, where `t` is an extended ShopSync
-- table. See https://p.sc3.io/7Ae4KxgzAM for more info on the table format.
--
local function listen()
    peripheral.find("modem").open(9773)
    while true do
        local _, _, c, r, m = os.pullEvent("modem_message")
        pcall(handleMsg, c, r, m)
    end
end

--#endregion listener

return {
    listen = listen,
    getPrice = getPrice,
}
