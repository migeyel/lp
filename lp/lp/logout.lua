local sessions = require "lp.sessions"
local threads = require "lp.threads"
local log = require "lp.log"

local SENSOR_SLEEP_PERIOD = 15
local SENSOR_RADIUS_INFINITY_NORM = 5
local SESSION_TIMEOUT_MS = 180000

local sensor = assert(peripheral.find("plethora:sensor"), "coudln't find entity sensor")

-- Not being near the shop
threads.register(function()
    while true do
        sleep(SENSOR_SLEEP_PERIOD)
        local session, entities = nil, nil
        session = sessions.get()
        if session then
            entities = sensor.sense()
            session = sessions.get() -- sense() yields
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
            if playerHere then
                log:debug("Player is still here, letting the session continue")
            else
                log:info("Ending session due to player not being present")
                session:close()
                break
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
            session = sessions.get()
        end
        while os.epoch("utc") - session.lastActive < SESSION_TIMEOUT_MS do
            local ms = SESSION_TIMEOUT_MS - os.epoch("utc") + session.lastActive
            sleep(ms / 1000)
        end
        session = sessions.get()
        if session then
            log:info("Ending session due to inactivity")
            session:close()
        end
    end
end)
