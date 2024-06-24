--- New shop wallet, integrated with kstream.
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

local sendSuccessEvent = event.register()
local sendFailureEvent = event.register()

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

function stream.onTransaction(ctx, tx)
    if tx.type ~= "transfer" then return end
    ---@cast tx kstream.Transfer

    if tx.to ~= address then return end
    if tx.from == address then return end

    log:info(("Received %d KST from %s meta %s"):format(
        tx.value,
        tx.from,
        tx.metadata
    ))

    local sessions = require "lp.sessions"
    local metaname = tx.sent_metaname or ""
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
        local refund = kstream.makeRefund(pkey, address, tx, meta, nil)
        if refund then ctx:enqueueSend(refund) end
    else
        acct:transfer(tx.value, false)

        function ctx.onPrepare(revision)
            state.revision = revision
            sessions.state:commitMany(state)
        end

        function ctx.afterCommit()
            TransferReceivedEvent.queue(acct.uuid, tx.from, tx.value, tx.kv.message)
        end

        return
    end
end

function stream.onSendSuccess(ctx, tx, uuid)
    log:info("Sent " .. tx.amount .. " KST to " ..tx.to)

    function ctx.afterCommit()
        sendSuccessEvent.queue(uuid)
    end
end

function stream.onSendFailure(ctx, tx, uuid)
    log:warn("Failed sending " .. tx.amount .. " KST to " .. tx.to)

    function ctx.afterCommit()
        sendFailureEvent.queue(uuid)
    end

    local ud = tx.ud ---@type LpOutboxOutUd

    -- Refund failure, nothing else to do.
    if not ud then
        log:warn("Send failure is a refund, giving up")
        return
    end

    -- Withdraw failure, credit the account.
    local sessions = require "lp.sessions"
    local acct = sessions.getAcctByUuid(ud.accountUuid)
    if not acct then return end
    acct:transfer(tx.amount, false)
    log:info("Crediting account back")

    function ctx.onPrepare(revision)
        state.revision = revision
        sessions.state:commitMany(state)
    end
end

--- Removes Krist from an account and sets up a withdraw transaction. Always commits.
--- @param account Account
--- @param amount number
--- @param commit true
--- @return boolean ok If the transaction was set, or timed out waiting for the mutex.
--- @return number delta The true amount withdrawn.
--- @return number rem The remaining balance.
--- @return string? uuid The pending transaction uuid, if any.
local function setWithdrawTx(account, amount, commit)
    assert(commit)
    local sessions = require "lp.sessions"

    if amount > 0 then
        local delta, rem = account:transfer(-amount, false)
        local receiver = account.uuid:gsub("-", "") .. "@" .. KRISTPAY_DOMAIN
        local uuid

        local ok = stream:begin(function(ctx)
            uuid = ctx:enqueueSend({
                to = receiver,
                amount = -delta,
                privateKey = pkey,
                meta = {
                    ["return"] = account.username .. "@lp.kst",
                },
                ud = { ---@type LpOutboxOutUd
                    accountUuid = account.uuid,
                }
            })

            function ctx.onPrepare(revision)
                state.revision = revision
                sessions.state:commitMany(state)
            end
        end, 10)

        return ok, -delta, rem, uuid
    else
        return true, 0, account.balance
    end
end

--- Sends the pending transaction.
--- @param uuid string? The transaction uuid.
--- @param timeout number? A timeout to abort sending after.
--- @return "ok"|"error"|"timeout" result The send result.
local function sendPendingTx(uuid, timeout)
    if not uuid then return "ok" end
    local timer = timeout and os.startTimer(timeout) or -1
    while true do
        local e, p1 = event.pull()
        if e == sendSuccessEvent and p1 == uuid then
            os.cancelTimer(timer)
            return "ok"
        elseif e == sendFailureEvent and p1 == uuid then
            os.cancelTimer(timer)
            return "error"
        elseif e == "timer" and p1 == timer then
            return "timeout"
        end
    end
end

threads.register(function() stream:run() end)

return {
    TransferReceivedEvent = TransferReceivedEvent,
    address = address,
    getIsKristUp = getIsKristUp,
    fetchBalance = fetchBalance,
    sendPendingTx = sendPendingTx,
    setWithdrawTx = setWithdrawTx,
    state = state,
}
