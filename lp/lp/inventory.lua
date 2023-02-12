local abstractInvLib = require "abstractInvLib"
local mutex = require "lp.mutex"
local log = require "lp.log"

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
local inv = abstractInvLib(filteredStorage)
inv.refreshStorage()
inv.defrag()
log:info("Inventory loaded")

return {
    inv = inv,
    turtleMutex = mutex(),
}
