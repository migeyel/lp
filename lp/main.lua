require "loaders"

local log = require "lp.log"
local logging = require "logging"

log.providers = {}
log:addProvider(logging.providers.print)
log:addProvider(logging.providers.file)

local function report(e)
    if e:match("^Terminated") then
        log:info("Terminated")
    else
        log:critical(e)
    end

    local mon = peripheral.find("monitor")
    mon.setBackgroundColor(colors.red)
    mon.setTextColor(colors.white)
    mon.clear()

    local w, h = mon.getSize()
    local win = window.create(mon, 2, 2, w, h)
    local old = term.redirect(win)
    term.setBackgroundColor(colors.red)
    term.setTextColor(colors.white)
    term.clear()

    print(e)

    term.redirect(old)
end

log:info("Starting LP store")

local ok, err = xpcall(
    function()
        -- TODO move recovery into a thread and put it as a startup dependency.
        -- (So that it doesn't block waiting for the inventory to initialize)
        require "lp.echest".recover()
        require "lp.stream"
        require "lp.wallet"
        require "lp.ui"
        require "lp.sucker"
        require "lp.logout"
        require "lp.command"
        require "lp.rsession"
        require "lp.frequencies"
        require "lp.broadcast"
        require "lp.secprice"
        require "lp.allocation"
        require "lp.propositions"
        local threads = require "lp.threads"
        log:info("Thread runtime started")
        parallel.waitForAll(unpack(threads.t))
    end,
    function(e)
        local ok, dt = pcall(debug.traceback)
        if ok then 
            return tostring(e) .. "\n" .. tostring(dt)
        else
            return tostring(e)
        end
    end
)

if ok then
    report("the shop returned without throwing an error")
else
    report(err)
end

if not err:match("^Terminated") then
    log:info("Restarting 5 seconds")
    sleep(5)
    os.reboot()
end
