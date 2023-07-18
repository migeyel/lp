local event = require "lp.event"

return function()
    local slot = nil
    local releaseEvent = event.register("mutex_release")

    ---@class Mutex
    local mutex = {}

    function mutex.unlock()
        if slot then
            slot = nil
            releaseEvent.queue()
        end
    end

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
