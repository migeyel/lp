local wallet = require "lp.wallet"
local pools = require "lp.pools"
local inventory = require "lp.inventory"
local threads = require "lp.threads"

local SECURITY_TAG = "LP Security"
local SEC_KST_SUM_PART = 0.1
local SEC_KST_MAX_REALLOC_PART = 0.05
local SEC_ITEMS_TARGET = 512
local SEC_ITEMS_MAX_REALLOC_PART = 8

---@return Pool
local function getSecPool()
    return assert(pools.getByTag(SECURITY_TAG), "failed to find sec pool")
end

---@param commit boolean
local function reallocKrist(commit)
    local pool = getSecPool()
    local targetKst = pools.totalKrist() * SEC_KST_SUM_PART
    local diff = targetKst - pool.allocatedKrist
    if math.abs(diff) < 0.5 then return end
    local upperBound = SEC_KST_MAX_REALLOC_PART * pool.allocatedKrist
    local lowerBound = -SEC_KST_MAX_REALLOC_PART * pool.allocatedKrist
    diff = math.min(upperBound, diff)
    diff = math.max(lowerBound, diff)
    diff = math.min(diff, wallet.getSecFund())
    wallet.reallocateSec(-diff, false)
    pool:reallocKst(diff, false)
    if commit then pools.state:commitMany(wallet.state) end
    pools.priceChangeEvent.queue(pool:id())
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
        sleep(math.random() * 2)
        reallocKrist(true)
        reallocItems()
    end
end)

return {
    getSecPool = getSecPool,
}
