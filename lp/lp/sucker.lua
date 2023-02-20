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
        local guard = inventory.turtleMutex.lock()
        turtle.suckUp()
        if turtle.getItemCount(1) == 0 then
            guard.unlock()
            sleep(INTERVAL)
        else
            local item = turtle.getItemDetail(1, true)
            local poolId = item.name .. "~" .. (item.nbt or "NONE")
            local session = sessions.get()
            local pool = pools.get(poolId)
            if pool and session then
                local amt = inventory.get().pullItems(
                    modem.getNameLocal(),
                    1
                )
                if amt < item.count then
                    local space = inventory.get().totalSpaceForItem(
                        item.name,
                        item.nbt
                    )
                    require"cc.pretty".pretty_print(space)
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
                        session.user,
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
            guard.unlock()
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
                inventory.turtleMutex.lock().unlock()
            end,
            suck
        )
        local guard = inventory.turtleMutex.lock()
        turtle.select(1)
        turtle.drop()
        guard.unlock()
    end
end)
