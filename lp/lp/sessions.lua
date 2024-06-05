local state = require "lp.state".open "lp.session"
local event = require "lp.event"
local util = require "lp.util"
local pools = require "lp.pools"
local wallet = require "lp.wallet"
local stream = require "lp.stream"
local log = require "lp.log"

local accountBalanceSum = 0

---@type table<string, number?>
local assetSums = {}

---@type table<string, Account|nil>
state.accounts = state.accounts or {}

--- Map of lowercase usernames to uuids.
---@type table<string, string>
local uuidIndex = {}

for _, v in pairs(state.accounts) do
    if v.uuid then
        uuidIndex[v.username:lower()] = v.uuid
    end
    accountBalanceSum = accountBalanceSum + v.balance
    for k, a in pairs(v.assets or {}) do
        assetSums[k] = (assetSums[k] or 0) + a
    end
end

---@type Session|nil
state.session = nil
state.commit()

local ECHEST_ALLOCATION_PRICE = 20

-- uuid: string
local startEvent = event.register("session_start")

-- uuid: string
-- transferred: number
-- remaining: number
-- summary: { paid: number, earned: number, fees: number }
local endEvent = event.register("session_end")

-- id: string
local buyEvent = event.register("session_buy")

-- id: string
local sellEvent = event.register("session_sell")

-- uuid: string
local sessionBalChangeEvent = event.register("session_bal_change")

local mFloor, mCeil = util.mFloor, util.mCeil

local frequencyMap = {}

for _, account in pairs(state.accounts) do
    if account.storageFrequency then
        frequencyMap[account.storageFrequency] = account
    end
end

---@class Account
---@field username string
---@field balance number
---@field assets table<string, number?>?
---@field uuid string
---@field storageFrequency number|nil
---@field persist true|nil
local Account = {}

---Sets the username for an account, creating it if needeed.
---@param username string
---@param uuid string
---@param commit boolean
---@return Account
local function setAcct(uuid, username, commit)
    local acct = state.accounts[uuid] or {
        balance = 0,
        uuid = uuid,
    }

    if acct.username then
        uuidIndex[acct.username:lower()] = nil
        uuidIndex[username:lower()] = uuid
    end

    acct.username = username
    state.accounts[uuid] = acct

    if commit then state.commit() end

    return setmetatable(acct, { __index = Account })
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

---@param commit boolean
---@return boolean
function Account:togglePersistence(commit)
    if self.persist then
        self.persist = nil
    else
        self.persist = true
    end

    if commit then state.commit() end
    return not not self.persist
end

---@param frequency number
---@param commit boolean
---@return boolean
---@nodiscard
function Account:allocFrequency(frequency, commit)
    if self.storageFrequency then return false end
    if frequencyMap[frequency] then return false end
    frequencyMap[frequency] = self
    self.storageFrequency = frequency
    if commit then state.commit() end
    return true
end

---@param delta number
---@param commit boolean
---@return number newDelta The true transferred amount.
---@return number newBal The remaining balance of the account.
function Account:transfer(delta, commit)
    local balance = self.balance
    delta = math.max(delta, -balance)
    accountBalanceSum = accountBalanceSum - balance
    balance = util.mFloor(balance + delta)
    accountBalanceSum = accountBalanceSum + balance
    self.balance = balance

    if commit then state.commit() end

    local session = state.session
    if session and session:account() == self then
       sessionBalChangeEvent.queue(self.uuid)
    end

    return delta, balance
end

---@param id string
---@return number
function Account:getAsset(id)
    if not self.assets then return 0 end
    return self.assets[id] or 0
end

---@param id string
---@param amount number
function Account:setAsset(id, amount)
    if not self.assets then self.assets = {} end
    self.assets[id] = amount ~= 0 and amount or nil
end

---@param id string
---@param delta number
---@param commit boolean
---@return number newDelta The true transferred amount.
---@return number newBal The remaining securities balance of the account.
function Account:transferAsset(id, delta, commit)
    local balance = self:getAsset(id)
    delta = math.max(delta, -balance)
    assetSums[id] = (assetSums[id] or 0) - balance
    balance = util.mFloor(balance + delta)
    assetSums[id] = (assetSums[id] or 0) + balance
    self:setAsset(id, balance)

    if commit then state.commit() end

    return delta, balance
end

---@param delta number
---@param commit boolean
---@return boolean
function Account:tryTransfer(delta, commit)
    local balance = self.balance
    if balance < -delta then return false end
    accountBalanceSum = accountBalanceSum - balance
    balance = balance + delta
    accountBalanceSum = accountBalanceSum + balance
    self.balance = balance

    if commit then state.commit() end

    local session = state.session
    if session and session:account() == self then
       sessionBalChangeEvent.queue(self.uuid)
    end

    return true
end

---@param id string
---@param delta number
---@param commit boolean
---@return boolean
function Account:tryTransferAsset(id, delta, commit)
    local balance = self:getAsset(id)
    if balance < -delta then return false end
    assetSums[id] = assetSums[id] - balance
    balance = balance + delta
    assetSums[id] = assetSums[id] + balance
    self:setAsset(id, balance)

    if commit then state.commit() end

    return true
end

---@param pool Pool
---@param amount number
---@param commit boolean
---@return number earned
---@return number fee
function Account:sell(pool, amount, commit)
    assert(type(amount == "number") and amount % 1 == 0)

    local priceNoFee = pool:sellPrice(amount)
    local fee = pool:sellFee(amount)
    local priceWithFee = util.mFloor(priceNoFee - fee)

    self:transfer(priceWithFee, false)
    pool:reallocItems(amount, false)
    pool:reallocKst(-priceNoFee, false)
    wallet.reallocateFee(fee / 2, false)
    if commit then pools.state:commitMany(state, wallet.state) end

    sellEvent.queue(pool:id())
    return priceWithFee, fee
end

---@param pool Pool
---@param amount number
---@param commit boolean
---@return boolean ok
---@return number paid
---@return number fee
function Account:tryBuy(pool, amount, commit)
    assert(type(amount == "number") and amount % 1 == 0)

    local priceNoFee = pool:buyPrice(amount)
    local fee = pool:buyFee(amount)
    local priceWithFee = util.mCeil(priceNoFee + fee)
    if self.balance < priceWithFee then return false, 0, 0 end

    self:transfer(-priceWithFee, false)
    pool:reallocItems(-amount, false)
    pool:reallocKst(priceNoFee, false)
    wallet.reallocateFee(fee / 2, false)
    if commit then pools.state:commitMany(state, wallet.state) end

    buyEvent.queue(pool:id())
    return true, priceWithFee, fee
end

---@class Session
---@field uuid string
---@field lastActive number
---@field paid number
---@field earned number
---@field fees number
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

    setAcct(uuid, username, false)

    state.session = {
        uuid = uuid,
        lastActive = os.epoch("utc"),
        paid = 0,
        earned = 0,
        fees = 0,
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
function Session:sellPriceWithFee(pool, amount)
    local price = pool:sellPrice(amount)
    local sellFee = pool:sellFee(amount)
    return mFloor(price - sellFee)
end

---@param pool Pool
---@param amount number
---@param commit boolean
---@return boolean
function Session:tryBuy(pool, amount, commit)
    assert(type(amount == "number") and amount % 1 == 0)
    local ok, paid, fee = self:account():tryBuy(pool, amount, false)
    if not ok then return false end
    self.lastActive = os.epoch("utc")
    self.paid = self.paid + paid
    self.fees = self.fees + fee
    if commit then pools.state:commitMany(state, wallet.state) end
    return true
end

---@param pool Pool
---@param amount number
---@param commit boolean
function Session:sell(pool, amount, commit)
    assert(type(amount == "number") and amount % 1 == 0)
    local earned, fee = self:account():sell(pool, amount, false)
    self.lastActive = os.epoch("utc")
    self.earned = self.earned + earned
    self.fees = self.fees + fee
    if commit then pools.state:commitMany(state, wallet.state) end
    sellEvent.queue(pool:id())
end

function Session:close()
    local acct = self:account()
    local summary = {
        paid = self.paid,
        earned = self.earned,
        fees = self.fees,
    }

    if acct.persist or not stream.getIsKristUp() then
        state.session = nil
        state:commitMany(pools.state)
        endEvent.queue(self.uuid, 0, acct.balance, summary)
    else
        state.session = nil
        state:commitMany(pools.state)
        local guard = stream.boxViewMutex.tryLock(10)
        if not guard then
            return endEvent.queue(self.uuid, 0, acct.balance, summary)
        end
        local amt, rem = stream.setWithdrawTx(acct, math.floor(acct.balance), true)
        local result = stream.sendPendingTx(10)
        if result == "error" then
            stream.unsetWithdrawTx(true)
            log:error("Error while sending close tx: " .. acct.uuid .. " " .. amt)
            guard.unlock()
            endEvent.queue(self.uuid, 0, acct.balance, summary)
        elseif result == "timeout" then
            log:warn("Krist timeout sending close tx: " .. acct.uuid .. " " .. amt)
            stream.deferSend(guard)
            endEvent.queue(self.uuid, amt, rem, summary)
        else
            log:info("Sent " .. amt .. " krist to " .. acct.uuid)
            guard.unlock()
            endEvent.queue(self.uuid, amt, rem, summary)
        end
    end
end

local function totalBalances()
    return accountBalanceSum
end

local function totalAssets(id)
    return assetSums[id] or 0
end

--- @param amount number
--- @param commit boolean
--- @return table<string, number>, number, number
local function distribute(amount, commit)
    amount = math.max(0, amount)
    local _, trueFundDelta = wallet.reallocateFee(-amount, false)
    local toDistribute = -trueFundDelta
    local total = totalAssets("lp:security~NONE")
    local dists = {}
    for _, acct in accounts() do
        local secs = acct:getAsset("lp:security~NONE")
        local ratio = secs / total
        local dist = util.mFloor(ratio * toDistribute)
        acct:transfer(dist, false)
        if dist > 0 then
            dists[acct.uuid] = dist
        end
    end
    if commit then state:commitMany(wallet.state, pools.state) end
    return dists, toDistribute, total
end

return {
    ECHEST_ALLOCATION_PRICE = ECHEST_ALLOCATION_PRICE,
    startEvent = startEvent,
    endEvent = endEvent,
    buyEvent = buyEvent,
    sellEvent = sellEvent,
    sessionBalChangeEvent = sessionBalChangeEvent,
    accounts = accounts,
    setAcct = setAcct,
    getAcctByUsername = getAcctByUsername,
    getAcctByUuid = getAcctByUuid,
    get = get,
    create = create,
    totalBalances = totalBalances,
    totalAssets = totalAssets,
    state = state,
    distribute = distribute,
}
