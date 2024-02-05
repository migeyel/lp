---@param n number
---@return number
local function mFloor(n)
    return math.floor(n * 1000) / 1000
end

---@param n number
---@return number
local function mCeil(n)
    return math.ceil(n * 1000) / 1000
end

---@param n number
---@return number
local function mRound(n)
    return math.floor(n * 1000 + 1/2) / 1000
end

local function freq2Num(l, m, r)
    return math.log(l, 2)
        + math.log(m, 2) * 16
        + math.log(r, 2) * 256
end

local function num2Freq(f)
    return 2 ^ bit32.extract(f, 0, 4),
        2 ^ bit32.extract(f, 4, 4),
        2 ^ bit32.extract(f, 8, 4)
end

local colorName = {}
for k, v in pairs(colors) do
    if type(v) == "number" then
        colorName[v] = k
    end
end

---@generic T
---@param arr T[]
---@param pageSize number
---@param pageNumber number
---@return T[] page
---@return number pageNumber
---@return number numPages
local function paginate(arr, pageSize, pageNumber)
    local numPages = math.ceil(#arr / pageSize)
    pageNumber = math.max(1, math.min(numPages, pageNumber))
    local index = (pageNumber - 1) * pageSize + 1
    local page = table.pack(table.unpack(arr, index, index + pageSize - 1))
    return page, pageNumber, numPages
end

return {
    mFloor = mFloor,
    mCeil = mCeil,
    mRound = mRound,
    freq2Num = freq2Num,
    num2Freq = num2Freq,
    paginate = paginate,
    colorName = colorName,
}
