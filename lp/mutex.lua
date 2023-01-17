local event = require "lp.event"

return function()
    local slot = nil
    local releaseEvent = event.register()

    ---@class Mutex
    local mutex = {}

    ---@return MutexGuard
    function mutex.lock()
        while slot do
            releaseEvent.pull()
        end

        ---@class MutexGuard
        local guard = {}

        function guard.unlock()
            if slot == guard then
                slot = nil
                releaseEvent.queue()
            end
        end

        slot = guard

        return guard
    end

    return mutex
end
