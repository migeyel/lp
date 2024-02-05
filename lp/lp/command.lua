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
local allocation = require "lp.allocation"
local secprice = require "lp.secprice"
local propositions = require "lp.propositions"

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
            and math.max(
                math.abs(e.x),
                math.abs(e.y),
                math.abs(e.z)
            ) < SENSOR_RADIUS_INFINITY_NORM
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
        ctx.reply(
            {
                text = "LP Notice\n",
                formats = { cbb.formats.BOLD },
            },
            {
                text = table.concat {
                    "Starting from 2024-02-04, LP Securities ownership will ",
                    "now be tracked digitally. This measure aims to save on ",
                    "ink costs as well as improve bookkeeping. Dropping books ",
                    "in a session now brings them into \\lp balance. To sell, ",
                    "use \\lp sell.",
                },
            }
        )
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
            text = receiver.username,
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
        local price = util.mCeil(pool:buyPrice(amount) + pool:buyFee(amount))
        if price > session:balance() then
            return ctx.replyErr(
                ("You don't have the %g KST necessary to buy this"):format(
                    price
                )
            )
        end
        if pool:isDigital() then
            if session:tryBuy(pool, amount, false) then
                session:account():transferAsset(pool:id(), amount, false)
                pools.state:commitMany(sessions.state)
                log:info(("%s bought %d units of %q for %g"):format(
                    ctx.user,
                    amount,
                    pool.label,
                    price
                ))
                ctx.reply({
                    text = ("Bought %d units of %q for %g"):format(
                        amount,
                        pool.label,
                        price
                    )
                })
            end
        elseif session:tryBuy(pool, amount, true) then
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
local function handleSell(ctx)
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
    if pool and pool:isDigital() then
        if session:account():getAsset(pool:id()) < amount then
            return ctx.replyErr(
                ("You don't have the %g items necessary to buy this"):format(
                    amount
                )
            )
        end

        local price = util.mFloor(pool:sellPrice(amount) - pool:sellFee(amount))
        if session:account():tryTransferAsset(pool:id(), -amount, false) then
            session:sell(pool, amount, false)
            pools.state:commitMany(sessions.state)
            log:info(("%s sold %d units of %q for %g"):format(
                ctx.user,
                amount,
                pool.label,
                price
            ))
            ctx.reply({
                text = ("Sold %d units of %q for %g"):format(
                    amount,
                    pool.label,
                    price
                ),
            })
        end
    else
        return ctx.replyErr(
            ("The item pool %q isn't digital"):format(label),
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
    local allocDyn = wallet.getDynFund()
    local unalloc = totalKrist and totalKrist
        - allocPools
        - allocAccts
        - allocDyn
    local secPool = secprice.getSecPool()
    local secTotal = secPool.allocatedItems + sessions.totalAssets(secPool:id())
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
                text = totalKrist
                    and ("  - Allocated to accounts: %g KST (%g%%)\n"):format(
                        allocAccts,
                        util.mRound(100 * allocAccts / totalKrist)
                    )
                    or ("  - Allocated to accounts: %g KST\n"):format(
                        allocAccts
                    ),
            },
            {
                text = totalKrist
                    and ("  - Allocated to pools: %g KST (%g%%)\n"):format(
                        allocPools,
                        util.mRound(100 * allocPools / totalKrist)
                    )
                    or ("  - Allocated to pools: %g KST\n"):format(
                        allocPools
                    ),
            },
            {
                text = totalKrist
                    and ("  - Unused dyn allocation fund: %g KST (%g%%)\n"):format(
                        allocDyn,
                        util.mRound(100 * allocDyn / totalKrist)
                    )
                    or ("  - Unused dyn allocation fund: %g KST"):format(
                        allocDyn
                    )
            },
            {
                text = totalKrist
                    and ("  - Unallocated: %g KST (%g%%)\n"):format(
                        unalloc,
                        util.mRound(100 * unalloc / totalKrist)
                    )
                    or ("  - Unallocated: Unavailable"),
            },
            {
                text = ("- Total issued securities: %g"):format(
                    secTotal
                )
            }
        )
end

---@param ctx cbb.Context
local function handleInfo(ctx)
    local label = ctx.args.item ---@type string

    local pool = pools.getByTag(label)
    if pool then
        local prod = pool.allocatedItems * pool.allocatedKrist
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
                text = ("- Allocated Krist: %g (%g%%)\n"):format(
                    pool.allocatedKrist,
                    util.mRound(100 * pool.allocatedKrist / pools.totalKrist())
                ),
            },
            {
                text = ("- k * i: %g (%g%%)\n"):format(
                    prod,
                    util.mRound(100 * prod / pools.totalProduct())
                ),
            },
            {
                text = ("- Price: %g\n"):format(pool:midPrice()),
            },
            {
                text = ("- Trading Fees: %g%%"):format(100 * pool:getFeeRate()),
            },
            pool.dynAlloc and (
                pool.dynAlloc.type == "fixed_rate" and {
                    text = ("\n- Dynamic allocation: Fixed rate at %g%%"):format(
                        100 * pool.dynAlloc.rate
                    )
                } or {
                    text = ("\n- Dynamic allocation: Weighted w = %g"):format(
                        pool.dynAlloc.weight
                    )
                }
            ) or nil
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

    local out = {{ ---@type cbb.FormattedBlock[]
        text = ("Balance:\n- Krist: %g KST"):format(acct.balance)
    }}

    for id, amt in pairs(acct.assets or {}) do
        local pool = pools.get(id)
        out[#out + 1] = {
            text = ("\n- %s: %g"):format(pool and pool.label or id, amt),
        }
    end

    return ctx.reply(table.unpack(out))
end

---@param ctx cbb.Context
local function handleBaltopKst(ctx)
    local arr = {} ---@type Account[]
    for _, acct in sessions.accounts() do
        arr[#arr + 1] = acct
    end

    table.sort(arr, function(a, b) return a.balance > b.balance end)

    local out = {{ text = "Top Krist balances:" }} ---@type cbb.FormattedBlock[]
    for i = 1, 10 do
        if arr[i].balance == 0 then break end
        out[#out + 1] = {
            text = ("\n%d. %s: %g KST"):format(
                i,
                arr[i].username,
                arr[i].balance
            )
        }
    end

    return ctx.reply(table.unpack(out))
end

---@param ctx cbb.Context
local function handleBaltopAsset(ctx)
    local tag = ctx.args.asset
    local pool = pools.getByTag(tag)
    if not pool or not pool:isDigital() then
        return ctx.replyErr(
            "This asset does not match any digital pool",
            ctx.argTokens.asset
        )
    end

    local id = pool:id()
    local arr = {} ---@type Account[]
    for _, acct in sessions.accounts() do
        arr[#arr + 1] = acct
    end

    table.sort(arr, function(a, b) return a:getAsset(id) > b:getAsset(id) end)

    local out = {{
        text = ("Top %s balances:"):format(pool.label)
    }} ---@type cbb.FormattedBlock[]

    for i = 1, 10 do
        if arr[i]:getAsset(id) == 0 then break end
        out[#out + 1] = {
            text = ("\n%d. %s: %g"):format(
                i,
                arr[i].username,
                arr[i]:getAsset(id)
            )
        }
    end

    return ctx.reply(table.unpack(out))
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

    local account = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    ctx.reply({
        text = "Ok, " .. (account:transfer(amount, true)),
        color = cbb.colors.WHITE,
    })
end

---@param ctx cbb.Context
local function handleDynRealloc(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local amount = ctx.args.amount ---@type number
    ctx.reply({
        text = "New balance: " .. wallet.reallocateDyn(amount, true),
        color = cbb.colors.WHITE,
    })
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

        otherPrice = util.mRound(otherPrice)

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

    amount = util.mFloor(amount)
    local pool = pools.getByTag(label)
    if pool then
        if -amount >= pool.allocatedKrist then
            return ctx.replyErr(
                "The pool doesn't have the KST needed to reallocate"
            )
        end
        pool:reallocKst(amount, true)
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end
end

---@param ctx cbb.Context
local function handleSetAllocFixedRate(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local label = ctx.args.item ---@type string
    local rate = ctx.args.value ---@type number

    if rate <= 0 or rate >= 1 then
        return ctx.replyErr(
            "Refusing to set the rate to possibly undesired value",
            ctx.argTokens.value
        )
    end

    local pool = pools.getByTag(label)
    if pool then
        pool.dynAlloc = {
            type = "fixed_rate",
            rate = rate,
        }
        pools.state.commit()
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end

    ctx.reply { text = "success" }
end

---@param ctx cbb.Context
local function handleSetAllocWeightedRemainder(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local label = ctx.args.item ---@type string
    local weight = ctx.args.value ---@type number

    if weight <= 0 then
        return ctx.replyErr(
            "Refusing to set the weight to possibly undesired value",
            ctx.argTokens.value
        )
    end

    local pool = pools.getByTag(label)
    if pool then
        pool.dynAlloc = {
            type = "weighted_remainder",
            weight = weight,
        }
        pools.state.commit()
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end

    ctx.reply { text = "success" }
end

local function handleSetAllocStatic(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local label = ctx.args.item ---@type string

    local pool = pools.getByTag(label)
    if pool then
        pool.dynAlloc = nil
        pools.state.commit()
    else
        return ctx.replyErr(
            ("The item pool %q doesn't exist"):format(label),
            ctx.argTokens.item
        )
    end

    ctx.reply { text = "success" }
end

---@param ctx cbb.Context
local function handleAllocRebalance(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local toMove = ctx.args.value ---@type number
    allocation.rebalance(toMove, true)
    local pool = secprice.getSecPool()
    local itemsToMove = toMove / pool:midPrice()
    secprice.reallocItems(itemsToMove)
    ctx.reply { text = "success" }
end

---@param ctx cbb.Context
local function handleMint(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local id = ctx.args.id ---@type string
    local amount = ctx.args.amount ---@type number

    if not id:match("^lp:[^~]*~NONE$") then
        return ctx.replyErr("Not a valid asset ID", ctx.argTokens.id)
    end

    local acct = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    local _, bal = acct:transferAsset(id, amount, true)

    ctx.reply { text = "Balance: " .. tostring(bal) }
end

---@param ctx cbb.Context
local function handleRebalanceInfo(ctx)
    local pos, neg = allocation.computeTargetDeltas()

    local array = {}
    for k, v in pairs(pos) do array[#array + 1] = {k, v} end
    for k, v in pairs(neg) do array[#array + 1] = {k, v} end

    table.sort(array, function(a, b) return math.abs(a[2]) > math.abs(b[2]) end)

    ---@type cbb.FormattedBlock[]
    local out = {{
        text = "Top pending rebalancing actions:"
    }}

    for i = 1, math.min(10, #array) do
        local kv = array[i]
        local pool = pools.get(kv[1])
        if pool then
            local percent = util.mRound(100 * kv[2] / pool.allocatedKrist)
            out[#out + 1] = {
                text = "\n" .. tostring(i) .. ". " .. pool.label .. ": "
            }
            if kv[2] < 0 then
                out[#out + 1] = {
                    text = tostring(kv[2]),
                    color = cbb.colors.RED,
                }
            else
                out[#out + 1] = {
                    text = tostring(kv[2]),
                    color = cbb.colors.GREEN,
                }
            end
            out[#out + 1] = {
                text = " KST ("
            }
            if kv[2] < 0 then
                out[#out + 1] = {
                    text = tostring(percent) .. "%",
                    color = cbb.colors.RED,
                }
            else
                out[#out + 1] = {
                    text = tostring(percent) .. "%",
                    color = cbb.colors.GREEN,
                }
            end
            out[#out + 1] = {
                text = ")"
            }
        end
    end

    return ctx.reply(table.unpack(out))
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

---@param ctx cbb.Context
local function handlePropose(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local title = ctx.args.title ---@type string
    local description = ctx.args.description ---@type string
    local yes = ctx.args.yes ---@type string
    local no = ctx.args.no ---@type string
    local expDays = ctx.args.expDays ---@type number

    local author = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    local expiry = os.epoch("utc") + expDays * 1000 * 3600 * 24
    propositions.create(author, title, description, yes, no, expiry, true)

    ctx.reply({ text = "success" })
end

local function handleDelProp(ctx)
    if ctx.user:lower() ~= "pg231" then return end -- lazy
    local id = ctx.args.id ---@type number
    local prop = propositions.get(id)
    if not prop then
        return ctx.replyErr("This proposition doesn't exist", ctx.argTokens.id)
    end
    prop:delete(true)
    return ctx.reply({ text = "Success!" })
end

---@param ctx cbb.Context
local function handleVote(ctx)
    local id = ctx.args.id ---@type number
    local ratio = ctx.args.ratio ---@type number

    ratio = math.min(1, math.max(0, ratio))

    local voter = sessions.setAcct(ctx.data.user.uuid, ctx.user, true)
    local prop = propositions.get(id)
    if not prop then
        return ctx.replyErr("This proposition doesn't exist", ctx.argTokens.id)
    end

    prop:cast(voter, ratio, true)
    return ctx.reply({ text = "Success!" })
end

---@param ctx cbb.Context
local function handleQueryProposition(ctx)
    local id = ctx.args.id ---@type number

    local prop = propositions.get(id)
    if not prop then
        return ctx.replyErr("This proposition doesn't exist", ctx.argTokens.id)
    end

    return ctx.reply(table.unpack(prop:render()))
end

---@param ctx cbb.Context
local function handleListPropositions(ctx)
    local out = {{ text = "Propositions:" }} ---@type cbb.FormattedBlock[]
    for _, prop in propositions.propositions() do
        out[#out + 1] = {
            text = ("\n%d. "):format(prop.id),
            formats = { cbb.formats.BOLD },
        }
        out[#out + 1] = {
            text = prop.title,
        }
    end
    return ctx.reply(table.unpack(out))
end

local recursiveWrongPool = {
    
}

local root = cbb.literal("lp") "lp" {
    cbb.literal("help") "help" {
        help = "Provides this help message",
        execute = function(ctx)
            return cbb.sendHelpTopic(1, ctx, 10, 1)
        end,
        cbb.integerExpr "page" {
            execute = function(ctx)
                return cbb.sendHelpTopic(2, ctx, 10, ctx.args.page)
            end
        }
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
    cbb.literal("sell") "sell" {
        cbb.string "item" {
            cbb.integerExpr "amount" {
                help = "Sells a digital item",
                execute = handleSell,
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
    cbb.literal("baltop") "baltop" {
        help = "Displays top Krist balances",
        execute = handleBaltopKst,
        cbb.string "asset" {
            help = "Displays top asset balances",
            execute = handleBaltopAsset,
        },
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
    cbb.literal("fund") "fund" {
        cbb.literal("dyn") "dyn" {
            cbb.numberExpr "amount" {
                execute = handleDynRealloc,
            }
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
            cbb.literal("rate") "rate" {
                cbb.numberExpr "value" {
                    execute = handleSetAllocFixedRate,
                },
            },
            cbb.literal("weight") "weight" {
                cbb.numberExpr "value" {
                    execute = handleSetAllocWeightedRemainder,
                },
            },
            cbb.literal("static") "static" {
                execute = handleSetAllocStatic,
            },
            cbb.numberExpr "amount" {
                execute = handleAlloc,
            }
        }
    },
    cbb.literal("rebalance") "rebalance" {
        help = "Displays information about pending rebalance reallocations",
        execute = handleRebalanceInfo,
        cbb.numberExpr "value" {
            execute = handleAllocRebalance,
        },
    },
    cbb.literal("kick") "kick" {
        execute = handleKick,
    },
    cbb.literal("mint") "mint" {
        cbb.string "id" {
            cbb.numberExpr "amount" {
                execute = handleMint,
            },
        },
    },
    cbb.literal("proposition") "proposition" {
        cbb.literal("list") "list" {
            execute = handleListPropositions,
        },
        cbb.literal("vote") "vote" {
            cbb.integer "id" {
                cbb.number "ratio" {
                    execute = handleVote,
                }
            }
        },
        cbb.literal("delete") "delete" {
            cbb.integer "id" {
                execute = handleDelProp,
            },
        },
        cbb.literal("new") "new" {
            cbb.string "title" {
                cbb.string "description" {
                    cbb.string "yes" {
                        cbb.string "no" {
                            cbb.integerExpr "expDays" {
                                execute = handlePropose,
                            },
                        },
                    },
                },
            },
        },
        cbb.integer "id" {
            execute = handleQueryProposition,
        },
    },
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
        cbb.execute(root, BOT_NAME, { "command", user, command, args, etc })
    end
end)

threads.register(function()
    ChatboxReadyEvent.pull()

    local function ping()
        chatbox.tell(".ping", "is the chatbox socket alive?")
    end

    while true do
        sleep(30)
        local ok, err = pcall(ping)
        if not ok then
            error("chatbox socket errored on tell")
        end
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
