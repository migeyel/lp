--- New shop wallet, integrated with kstream.
local mutex = require "lp.mutex"
local config = require "lp.setup"
local kstream = require "kstream"
local log = require "lp.log"
local event = require "lp.event"
local threads = require "lp.threads"

local KRISTPAY_DOMAIN = "switchcraft.kst"
local STREAM_PATH = "/lpstream"

-- receiver uuid: string
-- sender: string (username or krist address)
-- amount: number
-- message: string?
local TransferReceivedEvent = event.register("transfer_received")

--- @class KstreamState: State
--- @field revision number? The state revision, if any.

--- @class LpOutboxOutUd The LP outbox userdata.
--- @field accountUuid string The account UUID.

--- We set UD to nil on refunds.
--- @alias LpOutboxUd LpOutboxOutUd | nil

local state = require "lp.state".open "lp.kstream" --[[@as KstreamState]]

--- Held while there's an outgoing transaction by the transaction's owner.
---
--- If Krist is down, then this mutex will be bound up by either the incoming thread
--- issuing a refund or the outgoing thread issuing a withdrawal.
local outboxMutex = mutex()

--- Variable for passing on the outbox mutex from the initial owner to the deferred
--- outbox forwarder thread.
--- @type MutexGuard?
local outboxMutexPass = outboxMutex.lock()

--- To call after setting the pass variable.
local outboxMutexPassEvent = event.register()

local pkey = config.pkey --[[@as string]]
local address = kstream.makev2address(pkey)

if not fs.isDir(STREAM_PATH) then
    log:info("Creating fresh stream")
    kstream.Stream.create(
        STREAM_PATH,
        "https://krist.dev",
        address
    )
end

local stream = kstream.Stream.open(STREAM_PATH, state.revision)

local function getIsKristUp()
    return stream:isUp()
end

---@param timeout number?
---@return number?
local function fetchBalance(timeout)
    return stream:getBalance(address, timeout)
end

local function handleOwnTx()
    stream:fetch()

    -- Need to acquire so we can issue refunds.
    local guard = outboxMutex.lock()

    local bv = stream:getBoxView()
    local tx = assert(bv:popInbox())

    if tx.type ~= "transfer" then
        guard.unlock()
        bv:commit()
        return
    end

    ---@cast tx kstream.Transfer

    if tx.to ~= address then
        guard.unlock()
        bv:commit()
        return
    end

    if tx.from == address then
        guard.unlock()
        bv:commit()
        return
    end

    log:info(("Received %d KST from %s meta %s"):format(
        tx.value,
        tx.from,
        tx.metadata
    ))

    local sessions = require "lp.sessions"
    local metaname = tx.kv.metaname or ""
    local useruuid = tx.kv.useruuid or ""
    local username = (tx.kv.username or ""):lower()
    local acct = sessions.getAcctByUsername(metaname)
              or sessions.getAcctByUuid(useruuid)
              or sessions.getAcctByUsername(username)
    if not acct then
        local ref = metaname ~= "" and metaname
                 or useruuid ~= "" and useruuid
                 or username ~= "" and username
                 or ""
        log:error("No account " .. username)
        local meta = { error = "Account '" .. ref .. "' not found" }
        local refund = kstream.makeRefundFor(pkey, address, tx, meta, nil)
        bv:setOutbox(refund)
        bv:commit()
        stream:send() -- Ignore failures *shrug*
    else
        acct:transfer(tx.value, false)
        state.revision = bv:prepare()
        sessions.state:commitMany(state)
        bv:commit()
        TransferReceivedEvent.queue(acct.uuid, tx.from, tx.value, tx.kv.message)
    end

    guard.unlock()
end

--- Removes Krist from an account and sets up a withdraw transaction. Always commits.
--- @param account Account
--- @param amount number
--- @param commit true
--- @return number delta The true amount withdrawn.
--- @return number rem The remaining balance.
local function setWithdrawTx(account, amount, commit)
    assert(commit)
    local sessions = require "lp.sessions"

    if amount > 0 then
        local bv = stream:getBoxView()
        assert(not bv:getOutbox()) -- We trust that the caller holds the mutex.

        local delta, rem = account:transfer(-amount, false)
        local receiver = account.uuid:gsub("-", "") .. "@" .. KRISTPAY_DOMAIN

        bv:setOutbox({
            to = receiver,
            amount = -delta,
            privateKey = pkey,
            meta = {},
            ud = { ---@type LpOutboxOutUd
                accountUuid = account.uuid,
            }
        })

        state.revision = bv:prepare()
        sessions.state:commitMany(state)
        bv:commit()

        return -delta, rem
    else
        return 0, account.balance
    end
end

--- Aborts an outgoing withdraw transaction and credits the account. Always commits.
---
--- Fails if the the backend doesn't know if the transaction has been sent (e.g. if the
--- request has been sent but the Krist node didn't return a response). Also fails if
--- we can't unset the transaction for some other reason.
---
--- @param commit true
--- @return boolean ok
local function unsetWithdrawTx(commit)
    assert(commit)
    local sessions = require "lp.sessions"

    local bv = stream:getBoxView()
    if not bv:isOutboxKnown() then
        bv:abort()
        return false
    end

    local outbox = bv:getOutbox()
    if not outbox then
        bv:abort()
        return true
    end

    local ud = assert(outbox.ud, "can't unset refund transactions") ---@type LpOutboxOutUd
    local account = sessions.getAcctByUuid(ud.accountUuid)
    if not account then
        -- Account was deleted after the outgoing transaction was made. Can't unset.
        bv:abort()
        return false
    end

    account:transfer(outbox.amount, false)
    bv:setOutbox()
    state.revision = bv:prepare()
    sessions.state:commitMany(state)
    bv:commit()

    return true
end

--- Sends the pending transaction.
--- @param timeout number? A timeout to abort sending after.
--- @return kstream.Result result The send result.
local function sendPendingTx(timeout)
    return stream:send(timeout)
end

--- Defers the sending of a pending transaction.
--- @param guard MutexGuard The outbox mutex guard.
local function deferSend(guard)
    outboxMutexPass = guard
    outboxMutexPassEvent.queue()
end

threads.register(function()
    log:info("Started deferred stream outbox sender thread")
    while true do
        while not outboxMutexPass do outboxMutexPassEvent.pull() end
        local guard = outboxMutexPass
        outboxMutexPass = nil
        stream:resolveOutbox()
        local bv = stream:getBoxView()
        local outbox = bv:getOutbox()
        if outbox then
            log:info("Deferred send " .. outbox.amount .. " to " .. outbox.to)
            bv:abort()
            if sendPendingTx() then
                log:info("Deferred send OK")
            else
                log:error("Deferred send failure")
                -- No timeout, so the transaction is malformed.
                local bv = stream:getBoxView()
                local outbox = assert(bv:getOutbox())
                if outbox.ud then
                    -- Outgoing withdrawal, abort and credit the account.
                    log:info("Deferred send credit")
                    bv:abort()
                    unsetWithdrawTx(true)
                else
                    -- Incoming refund, swallow the Krist.
                    log:info("Deferred send swallow")
                    bv:setOutbox()
                    bv:commit()
                end
            end
        else
            log:info("No outbox")
            bv:abort()
        end
        guard.unlock()
    end
end)

threads.register(function() while true do handleOwnTx() end end)

threads.register(function() stream:listen() end)

return {
    TransferReceivedEvent = TransferReceivedEvent,
    address = address,
    boxViewMutex = outboxMutex,
    getIsKristUp = getIsKristUp,
    fetchBalance = fetchBalance,
    sendPendingTx = sendPendingTx,
    setWithdrawTx = setWithdrawTx,
    unsetWithdrawTx = unsetWithdrawTx,
    deferSend = deferSend,
    state = state,
}
