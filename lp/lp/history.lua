local lproto = require "lproto"

local INIT_TIMESTAMP = 1690589868159

--- An lproto schema for a HistoryState.
---
--- We use the fact that the concatenation of ProtoBuf messages results in the
--- concatenation of inner lists to let files be updated in-place by appending.
---
--- We store price and time differences rather than values. The items and mKst
--- refer to the last value in the same pool, where the time delta is global.
--- The first deltaTime refers to the difference from INIT_TIMESTAMP, whereas
--- the first item and mKst deltas for a pool refer to the difference from 0.
---
--- When a price for a new pool is appended, the pool is registered in the pools
--- index, and its position in the list is used in poolIndex, rather than using
--- the full pool name.
---
local HistoryStruct = lproto.message {
    pools = lproto.bytes { repeated = true } (2),
    prices = lproto.message {
        poolIndex = lproto.uint53 (1);
        deltaTime = lproto.uint53 (2);
        deltaItems = lproto.sint53 (3);
        deltaMKst = lproto.sint53 (4);
    } { repeated = true } (1);
}

--- A snapshot telling where an item's price was at a given time.
---@class HistoryPriceSnapshot
---@field timestamp integer
---@field items integer
---@field mKst integer

--- A time sequence of price changes into string-indexed pools.
---@class HistoryState
---@field lastTimestamp number
---@field poolIdIndex string[]
---@field poolIdRev table<string, integer>
---@field prices table<string, HistoryPriceSnapshot[]>
local HistoryState = {}

--- Creates a new empty history state.
---@return HistoryState
function HistoryState.new()
    return setmetatable({
        lastTimestamp = INIT_TIMESTAMP,
        poolIdIndex = {},
        poolIdRev = {},
        prices = {},
    }, { __index = HistoryState })
end

--- Decodes a state from an encoded string, which is the concatenation of many
--- appendPrice outputs.
---@param encoded string
---@return HistoryState
function HistoryState.decode(encoded)
    local struct = HistoryStruct.deserialize(encoded)
    local poolIdIndex = {} ---@type string[]
    local poolIdRev = {} ---@type table<string, integer>
    local prices = {} ---@type table<string, HistoryPriceSnapshot[]>
    local lastTimestamp = INIT_TIMESTAMP

    for i, poolId in ipairs(struct.pools) do
        poolIdIndex[i] = poolId
        poolIdRev[poolId] = i
    end

    for _, tx in ipairs(struct.prices) do
        lastTimestamp = lastTimestamp + tx.deltaTime

        local poolIndex = tx.poolIndex + 1
        local poolId = poolIdIndex[poolIndex]
        local poolPrices = prices[poolId] or {}
        prices[poolId] = poolPrices

        local lastPrice = poolPrices[#poolPrices] or {}
        local newItems = (lastPrice.items or 0) + tx.deltaItems
        local newMKst = (lastPrice.mKst or 0) + tx.deltaMKst
        local newPrice = newMKst / newItems

        if newPrice > 0 and newPrice < 2 ^ 40 then
            poolPrices[#poolPrices + 1] = {
                timestamp = lastTimestamp,
                items = (lastPrice.items or 0) + tx.deltaItems,
                mKst = (lastPrice.mKst or 0) + tx.deltaMKst,
            }
        else
            poolPrices[#poolPrices + 1] = {
                timestamp = lastTimestamp,
                items = lastPrice.items,
                mKst = lastPrice.mKst,
            }
        end
    end

    return setmetatable({
        lastTimestamp = lastTimestamp,
        poolIdIndex = poolIdIndex,
        poolIdRev = poolIdRev,
        prices = prices,
    }, { __index = HistoryState })
end

--- Appends a price entry into the tail of a history state. Returns an encoded
--- string that can be appended into a file representing the serialized state to
--- also update it.
---@param poolId string
---@param price HistoryPriceSnapshot
---@return string
function HistoryState:appendPrice(poolId, price)
    local struct = {}

    if price.timestamp < self.lastTimestamp then
        error(("attempted to append a price in the past (%d < %d)"):format(
            price.timestamp,
            self.lastTimestamp
        ))
    end

    local index = self.poolIdRev[poolId]
    if not index then
        index = #self.poolIdIndex + 1
        self.poolIdIndex[index] = poolId
        self.poolIdRev[poolId] = index
        self.prices[poolId] = {}
        struct.pools = { poolId }
    end

    local poolPrices = self.prices[poolId]
    local lastPrice = poolPrices[#poolPrices] or {}

    struct.prices = {
        {
            poolIndex = index - 1,
            deltaTime = price.timestamp - self.lastTimestamp,
            deltaItems = price.items - (lastPrice.items or 0),
            deltaMKst = price.mKst - (lastPrice.mKst or 0),
        },
    }

    self.lastTimestamp = price.timestamp
    poolPrices[#poolPrices + 1] = price

    return HistoryStruct.serialize(struct)
end

---@param poolId string
---@param price HistoryPriceSnapshot
function HistoryState:mergePrice(poolId, price)
    local index = self.poolIdRev[poolId]
    if not index then
        index = #self.poolIdIndex + 1
        self.poolIdIndex[index] = poolId
        self.poolIdRev[poolId] = index
        self.prices[poolId] = {}
    end

    local poolPrices = self.prices[poolId]
    poolPrices[#poolPrices + 1] = price
end

--- Merges two history states into a single one.
---@param incoming HistoryState
---@return HistoryState
function HistoryState:merge(incoming)
    local new = self.new()

    local poolIds = {}
    for poolId in pairs(self.prices) do poolIds[poolId] = true end
    for poolId in pairs(incoming.prices) do poolIds[poolId] = true end

    for poolId in pairs(poolIds) do
        local prices1 = self.prices[poolId] or {}
        local prices2 = incoming.prices[poolId] or {}
        local i, j = 1, 1
        while i <= #prices1 and j <= #prices2 do
            local price1 = prices1[i]
            local price2 = prices2[j]
            if price1.timestamp < price2.timestamp then
                new:mergePrice(poolId, price1)
                i = i + 1
            else
                new:mergePrice(poolId, price2)
                j = j + 1
            end
        end

        while i < #prices1 do
            new:mergePrice(poolId, prices1[i])
            i = i + 1
        end

        while j < #prices2 do
            new:mergePrice(poolId, prices2[j])
            j = j + 1
        end
    end

    return new
end

--- Returns the (open, close, low, high) prices at a specified time range.
--- Returns nil if the start of the range falls outside of price history.
---@param poolId string
---@param startMs integer
---@param endMs integer
---@return number[]? candlestick
function HistoryState:getCandlestick(poolId, startMs, endMs)
    local prices = self.prices[poolId]
    if not prices then return end
    if #prices == 0 then return end

    local at = 1
    local h = #prices
    while at < h do
        local m = math.ceil((at + h) / 2)
        if prices[m].timestamp > startMs then
            h = m - 1
        else
            at = m
        end
    end

    local open = prices[at].mKst / prices[at].items / 1000
    local low = open
    local high = open
    local close = open

    at = at + 1
    while prices[at] and prices[at].timestamp <= endMs do
        close = prices[at].mKst / prices[at].items / 1000
        low = math.min(low, close)
        high = math.max(high, close)
        at = at + 1
    end

    return { open, close, low, high }
end

-- A UUID for finding which disk holds the history.
local DIR_UUID = "fdfeb842-7d95-49b6-88d2-0fae1bb29117"

local historyDir = nil
local drives = { peripheral.find("drive") } ---@type Drive[]
for _, drive in pairs(drives) do
    local mountPath = drive.getMountPath()
    if mountPath then
        local testPath = fs.combine(mountPath, DIR_UUID)
        if fs.isDir(testPath) then
            historyDir = testPath
            break
        end
    end
end

assert(historyDir, "history directory disk not found")

-- We store the history as a set of files, one per day, in a directory. Every
-- file holds a separate serialized history entry. We update by appending to the
-- latest file and decode into memory by merging all files using merge().
local MAX_FILES = 7

--- The history of all files in the directory.
local fullHistory = HistoryState.new()

--- The history of the latest file in the directory.
local tailHistory = HistoryState.new()

--- The filename of the latest file in the directory.
local tailFile = nil

local function reloadTailHistory()
    tailFile = os.date("%Y%m%d.bin") --[[@as string]]
    if fs.exists(fs.combine(historyDir, tailFile)) then
        local f = assert(fs.open(fs.combine(historyDir, tailFile), "rb"))
        tailHistory = HistoryState.decode(tostring(f.readAll()))
        f.close()
    else
        tailHistory = HistoryState.new()
    end
end

reloadTailHistory()

local function reloadFullHistory()
    -- TODO this is quadratic, maybe look into merging as a tree to get it to be
    -- log-linear.
    fullHistory = HistoryState.new()
    for _, filename in ipairs(fs.list(historyDir)) do
        local f = assert(fs.open(fs.combine(historyDir, filename), "rb"))
        local new = HistoryState.decode(tostring(f.readAll()))
        fullHistory = fullHistory:merge(new)
        f.close()
    end
end

reloadFullHistory()

--- Updates the tail file, and matching state, to match the current date.
local function setTailFile()
    if os.date("%Y%m%d.bin") ~= tailFile then
        reloadTailHistory()
    end
end

--- Deletes old files and updates the full state when needed.
local function enforceMaxFiles()
    local filenames = fs.list(historyDir)
    table.sort(filenames)

    local update = false
    while #filenames > MAX_FILES do
        fs.delete(fs.combine(historyDir, table.remove(filenames, 1)))
        update = true
    end

    if update then reloadFullHistory() end
end

local function tryAppend(path, data)
    assert(fs.getFreeSpace(path) > #data, "out of space")
    local f = assert(fs.open(path, "ab"))
    f.write(data)
    f.close()
end

---@param poolId string
---@param price HistoryPriceSnapshot
local function addPriceEntry(poolId, price)
    setTailFile()
    enforceMaxFiles()
    fullHistory:appendPrice(poolId, price)
    local encoded = tailHistory:appendPrice(poolId, price)
    tryAppend(fs.combine(historyDir, tailFile), encoded)
end

local function getCandlestick(poolId, startMs, endMs)
    return fullHistory:getCandlestick(poolId, startMs, endMs)
end

return {
    addPriceEntry = addPriceEntry,
    getCandlestick = getCandlestick,
}
