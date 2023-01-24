local t = {}
local startups = {}

--- Registers a function that will run on every thread registered afterwards.
local function registerStartup(f)
    startups[#startups + 1] = f
end

local function register(f)
    local threadStartups = { unpack(startups) }
    t[#t + 1] = function()
        for _, v in ipairs(threadStartups) do v() end
        return f()
    end
end

return {
    t = t,
    registerStartup = registerStartup,
    register = register,
}
