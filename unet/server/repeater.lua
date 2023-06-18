local sha256 = require "ccryptolib.sha256"
local dllist = require "unet.server.dllist"
local helpers = require "unet.common.helpers"
local server = require "unet.server.server"
local aead = require "ccryptolib.aead"
local chacha20 = require "ccryptolib.chacha20"

local MODEM_CHANNEL = 7635
local INTRO_PREFIX = "UNet introduction prefix (\\unet)"

local modem = peripheral.find("modem", function() return true end) --[[@as Modem]]
modem.open(MODEM_CHANNEL)

--- The epoch at program start.
local initEpoch = os.epoch("utc")

--- The maximum number of sessions a user can have concurrently.
local MAX_USER_SESSION_COUNT = 16

--- The maximum number of open channels per user.
local MAX_USER_OPEN_CHANNELS = 16

---@class unet2.Session
---@field user unet2.User The session's user.
---@field channels table<string, true> The channels this session is listening.
---@field sDesc string The current server-sending descriptor.
---@field cDesc string The current client-sending descriptor.
---@field cKey string The current client-sending encryption key.
---@field sKey string The current server-sending encryption key.
---@field expiresAt number When this session will expire.
---@field expireListNode Node The session's node in the expiration linked-list.
local Session = {}
local SessionMt = { __index = Session }

--- Linked list of all sessions, ordered by expiration.
local expireList = dllist.new()

--- Sessions indexed by current client-sending descriptor.
---@type table<string, unet2.Session>
local sessionsByCDesc = {}

function Session:delete()
    -- Delete references and internal state.
    self.expireListNode:delete()
    sessionsByCDesc[self.cDesc] = nil
    for ch in pairs(self.channels) do self:closeChannel(ch) end
    self.user.allSessions[self] = nil
    self.user.nSessions = self.user.nSessions - 1

    -- Hopefully avoid reentrancy hell.
    self:transmit(server.makeSessionDeletionPacket())
end

---@param ciphertext string
---@return string?
function Session:decryptClientMsg(ciphertext)
    if #ciphertext < 16 then return end
    local ctx = ciphertext:sub(1, -17)
    local tag = ciphertext:sub(-16)
    local padded = aead.decrypt(self.cKey, ("\0"):rep(12), tag, ctx, "", 8)
    if not padded then return end
    local msg = helpers.unpad(padded)
    if not msg then return end
    self:ratchetClientKeys()
    return msg
end

function Session:ratchetClientKeys()
    sessionsByCDesc[self.cDesc] = nil
    local keys = chacha20.crypt(self.cKey, ("\xff"):rep(12), ("\0"):rep(64), 8)
    self.cDesc = keys:sub(1, 32)
    self.cKey = keys:sub(33, 64)
    sessionsByCDesc[self.cDesc] = self
end

---@param msg string
---@param prefixlen number
---@param minlen number
---@return string
function Session:encryptServerMsg(msg, prefixlen, minlen)
    local padded = helpers.pad(msg, prefixlen + 16, minlen, 64)
    local ctx, tag = aead.encrypt(self.sKey, ("\0"):rep(12), padded, "", 8)
    return ctx .. tag
end

function Session:ratchetServerKeys()
    local keys = chacha20.crypt(self.sKey, ("\xff"):rep(12), ("\0"):rep(64), 8)
    self.sDesc = keys:sub(1, 32)
    self.sKey = keys:sub(33, 64)
end

---@param msg string
function Session:transmit(msg)
    local prefix = self.sDesc
    local ctx = self:encryptServerMsg(msg, 32, 112)
    local packet = prefix .. ctx
    self:ratchetServerKeys()
    modem.transmit(MODEM_CHANNEL, MODEM_CHANNEL, packet)
end

---@param channel string
function Session:closeChannel(channel)
    if self.channels[channel] then
        self.channels[channel] = nil
        self.user.sessions[channel] = nil
        self.user.nOpenChannels = self.user.nOpenChannels - 1
    end
end

---@param channel string
---@return boolean ok Whether the channel was opened or the limit was hit.
function Session:tryOpenChannel(channel)
    if self.user.sessions[channel] then
        self.user.sessions[channel]:closeChannel(channel)
    end

    if self.user.nOpenChannels >= MAX_USER_OPEN_CHANNELS then return false end

    self.user.sessions[channel] = self
    self.channels[channel] = true
    self.user.nOpenChannels = self.user.nOpenChannels + 1

    return true
end

function Session:updateExpiry()
    local new = os.clock() + server.SESSION_EXPIRE_MS / 1000
    self.expiresAt = new
    self.expireListNode:delete()
    self.expireListNode = expireList:pushBack(self)
end

local function expireOldSessions()
    local now = os.clock()
    local first = expireList:first()
    while first do
        local session = first.data ---@type unet2.Session
        if session.expiresAt > now then break end
        session:delete()
        first = expireList:first()
    end
end

---@class unet2.User
---@field uuid string The user's UUID.
---@field lastCounter number The last acceptable counter for this user.
---@field sessionKey string The session derivation master key.
---@field introKey string The introduction tag key.
---@field prefix string The session introduction prefix.
---@field allSessions table<unet2.Session, true> ALL sessions held by the user.
---@field nSessions number The number of entries in allSessions.
---@field nOpenChannels number The number of entries in sessions.
---@field sessions table<string, unet2.Session> The open channels and sessions.
local User = {}
local UserMt = { __index = User }

--- List of all users, indexed by UUID.
---@type table<string, unet2.User>
local usersByUuid = {}

--- List of all users, indexed by introduction prefix.
---@type table<string, unet2.User>
local usersByPrefix = {}

function User:delete()
    usersByUuid[self.uuid] = nil
    usersByPrefix[self.prefix] = nil
    for session in pairs(self.allSessions) do
        session:delete()
    end
end

---@param counter string
---@param nonce string
---@return unet2.Session
function User:newSession(counter, nonce)
    local subKey = sha256.digest(counter .. nonce .. self.sessionKey)
    local sessionKeys = chacha20.crypt(subKey, ("\0"):rep(12), ("\0"):rep(128), 8)
    local cDesc = sessionKeys:sub(1, 32)
    local sDesc = sessionKeys:sub(33, 64)
    local cKey = sessionKeys:sub(65, 96)
    local sKey = sessionKeys:sub(97, 128)

    ---@type unet2.Session
    local session = setmetatable({
        user = self,
        channels = {},
        cDesc = cDesc,
        sDesc = sDesc,
        cKey = cKey,
        sKey = sKey,
        expiresAt = os.clock() + server.SESSION_EXPIRE_MS / 1000,
    }, SessionMt)

    self.allSessions[session] = true
    self.nSessions = self.nSessions + 1
    session.expireListNode = expireList:pushBack(session)
    sessionsByCDesc[cDesc] = session
    return session
end

---@param uuid string
---@param token string
---@return unet2.User
local function resetUser(uuid, token)
    local lastCounter = initEpoch
    local oldUser = usersByUuid[uuid]
    if oldUser then
        lastCounter = oldUser.lastCounter
        oldUser:delete()
    end

    local masterKey = sha256.digest(token)
    local keys = chacha20.crypt(masterKey, ("\0"):rep(12), ("\0"):rep(96), 8)
    local prefix = keys:sub(65, 96)

    ---@type unet2.User
    local user = setmetatable({
        uuid = uuid,
        lastCounter = lastCounter,
        sessionKey = keys:sub(1, 32),
        introKey = keys:sub(33, 64),
        prefix = prefix,
        allSessions = {},
        nSessions = 0,
        nOpenChannels = 0,
        sessions = {},
    }, UserMt)

    usersByPrefix[prefix] = user
    usersByUuid[uuid] = user
    return user
end

---@param m any
---@return boolean?
local function parseIntro(m)
    expireOldSessions()

    if type(m) ~= "string" then return end
    if #m ~= 32 + 32 + 6 + 12 + 16 then return end
    if m:sub(1, 32) ~= INTRO_PREFIX then return end

    local user = usersByPrefix[m:sub(33, 64)]
    if not user then return end

    if user.nSessions >= MAX_USER_SESSION_COUNT then return end

    local sCounter = m:sub(65, 70)
    local nCounter = ("<I6"):unpack(sCounter)
    if nCounter <= user.lastCounter then return end

    local nonce = m:sub(71, 82)
    local tag = m:sub(83, 98)
    local ok = aead.decrypt(user.introKey, nonce, tag, "", sCounter, 8)
    if not ok then return end

    user.lastCounter = nCounter
    server.onSessionCreation(user:newSession(sCounter, nonce))

    return true
end

---@param m any
---@return string | nil
---@return unet2.Session | nil
local function parseTransport(m)
    if type(m) ~= "string" then return end
    if #m > 2 ^ 17 then return end
    if #m < 32 + 16 then return end

    local desc = m:sub(1, 32)
    local session = sessionsByCDesc[desc]
    if not session then return end

    local msg = session:decryptClientMsg(m:sub(33))
    if not msg then return end

    session:updateExpiry()
    expireOldSessions()

    return msg, session
end

---@param e table
local function onModemMessage(e)
    local _, _, ch, _, m = table.unpack(e)
    if ch == MODEM_CHANNEL then
        if not parseIntro(m) then
            local msg, session = parseTransport(m)
            if msg then
                pcall(server.onUserMsg, msg, usersByUuid, session)
            end
        end
    end
end

return {
    onModemMessage = onModemMessage,
    resetUser = resetUser,
    usersByUuid = usersByUuid,
}
