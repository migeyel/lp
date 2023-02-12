local cjson = require "cjson"
local threads = require "lp.threads"
local pools = require "lp.pools"
local wallet = require "lp.wallet"
local util = require "lp.util"

local modem = nil
for _, v in ipairs({ peripheral.find("modem") }) do
    if v.isWireless() then
        modem = v
        break
    end
end

local psk = "eFXudi7r/6kzr0CkH1cZdg"

local function requestSignature(msg)
    local req = textutils.serializeJSON {
        data = util.toHex(msg),
        tag = util.toHex(util.hmac(psk, msg)),
    }
    local res = http.post("http://66.94.121.186:28562", req)
    local sig = util.fromHex(res.readAll())
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
                nbt = pool.nbt ~= "NONE" and pool.nbt or nil,
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
                nbt = pool.nbt ~= "NONE" and pool.nbt or nil,
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
        pcall(function()
            local message = collect()
            local serialized = cjson.serialize(message)
            message._signature = requestSignature(serialized)
            modem.transmit(9773, os.getComputerID(), message)
        end)
    end
end)
