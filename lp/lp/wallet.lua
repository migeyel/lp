--- Shop wallet management.

local config = require "lp.setup"
local state = require "lp.state".open "lp.wallet"
local util = require "lp.util"
local log = require "lp.log"
local threads = require "lp.threads"
local jua = require "jua"
local w = require "w"
local r = require "r"
local k = require "k"

local ROUNDING_BIAS = 0.01
local SOCKET_MAX_IDLE_MS = 15000

state.pendingout = state.pendingout or 0
state.roundingFund = state.roundingFund or 0
state.commit()

local function getRoundingFund()
    return state.roundingFund
end

-- Check if the pkey has changed.
if state.pkey ~= config.pkey then
    log:info("Private key has changed from previous run")
    state.totalout = nil
    state.lastseen = nil
    state.pkey = config.pkey
    state.commit()
end

local json = {
    encode = textutils.serializeJSON,
    decode = textutils.unserialiseJSON,
}

r.init(jua)
w.init(jua)
k.init(jua, json, w, r)

local address = k.makev2address(config.pkey)

---@param str string
---@return boolean, boolean
local function isValidAddress(str)
    if str:match("^[a-f0-9]+$") and #str == 10 then return true, false end
    if str:match("^k[a-z0-9]+$") and #str == 10 then return true, false end
    local m, n = str:match("^([a-z0-9-_]+)@([a-z0-9]+)%.kst$")
    if m and n and #m <= 32 and #n <= 64 then return true, true end
    return false, false
end

--- Builds and commits to sending a transaction to someone.
---@param receiver string
---@param amount integer
---@param cm table
---@param commit boolean
local function setPendingTx(receiver, amount, cm, commit)
    log:info(("Now starting to process sending K%d to %s"):format(
        amount,
        receiver
    ))

    if receiver == address then
        log:error("Rejected for being self-send")
        return
    end
    if amount <= 0 then
        log:error("Rejected for being <= 0")
        return
    end
    if state.PENDING then
        log:error("Rejected because of existing pending tx")
    end
    local valid, named = isValidAddress(receiver)
    if not valid then
        log:error("Rejected for not being a valid receiver")
        return
    end

    local sendAmt = nil
    if math.fmod(amount, 1) == 0 then
        sendAmt = amount
    else
        local integral = math.floor(amount)
        local frac = amount - integral
        if state.roundingFund >= 1 and math.random() + ROUNDING_BIAS < frac then
            log:info("Rounded " .. amount .. " up to " .. integral + 1)
            sendAmt = integral + 1
            state.roundingFund = util.mFloor(state.roundingFund - (1 - frac))
        else
            log:info("Rounded " .. amount .. " down to " .. integral)
            state.roundingFund = util.mFloor(state.roundingFund + frac)
            sendAmt = integral
        end
        log:info("Rounding fund now at " .. state.roundingFund)
    end

    if sendAmt <= 0 then return end

    -- Encode commonMeta.
    local cmCopy = {}
    for i, v in pairs(cm) do
        cmCopy[i] = v
    end

    if named then
        cmCopy[1] = receiver
    end

    local metaBuf = {}
    for i, v in ipairs(cmCopy) do
        cmCopy[i] = nil
        metaBuf[#metaBuf + 1] = v
    end

    for i, v in pairs(cmCopy) do
        metaBuf[#metaBuf + 1] = i .. "=" .. v
    end

    -- Commit pending transaction to local state.
    state.pendingout = state.pendingout + sendAmt
    state.PENDING = {
        to = receiver,
        amount = sendAmt,
        idempotencyToken = tostring(math.random(0, 2 ^ 31 - 2)),
        meta = table.concat(metaBuf, ";"),
    }

    if commit then
        state.commit()
        log:info("Tx K" .. sendAmt .. " to " .. receiver .. " committed")
    else
        log:info("Tx K" .. sendAmt .. " to " .. receiver .. " is now in memory")
    end
end

local function sendPendingTx()
    if not state.PENDING then return end

    -- Send to node.
    local ok, e = jua.await(
        k.makeTransaction,
        state.pkey,
        state.PENDING.to,
        state.PENDING.amount,
        state.PENDING.meta
        -- IDEMPOTENCYYYY
    )

    -- Clean up local state.
    if ok then
        log:info("Tx K" .. state.PENDING.amount .. " to "
                 .. state.PENDING.to .. " confirmed")
        state.totalout = state.totalout + state.PENDING.amount
        state.pendingout = 0
        state.PENDING = nil
        state.commit()
        return true
    else
        log:error("Tx K" .. state.PENDING.amount .. " to "
                  .. state.PENDING.to .. " failed: " .. tostring(e.message))
        state.pendingout = 0
        state.PENDING = nil
        state.commit()
        return false
    end
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

---@param tx Transaction
---@param outCm table
---@param commit boolean
local function setPendingRefund(tx, outCm, commit)
    local cm = k.parseMeta(tx.metadata or "").meta ---@type table<string, string>
    local refundAddress = tx.from

    if cm["return"] then
        if isValidAddress(cm["return"]) then
            refundAddress = cm["return"]
        else
            local err = { error = "Invalid return address" }
            setPendingTx(refundAddress, tx.value, err, commit)
            return
        end
    end

    if not cm.error and cm["return"] ~= "false" then
        setPendingTx(refundAddress, tx.value, outCm, commit)
    end
end

--- Refunds a lost transaction, setting its id as the last seen id.
---@param tx Transaction
local function refundLostTx(tx)
    local err = { error = "We didn't catch your transaction back when it was sent" }
    state.lastseen = tx.id
    setPendingRefund(tx, err, true)
    sendPendingTx()
end

local function refundLostTxs()
    local minSeenId = math.huge
    local seenTxs = {} ---@type table<integer, Transaction>
    local offset = 0
    repeat
        ---@type nil, Transaction[]
        local _, txs = jua.await(k.addressTransactions, address, 50, offset)

        if #txs == 0 then break end

        -- Check if the new data overlaps with the last of the given txs.
        local overlaps = false
        for _, tx in ipairs(txs) do
            if seenTxs[tx.id] then
                overlaps = true
                break
            end
        end

        if not overlaps and offset ~= 0 then
            offset = math.max(offset - 45, 0)
        else
            offset = offset + 45
            for _, tx in ipairs(txs) do
                minSeenId = math.min(minSeenId, tx.id)
                seenTxs[tx.id] = tx
                if tx.id <= state.lastseen then break end
            end
        end
    until minSeenId <= state.lastseen

    -- Remove the last known transaction.
    seenTxs[minSeenId] = nil

    local keys = {} ---@type integer[]
    for key in pairs(seenTxs) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    for i = 1, #keys do
        local tx = seenTxs[keys[i]]
        assert(tx.id > state.lastseen)
        if tx.to == address and tx.from ~= address then
            refundLostTx(tx)
        else
            state.lastseen = tx.id
            state.commit()
        end
    end
end

local function reallocateRounding(delta, commit)
    delta = math.max(delta, -state.roundingFund)
    state.roundingFund = util.mFloor(state.roundingFund + delta)
    if commit then state.commit() end
    return state.roundingFund
end

local function checkTotalout()
    local ok1, ok2, data = pcall(jua.await, k.address, address)
    if ok1 and ok2 then
        if state.totalout then
            local outN = state.totalout
            local outP = state.totalout + state.pendingout
            if data.totalout ~= outN and data.totalout ~= outP then
                error(
                    "the total output of the main wallet is different from " ..
                    "expected. Did someone meddle with it or did the server " ..
                    "restore from a backup?"
                )
            end

            -- Recover the pending transaction.
            -- This can fail if a transaction with the exact same amount is sent
            -- by someone else, which really really really shouldn't happen.
            if data.totalout == outN and state.pendingout ~= 0 then
                log:info("Recovering pending transaction")
                sendPendingTx()
            end
        else
            state.totalout = data.totalout
            state.commit()
        end
        log:info("Totalout check passed")
    else
        error("Totalout check failed: " .. (ok1 or ok2 or "unknown error"))
    end
end

local function checkLastseen()
    ---@type boolean, boolean, Transaction[]
    local ok1, ok2, txs = pcall(jua.await, k.addressTransactions, address)
    if ok1 and ok2 then
        if state.lastseen then
            if #txs > 0 then
                local last = txs[1]
                if last.id > state.lastseen then
                    refundLostTxs()
                end
            else
                state.lastseen = nil
                state.commit()
            end
        else
            state.lastseen = txs[1].id
            state.commit()
        end
        log:info("Lost transaction check finished")
    else
        error("Lost transaction check failed: " .. (ok1 or ok2 or "unknown error"))
    end
end

local function commitWith(t, ...)
    if select("#", ...) == 0 then
        state:commitMany(unpack(t))
    else
        return select(1, ...)(t, select(2, ...))
    end
end

local function fetchBalance()
    local ok, data = assert(jua.await(k.address, address))
    return ok and data.balance
end

local socket = nil
local lastHeartbeat = os.epoch("utc")

---@param ev TransactionEvent
local function handleOwnTx(ev)
    if ev.type ~= "event" then return end
    if ev.event ~= "transaction" then return end
    local tx = ev.transaction
    if tx.to ~= address then return end
    if tx.from == address then return end

    log:info(("Received %d KST from %s meta %s"):format(
        tx.value,
        tx.from,
        tx.metadata
    ))

    local sessions = require "lp.sessions"
    local cm = k.parseMeta(tx.metadata or "").meta
    local username = (cm.username or ""):lower()
    local acct = sessions.getAcct(username)
    if not acct then
        log:error("No account " .. username)
        local err = { error = "Account " .. username .. " not found" }
        state.lastseen = tx.id
        setPendingRefund(tx, err, true)
        sendPendingTx()
        return
    else
        acct:transfer(tx.value, false)
        state.lastseen = tx.id
        sessions.commitWith { state }
    end
end

local function handleKeepalive()
    log:debug("Krist keepalive")
    lastHeartbeat = os.epoch("utc")
end

local function hearbeatWatchdog()
    while not socket do
        sleep(SOCKET_MAX_IDLE_MS / 1000)
    end
    while true do
        if os.epoch("utc") - lastHeartbeat > SOCKET_MAX_IDLE_MS then
            -- Not elegant at all, but I need to check for lost txs and I can't
            -- send them becuase I don't sync with the other programs that are
            -- sending stuff as well.
            -- This reboots the system and recovers lost txs.
            error("socket idle limit reached")
        end
        sleep((SOCKET_MAX_IDLE_MS - os.epoch("utc") + lastHeartbeat) / 1000)
    end
end

local function juaThread()
    jua.go(function()
        socket = select(2, assert(jua.await(k.connect, state.pkey)))
        log:info("Socket open")
        local ok, e = jua.await(socket.subscribe, "ownTransactions", handleOwnTx)
        assert(ok, e.message)
        socket.on("keepalive", handleKeepalive)
    end)
end

threads.register(juaThread)
threads.register(hearbeatWatchdog)

return {
    address = address,
    reallocateRounding = reallocateRounding,
    checkTotalout = checkTotalout,
    checkLastseen = checkLastseen,
    getRoundingFund = getRoundingFund,
    setPendingRefund = setPendingRefund,
    setPendingTx = setPendingTx,
    sendPendingTx = sendPendingTx,
    fetchBalance = fetchBalance,
    commitWith = commitWith,
}
