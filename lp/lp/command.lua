local sessions = require "lp.sessions"
local threads = require "lp.threads"
local pools   = require "lp.pools"
local inventory = require "lp.inventory"
local frequencies = require "lp.frequencies"
local rsession = require "lp.rsession"
local util = require "lp.util"
local log = require "lp.log"

local sensor = assert(peripheral.find("plethora:sensor"), "coudln't find entity sensor")
local SENSOR_RADIUS_INFINITY_NORM = 5

local chatbox = chatbox
if not chatbox then
    -- dummy
    chatbox = {
        tell = function(recv, msg, name)
            print(("%s -> %s: %s"):format(name, recv, msg))
        end,

        hasCapability = function(cap)
            return ({ command = true, tell = true, read = true })[cap] or false
        end,
    }
end

local modem = peripheral.find("modem")

if not chatbox.hasCapability("command") or not chatbox.hasCapability("tell") then
	error("chatbox does not have the required permissions")
end

local BOT_NAME = "LP Shop"

local function tell(user, msg)
    return chatbox.tell(user, msg, BOT_NAME)
end

---@param user string
---@param args string[]
local function handleStart(user, args)
    if #args ~= 0 then
        tell(user, "Usage: `\\lp start`")
        return
    end

    local entities = sensor.sense()
    local playerHere = false
    for _, e in pairs(entities) do
        local valid = e.key == "minecraft:player"
            and e.name:lower() == user:lower()
            and math.max(e.x, e.y, e.z) < SENSOR_RADIUS_INFINITY_NORM
        if valid then
            playerHere = true
            break
        end
    end

    if not playerHere then
        local m = "Error: Please get near the shop. It's located at (x = 286, z = -248)"
        tell(user, m)
        return
    end

    if sessions.create(user, true) then
        log:info("Started a session for " .. user)
    else
        tell(user, "Error: Another session is already in place")
    end
end

---@param user string
---@param args string[]
local function handleExit(user, args)
    if #args ~= 0 then
        tell(user, "Usage: `\\lp exit`")
        return
    end

    local session = sessions.get()
    if session and user:lower() == session.user then
        session:close()
        log:info("Session ended using command")
    else
        tell(user, "Error: There is no session for you to exit")
    end
end

---@param user string
---@param args string[]
local function handleBuy(user, args)
    if #args < 2 then
        tell(user, "Usage: `\\lp buy <item> <amount>`")
        return
    end

    local session = sessions.get()
    if not session or user:lower() ~= session.user then
        tell(user, "Error: Start a session first with \\lp start")
        return
    end

    local amount = tonumber(args[#args])
    if not amount then
        tell(user, ("Error: %q isn't a number"):format(args[#args]))
        return
    end

    amount = math.floor(math.max(0, math.min(65536, amount)))
    local label = table.concat(args, " ", 1, #args - 1)
    local pool = pools.getByTag(label)
    if pool then
        local price = session:buyPriceWithFee(pool, amount)
        if price > session:balance() then
            tell(user, ("Error: You don't have the %g KST necessary to buy this"):format(price))
            return
        end
        if session:tryBuy(pool, amount, true) then
            log:info(("%s bought %d units of %q for %g"):format(
                user,
                amount,
                pool.label,
                price
            ))
            local remaining = amount
            while remaining > 0 do
                local guard = inventory.turtleMutex.lock()
                turtle.select(1)
                turtle.drop()
                local pushed = inventory.inv.pushItems(
                    modem.getNameLocal(),
                    pool.item,
                    remaining,
                    1,
                    pool.nbt
                )
                turtle.select(1)
                turtle.drop()
                guard.unlock()
                remaining = remaining - pushed
            end
        end
    else
        tell(user, ("Error: The item pool %q doesn't exist"):format(label))
    end
end

---@param user string
---@param args string[]
local function handleToken(user, args)
    if #args > 1 or #args == 1 and args[1] ~= "regenerate" then
        tell(user, "Usages:\n \\lp token\n \\lp token regenerate")
        return
    end

    local acct = sessions.getAcctOrCreate(user, true)

    if args[1] == "regenerate" then
        acct:setRemoteToken(util.toHex(util.randomBytes(16)), true)
        rsession.updateListener(acct)
        tell(user, ("Token regenerated successfully"))
    elseif not acct.remoteToken then
        acct:setRemoteToken(util.toHex(util.randomBytes(16)), true)
        rsession.updateListener(acct)
    end

    local msg = (
        "Your remote session token is `%s`. Never give this token to anyone."
    ):format(acct.remoteToken)
    tell(user, msg)
end

---@param user string
---@param args string[]
local function handleBalance(user, args)
    if #args ~= 0 then
        tell(user, "Usage: \\lp balance")
        return
    end

    local acct = sessions.getAcctOrCreate(user, true)
    tell(user, ("Your balance is %g KST"):format(acct.balance))
end

---@param user string
---@param args string[]
local function handleFrequency(user, args)
    if #args > 1 or #args == 1 and args[1] ~= "buy" then
        tell(user, "Usages:\n \\lp frequency\n \\lp frequency buy")
        return
    end

    if #args == 0 then
        local msg = (
            "The current price for an allocated frequency is %g KST. You can" ..
            " get one by using \\lp frequency buy"
        ):format(sessions.ECHEST_ALLOCATION_PRICE)
        tell(user, msg)
        return
    end


    local session = sessions.get()
    if not session or user ~= session.user then
        tell(user, "Error: Start a session first with \\lp start")
        return
    end

    local acct = session:account()
    if acct.storageFrequency then
        tell(user, "Error: You already own a frequency")
        return
    end

    if acct.balance < sessions.ECHEST_ALLOCATION_PRICE then
        local msg = (
            "Error: You don't have the %g KST necessary to acquire a frequency"
        ):format(sessions.ECHEST_ALLOCATION_PRICE)
        tell(user, msg)
        return
    end

    local nbt, frequency = frequencies.popFrequency()
    if not nbt or not frequency then
        tell(
            user,
            "Error: There are no frequencies for sale currently"
        )
        return
    end

    if not acct:allocFrequency(frequency, false) then
        tell(user, "Error: Failed to allocate")
        return
    end
    acct:transfer(-sessions.ECHEST_ALLOCATION_PRICE, true)

    log:info(("%s has paid %d for frequency %d"):format(
        user, sessions.ECHEST_ALLOCATION_PRICE, frequency
    ))

    local guard = inventory.turtleMutex.lock()
    turtle.select(1)
    turtle.drop()
    inventory.inv.pushItems(
        modem.getNameLocal(),
        "sc-goodies:ender_storage",
        1,
        1,
        nbt
    )
    turtle.select(1)
    turtle.drop()
    guard.unlock()
end

local function handleRawdelta(user, args)
    if #args < 1 then
        tell(user, "Usage: `^lp rawdelta <amount>`")
        return
    end

    local session = sessions.get()
    if not session or user:lower() ~= session.user then
        tell(user, "Error: Start a session first with \\lp start")
        return
    end

    local amount = tonumber(args[1])
    if not amount then
        tell(user, ("Error: %q isn't a number"):format(args[1]))
        return
    end

    tell(user, "Ok, " .. amount)
    session:transfer(amount, true)
end

local function arbHelper(pool, amt, otherPrice)
    local buyPrice = math.ceil(amt * otherPrice)
    local sellPrice = util.mFloor(pool:sellPrice(amt) - pool:sellFee(amt))
    local profit = sellPrice - buyPrice
    return buyPrice, sellPrice, profit
end

local function handleArb(user, args)
    if #args < 2 then
        tell(user, "Usage: `\\lp arb <item> <price>`")
        return
    end

    local otherPrice = tonumber(args[#args])
    if not otherPrice then
        tell(user, ("Error: %q isn't a number"):format(args[#args]))
        return
    end

    if otherPrice == 0 then
        tell(
            user,
            "If someone is giving stuff away for free then any amount is profitable"
        )
        return
    end

    if otherPrice < 0 then
        tell(
            user,
            "If someone is paying you to take their items, you don't even need to sell them back"
        )
        return
    end

    local label = table.concat(args, " ", 1, #args - 1)
    local pool = pools.getByTag(label)
    if pool then
        if otherPrice >= pool:midPrice() then
            tell(
                user,
                "There is no way to profit from arbitrage at current prices"
            )
            return
        end

        local initAmt = math.ceil(
            math.sqrt(
                pool.allocatedKrist * pool.allocatedItems / otherPrice
            ) - pool.allocatedItems
        )

        local maxAmt, maxBuyPrice, maxSellPrice
        local maxProfit = -math.huge
        local amt = initAmt
        while amt > 0 do
            local buyPrice, sellPrice, profit = arbHelper(pool, amt, otherPrice)
            if profit <= maxProfit then break end
            maxAmt = amt
            maxBuyPrice = buyPrice
            maxSellPrice = sellPrice
            maxProfit = profit
            amt = math.floor((buyPrice - 1) / otherPrice)
        end

        if maxProfit > 0 then
            tell(
                user,
                (
                    "If a shop is selling for %g, then:\n"
                    .. "1. Buy %d items, paying %d\n"
                    .. "2. Sell %d items here, earning %g\n"
                    .. "3. Keep the difference of %g as profit"
                ):format(
                    otherPrice,
                    maxAmt,
                    maxBuyPrice,
                    maxAmt,
                    maxSellPrice,
                    maxProfit
                )
            )
        else
            tell(
                user,
                "There is no way to profit from arbitrage at current prices"
            )
        end
    else
        tell(user, ("Error: The item pool %q doesn't exist"):format(label))
    end
end

local function handlePrice(user, args)
    if #args < 2 then
        tell(user, "Usage: `\\lp price <item> <amount>`")
        return
    end

    local amount = tonumber(args[#args])
    if not amount then
        tell(user, ("Error: %q isn't a number"):format(args[#args]))
        return
    end

    local label = table.concat(args, " ", 1, #args - 1)
    local pool = pools.getByTag(label)
    if pool then
        if amount > 0 then
            local price = util.mCeil(pool:buyPrice(amount) + pool:buyFee(amount))
            tell(user, ("Buying %d of %q would cost you %g KST (%g KST/i)"):format(
                amount,
                label,
                price,
                util.mCeil(price / amount)
            ))
        elseif amount < 0 then
            amount = -amount
            local price = util.mFloor(pool:sellPrice(amount) - pool:sellFee(amount))
            tell(user, ("Selling %d of %q would earn you %g KST (%g KST/i)"):format(
                amount,
                label,
                price,
                util.mFloor(price / amount)
            ))
        else
            tell(user, ("The middle price of %q is %g KST"):format(
                label,
                pool:midPrice()
            ))
        end
    else
        tell(user, ("Error: The item pool %q doesn't exist"):format(label))
    end
end

local function handleAlloc(user, args)
    if #args < 2 then
        tell(user, "Usage: `^lp alloc <item> <amount>`")
        return
    end

    local session = sessions.get()
    if not session or user:lower() ~= session.user then
        tell(user, "Error: Start a session first with \\lp start")
        return
    end

    local amount = tonumber(args[#args])
    if not amount then
        tell(user, ("Error: %q isn't a number"):format(args[#args]))
        return
    end

    amount = util.mFloor(amount)
    local label = table.concat(args, " ", 1, #args - 1)
    local pool = pools.getByTag(label)
    if pool then
        if amount > session:balance() then
            tell(user, "Error: You don't have the KST needed to reallocate")
            return
        elseif -amount >= pool.allocatedKrist then
            tell(user, "Error: The pool doesn't have the KST needed to reallocate")
            return
        end
        local trueAmount = session:account():transfer(-amount, false)
        pool:reallocKst(-trueAmount, false)
        pools.state:commitMany(sessions.state)
    else
        tell(user, ("Error: The item pool %q doesn't exist"):format(label))
    end
end

threads.register(function()
    while true do
        local _, user, command, args, etc = os.pullEvent("command")
        user = user:lower()
        if command == "lp" then
            if args[1] == "start" then
                handleStart(user, { unpack(args, 2) })
            elseif args[1] == "arb" then
                handleArb(user, { unpack(args, 2) })
            elseif args[1] == "price" then
                handlePrice(user, { unpack(args, 2) })
            elseif args[1] == "buy" then
                handleBuy(user, { unpack(args, 2) })
            elseif args[1] == "exit" then
                handleExit(user, { unpack(args, 2) })
            elseif args[1] == "rawdelta" and etc.ownerOnly then
                handleRawdelta(user, { unpack(args, 2) })
            elseif args[1] == "alloc" and etc.ownerOnly then
                handleAlloc(user, { unpack(args, 2) })
            elseif args[1] == "balance" and etc.ownerOnly then
                handleBalance(user, { unpack(args, 2) })
            elseif args[1] == "token" and etc.ownerOnly then
                handleToken(user, { unpack(args, 2) })
            elseif args[1] == "frequency" and etc.ownerOnly then
                handleFrequency(user, { unpack(args, 2) })
            elseif args[1] == "help" or args[1] == "" or args[1] == nil then
                tell(
                    user,
                    "Come check PG231's liquidity pool store at "
                    .. "(x = 286, z = -248)! You can buy *and* sell items! "
                    .. "Begin by using \\lp start"
                )
            else
                tell(user, ("Error: Unknown subcommand %q"):format(
                    ((args or {})[1] or ""):sub(1, 32)
                ))
            end
        end
    end
end)

threads.register(function()
    while true do
        local user, amt, rem = sessions.endEvent.pull()
        local msg = (
            "Your %d KST were transferred. The remaining %g are stored in "
            .. "your account and will reappear in the next session."
        ):format(amt, rem)
        tell(user, msg)
    end
end)
