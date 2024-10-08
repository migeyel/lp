--- Sucks items from the top of the turtle.

local INTERVAL = 1

local pools = require "lp.pools"
local sessions = require "lp.sessions"
local inventory = require "lp.inventory"
local threads = require "lp.threads"
local log = require "lp.log"

local modem = peripheral.find("modem")

local function suck()
    while true do
        local guard1 = inventory.turtleMutexes[1].lock()
        local guard2 = inventory.turtleMutex.lock()
        turtle.select(1)
        turtle.suckUp()
        if turtle.getItemCount(1) == 0 then
            guard1.unlock()
            guard2.unlock()
            sleep(INTERVAL)
        else
            local item = turtle.getItemDetail(1, true)
            local poolId = item.name .. "~" .. (item.nbt or "NONE")
            local session = sessions.get()
            local pool = pools.get(poolId)
            if pool and not pool.liquidating and session then
                local amt = inventory.get().pullItems(
                    modem.getNameLocal(),
                    1
                )
                if amt < item.count then
                    local space = inventory.get().totalSpaceForItem(
                        item.name,
                        item.nbt
                    )
                    if space >= item.count - amt then
                        inventory.get().defrag()
                        amt = amt + inventory.get().pullItems(
                            modem.getNameLocal(),
                            1
                        )
                    end
                end
                pool = pools.get(poolId) -- pullItems() yields
                session = sessions.get()
                if pool and session then
                    session:sell(pool, amt, true)
                    log:info(("%s sold %d units of %q for %g"):format(
                        session:account().username,
                        amt,
                        pool.label,
                        session:sellPriceWithFee(pool, amt)
                    ))
                else
                    inventory.get().pushItems(
                        modem.getNameLocal(),
                        item.name,
                        item.count,
                        nil,
                        item.nbt
                    )
                end
            end
            turtle.select(1)
            turtle.drop()
            guard1.unlock()
            guard2.unlock()
        end
    end
end

threads.register(function()
    inventory.get()
    while true do
        local session = sessions.get()
        while not session do
            sessions.startEvent.pull()
            session = sessions.get()
        end
        parallel.waitForAny(
            function()
                sessions.endEvent.pull()
                -- Wait for the suck loop to finish.
                local guard1 = inventory.turtleMutexes[1].lock()
                local guard2 = inventory.turtleMutex.lock()
                guard1.unlock()
                guard2.unlock()
            end,
            suck
        )
        local guard1 = inventory.turtleMutexes[1].lock()
        local guard2 = inventory.turtleMutex.lock()
        turtle.select(1)
        turtle.drop()
        guard1.unlock()
        guard2.unlock()
    end
end)
