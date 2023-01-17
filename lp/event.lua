--- Little interface for keeping track of events without resorting to strings.
--
-- As I write this, I'm really starting to think about that "FizzBuzz Enterprise
-- Edition" joke on github. Am I really being so enterprise-grade to make a FULL
-- MODULE to keep track of events?

local events = setmetatable({}, { __mode = "v" })
local ids = setmetatable({}, { __mode = "k" })
local n = 0

---@return Event
local function register()
    n = n + 1
    local id = "lb_event_" .. n

    ---@class Event
    local event = {}

    events[id] = event
    ids[event] = id

    function event.queue(...)
        os.queueEvent(id, ...)
    end

    function event.pull()
        return select(2, os.pullEvent(id))
    end

    return event
end

---@param filter string|nil
local function pull(filter)
    if filter then
        local d = events[filter]
        if d then
            return d.pull()
        else
            return os.pullEvent(filter)
        end
    else
        local e = { os.pullEvent(filter) }
        local f = events[e[1]]
        if f then
            return f, unpack(e, 2)
        else
            return unpack(e)
        end
    end
end

return {
    pull = pull,
    register = register,
}
