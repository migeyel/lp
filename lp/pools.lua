--- The big file.
--
-- Allocation manages what *actually* is in each liquidity pool. Its state can
-- be manually audited to make sure it's in agreement with the wallet and
-- inventory.
--

local FEE_RATE = 0.05 -- TODO configure

local state = require "lp.state".open "lp.pools"
local util = require "lp.util"

local mFloor, mCeil, mRound = util.mFloor, util.mCeil, util.mRound

---@type table<string, Pool|nil>
state.pools = state.pools or {}
state.commit()

local poolTags = {}
for _, p in pairs(state.pools) do
    local tag = p.label:gsub(" ", ""):lower()
    poolTags[tag] = p
end

---@class Pool
---@field label string
---@field item string
---@field nbt string
---@field allocatedItems number
---@field allocatedKrist number
---@field tag string
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
    if commit then state.commit() end

    return setmetatable(pool, { __index = Pool }), nil
end

local function pools()
    local function pnext(_, k0)
        local k1, p = next(state.pools, k0)
        if p then return k1, setmetatable(p, { __index = Pool }) end
    end

    return pnext, nil, nil
end

function Pool:id()
    return self.item .. "~" .. self.nbt
end

---@param delta number
---@param commit boolean
function Pool:reallocKst(delta, commit)
    delta = math.max(delta, -self.allocatedKrist)
    self.allocatedKrist = self.allocatedKrist + delta
    if commit then state.commit() end
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
    self.allocatedKrist = self.allocatedKrist + kDelta
    if commit then state.commit() end
end

---@param commit boolean
function Pool:remove(commit)
    poolTags[self.label:gsub(" ", ""):lower()] = nil
    state.pools[self:id()] = nil
    if commit then state.commit() end
end

---@param amount number
---@return number
function Pool:buyPrice(amount)
    if amount >= self.allocatedItems then return 1 / 0 end
    return mCeil(amount * self.allocatedKrist / (self.allocatedItems - amount))
end

---@param amount number
---@return number
function Pool:sellPrice(amount)
    return mFloor(amount * self.allocatedKrist / (self.allocatedItems + amount))
end

---@return number
function Pool:midPrice()
    return mRound(self.allocatedKrist / self.allocatedItems)
end

---@param amount number
---@return number
function Pool:buyFee(amount)
    return self:buyPrice(amount) * FEE_RATE
end

---@param amount number
---@return number
function Pool:sellFee(amount)
    return self:sellPrice(amount) * FEE_RATE
end

---@return number
function Pool:midPriceUnrounded()
    return self.allocatedKrist / self.allocatedItems
end

local function commitWith(t, ...)
    if select("#", ...) == 0 then
        state:commitMany(unpack(t))
    else
        return select(1, ...)(t, select(2, ...))
    end
end

return {
    create = create,
    get = get,
    getByTag = getByTag,
    pools = pools,
    commitWith = commitWith,
}
