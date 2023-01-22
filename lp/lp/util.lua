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

return {
    mFloor = mFloor,
    mCeil = mCeil,
    mRound = mRound,
}
