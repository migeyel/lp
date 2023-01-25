local expect = require "cc.expect".expect
local sha256 = require "sha256"
local cjson = require "cjson"
local threads = require "lp.threads"
local pools = require "lp.pools"
local wallet = require "lp.wallet"

local modem = nil
for _, v in ipairs({ peripheral.find("modem") }) do
    if v.isWireless() then
        modem = v
        break
    end
end

local psk = "eFXudi7r/6kzr0CkH1cZdg"

local function strx(s1, s2)
    local b1 = { s1:byte(1, -1) }
    local b2 = { s2:byte(1, -1) }
    local b3 = {}
    for i = 1, math.max(#b1, #b2) do
        b3[i] = bit32.bxor(b1[i] or 0, b2[i] or 0)
    end
    return string.char(unpack(b3))
end

local function hmac(key, msg)
    expect(1, key, "string")
    expect(2, msg, "string")
    if #key > 64 then key = sha256(key) end
    local ipad = strx(key, ("\x36"):rep(64))
    local opad = strx(key, ("\x5c"):rep(64))
    return sha256(opad .. sha256(ipad .. msg))
end

local function toHex(s)
    return ("%02x"):rep(#s):format(s:byte(1, -1))
end

local function fromHex(s)
    return s:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
end

local function requestSignature(msg)
    local req = textutils.serializeJSON {
        data = toHex(msg),
        tag = toHex(hmac(psk, msg)),
    }
    local res = http.post("http://66.94.121.186:28562", req)
    local sig = fromHex(res.readAll())
    res.close()
    return sig
end

local function collect()
    local out = {
        _lpx_version = 0,
        _timestamp = os.epoch("utc"),
        type = "ShopSync",
        info = {
            name = "PG231's Lyqydity Pools",
            description = "Buys and sells items with dynamic pricing.",
            owner = "PG231",
            multiShop = nil,
            software = nil,
            location = {
                coordinates = { 286, 69, -248 },
                description = "/warp lyqyd",
                dimension = "overworld",
            },
        },
        items = {},
    }

    for _, pool in pools.pools() do
        -- Buy entry
        out.items[#out.items + 1] = {
            shopBuysItem = false,
            prices = {
                {
                    value = pool:midPriceUnrounded(),
                    currency = "KST",
                    address = wallet.address,
                    _fee = pools.FEE_RATE,
                }
            },
            item = {
                name = pool.item,
                nbt = #pool.nbt ~= "NONE" and pool.nbt or nil,
                displayName = pool.label,
            },
            stock = pool.allocatedItems,
            madeOnDemald = false,
            requiresInteraction = true,
            noLimit = true,
        }

        -- Sell entry
        out.items[#out.items + 1] = {
            shopBuysItem = true,
            prices = {
                {
                    value = pool:midPriceUnrounded(),
                    currency = "KST",
                    address = wallet.address,
                    _fee = pools.FEE_RATE,
                }
            },
            item = {
                name = pool.item,
                nbt = #pool.nbt ~= "NONE" and pool.nbt or nil,
                displayName = pool.label,
            },
            stock = pool.allocatedItems,
            noLimit = true,
        }
    end

    return out
end

threads.register(function()
    while true do
        sleep(30)
        local message = collect()
        local serialized = cjson.serialize(message)
        message._signature = requestSignature(serialized)
        modem.transmit(9773, os.getComputerID(), message)
    end
end)
