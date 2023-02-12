local expect = require "cc.expect".expect
local config = require "lp.setup"
local chapoly = require "chapoly"
local sha256 = require "sha256"

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

local function strx(s1, s2)
    local b1 = { s1:byte(1, -1) }
    local b2 = { s2:byte(1, -1) }
    local b3 = {}
    for i = 1, math.max(#b1, #b2) do
        b3[i] = bit32.bxor(b1[i] or 0, b2[i] or 0)
    end
    return string.char(unpack(b3))
end

local function hmac(key, msg)
    expect(1, key, "string")
    expect(2, msg, "string")
    if #key > 64 then key = sha256(key) end
    local ipad = strx(key, ("\x36"):rep(64))
    local opad = strx(key, ("\x5c"):rep(64))
    return sha256(opad .. sha256(ipad .. msg))
end

local function toHex(s)
    return ("%02x"):rep(#s):format(s:byte(1, -1))
end

local function fromHex(s)
    return s:gsub("..", function(h) return string.char(tonumber(h, 16)) end)
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

local rngState = hmac(
    config.pkey,
    os.epoch("utc") .. "|" .. math.random(0, 2 ^ 31 - 2)
)

local function randomBytes(n)
    local nonce = ("\0"):rep(12)
    local msg = ("\0"):rep(n + 32)
    local out = chapoly.crypt(rngState, nonce, msg, 8)
    rngState = out:sub(1, 32)
    return out:sub(33)
end

return {
    hmac = hmac,
    toHex = toHex,
    fromHex = fromHex,
    mFloor = mFloor,
    mCeil = mCeil,
    mRound = mRound,
    freq2Num = freq2Num,
    num2Freq = num2Freq,
    randomBytes = randomBytes,
}
