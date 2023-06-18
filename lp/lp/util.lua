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

local freqNames = {
    [0] = "white", "orange", "magenta", "light blue", "yellow", "lime", "pink",
    "gray", "light gray", "cyan", "purple", "blue", "brown", "green", "red",
    "black",
}

return {
    mFloor = mFloor,
    mCeil = mCeil,
    mRound = mRound,
    freq2Num = freq2Num,
    num2Freq = num2Freq,
    freqNames = freqNames,
}
