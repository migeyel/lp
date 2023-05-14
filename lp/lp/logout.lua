local sessions = require "lp.sessions"
local threads = require "lp.threads"
local event = require "lp.event"
local log = require "lp.log"

local SENSOR_SLEEP_PERIOD = 7
local SLEEP_PERIODS_UNTIL_LOGOUT = 2
local SENSOR_RADIUS_INFINITY_NORM = 5
local SESSION_TIMEOUT_MS = 90000

local sensor = assert(peripheral.find("plethora:sensor"), "coudln't find entity sensor")

local sessionPlayerAbsentEvent = event.register()

threads.register(function()
    while true do
        sleep(SENSOR_SLEEP_PERIOD)
        local session, entities = nil, nil
        session = sessions.get()
        if session then
            entities = sensor.sense()
            session = sessions.get() -- .sense() yields
        end
        if session then
            local playerHere = false
            for _, e in pairs(entities) do
                local valid = e.key == "minecraft:player"
                    and e.name:lower() == session.user:lower()
                    and math.max(e.x, e.y, e.z) < SENSOR_RADIUS_INFINITY_NORM
                if valid then
                    playerHere = true
                    break
                end
            end
            if not playerHere then
                sessionPlayerAbsentEvent.queue()
            end
        end
    end
end)

-- Not being near the shop
threads.register(function()
    while true do
        local session = sessions.get()
        while not session do
            sessions.startEvent.pull()
            session = sessions.get()
        end
        local awayCounter = 0
        while true do
            local e = event.pull()
            if e == sessions.endEvent then
                break
            elseif e == sessionPlayerAbsentEvent then
                awayCounter = awayCounter + 1
                if awayCounter >= SLEEP_PERIODS_UNTIL_LOGOUT then
                    session = sessions.get() -- .pull() yields
                    if session then
                        log:info("Ending session due to player absence")
                        session:close()
                    end
                    break
                end
            end
        end
    end
end)

-- Inactivity
threads.register(function()
    while true do
        local session = sessions.get()
        while not session do
            sessions.startEvent.pull()
            session = sessions.get() -- .pull() yields
        end
        if os.epoch("utc") - session.lastActive >= SESSION_TIMEOUT_MS then
            log:info("Ending session due to inactivity")
            session:close()
        end
        local ms = session.lastActive + SESSION_TIMEOUT_MS - os.epoch("utc")
        local id = os.startTimer(ms / 1000)
        while true do
            local e, p1 = event.pull()
            if e == sessions.endEvent then
                os.cancelTimer(id)
                break
            elseif e == "timer" and p1 == id then
                break
            end
        end
    end
end)
