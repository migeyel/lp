local pools = require "lp.pools"
local threads = require "lp.threads"
local sessions = require "lp.sessions"

local SECURITY_TAG = "LP Security"
local SEC_ITEMS_TARGET_FRAC = 0.05
local SEC_ITEMS_MAX_REALLOC_PART = 1
local MEAN_REALLOCATION_TIME = 300

---@return Pool
local function getSecPool()
    return assert(pools.getByTag(SECURITY_TAG), "failed to find sec pool")
end

local function reallocItems(limit)
    local pool = getSecPool()
    local total = pool.allocatedItems + sessions.totalAssets(pool:id())
    local target = math.floor(SEC_ITEMS_TARGET_FRAC * total + 0.5)
    local diff = target - pool.allocatedItems
    if diff == 0 then return end
    diff = math.min(limit, diff)
    diff = math.max(-limit, diff)
    pool:reallocItems(diff, true)
end

threads.register(function()
    while true do
        sleep(math.random(0, MEAN_REALLOCATION_TIME))
        reallocItems(SEC_ITEMS_MAX_REALLOC_PART)
    end
end)

return {
    reallocItems = reallocItems,
    getSecPool = getSecPool,
}
