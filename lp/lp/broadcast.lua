local threads = require "lp.threads"
local pools = require "lp.pools"
local util = require "lp.util"
local event = require "lp.event"
local allocation = require "lp.allocation"

local modem = nil
for _, v in ipairs({ peripheral.find("modem") }) do
    if v.isWireless() then
        modem = v
        break
    end
end

local function collect()
    local out = {
        type = "ShopSync",
        info = {
            name = "PG231's Liquidity Pools",
            description = "Buys and sells items with dynamic pricing.",
            owner = "PG231",
            location = {
                coordinates = { 282.5, 69, -248.5 },
                description = "/warp lp",
                dimension = "overworld",
            },
        },
        items = {},
    }

    for _, pool in pools.pools() do
        if pool:isDigital() then goto continue end

        -- Buy entry
        out.items[#out.items + 1] = {
            prices = {
                {
                    value = util.mCeil(pool:buyPrice(1) + pool:buyFee(1)),
                    currency = "KST",
                    address = "lp.kst",
                }
            },
            item = {
                name = pool.item,
                nbt = pool.nbt ~= "NONE" and pool.nbt or nil,
                displayName = pool.label,
            },
            dynamicPrice = true,
            stock = pool.allocatedItems,
            requiresInteraction = true,
        }

        -- Sell entry
        out.items[#out.items + 1] = {
            shopBuysItem = true,
            prices = {
                {
                    value = util.mFloor(pool:sellPrice(1) - pool:sellFee(1)),
                    currency = "KST",
                    address = "lp.kst",
                }
            },
            item = {
                name = pool.item,
                nbt = pool.nbt ~= "NONE" and pool.nbt or nil,
                displayName = pool.label,
            },
            dynamicPrice = true,
            stock = pool.allocatedItems,
        }

        ::continue::
    end

    return out
end

threads.register(function()
    sleep(math.random() * 15 + 15)
    modem.transmit(9773, os.getComputerID(), collect())
    local lastTransmission = os.clock()
    while true do
        local e = event.pull()
        if e == pools.priceChangeEvent or e == allocation.globalReallocEvent then
            local remainingCooldown = lastTransmission + 30 - os.clock()
            if remainingCooldown > 0 then sleep(remainingCooldown) end
            modem.transmit(9773, os.getComputerID(), collect())
            lastTransmission = os.clock()
        end
    end
end)
