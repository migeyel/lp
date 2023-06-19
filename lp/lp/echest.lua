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

--- Pulls a number of items into an ender storage, dumping anything it can't
--- transfer.
---@param amount number How many items are in the 16th turtle slot to be sent.
---@param slot number Which slot to try to send the items into.
---@return number dumpAmt How many items were dumped.
---@async
local function tryPull(slot, amount)
    -- Pull into the desired slot.
    local pullAmt = echest.pullItems(turtleName, 16, nil, slot)

    -- Pull remaining items into the dump chest.
    local dumpAmt = 0
    while pullAmt + dumpAmt < amount do
        dumpAmt = dumpAmt + dumpchest.pullItems(turtleName, 16)
    end

    return dumpAmt
end

---@param frequency number
---@param slot number
---@return boolean
---@return table
local function getItemDetail(frequency, slot)
    setFrequency(frequency)
    return pcall(echest.getItemDetail, slot)
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

    setFrequency(frequency)

    -- Check that an output slot exists.
    local ok, detail = pcall(echest.getItemDetail, slot)
    if not ok or detail then
        echestGuard.unlock()
        return "NONEMPTY"
    end

    -- Push items to the temporary turtle slot 16.
    local turtleGuard = inventory.turtleMutexes[16].lock()
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
            -- Abort, pull items back to storage.
            inventory.get().pullItems(turtleName, 16)

            turtleGuard.unlock()
            echestGuard.unlock()
        end,

        ---@return number dumpAmt How many items were dumped.
        ---@nodiscard
        ---@async
        commit = function(...)
            -- Commit the pending transfer along with transaction results.
            state.PENDING = { slot = slot }
            state:commitMany(...)

            local dumpAmt = tryPull(slot, trueAmount)

            turtleGuard.unlock()

            -- Commit transfer "success".
            state.PENDING = nil
            state.commit()

            echestGuard.unlock()

            return dumpAmt
        end,
    }
end

---@param frequency number The frequency number to pull from.
---@param slot number The slot to pull from.
---@param item string The item id to check after pulling.
---@param nbt string The item NBT to check after pulling.
---@return table|number # The table, or the number of dumped items.
---@nodiscard
---@async
local function preparePull(frequency, slot, item, nbt)
    local echestGuard = echestMutex.lock()
    assert(not state.PENDING) -- The mutex should make this always true.

    setFrequency(frequency)

    -- Commit a pending transfer that has already been done.
    state.PENDING = { slot = slot }
    state.commit()

    -- Pull the item.
    local turtleGuard = inventory.turtleMutexes[16].lock()
    local amount = echest.pushItems(turtleName, slot, nil, 16)

    -- Check that we got what we expected.
    local detail = turtle.getItemDetail(16, true)
    local checkNbt = nbt ~= "NONE" and nbt or nil
    if not detail or detail.name ~= item or detail.nbt ~= checkNbt then
        log:error("pull: item data mismatch")

        -- Abort, pull items back to the ender chest.
        local dumpAmt = tryPull(slot, amount)

        state.PENDING = nil
        state.commit()

        turtleGuard.unlock()
        echestGuard.unlock()

        return dumpAmt
    end

    return {
        amount = amount,

        ---@async
        commit = function(...)
            -- Commit the reversed transfer away along with transaction results.
            state.PENDING = nil
            state:commitMany(...)

            -- Push items to storage.
            inventory.get().pullItems(turtleName, 16)
            turtleGuard.unlock()

            echestGuard.unlock()
        end,

        ---@return number dumpAmt How many items were dumped.
        ---@nodiscard
        ---@async
        rollback = function()
            -- Abort, pull items back to the ender chest.
            local dumpAmt = tryPull(slot, amount)

            state.PENDING = nil
            state.commit()

            turtleGuard.unlock()
            echestGuard.unlock()

            return dumpAmt
        end,
    }
end

local function recover()
    local echestGuard = echestMutex.lock()
    local turtleGuard = inventory.turtleMutexes[16].lock()

    log:info("Starting recovery")

    if state.PENDING then
        log:info("Recovering pending item transfer")
        if turtle.getItemCount(16) > 0 then
            -- Complete the pending transfer.
            tryPull(state.PENDING.slot, turtle.getItemCount(16))
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
