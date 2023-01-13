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

local err = nil
local ok = xpcall(
    function()
        local wallet = require "lp.wallet"
        wallet.checkTotalout()
        wallet.checkLastseen()

        require "lp.ui"
        require "lp.sucker"
        require "lp.logout"
        require "lp.command"

        local threads = require "lp.threads"
        parallel.waitForAll(unpack(threads.t))
    end,
    function(e)
        err = e
        report(e .. "\n" .. debug.traceback())
    end
)

if ok then
    report("the shop returned without throwing an error")
end

if err ~= "Terminated" then
    log:info("Restarting 5 seconds")
    sleep(5)
    os.reboot()
end
