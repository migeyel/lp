local abstractInvLib = require "abstractInvLib"
local mutex = require "lp.mutex"
local log = require "lp.log"

local inv = nil

---@return AbstractInventory
local function get()
    if inv then return inv end
    log:info("Starting inventory")

    local storage = { peripheral.find("inventory") }
    for i, v in pairs(storage) do storage[i] = peripheral.getName(v) end
    inv = abstractInvLib(storage)
    inv.refreshStorage()
    inv.defrag()

    log:info("Inventory ready")
    return inv
end

return {
    get = get,
    turtleMutex = mutex(),
}
