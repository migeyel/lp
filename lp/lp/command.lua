local sessions = require "lp.sessions"
local threads = require "lp.threads"
local pools = require "lp.pools"
local inventory = require "lp.inventory"
local event = require "lp.event"
local frequencies = require "lp.frequencies"
local inv = require "lp.inventory"
local util = require "lp.util"
local log = require "lp.log"
local cbb = require "cbb"
local wallet = require "lp.wallet"

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
---@return Session?
local function tryStartSession(ctx)
    local entities = sensor.sense()
    local playerHere = false
    for _, e in pairs(entities) do
        local valid = e.key == "minecraft:player"
            and e.id == ctx.data.user.uuid
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
                text = "/warp lp",
                color = cbb.colors.GRAY,
            },
            {
                text = ".",
                color = cbb.colors.WHITE,
            }
        )
    end

    local session = sessions.create(ctx.data.user.uuid, ctx.user, true)
    if session then
        log:info("Started a session for " .. ctx.user)
        return session
    else
        return ctx.replyErr("Another session is already in place")
    end
end

---@param ctx cbb.Context
local function handleStart(ctx)
    return tryStartSession(ctx)
end

---@param ctx cbb.Context
local function handleExit(ctx)
    local session = sessions.get()
    if session and ctx.data.user.uuid == session.uuid then
        session:close()
        log:info("Session ended using command")
    else
        return ctx.replyErr("There is no session for you to exit")
    end
end

-- receiver uuid: string
-- sender: string (username or krist address)
-- amount: number
local TransferReceivedEvent = event.register("transfer_received")

---@param ctx cbb.Context
local function handlePay(ctx)
    local receiver = sessions.getAcctByUsername(ctx.args.receiver:lower())
    local amount = util.mFloor(ctx.args.amount)

    if not receiver then
        return ctx.replyErr(
            "That user has no account in the LP.",
            ctx.argTokens.receiver
        )
    end

    local sender = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    if sender.balance < amount then
        return ctx.replyErr(
            ("You don't have the %g KST needed to pay."):format(amount)
        )
    end
    if amount < 0 then
        return ctx.replyErr(
            "I'm not falling for that trick again.",
            ctx.argTokens.amount
        )
    end

    local trueAmount = sender:transfer(-amount, false)
    receiver:transfer(-trueAmount, true)

    TransferReceivedEvent.queue(
        receiver.uuid,
        ctx.data.user.displayName,
        -trueAmount
    )

    return ctx.reply(
        {
            text = "Success!",
            color = cbb.colors.DARK_GREEN,
        },
        {
            text = " paid ",
            color = cbb.colors.GREEN,
        },
        {
            text = ("%g KST"):format(-trueAmount),
            color = cbb.colors.YELLOW,
        },
        {
            text = " to ",
            color = cbb.colors.GREEN,
        },
        {
            text = ctx.args.receiver,
            color = cbb.colors.AQUA,
        }
    )
end

---@param ctx cbb.Context
local function handleBuy(ctx)
    local label = ctx.args.item ---@type string
    local amount = ctx.args.amount ---@type integer

    local session = sessions.get()
    if not session then
        session = tryStartSession(ctx)
        if not session then return end
    elseif ctx.data.user.uuid ~= session.uuid then
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
                local guard1 = inventory.turtleMutexes[1].lock()
                local guard2 = inventory.turtleMutex.lock()
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
                guard1.unlock()
                guard2.unlock()
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

---@param ctx cbb.Context
local function handleSysInfo(ctx)
    local usage = inv.get().getUsage()
    local totalKrist = wallet.getIsKristUp() and wallet.fetchBalance()
    local allocPools = pools.totalKrist()
    local allocAccts = sessions.totalBalances()
    local unalloc = totalKrist and totalKrist - allocPools - allocAccts
    return ctx.reply(
            {
                text = "LP System Info\n",
            },
            {
                text = ("- Inventory: %g slots\n"):format(usage.total),
            },
            {
                text = ("  - Used: %g slots (%g%%)\n"):format(
                    usage.used,
                    util.mRound(100 * usage.used / usage.total)
                ),
            },
            {
                text = ("  - Free: %g slots (%g%%)\n"):format(
                    usage.free,
                    util.mRound(100 * usage.free / usage.total)
                ),
            },
            {
                text = totalKrist
                    and ("- Balance: %g KST\n"):format(totalKrist)
                    or ("- Balance: Unavailable\n"),
            },
            {
                text = ("  - Allocated to accounts: %g KST (%g%%)\n"):format(
                    allocAccts,
                    util.mRound(100 * allocAccts / totalKrist)
                ),
            },
            {
                text = ("  - Allocated to pools: %g KST (%g%%)\n"):format(
                    allocPools,
                    util.mRound(100 * allocPools / totalKrist)
                ),
            },
            {
                text = totalKrist
                    and ("  - Unallocated: %g KST (%g%%)"):format(
                        unalloc,
                        util.mRound(100 * unalloc / totalKrist)
                    )
                    or ("  - Unallocated: Unavailable"),
            }
        )
end

---@param ctx cbb.Context
local function handleInfo(ctx)
    local label = ctx.args.item ---@type string

    local pool = pools.getByTag(label)
    if pool then
        return ctx.reply(
            {
                text = ("Pool %q\n"):format(pool.label),
            },
            {
                text = ("- Item Name: %s\n"):format(pool.item),
            },
            {
                text = ("- Item NBT: %s\n"):format(pool.nbt),
            },
            {
                text = ("- Allocated Items: %g\n"):format(pool.allocatedItems),
            },
            {
                text = ("- Allocated Krist: %g\n"):format(pool.allocatedKrist),
            },
            {
                text = ("- Price: %g\n"):format(pool:midPrice()),
            },
            {
                text = ("- Trading Fees: %g%%"):format(100 * pool:getFeeRate()),
            }
        )
    else
        return ctx.replyErr(
            ("The pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end
end

---@param ctx cbb.Context
local function handlePersist(ctx)
    local acct = sessions.setAcct(ctx.data.user.uuid, ctx.user, false)
    local persist = acct:togglePersistence(true)
    if persist then
        return ctx.reply({
            text = "Your balance will now persist across sessions."
        })
    else
        return ctx.reply({
            text = "Your balance will no longer persist across sessions."
        })
    end
end

---@param ctx cbb.Context
local function handleBalance(ctx)
    local acct = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    return ctx.reply({
        text = ("Your balance is %g KST"):format(acct.balance)
    })
end

---@param ctx cbb.Context
local function handleWithdraw(ctx)
    local amount = ctx.args.amount
    local acct = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    if acct.balance < amount then
        return ctx.replyErr(
            ("You don't have the %g KST needed to withdraw."):format(amount)
        )
    end
    if amount == 0 then
        return ctx.replyErr(
            "You can't transfer 0 KST you dummy!",
            ctx.argTokens.amount
        )
    end
    if amount < 0 then
        return ctx.replyErr(
            "You're late. The infinite money glitch has been patched already.",
            ctx.argTokens.amount
        )
    end
    if not wallet.getIsKristUp() then
        return ctx.replyErr(
            "Krist seems currently down, please try again later."
        )
    end
    local amt, _ = acct:withdraw(amount, true)
    if amt ~= 0 and not wallet.sendPendingTx() then
        return ctx.replyErr(
            "An unknown error occurred while withdrawing, please ping PG231."
        )
    end
end

---@param ctx cbb.Context
local function handleFreqQuery(ctx)
    local usernameOpt = ctx.args.player
    if usernameOpt then
        local acct = sessions.getAcctByUsername(usernameOpt)
        if acct and acct.storageFrequency then
            local l, m, r = util.num2Freq(acct.storageFrequency)
            return ctx.reply({
                text = ("%s: (%s, %s, %s)"):format(
                    acct.username,
                    util.colorName[l],
                    util.colorName[m],
                    util.colorName[r]
                )
            })
        else
            return ctx.reply({
                text = "The account doesn't exist or has no frequency."
            })
        end
    end

    local acct = sessions.getAcctByUuid(ctx.data.user.uuid)
    if acct and acct.storageFrequency then
        local l, m, r = util.num2Freq(acct.storageFrequency)
        return ctx.reply({
            text = (
                "Your allocated frequency is (%s, %s, %s). You cannot buy " ..
                "another frequency. The current price for an allocated " ..
                "frequency is %g KST. There are %g frequencies currently " ..
                "available."
            ):format(
                util.colorName[l],
                util.colorName[m],
                util.colorName[r],
                sessions.ECHEST_ALLOCATION_PRICE,
                frequencies.numFrequencies()
            )
        })
    end

    return ctx.reply({
        text = (
            "The current price for an allocated frequency is %g KST. You can" ..
            " get one by using \\lp frequency buy. There are %g frequencies" ..
            " currently available."
        ):format(sessions.ECHEST_ALLOCATION_PRICE, frequencies.numFrequencies())
    })
end

---@param ctx cbb.Context
local function handleFreqBuy(ctx)
    local session = sessions.get()

    if not session or ctx.data.user.uuid ~= session.uuid then
        return ctx.replyErr("Start a session first with \\lp start")
    end

    local acct = session:account()
    if acct.storageFrequency then
        return ctx.replyErr("You already own a frequency")
    end

    if acct.balance < sessions.ECHEST_ALLOCATION_PRICE then
        return ctx.replyErr(
            (
                "You don't have the %g KST necessary to acquire a frequency"
            ):format(sessions.ECHEST_ALLOCATION_PRICE)
        )
    end

    local nbt, frequency = frequencies.popFrequency()
    if not nbt or not frequency then
        return ctx.replyErr("There are no frequencies for sale currently")
    end

    if not acct:allocFrequency(frequency, false) then
        return ctx.replyErr("Failed to allocate")
    end

    acct:transfer(-sessions.ECHEST_ALLOCATION_PRICE, false)
    assert(sessions.getAcctByUuid(sessions.PG231)):transfer(
        sessions.ECHEST_ALLOCATION_PRICE,
        true
    )

    log:info(("%s has paid %d for frequency %d"):format(
        ctx.user, sessions.ECHEST_ALLOCATION_PRICE, frequency
    ))

    local guard1 = inventory.turtleMutexes[1].lock()
    local guard2 = inventory.turtleMutex.lock()
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
    guard1.unlock()
    guard2.unlock()
end

---@param ctx cbb.Context
local function handleRawdelta(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local amount = ctx.args.amount ---@type number

    local session = sessions.get()
    if not session or ctx.data.user.uuid ~= session.uuid then
        return ctx.replyErr("Start a session first with \\lp start")
    end

    ctx.reply({
        text = "Ok, " .. amount,
        color = cbb.colors.WHITE,
    })

    session:transfer(amount, true)
end

local function handleFeeRate(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local label = ctx.args.item ---@type string
    local rate = ctx.args.rate ---@type number

    local pool = pools.getByTag(label)
    if pool then
        pool:setFeeRate(rate, true)
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end
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
    if not session or ctx.data.user.uuid ~= session.uuid then
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
            text = "\nJune 21st - ",
            color = cbb.colors.BLUE,
        },
        {
            text = "\\lp buy ",
            color = cbb.colors.GRAY,
        },
        {
            text = "now tries to start a session if possible.",
        },
        {
            text = "\nJune 20th - ",
            color = cbb.colors.BLUE,
        },
        {
            text = "New commands: ",
        },
        {
            text = "\\lp persist",
            color = cbb.colors.GRAY,
        },
        {
            text = ", "
        },
        {
            text = "\\lp frequency",
            color = cbb.colors.GRAY,
        },
        {
            text = ", "
        },
        {
            text = "\\lp balance",
            color = cbb.colors.GRAY,
        },
        {
            text = ", and "
        },
        {
            text = "\\lp withdraw",
            color = cbb.colors.GRAY,
        },
        {
            text = "."
        },
        {
            text = "\nJune 17th - ",
            color = cbb.colors.BLUE,
        },
        {
            text = "New command: ",
        },
        {
            text = "\\lp info",
            color = cbb.colors.GRAY,
        },
        {
            text = "."
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

local recursiveWrongPool = {
    
}

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
    cbb.literal("info") "info" {
        help = "Displays information about the system",
        execute = handleSysInfo,
        cbb.string "item" {
            help = "Displays information about a pool",
            execute = handleInfo,
        },
    },
    cbb.literal("exit") "exit" {
        help = "Exits a session",
        execute = handleExit,
    },
    cbb.literal("pay") "pay" {
        cbb.string "receiver" {
            cbb.numberExpr "amount" {
                help = "Transfers Krist in your LP balance to someone else",
                execute = handlePay,
            },
        },
    },
    cbb.literal("persist") "persist" {
        help = "Toggles balance persistence on session exit",
        execute = handlePersist,
    },
    cbb.literal("frequency") "frequency" {
        help = "Displays ender storage frequency information",
        execute = handleFreqQuery,
        cbb.literal("buy") "buy" {
            help = "Buys an ender storage frequency",
            execute = handleFreqBuy,
        },
        cbb.string "player" {
            execute = handleFreqQuery,
        },
    },
    cbb.literal("balance") "balance" {
        help = "Displays your balance",
        execute = handleBalance,
    },
    cbb.literal("withdraw") "withdraw" {
        cbb.integerExpr "amount" {
            help = "Withdraws Krist from your account",
            execute = handleWithdraw,
        }
    },
    cbb.literal("rawdelta") "rawdelta" {
        cbb.numberExpr "amount" {
            execute = handleRawdelta,
        }
    },
    cbb.literal("feerate") "feerate" {
        cbb.string "item" {
            cbb.numberExpr "rate" {
                execute = handleFeeRate,
            }
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

local ChatboxReadyEvent = event.register("chatbox_ready")

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
        local uuid, amt, rem = sessions.endEvent.pull()
        if amt ~= 0 then
            cbb.tell(uuid, BOT_NAME, {
                text = (
                    "Your %d KST were transferred. The remaining %g are stored "
                        .. "in your account and will reappear in the next "
                        .. "session."
                ):format(
                    amt,
                    rem
                ),
            })
        else
            cbb.tell(uuid, BOT_NAME, {
                text = (
                    "Your balance of %g KST is stored in your account and will "
                        .. "reappear in the next session."
                ):format(
                    rem
                ),
            })
        end
    end
end)

threads.register(function()
    ChatboxReadyEvent.pull()
    while true do
        local uuid, sender, amt = TransferReceivedEvent.pull()
        cbb.tell(uuid, BOT_NAME,
            {
                text = assert(sender),
                color = cbb.colors.AQUA,
            },
            {
                text = " sent you ",
                color = cbb.colors.GREEN,
            },
            {
                text = ("%g KST"):format(amt),
                color = cbb.colors.YELLOW,
            }
        )
    end
end)
