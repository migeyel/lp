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
    local filteredStorage = {}
    for _, v in pairs(storage) do
        local name = peripheral.getName(v)
        local isEnderStorage = false
        for _, ty in ipairs { peripheral.getType(name) } do
            if ty == "ender_storage" then
                isEnderStorage = true
            end
        end
        if not isEnderStorage then
            filteredStorage[#filteredStorage + 1] = peripheral.getName(v)
        end
    end

    log:info("Loading inventory with " .. #filteredStorage .. " containers")
    local linv = abstractInvLib(filteredStorage)
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
