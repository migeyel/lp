local KRISTPAY_DOMAIN = "switchcraft.kst"

local state = require "lp.state".open "lp.session"
local event = require "lp.event"
local util = require "lp.util"
local pools= require "lp.pools"
local wallet = require "lp.wallet"

---@type table<string, Account|nil>
state.accounts = state.accounts or {}

---@type table<string, string>
local uuidIndex = {}

for _, v in pairs(state.accounts) do
    if v.uuid then
        uuidIndex[v.username] = v.uuid
    end
end

---@type Session|nil
state.session = nil
state.commit()

-- uuid: string
local startEvent = event.register()

-- uuid: string
-- transferred: number
-- remaining: number
local endEvent = event.register()

-- id: string
local buyEvent = event.register()

-- id: string
local sellEvent = event.register()

-- uuid: string
local sessionBalChangeEvent = event.register()

local mFloor, mCeil = util.mFloor, util.mCeil

---@class Account
---@field username string
---@field balance number
---@field uuid string
local Account = {}

---Sets the username for an account, creating it if needeed.
---@param username string
---@param uuid string
---@param commit boolean
local function setAcct(uuid, username, commit)
    local acct = state.accounts[uuid] or {
        balance = 0,
        uuid = uuid,
    }

    if acct.username then
        uuidIndex[acct.username] = nil
        uuidIndex[username] = uuid
    end

    acct.username = username

    if commit then state.commit() end
end

---@param uuid string
---@return Account?
local function getAcctByUuid(uuid)
    local acct = state.accounts[uuid]
    if acct then return setmetatable(acct, { __index = Account }) end
end

---@param username string
---@return Account?
local function getAcctByUsername(username)
    local uuid = uuidIndex[username]
    if uuid then return getAcctByUuid(uuid) end
end

local function accounts()
    local function anext(_, k0)
        local k1, p = next(state.accounts, k0)
        if p then return k1, setmetatable(p, { __index = Account }) end
    end

    return anext, nil, nil
end

---@param delta number
---@param commit boolean
---@return number newDelta The true transferred amount.
---@return number newBal The remaining balance of the account.
function Account:transfer(delta, commit)
    delta = math.max(delta, -self.balance)
    self.balance = util.mFloor(self.balance + delta)
    if commit then state.commit() end
    local session = state.session
    if session and session:account() == self then
       sessionBalChangeEvent.queue(self.uuid)
    end
    return delta, self.balance
end

---@param delta number
---@param commit boolean
---@return boolean
function Account:tryTransfer(delta, commit)
    if self.balance < -delta then return false end
    self.balance = self.balance + delta
    if commit then state.commit() end
    local session = state.session
    if session and session:account() == self then
       sessionBalChangeEvent.queue(self.uuid)
    end
    return true
end

---@class Session
---@field uuid string
---@field lastActive number
---@field buyFees table
---@field sellFees table
---@field closed boolean
local Session = {}

---@return Session|nil
local function get()
    local s = state.session
    if s then return setmetatable(s, { __index = Session }) end
end

---@param uuid string
---@param username string
---@param commit boolean
---@return Session?
local function create(uuid, username, commit)
    if get() then return end

    username = username:lower()

    setAcct(uuid, username, false)

    state.session = {
        uuid = uuid,
        lastActive = os.epoch("utc"),
        buyFees = {},
        sellFees = {},
    }

    if commit then state.commit() end

    startEvent.queue(uuid)

    return setmetatable(state.session, { __index = Session })
end

---@return Account
function Session:account()
    -- This doesn't error because create() makes the account whenever a new
    -- session starts.
    return assert(getAcctByUuid(self.uuid))
end

---@return number
function Session:balance()
    return self:account().balance
end

---@param amount number
---@param commit boolean
function Session:transfer(amount, commit)
    self:account():transfer(amount, commit)
end

---@param pool Pool
---@param amount number
---@return number
---@return number
---@return number
function Session:buyPriceWithFee(pool, amount)
    local price = pool:buyPrice(amount)
    local id = pool:id()
    if price == 1 / 0 then
        return 1 / 0, self.buyFees[id] or 0, self.sellFees[id] or 0
    end
    local basicFee = pool:buyFee(amount)
    local sellFeesUsed = math.min(basicFee, self.sellFees[id] or 0)
    local refundedFee = basicFee - 2 * sellFeesUsed
    local priceWithFee = mCeil(price + refundedFee)
    local newSellFees = mFloor((self.sellFees[id] or 0) - sellFeesUsed)
    local earnings = math.max(refundedFee, 0)
    local newBuyFees = mFloor((self.buyFees[id] or 0) + earnings)
    return priceWithFee, newBuyFees, newSellFees
end

---@param pool Pool
---@param amount number
---@return number
---@return number
---@return number
function Session:sellPriceWithFee(pool, amount)
    local price = pool:sellPrice(amount)
    local id = pool:id()
    local basicFee = pool:sellFee(amount)
    local buyFeesUsed = math.min(basicFee, self.buyFees[id] or 0)
    local refundedFee = basicFee - 2 * buyFeesUsed
    local priceWithFee = mFloor(price - refundedFee)
    local newBuyFees = mFloor((self.buyFees[id] or 0) - buyFeesUsed)
    local earnings = math.max(refundedFee, 0)
    local newSellFees = mFloor((self.sellFees[id] or 0) + earnings)
    return priceWithFee, newBuyFees, newSellFees
end

---@param pool Pool
---@param amount number
---@param commit boolean
---@return boolean
function Session:tryBuy(pool, amount, commit)
    assert(type(amount == "number") and amount % 1 == 0)
    local priceNoFee = pool:buyPrice(amount)
    local priceWithFee, newBuyFees, newSellFees = self:buyPriceWithFee(pool, amount)
    if self:balance() < priceWithFee then return false end

    self.lastActive = os.epoch("utc")
    self:transfer(-priceWithFee, false)
    self.buyFees[pool:id()] = newBuyFees
    self.sellFees[pool:id()] = newSellFees
    pool:reallocItems(-amount, false)
    pool:reallocKst(priceNoFee, false)
    if commit then pools.state:commitMany(state) end

    buyEvent.queue(pool:id())

    return true
end

---@param pool Pool
---@param amount number
---@param commit boolean
function Session:sell(pool, amount, commit)
    assert(type(amount == "number") and amount % 1 == 0)

    local priceNoFee = pool:sellPrice(amount)
    local priceWithFee, newBuyFees, newSellFees = self:sellPriceWithFee(pool, amount)

    self.lastActive = os.epoch("utc")
    self:transfer(priceWithFee, false)
    self.buyFees[pool:id()] = newBuyFees
    self.sellFees[pool:id()] = newSellFees
    pool:reallocItems(amount, false)
    pool:reallocKst(-priceNoFee, false)
    if commit then pools.state:commitMany(state) end

    sellEvent.queue(pool:id())
end

local function closedSessionError()
    error("attempt to use a closed session")
end

function Session:close()
    local acct = self:account()
    local balFloor = math.floor(acct.balance)
    local delta, rem = acct:transfer(-balFloor, false)
    local amt = -delta
    local receiver = self.uuid:gsub("-", "") .. "@" .. KRISTPAY_DOMAIN
    wallet.setPendingTx(receiver, amt,  {}, false)
    state.session = nil
    setmetatable(self, { __index = closedSessionError })
    for id, fee in pairs(self.buyFees) do
        local pool = pools.get(id)
        if pool and fee > 0 then pool:reallocKst(fee, false) end
    end
    for id, fee in pairs(self.sellFees) do
        local pool = pools.get(id)
        if pool and fee > 0 then pool:reallocKst(fee, false) end
    end
    wallet.state:commitMany(state, pools.state)
    endEvent.queue(self.uuid, amt, rem)
    wallet.sendPendingTx()
end

return {
    startEvent = startEvent,
    endEvent = endEvent,
    buyEvent = buyEvent,
    sellEvent = sellEvent,
    sessionBalChangeEvent = sessionBalChangeEvent,
    accounts = accounts,
    getAcctByUsername = getAcctByUsername,
    getAcctByUuid = getAcctByUuid,
    get = get,
    create = create,
    state = state,
}
