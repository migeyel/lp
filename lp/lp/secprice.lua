local pools = require "lp.pools"
local threads = require "lp.threads"

local SECURITY_TAG = "LP Security"
local SEC_ITEMS_TARGET = 512
local SEC_ITEMS_MAX_REALLOC_PART = 8

---@return Pool
local function getSecPool()
    return assert(pools.getByTag(SECURITY_TAG), "failed to find sec pool")
end

local function reallocItems()
    local pool = getSecPool()
    local diff = SEC_ITEMS_TARGET - pool.allocatedItems
    if diff == 0 then return end
    diff = math.min(SEC_ITEMS_MAX_REALLOC_PART, diff)
    diff = math.max(-SEC_ITEMS_MAX_REALLOC_PART, diff)
    pool:reallocItems(diff, true)
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
