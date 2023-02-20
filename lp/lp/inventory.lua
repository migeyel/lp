local abstractInvLib = require "abstractInvLib"
local mutex = require "lp.mutex"
local log = require "lp.log"

local invStartupMutex = mutex()
local inv = nil

---@return AbstractInventory
local function get()
    local guard = invStartupMutex.lock()
    if inv then
        guard.unlock()
        return inv
    end

    log:info("Starting inventory")

    local storage = { peripheral.find("inventory") }
    for i, v in pairs(storage) do storage[i] = peripheral.getName(v) end
    local linv = abstractInvLib(storage)
    linv.refreshStorage()
    linv.defrag()

    log:info("Inventory ready")
    inv = linv

    guard.unlock()
    return linv
end

return {
    get = get,
    turtleMutex = mutex(),
}
