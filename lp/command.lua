local sessions = require "lp.sessions"
local threads = require "lp.threads"
local pools   = require "lp.pools"
local inventory = require "lp.inventory"
local log = require "lp.log"

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
        tell(user, "Usage: \\lp start")
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
        tell(user, "Usage: \\lp exit")
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
        tell(user, "Usage: \\lp buy <item> <amount>")
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

local function handleRawdelta(user, args)
    if #args < 1 then
        tell(user, "Usage: \\lp rawput <amount>")
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

threads.register(function()
    while true do
        local _, user, command, args, etc = os.pullEvent("command")
        if command == "lp" then
            if args[1] == "start" then
                handleStart(user, { unpack(args, 2) })
            elseif args[1] == "buy" then
                handleBuy(user, { unpack(args, 2) })
            elseif args[1] == "exit" then
                handleExit(user, { unpack(args, 2) })
            elseif args[1] == "rawdelta" and etc.ownerOnly then
                handleRawdelta(user, { unpack(args, 2) })
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