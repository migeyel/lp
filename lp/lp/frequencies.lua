local inventory = require "lp.inventory"
local util = require "lp.util"
local md5 = require "md5"

local FREQUENCY_OWNER_USERNAME = "PG231"
local FREQUENCY_OWNER_UUID = "eddfb53516e14c6a8b6e3fcf4b85dc73"

---@param username string
---@param uuid string
---@param left number
---@param middle number
---@param right number
local function enderStorageNBTHash(username, uuid, left, middle, right)
    local uuidBytes = ""
    for m in uuid:gmatch("%x%x") do
        uuidBytes = uuidBytes .. string.char(tonumber(m, 16))
    end
    return md5(
        "\10\0\0"
            .. "\10\0\14BlockEntityTag"
                .. "\1\0\22computerChangesEnabled\0"
                .. "\10\0\9frequency"
                    .. "\1\0\4left" .. string.char(left)
                    .. "\1\0\6middle" .. string.char(middle)
                    .. "\11\0\5owner\0\0\0\4" .. uuidBytes
                    .. "\8\0\9ownerName" .. (">s2"):pack(username)
                    .. "\1\0\5right" .. string.char(right)
                .. "\0"
                .. "\8\0\2id\0\24sc-goodies:ender_storage"
            .. "\0"
        .. "\0"
    )
end

---@type table<string, number>
local storedFrequencies = {}

for left = 0, 15 do
    for middle = 0, 15 do
        for right = 0, 15 do
            local hash = enderStorageNBTHash(
                FREQUENCY_OWNER_USERNAME,
                FREQUENCY_OWNER_UUID,
                left,
                middle,
                right
            )

            if inventory.inv.getCount("sc-goodies:ender_storage", hash) > 0 then
                storedFrequencies[hash] = util.freq2Num(
                    2 ^ left,
                    2 ^ middle,
                    2 ^ right
                )
            end
        end
    end
end

---@return string?, number?
local function popFrequency()
    local h, f = next(storedFrequencies)
    if h then storedFrequencies[h] = nil end
    return h, f
end

return {
    popFrequency = popFrequency,
}
