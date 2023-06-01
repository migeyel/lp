local sessions = require "lp.sessions"
local threads = require "lp.threads"
local pools = require "lp.pools"
local inventory = require "lp.inventory"
local event = require "lp.event"
local frequencies = require "lp.frequencies"
local rsession = require "lp.rsession"
local util = require "lp.util"
local log = require "lp.log"
local cbb = require "cbb"

local sensor = assert(peripheral.find("plethora:sensor"), "coudln't find entity sensor")
local SENSOR_RADIUS_INFINITY_NORM = 5

local chatbox = chatbox
if not chatbox then
    -- dummy
    chatbox = {
        tell = function(recv, msg, name)
            print(("%s -> %s: %s"):format(name, recv, msg))
        end,

        isConnected = function() return true end,

        hasCapability = function(cap)
            return ({ command = true, tell = true, read = true })[cap] or false
        end,
    }
end

local modem = peripheral.find("modem")

local BOT_NAME = "LP Shop"

---@param ctx cbb.Context
local function handleStart(ctx)
    local entities = sensor.sense()
    local playerHere = false
    for _, e in pairs(entities) do
        local valid = e.key == "minecraft:player"
            and e.name:lower() == ctx.user:lower()
            and math.max(e.x, e.y, e.z) < SENSOR_RADIUS_INFINITY_NORM
        if valid then
            playerHere = true
            break
        end
    end

    if not playerHere then
        return ctx.reply(
            {
                text = "Please get near the shop. It's located at "
                    .. "(x = 286, z = -248). You can also use ",
                color = cbb.colors.WHITE,
            },
            {
                text = "\\warp lp",
                color = cbb.colors.GRAY,
            },
            {
                text = ".",
                color = cbb.colors.WHITE,
            }
        )
    end

    if sessions.create(ctx.user, true) then
        log:info("Started a session for " .. ctx.user)
    else
        return ctx.replyErr("Another session is already in place")
    end
end

---@param ctx cbb.Context
local function handleExit(ctx)
    local session = sessions.get()
    if session and ctx.user:lower() == session.user then
        session:close()
        log:info("Session ended using command")
    else
        return ctx.replyErr("There is no session for you to exit")
    end
end

---@param ctx cbb.Context
local function handleBuy(ctx)
    local label = ctx.args.item ---@type string
    local amount = ctx.args.amount ---@type integer

    local session = sessions.get()
    if not session or ctx.user:lower() ~= session.user then
        return ctx.replyErr("Start a session first with \\lp start")
    end

    amount = math.floor(math.max(0, math.min(65536, amount)))
    local pool = pools.getByTag(label)
    if pool then
        local price = session:buyPriceWithFee(pool, amount)
        if price > session:balance() then
            return ctx.replyErr(
                ("You don't have the %g KST necessary to buy this"):format(
                    price
                )
            )
        end
        if session:tryBuy(pool, amount, true) then
            log:info(("%s bought %d units of %q for %g"):format(
                ctx.user,
                amount,
                pool.label,
                price
            ))
            local remaining = amount
            while remaining > 0 do
                local guard = inventory.turtleMutex.lock()
                turtle.select(1)
                turtle.drop()
                local pushed = inventory.get().pushItems(
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
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
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
    inventory.get().pushItems(
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

local function handleRawdelta(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local amount = ctx.args.amount ---@type number

    local session = sessions.get()
    if not session or ctx.user:lower() ~= session.user then
        return ctx.replyErr("Start a session first with \\lp start")
    end

    ctx.reply({
        text = "Ok, " .. amount,
        color = cbb.colors.WHITE,
    })

    session:transfer(amount, true)
end

local function arbHelper(pool, amt, otherPrice)
    local buyPrice = math.ceil(amt * otherPrice)
    local sellPrice = util.mFloor(pool:sellPrice(amt) - pool:sellFee(amt))
    local profit = sellPrice - buyPrice
    return buyPrice, sellPrice, profit
end

---@param ctx cbb.Context
local function handleArb(ctx)
    local otherPrice = ctx.args.price ---@type number
    local label = ctx.args.item ---@type string

    if otherPrice == 0 then
        return ctx.reply({
            text = "If someone is giving stuff away for free then any amount "
                .. "is profitable",
        })
    end

    if otherPrice < 0 then
        return ctx.reply({
            text = "If someone is paying you to take their items, you don't "
                .. "even need to sell them back",
        })
    end

    local pool = pools.getByTag(label)
    if pool then
        if otherPrice >= pool:midPrice() then
            return ctx.reply({
                text = "There is no way to profit from arbitrage at current "
                    .. "prices",
            })
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
            return ctx.reply({
                text = (
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
                    ),
            })
        else
            return ctx.reply({
                text = "There is no way to profit from arbitrage at current "
                    .. "prices",
            });
        end
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end
end

---@param ctx cbb.Context
local function handlePrice(ctx)
    local amount = ctx.args.amount ---@type integer
    local label = ctx.args.item ---@type string

    local pool = pools.getByTag(label)
    if pool then
        if amount > 0 then
            local price = util.mCeil(pool:buyPrice(amount) + pool:buyFee(amount))
            return ctx.reply({
                text = (
                    "Buying %d of %q would cost you %g KST (%g KST/i)"
                ):format(
                    amount,
                    label,
                    price,
                    util.mCeil(price / amount)
                ),
            })
        elseif amount < 0 then
            amount = -amount
            local price = util.mFloor(pool:sellPrice(amount) - pool:sellFee(amount))
            return ctx.reply({
                text = (
                    "Selling %d of %q would earn you %g KST (%g KST/i)"
                ):format(
                    amount,
                    label,
                    price,
                    util.mFloor(price / amount)
                ),
            })
        else
            return ctx.reply({
                text = ("The middle price of %q is %g KST"):format(
                    label,
                    pool:midPrice()
                ),
            })
        end
    else
        return ctx.replyErr(
            ("The pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end
end

---@param ctx cbb.Context
local function handleAlloc(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local label = ctx.args.item ---@type string
    local amount = ctx.args.amount ---@type number

    local session = sessions.get()
    if not session or ctx.user:lower() ~= session.user then
        return ctx.replyErr("Start a session first with \\lp start")
    end

    amount = util.mFloor(amount)
    local pool = pools.getByTag(label)
    if pool then
        if amount > session:balance() then
            return ctx.replyErr("You don't have the KST needed to reallocate")
        elseif -amount >= pool.allocatedKrist then
            return ctx.replyErr(
                "The pool doesn't have the KST needed to reallocate"
            )
        end
        local trueAmount = session:account():transfer(-amount, false)
        pool:reallocKst(-trueAmount, false)
        pools.state:commitMany(sessions.state)
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end
end

---@param ctx cbb.Context
local function handleKick(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local session = sessions.get()
    if session then
        session:close()
        log:info("Session ended by kicking")
    else
        return ctx.replyErr("There is no session to terminate")
    end
end

---@param ctx cbb.Context
local function handleWhatsNew(ctx)
    return ctx.reply(
        {
            text = "LP Recent Changes:",
        },
        {
            text = "\nMay 14th - ",
            color = cbb.colors.BLUE,
        },
        {
            text = "Commands now accept evaluated expressions as arguments. "
                .. "Example: ",
        },
        {
            text = "\\lp price Wheat 9*64+1",
            color = cbb.colors.GRAY,
        },
        {
            text = ".",
        },
        {
            text = "\nMay 14th - ",
            color = cbb.colors.BLUE,
        },
        {
            text = "The new command parser no longer supports spaces in ",
        },
        {
            text = "\\lp buy",
            color = cbb.colors.GRAY,
        },
        {
            text = " et al. The new syntax is ",
        },
        {
            text = "\\lp buy \"Iron Ingot\" 1",
            color = cbb.colors.GRAY,
        },
        {
            text = ".",
        }
    )
end

local root = cbb.literal("lp") "lp" {
    cbb.literal("help") "help" {
        help = "Provides this help message",
        execute = function(ctx)
            return cbb.sendHelpTopic(1, ctx)
        end,
    },
    cbb.literal("whatsnew") "whatsnew" {
        help = "Reports new changes to the shop software",
        execute = handleWhatsNew,
    },
    cbb.literal("start") "start" {
        help = "Starts a session",
        execute = handleStart,
    },
    cbb.literal("arb") "arb" {
        cbb.string "item" {
            cbb.numberExpr "price" {
                help = "Computes market arbitrage",
                execute = handleArb,
            },
        },
    },
    cbb.literal("price") "price" {
        cbb.string "item" {
            cbb.integerExpr "amount" {
                help = "Queries an item's price",
                execute = handlePrice,
            }
        }
    },
    cbb.literal("buy") "buy" {
        cbb.string "item" {
            cbb.integerExpr "amount" {
                help = "Buys an item",
                execute = handleBuy,
            },
        },
    },
    cbb.literal("exit") "exit" {
        help = "Exits a session",
        execute = handleExit,
    },
    cbb.literal("rawdelta") "rawdelta" {
        cbb.numberExpr "amount" {
            execute = handleRawdelta,
        }
    },
    cbb.literal("alloc") "alloc" {
        cbb.string "item" {
            cbb.numberExpr "amount" {
                execute = handleAlloc,
            }
        }
    },
    cbb.literal("kick") "kick" {
        execute = handleKick,
    }
}

local ChatboxReadyEvent = event.register()

threads.register(function()
    log:info("Starting chatbox")

    while not chatbox.isConnected() do
        sleep()
    end

    if not chatbox.hasCapability("command") or not chatbox.hasCapability("tell") then
        error("chatbox does not have the required permissions")
    end

    log:info("Chatbox ready")
    ChatboxReadyEvent.queue()
end)

threads.register(function()
    local timer = os.startTimer(20)

    while true do
        local e, id = event.pull()
        if e == ChatboxReadyEvent then
            break
        elseif e == "timer" and id == timer then
            error("chatbox did not connect after 20 seconds")
        end
    end

    inventory.get()
    while true do
        local _, user, command, args, etc = os.pullEvent("command")
        user = user:lower()
        cbb.execute(root, BOT_NAME, { "command", user, command, args, etc })
    end
end)

threads.register(function()
    ChatboxReadyEvent.pull()
    while true do
        local user, amt, rem = sessions.endEvent.pull()
        cbb.tell(user, BOT_NAME, {
            text = (
                "Your %d KST were transferred. The remaining %g are stored "
                    .. "in your account and will reappear in the next session."
            ):format(
                amt,
                rem
            ),
            color = cbb.colors.WHITE,
        })
    end
end)
