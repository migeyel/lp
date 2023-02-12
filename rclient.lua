local expect = require "cc.expect".expect
local sha256 = require "sha256"
local chaskey = require "chaskey"
local chapoly = require "chapoly"
local proto = require "proto"

local token = "bodia"
local masterKey = sha256(token)
local lastTimestamp = os.epoch("utc")
local context = os.epoch("utc") .. "|" .. math.random(0, 2 ^ 31 - 2) .. "|"
local rngState = sha256(context .. token)

local function randomBytes(n)
    local nonce = ("\0"):rep(12)
    local msg = ("\0"):rep(n + 32)
    local out = chapoly.crypt(rngState, nonce, msg, 8)
    rngState = out:sub(1, 32)
    return out:sub(33)
end

local SERVER_LISTEN_CHANNEL = 19260
local clientListenChannel = os.getComputerID()

local modem = peripheral.find("modem")
modem.open(clientListenChannel)

---@param key string
---@return string prefix, function mac, string dataKey
local function deriveKeys(key)
    local nonce = ("\0"):rep(12)
    local message = ("\0"):rep(16 + 16 + 32)
    local expanded = chapoly.crypt(key, nonce, message)
    local prefix, tagKey, dataKey = ("c16c16c32"):unpack(expanded) --[[@as string]]
    local mac = chaskey(tagKey)
    return prefix, mac, dataKey
end

local nonce = ("\0"):rep(12)
local message = ("\0"):rep(64)
local expandedMk = chapoly.crypt(masterKey, nonce, message)
local serverSubKey, clientSubKey = ("c32c32"):unpack(expandedMk) --[[@as string]]

local serverPrefix, serverMac, serverDataKey = deriveKeys(serverSubKey)
local clientPrefix, clientMac, clientDataKey = deriveKeys(clientSubKey)

---@param input string
---@param len number
---@return string
local function pad(input, len)
    return input .. "\x80" .. ("\0"):rep(len - #input - 1)
end

---@param input string
---@return string
local function unpad(input)
    for i = -1, -#input, -1 do
        if input:byte(i) == 0x80 then
            return input:sub(1, i - 1)
        end
    end
    return ""
end

---@param rch number
---@param m string
local function send(m)
    local timestamp = ("<I8"):pack(os.epoch("utc"))
    local timestampTag = serverMac(timestamp)
    local nonce = randomBytes(12)
    local ctx, dataTag = chapoly.encrypt(
        serverDataKey,
        nonce,
        pad(m, 0),
        "",
        8
    )

    local packet = ("c16c8c16c12c16"):pack(
        serverPrefix,
        timestamp,
        timestampTag,
        nonce,
        dataTag
    ) .. ctx

    modem.transmit(SERVER_LISTEN_CHANNEL, clientListenChannel, packet)
end

local function handleModemMessage(_, _, ch, rch, m)
    -- Basic checks
    if ch ~= clientListenChannel then return end
    if rch ~= SERVER_LISTEN_CHANNEL then return end
    if type(m) ~= "string" then return end
    if #m < 16 + 8 + 16 + 12 + 16 then return end
    if m:sub(1, 16) ~= clientPrefix then return end

    -- Check timestamp tag
    local timestamp, timestampTag, nonce, dataTag, ctxPos =
        ("c8c16c12c16"):unpack(m, 17)
    if timestampTag ~= clientMac(timestamp) then return end

    -- Check timestamp
    timestamp = ("<I8"):unpack(timestamp)
    if timestamp <= lastTimestamp then return end
    lastTimestamp = timestamp

    -- Decrypt
    local plaintext = chapoly.decrypt(
        clientDataKey,
        nonce,
        dataTag,
        m:sub(ctxPos),
        "",
        8
    )

    if plaintext then
        return unpad(plaintext)
    end
end

local function receive(id)
    local out = nil
    repeat
        out = handleModemMessage(os.pullEvent("modem_message"))
    until out
    return proto.Response.deserialize(out)
end

send(proto.Request.serialize {
    id = 0,
    buy = {
        label = "gold ingot",
        slot = 1,
        amount = 1,
        maxPerItem = 1.0,
    }
})

require("cc.pretty").pretty_print(receive(0))
