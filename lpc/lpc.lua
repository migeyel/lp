local unet = require "unet.client"
local rng = require "unet.common.rng"
local proto = require "lpc.proto"

local LP_CHANNEL = "lp"
local PG231_UUID = "eddfb535-16e1-4c6a-8b6e-3fcf4b85dc73"

local function mapFailure(t)
    if t.missingParameter then
        return "missing parameter: " .. t.missingParameter.parameter
    elseif t.noFrequency then
        return "user has no ender storage frequency allocated"
    elseif t.notEnoughFunds then
        return "not enough funds"
    elseif t.priceLimitExceeded then
        return "price limit exceeded"
    elseif t.noSuchPoolLabel then
        return ("no such pool: %q"):format(t.noSuchPoolLabel.label)
    elseif t.noSuchPoolItem then
        return ("item %s doesn't match any pool"):format(t.noSuchPoolItem.item)
    elseif t.noSuchAccount then
        return "you don't have an account registered"
    elseif t.buySlotOccupied then
        return "the given slot isn't empty"
    elseif t.sellSlotEmpty then
        return "the given slot is empty"
    elseif t.buyImproperRace then
        return "the given slot changed mid-transfer"
    elseif t.sellImproperRace then
        return "the given slot changed mid-transfer"
    end
end

--- @class lpc.Session
--- @field private _rid number
--- @field private _ch string
--- @field private _s unetc.Session
local Session = {}

--- @param field string
--- @param tbl table
--- @return table
function Session:_request(field, tbl)
    local rid = self._rid
    self._rid = rid + 1
    self._s:send(PG231_UUID, LP_CHANNEL, self._ch, proto.Request.serialize {
        id = rid,
        [field] = tbl,
    })

    while true do
        local _, sid, uuid, ch, _, m = os.pullEvent("unet_message")
        if sid == self._s:id() and uuid == PG231_UUID and ch == self._ch then
            local res = proto.Response.deserialize(m)
            if res.id == rid then return res end
        end
    end
end

--- @class lpc.Info
--- @field label string The pool label.
--- @field item string The pool item.
--- @field nbt string? The pool NBT hash, or nil if none.
--- @field allocatedItems number The number of allocated items.
--- @field allocatedKrist number The number of allocated Krist.

--- Gets pool info from a given label.
--- @param label string The pool label.
--- @return lpc.Info? info The pool info, or nil on failure.
--- @return string? error
function Session:info(label)
    local res = self:_request("info", { label = label })
    if res.failure then return nil, mapFailure(res.failure) end
    return res.success.info
end

--- @class lpc.Buy
--- @field amount number The amount of items bought, may be less than requested.
--- @field spent number The amount of Krist spent, including fees.
--- @field fees number The amount of Krist spent, only on fees.
--- @field balance number The remaining balance.
--- @field allocatedItems number The remaining allocated items in the pool.
--- @field allocatedKrist number The remaining allocated Krist in the pool.

--- Buys an item.
--- @param slot number The ender storage slot to deliver to.
--- @param label string The pool label.
--- @param amount number The desired number of items to buy.
--- @param maxPerItem number The maximum price to pay per item on execution.
--- @return lpc.Buy? buy The order execution result, or nil on failure
--- @return string? error
function Session:buy(slot, label, amount, maxPerItem)
    local res = self:_request("buy", {
        label = label,
        slot = slot,
        amount = amount,
        maxPerItem = maxPerItem,
    })

    if res.failure then return nil, mapFailure(res.failure) end
    return res.success.buy
end

--- @class lpc.Sell
--- @field amount number The amount of items sold, may be less than requested.
--- @field earned number The amount of Krist earned, including fees.
--- @field fees number The amount of Krist not earned due to fees.
--- @field balance number The remaining balance.
--- @field allocatedItems number The remaining allocated items in the pool.
--- @field allocatedKrist number The remaining allocated Krist in the pool.

--- Sells an item.
--- @param slot number The ender storage slot to take from.
--- @param minPerItem number The minimum amount earned per items on execution.
--- @return lpc.Sell? sell The order execution result, or nil on failure.
--- @return string? error
function Session:sell(slot, minPerItem)
    local res = self:_request("sell", { slot = slot })
    if res.failure then return nil, mapFailure(res.failure) end
    return res.success.sell
end

--- @class lpc.Account
--- @field balance number The account balance.

--- Queries information on an account.
--- @return lpc.Account? account The account info, or nil on failure.
--- @return string? error
function Session:account()
    local res = self:_request("account", {})
    if res.failure then return nil, mapFailure(res.failure) end
    return res.success.account
end

--- @param token string
--- @param modem Modem?
--- @param timeout number?
--- @return lpc.Session? session The session, or nil on timeout.
local function connect(token, modem, timeout)
    local channel = rng.random(32)
    local session = unet.connect(token, modem, timeout)
    if not session then return end
    session:open(channel)
end

return {
    connect = connect,
}
