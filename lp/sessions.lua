local KRISTPAY_DOMAIN = "switchcraft.kst"

local state = require "lp.state".open "lp.session"
local event = require "lp.event"
local util = require "lp.util"
local pools= require "lp.pools"
local wallet = require "lp.wallet"

---@type table<string, Account|nil>
state.accounts = state.accounts or {}
---@type Session|nil
state.session = nil
state.commit()

---@class Account
---@field username string
---@field balance number
local Account = {}

---@param username string
---@param commit boolean
---@return Account
local function getAcctOrCreate(username, commit)
    local acct = state.accounts[username]
    if not acct then
        acct = {
            username = username,
            balance = 0,
        }
        state.accounts[username] = acct
        if commit then state.commit() end
    end
    return setmetatable(acct, { __index = Account })
end

---@param username string
---@return Account | nil
local function getAcct(username)
    local acct = state.accounts[username]
    if acct then return setmetatable(acct, { __index = Account }) end
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
    return delta, self.balance
end

---@param delta number
---@param commit boolean
---@return boolean
function Account:tryTransfer(delta, commit)
    if self.balance < -delta then return false end
    self.balance = self.balance + delta
    if commit then state.commit() end
    return true
end

---@class Session
---@field user string
---@field balance number
---@field lastActive number
---@field buyFees table
---@field sellFees table
---@field closed boolean
local Session = {}

-- user: string
local startEvent = event.register()

-- user: string
-- transferred: number
-- remaining: number
local endEvent = event.register()

-- no params
local buyEvent = event.register()

-- no params
local sellEvent = event.register()

-- user: string
local sessionBalChangeEvent = event.register()

local mFloor, mCeil = util.mFloor, util.mCeil

---@return Session|nil
local function get()
    local s = state.session
    if s then return setmetatable(s, { __index = Session }) end
end

---@param username string
---@param commit boolean
---@return Session|nil
local function create(username, commit)
    if get() then return end

    username = username:lower()

    getAcctOrCreate(username, false)

    state.session = {
        user = username,
        lastActive = os.epoch("utc"),
        buyFees = {},
        sellFees = {},
    }

    if commit then state.commit() end

    startEvent.queue(username)

    return setmetatable(state.session, { __index = Session })
end

---@return Account
function Session:account()
    -- This doesn't error because create() makes the account whenever a new
    -- session starts.
    return assert(state.accounts[self.user])
end

---@return number
function Session:balance()
    return self:account().balance
end

---@param amount number
---@param commit boolean
function Session:transfer(amount, commit)
    self:account():transfer(amount, commit)
    sessionBalChangeEvent.queue()
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
    if commit then pools.commitWith { state } end

    buyEvent.queue()

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
    if commit then pools.commitWith { state } end

    sellEvent.queue()
end

local function closedSessionError()
    error("attempt to use a closed session")
end

function Session:close()
    local acct = self:account()
    local balFloor = math.floor(acct.balance)
    local delta, rem = acct:transfer(-balFloor, false)
    local amt = -delta
    wallet.setPendingTx(self.user .. "@" .. KRISTPAY_DOMAIN, amt,  {}, false)
    state.session = nil
    setmetatable(self, { __index = closedSessionError })
    wallet.commitWith { state }
    endEvent.queue(self.user, amt, rem)
    wallet.sendPendingTx()
end

local function commitWith(t, ...)
    if select("#", ...) == 0 then
        state:commitMany(unpack(t))
    else
        return select(1, ...)(t, select(2, ...))
    end
end

return {
    startEvent = startEvent,
    endEvent = endEvent,
    buyEvent = buyEvent,
    sellEvent = sellEvent,
    sessionBalChangeEvent = sessionBalChangeEvent,
    accounts = accounts,
    getAcct = getAcct,
    getAcctOrCreate = getAcctOrCreate,
    get = get,
    create = create,
    commitWith = commitWith,
}
