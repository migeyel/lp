local pools = require "lp.pools"
local inventory = require "lp.inventory"
local threads = require "lp.threads"

local SECURITY_TAG = "LP Security"
local SEC_ITEMS_TARGET = 512
local SEC_ITEMS_MAX_REALLOC_PART = 8

---@return Pool
local function getSecPool()
    local out = assert(pools.getByTag(SECURITY_TAG), "failed to find sec pool")
    assert(not out:isDigital())
    return out
end

local function reallocItems()
    local pool = getSecPool()
    local diff = SEC_ITEMS_TARGET - pool.allocatedItems
    if diff == 0 then return end
    local inv = inventory.get()
    local secInv = inventory.getSec()
    pool = getSecPool()
    diff = SEC_ITEMS_TARGET - pool.allocatedItems
    local secInvCount = secInv.getCount(pool.item, pool.nbt)
    local secInvFree = secInv.totalSpaceForItem(pool.item, pool.nbt)
    diff = math.min(SEC_ITEMS_MAX_REALLOC_PART, diff)
    diff = math.max(-SEC_ITEMS_MAX_REALLOC_PART, diff)
    diff = math.min(secInvCount, diff)
    diff = math.max(-secInvFree, diff)
    if diff > 0 then
        local count = inv.pullItems(secInv, pool.item, diff, nil, pool.nbt)
        pool = getSecPool()
        pool:reallocItems(count, true)
        pools.priceChangeEvent.queue(pool:id())
    elseif diff < 0 then
        pool:reallocItems(diff, true)
        pools.priceChangeEvent.queue(pool:id())
        inv.pushItems(secInv, pool.item, -diff, nil, pool.nbt)
    end
end

threads.register(function()
    while true do
        sleep(1)
        if math.random(1, 300) == 1 then
            reallocItems()
        end
    end
end)

return {
    getSecPool = getSecPool,
}
