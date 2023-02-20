local inventory = require "lp.inventory"
local state = require "lp.state".open "lp.echest"
local mutex = require "lp.mutex"
local log = require "lp.log"
local util = require "lp.util"

---@type table | nil
state.PENDING = state.PENDING or nil

local echestMutex = mutex()

local turtleName = peripheral.find("modem").getNameLocal()

local echest, dumpchest
for _, c in ipairs { peripheral.find("ender_storage") } do
    if c.isPersonal() then
        echest = c
    else
        dumpchest = c
    end
end

assert(echest, "missing personal chest")
assert(echest.areComputerChangesEnabled(), "missing echest emerald")
assert(dumpchest, "missing dumpchest")

local residentFrequency = util.freq2Num(echest.getFrequency())

---@param f number
---@async
local function setFrequency(f)
    if residentFrequency ~= f then
        residentFrequency = f
        echest.setFrequency(util.num2Freq(f))
    end
end

--- Pulls a number of items into an ender storage following a plan:
--- - At first, try to pull everything into the given slot.
--- - If that fails, try to pull everything into any slot.
--- - If that fails, pull everything into the dump chest.
---@param amount number How many items are in the 16th turtle slot to be sent.
---@param slot number Which slot to try and send the items into initially.
---@return boolean ok Whether the transfer succeeded in the first try.
---@return number dumpAmt How many items were dumped.
---@async
local function pullPullDump(slot, amount)
    -- Pull into the desired slot.
    local firstPullAmt = echest.pullItems(turtleName, 16, nil, slot)
    if firstPullAmt >= amount then
        return true, 0
    end

    -- Pull into any space available.
    local secondPullAmt = 0
    repeat
        local pulled = echest.pullItems(turtleName, 16)
        secondPullAmt = secondPullAmt + pulled
    until pulled == 0

    -- Pull into the dump chest.
    local dumpAmt = 0
    while firstPullAmt + secondPullAmt + dumpAmt < amount do
        dumpAmt = dumpAmt + dumpchest.pullItems(turtleName, 16)
    end

    return false, dumpAmt
end

---@param frequency number
---@param slot number
local function getItemDetail(frequency, slot)
    setFrequency(frequency)
    return echest.getItemDetail(slot)
end

---@param frequency number The frequency number to push to.
---@param item string The item id.
---@param nbt string The nbt string, or "NONE".
---@param amount number The desired amount of items to push.
---@param slot number The slot to push the items into.
---@return table|"NONEMPTY"
---@nodiscard
---@async
local function preparePush(frequency, item, nbt, amount, slot)
    local echestGuard = echestMutex.lock()
    assert(not state.PENDING) -- The mutex should make this always true.

    log:info("Preparing to push")
    setFrequency(frequency)

    -- Check that an output slot exists.
    local detail = echest.getItemDetail(slot)
    if detail then
        echestGuard.unlock()
        return "NONEMPTY"
    end

    -- Push items to the temporary turtle slot 16.
    local turtleGuard = inventory.turtleMutex.lock()
    local trueAmount = inventory.get().pushItems(
        turtleName,
        item,
        amount,
        16,
        nbt
    )

    return {
        amount = trueAmount,

        ---@async
        rollback = function()
            log:info("Push rollback")

            -- Abort, pull items back to storage.
            inventory.get().pullItems(turtleName, 16)

            turtleGuard.unlock()
            echestGuard.unlock()
        end,

        ---@return boolean ok Whether the transfer was to the specified slot.
        ---@return number dumpAmt How many items were dumped.
        ---@nodiscard
        ---@async
        commit = function(...)
            log:info("Push commit")

            -- Commit the pending transfer along with transaction results.
            state.PENDING = { slot = slot }
            state:commitMany(...)

            local ok, dumpAmt = pullPullDump(slot, trueAmount)

            turtleGuard.unlock()

            -- Commit transfer "success".
            state.PENDING = nil
            state.commit()

            log:info("Push complete")
            echestGuard.unlock()

            return ok, dumpAmt
        end,
    }
end

---@param frequency number The frequency number to pull from.
---@param slot number The slot to pull from.
---@param item string The item id to check after pulling.
---@param nbt string The item NBT to check after pulling.
---@return "OK"|"MISMATCH"|"MISMATCH_BLOCKED" # The transfer status.
---@return table|nil|number # The table, the number of dumped items, or nil.
---@nodiscard
---@async
local function preparePull(frequency, slot, item, nbt)
    local echestGuard = echestMutex.lock()
    assert(not state.PENDING) -- The mutex should make this always true.

    log:info("Preparing to pull")
    setFrequency(frequency)

    -- Commit a pending transfer that has already been done.
    state.PENDING = { slot = slot }
    state.commit()
    log:info("Reverse push committed")

    -- Pull the item.
    local turtleGuard = inventory.turtleMutex.lock()
    local amount = echest.pushItems(turtleName, slot, nil, 16)

    -- Check that we got what we expected.
    local detail = turtle.getItemDetail(16, true)
    local checkNbt = nbt ~= "NONE" and nbt or nil
    if not detail or detail.name ~= item or detail.nbt ~= checkNbt then
        log:error("abort: item data mismatch")

        -- Abort, pull items back to the ender chest.
        local ok, dumpAmt = pullPullDump(slot, amount)

        state.PENDING = nil
        state.commit()

        turtleGuard.unlock()
        echestGuard.unlock()

        if ok then
            return "MISMATCH"
        else
            return "MISMATCH_BLOCKED", dumpAmt
        end
    end

    return "OK", {
        amount = amount,

        ---@async
        commit = function(...)
            log:info("Pull commit")

            -- Commit the reversed transfer away along with transaction results.
            state.PENDING = nil
            state:commitMany(...)

            -- Push items to storage.
            inventory.get().pullItems(turtleName, 16)
            turtleGuard.unlock()

            log:info("Pull complete")
            echestGuard.unlock()
        end,

        ---@return boolean ok Whether the transfer was to the specified slot.
        ---@return number dumpAmt How many items were dumped.
        ---@nodiscard
        ---@async
        rollback = function()
            log:info("Pull rollback")

            -- Abort, pull items back to the ender chest.
            local ok, dumpAmt = pullPullDump(slot, amount)

            state.PENDING = nil
            state.commit()

            turtleGuard.unlock()
            echestGuard.unlock()

            return ok, dumpAmt
        end,
    }
end

local function recover()
    local echestGuard = echestMutex.lock()
    local turtleGuard = inventory.turtleMutex.lock()

    log:info("Starting recovery")

    if state.PENDING then
        log:info("Recovering pending transaction")
        if turtle.getItemCount(16) > 0 then
            -- Complete the pending transfer.
            pullPullDump(state.PENDING.slot, turtle.getItemCount(16))
        else
            -- Nothing to do, the transfer has been completed already.
        end
        state.PENDING = nil
        state.commit()
        log:info("Recovery done")
    else
        if turtle.getItemCount(16) > 0 then
            -- Get the items back into storage.
            inventory.get().pullItems(turtleName, 16)
        else
            -- Nothing to do.
        end
    end

    turtleGuard.unlock()
    echestGuard.unlock()
end

return {
    getItemDetail = getItemDetail,
    preparePush = preparePush,
    preparePull = preparePull,
    recover = recover,
}
