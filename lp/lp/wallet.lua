--- Shop wallet management.

local util = require "lp.util"
local pools = require "lp.pools"

---@class WalletPending
---@field to string
---@field amount number
---@field meta string

---@class WalletState: State
---@field PENDING WalletPending
---@field pendingout number
---@field totalout number?
---@field lastseen number?
---@field pkey string
---@field roundingFund number
---@field feeFund number
---@field secFund number
---@field dynFund number

local state = require "lp.state".open "lp.wallet" --[[@as WalletState]]
state.pendingout = state.pendingout or 0
state.roundingFund = state.roundingFund or 0
state.feeFund = state.feeFund or 0
state.secFund = state.secFund or 0
state.dynFund = state.dynFund or 0

local function getRoundingFund()
    return state.roundingFund
end

local function getDynFund()
    return state.dynFund
end

local function getFeeFund()
    return state.feeFund
end

---@class Transaction
---@field id integer
---@field from string
---@field to string
---@field value integer
---@field time string
---@field name string|nil
---@field metadata string|nil
---@field sent_metaname string|nil
---@field sent_name string|nil
---@field type string

---@class TransactionEvent
---@field type string
---@field event string
---@field transaction Transaction

local function reallocateDyn(delta, commit)
    state.dynFund = util.mRound(state.dynFund + delta)
    if commit then state.commit() end
    return state.dynFund
end

local function reallocateFee(delta, commit)
    local secprice = require "lp.secprice"
    local pool = secprice.getSecPool()
    local rate = pool.dynAlloc.rate / 2
    local fundDelta = math.max((1 - rate) * delta, -state.feeFund)
    local poolDelta = math.max(rate / (1 - rate) * fundDelta, -pool.allocatedKrist + 1)
    local oldFund = state.feeFund
    local oldPool = pool.allocatedKrist
    state.feeFund = util.mRound(state.feeFund + fundDelta)
    pool:reallocKst(poolDelta, false)
    local trueDelta = state.feeFund + pool.allocatedKrist - oldFund - oldPool
    if commit then state:commitMany(pools.state) end
    return state.feeFund, trueDelta
end

local function reallocateRounding(delta, commit)
    delta = math.max(delta, -state.roundingFund)
    state.roundingFund = util.mFloor(state.roundingFund + delta)
    if commit then state.commit() end
    return state.roundingFund
end

return {
    reallocateRounding = reallocateRounding,
    reallocateDyn = reallocateDyn,
    getRoundingFund = getRoundingFund,
    reallocateFee = reallocateFee,
    getDynFund = getDynFund,
    getFeeFund = getFeeFund,
    state = state,
}
