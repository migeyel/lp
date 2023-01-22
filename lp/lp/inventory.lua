local abstractInvLib = require "abstractInvLib"
local mutex          = require "lp.mutex"

local storage = { peripheral.find("inventory") }
for i, v in pairs(storage) do storage[i] = peripheral.getName(v) end
local inv = abstractInvLib(storage)

inv.refreshStorage()
inv.defrag()

return {
    inv = inv,
    turtleMutex = mutex(),
}
