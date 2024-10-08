--- The big file.
--
-- Allocation manages what *actually* is in each liquidity pool. Its state can
-- be manually audited to make sure it's in agreement with the wallet and
-- inventory.
--

local FEE_RATE = 0.05

local state = require "lp.state".open "lp.pools"
local event = require "lp.event"
local util = require "lp.util"

local mFloor, mCeil, mRound = util.mFloor, util.mCeil, util.mRound

local poolKristSum = 0

---@type table<string, Pool|nil>
state.pools = state.pools or {}

---@type table<string, table<string, boolean>>
state.categories = state.categories or {}

-- id: string
local priceChangeEvent = event.register("price_change")

local poolTags = {}

---@class FixedRateScheme
---@field type "fixed_rate"
---@field rate number

---@class WeightedRemainderScheme
---@field type "weighted_remainder"
---@field weight number

---@alias DynamicAllocationScheme
--- | FixedRateScheme
--- | WeightedRemainderScheme

---@class Pool
---@field label string
---@field item string
---@field nbt string
---@field allocatedItems number
---@field allocatedKrist number
---@field dynAlloc DynamicAllocationScheme?
---@field feeRate number?
---@field liquidating boolean?
local Pool = {}

---@param id string
---@return Pool|nil
local function get(id)
    local p = state.pools[id]
    if p then return setmetatable(p, { __index = Pool }) end
end

---@param label string
---@return Pool|nil
local function getByTag(label)
    local p = poolTags[label:gsub(" ", ""):lower()]
    if p then return setmetatable(p, { __index = Pool }) end
end

---@param label string
---@param itemName string
---@param nbt string
---@param numItems number
---@param numKrist number
---@param commit boolean
---@return Pool|nil
---@return string|nil
local function create(label, itemName, nbt, numItems, numKrist, commit)
    if getByTag(label)  then return nil, "pool label is already in use" end
    if numItems == 0 then return nil, "pool must allocate at least 1 item" end
    if numKrist == 0 then return nil, "pool must allocate Krist" end

    ---@type Pool
    local pool = {
        label = label,
        item = itemName,
        nbt = nbt,
        allocatedItems = numItems,
        allocatedKrist = numKrist,
    }

    local id = Pool.id(pool)
    if state.pools[id] then return nil, "pool already exists" end
    state.pools[id] = pool
    poolKristSum = poolKristSum + numKrist
    if commit then state.commit() end

    return setmetatable(pool, { __index = Pool }), nil
end

local function categories()
    return pairs(state.categories)
end

---@param category string|nil
local function pools(category)
    local cat = state.categories[category]
    if cat then
        return function(_, k0)
            local id = next(cat, k0)
            if id then
                local p = state.pools[id]
                if p then return id, setmetatable(p, { __index = Pool }) end
            end
        end, nil, nil
    else
        return function(_, k0)
            local k1, p = next(state.pools, k0)
            if p then return k1, setmetatable(p, { __index = Pool }) end
        end, nil, nil
    end
end

---@param label string
---@param commit boolean
function Pool:toggleCategory(label, commit)
    local cat = state.categories[label] or {}
    if cat[self:id()] then
        cat[self:id()] = nil
    else
        cat[self:id()] = true
    end
    if next(cat, nil) == nil then
        state.categories[label] = nil
    else
        state.categories[label] = cat
    end
    if commit then state.commit() end
    return cat[self:id()]
end

function Pool:isDigital()
    return self:id():sub(1, 3) == "lp:"
end

function Pool:id()
    return self.item .. "~" .. self.nbt
end

---@param delta number
---@param commit boolean
---@param supressEvent boolean?
function Pool:reallocKst(delta, commit, supressEvent)
    delta = math.max(delta, -self.allocatedKrist)
    poolKristSum = poolKristSum - self.allocatedKrist
    self.allocatedKrist = self.allocatedKrist + delta
    poolKristSum = poolKristSum + self.allocatedKrist
    if commit then state.commit() end
    if not supressEvent then priceChangeEvent.queue(self:id()) end
end

---@param delta number
---@param commit boolean
function Pool:reallocItems(delta, commit)
    delta = math.max(delta, -self.allocatedItems + 1)
    self.allocatedItems = self.allocatedItems + delta
    if commit then state.commit() end
end

---@param itemDelta number
---@param commit boolean
function Pool:reallocBalanced(itemDelta, commit)
    itemDelta = math.max(itemDelta, -self.allocatedItems + 1)
    local kDelta = mRound(itemDelta * self.allocatedKrist / self.allocatedItems)
    self.allocatedItems = self.allocatedItems + itemDelta
    poolKristSum = poolKristSum - self.allocatedKrist
    self.allocatedKrist = self.allocatedKrist + kDelta
    poolKristSum = poolKristSum + self.allocatedKrist
    if commit then state.commit() end
    priceChangeEvent.queue(self:id())
end

---@param commit boolean
function Pool:remove(commit)
    poolTags[self.label:gsub(" ", ""):lower()] = nil
    state.pools[self:id()] = nil
    if commit then state.commit() end
end

---@return number
function Pool:getFeeRate()
    if not self.liquidating then
        return self.feeRate or FEE_RATE
    else
        return 0
    end
end

---@param rate number
---@param commit boolean
function Pool:setFeeRate(rate, commit)
    self.feeRate = math.min(1, math.max(0, rate))
    if commit then state.commit() end
    priceChangeEvent.queue(self:id())
end

---@param amount number
---@return number
function Pool:buyPrice(amount)
    if amount >= self.allocatedItems then return 1 / 0 end
    if not self.liquidating then
        return mCeil(amount * self.allocatedKrist / (self.allocatedItems - amount))
    else
        return mCeil(amount * self.allocatedKrist / self.allocatedItems)
    end
end

---@param amount number
---@return number
function Pool:sellPrice(amount)
    if not self.liquidating then
        return mFloor(amount * self.allocatedKrist / (self.allocatedItems + amount))
    else
        return 0
    end
end

---@return number
function Pool:midPrice()
    return mRound(self.allocatedKrist / self.allocatedItems)
end

---@param amount number
---@return number
function Pool:buyFee(amount)
    local price = self:buyPrice(amount)
    if price == 1 / 0 then return 0 end
    return price * self:getFeeRate()
end

---@param amount number
---@return number
function Pool:sellFee(amount)
    return self:sellPrice(amount) * self:getFeeRate()
end

---@return number
function Pool:midPriceUnrounded()
    return self.allocatedKrist / self.allocatedItems
end

local function totalKrist()
    return poolKristSum
end

local function totalProduct()
    local out = 0
    for id, pool in pools() do
        out = out + pool.allocatedItems * pool.allocatedKrist
    end
    return out
end

for _, p in pools() do
    local tag = p.label:gsub(" ", ""):lower()
    poolTags[tag] = p
    poolKristSum = poolKristSum + p.allocatedKrist
end

return {
    priceChangeEvent = priceChangeEvent,
    create = create,
    get = get,
    getByTag = getByTag,
    categories = categories,
    pools = pools,
    totalKrist = totalKrist,
    totalProduct = totalProduct,
    state = state,
    FEE_RATE = FEE_RATE,
}
