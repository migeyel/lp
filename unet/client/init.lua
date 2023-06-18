local sha256 = require "ccryptolib.sha256"
local aead = require "ccryptolib.aead"
local chacha20 = require "ccryptolib.chacha20"
local rng = require "unet.common.rng"
local proto = require "unet.common.proto"
local helpers = require "unet.common.helpers"
local redrun = require "redrun"
local expect = require "cc.expect"

--- The modem channel to communicate introductions and messages through.
local MODEM_CHANNEL = 7635

--- The maximum user channel length allowed by the server.
local MAX_CHANNEL_LEN = 32

--- The prefix used by all introduction messages.
local INTRO_PREFIX = "UNet introduction prefix (\\unet)"

local function checkChannel(ch)
    if #ch > MAX_CHANNEL_LEN then
        error("channel name is too long", 3)
    end
end

--- Stateful data about a connection to the server.
--- @class unetc.ConnectionState
--- @field cDesc string The current client-sent descriptor prefix.
--- @field sDesc string The current server-sent descriptor prefix.
--- @field cKey string The current client-sent key.
--- @field sKey string The current server-sent key.
--- @field modem Modem The modem to send replies through.
local ConnectionState = {}
local ConnectionStateMt = { __index = ConnectionState }

--- Creates a new connection state.
--- @param modem Modem
--- @param token string
--- @return unetc.ConnectionState
local function newState(modem, token)
    local masterKey = sha256.digest(token)
    local keys = chacha20.crypt(masterKey, ("\0"):rep(12), ("\0"):rep(96), 8)
    local sessionKey = keys:sub(1, 32)
    local introKey = keys:sub(33, 64)
    local userd = keys:sub(65, 96)

    local nCounter = os.epoch("utc")
    local sCounter = ("<I6"):pack(nCounter)
    local nonce = rng.random(12)
    local _, tag = aead.encrypt(introKey, nonce, "", sCounter, 8)

    local subKey = sha256.digest(sCounter .. nonce .. sessionKey)
    local sessionKeys = chacha20.crypt(subKey, ("\0"):rep(12), ("\0"):rep(128), 8)
    local cDesc = sessionKeys:sub(1, 32)
    local sDesc = sessionKeys:sub(33, 64)
    local cKey = sessionKeys:sub(65, 96)
    local sKey = sessionKeys:sub(97, 128)

    local state = setmetatable({
        cDesc = cDesc,
        sDesc = sDesc,
        cKey = cKey,
        sKey = sKey,
        modem = modem,
    }, ConnectionStateMt)

    local packet = INTRO_PREFIX .. userd .. sCounter .. nonce .. tag
    modem.transmit(MODEM_CHANNEL, MODEM_CHANNEL, packet)

    return state
end

--- Sends a raw message to the server.
--- @param msg string The raw message to send.
function ConnectionState:send(msg)
    -- Encrypt
    local padded = helpers.pad(msg, 48, 112, 64)
    local ctx, tag = aead.encrypt(self.cKey, ("\0"):rep(12), padded, "", 8)
    local packet = self.cDesc .. ctx .. tag

    -- Refresh keys
    local keys = chacha20.crypt(self.cKey, ("\xff"):rep(12), ("\0"):rep(64), 8)
    self.cDesc = keys:sub(1, 32)
    self.cKey = keys:sub(33, 64)

    self.modem.transmit(MODEM_CHANNEL, MODEM_CHANNEL, packet)
end

--- Parses an incoming message from the modem. Presumably from the server.
--- @param m any The received message. 
--- @return string? out The parsed raw received message, or nil on failure.
function ConnectionState:parseTransport(m)
    if type(m) ~= "string" then return end
    if #m > 2 ^ 17 then return end
    if #m < 32 + 16 then return end

    if self.sDesc ~= m:sub(1, 32) then return end
    self.sDesc = nil

    -- Decrypt
    local ctx = m:sub(33, -17)
    local tag = m:sub(-16)
    local padded = aead.decrypt(self.sKey, ("\0"):rep(12), tag, ctx, "", 8)
    if not padded then return end
    local msg = helpers.unpad(padded)
    if not msg then return end

    -- Refresh keys
    local keys = chacha20.crypt(self.sKey, ("\xff"):rep(12), ("\0"):rep(64), 8)
    self.sDesc = keys:sub(1, 32)
    self.sKey = keys:sub(33, 64)

    return msg
end

--- Inner state for tracking a session with the server.
--- @class unetc.InnerSession
--- @field sessionId string A string for identifying this session.
--- @field playerId string The client's player UUID.
--- @field state unetc.ConnectionState The inner connection state.
--- @field apiId number A tracker for API request ids.
--- @field task number The listener task id.
--- @field timeout number The session inactivity timeout in milliseconds.
local InnerSession = {}
local InnerSessionMt = { __index = InnerSession }

function InnerSession:pingTimeoutSeconds()
    local min = 0.25 / 1000 / 2 * self.timeout
    local max = 0.75 / 1000 / 2 * self.timeout
    return math.random(min, max) + math.random(min, max) + math.random() - 0.5
end

--- RedRun listening task.
--- - Converts close events to unet_close
--- - Converts message events to unet_message
--- - Converts responses to unet_internal_message
--- @param isActive fun(): boolean Whether the session is active.
function InnerSession:listen(isActive)
    local pingId = nil
    local pingTimer = os.startTimer(self:pingTimeoutSeconds())

    while true do
        local e, p1, p2, _, p4, p5 = coroutine.yield()

        -- No longer active, shut down.
        if not isActive() then
            self:justRequest("shutdown", {})
            os.queueEvent("unet_closed", self.sessionId)
            return
        end

        -- Handle the event.
        if e == "timer" and p1 == pingTimer then
            -- The previous ping didn't reply, shut down.
            if pingId then
                self:justRequest("shutdown", {})
                os.queueEvent("unet_closed", self.sessionId)
                return
            end

            -- Send a new ping.
            pingId = self.apiId
            pingTimer = os.startTimer(self:pingTimeoutSeconds())
            self.apiId = self.apiId + 1
            self.state:send(proto.userMsg.serialize {
                version = 1,
                request = {
                    id = pingId,
                    ping = {},
                }
            })
        elseif e == "modem_message" and p2 == MODEM_CHANNEL then
            local data = self.state:parseTransport(p4)
            if data then
                local out = proto.serverMsg.deserialize(data)
                assert(out, "the server sent an invalid packet")
                os.queueEvent("unet_internal_message", self.sessionId, out)
                if out.okResponse then
                    if out.okResponse.requestId == pingId then
                        pingId = nil
                    end
                elseif out.event then
                    if out.event.closed then
                        os.queueEvent("unet_closed", self.sessionId)
                        return
                    elseif out.event.message then
                        os.queueEvent(
                            "unet_message",
                            self.sessionId,
                            out.event.message.senderUuid,
                            out.event.message.channel,
                            out.event.message.replyChannel,
                            out.event.message.data,
                            p5
                        )
                    end
                end
            end
        end
    end
end

--- Makes a request to the server.
--- @param request string
--- @param inner table
--- @async
function InnerSession:request(request, inner)
    local id = self.apiId
    self.apiId = id + 1

    self.state:send(proto.userMsg.serialize {
        version = 1,
        request = {
            id = id,
            [request] = inner,
        },
    })

    while true do
        local _, session, out = os.pullEvent("unet_internal_message")
        if session == self.sessionId then
            if out.okResponse then
                if out.okResponse.requestId == id then return out end
            elseif out.errResponse then
                if out.errResponse.requestId == id then return out end
            end
        end
    end
end

--- Makes a request but does not wait for a response.
--- @param request string
--- @param inner table
function InnerSession:justRequest(request, inner)
    self.state:send(proto.userMsg.serialize {
        version = 1,
        request = {
            [request] = inner,
        },
    })
end

--- A session with the server.
--- @class unetc.Session
--- @field _inner unetc.InnerSession The inner session state.
local Session = {}
local SessionMt = { __index = Session }

--- Sends a message to another player.
--- @param receiver string The receiver's player UUID.
--- @param channel string The receiver channel to send the message through.
--- @param replyChannel string The channel to ask them to reply to.
--- @param message string A serialized message.
function Session:send(receiver, channel, replyChannel, message)
    expect(1, receiver, "string")
    assert(helpers.isValidUuid(receiver), "receiver is not a valid UUID")
    checkChannel(expect(2, channel, "string"))
    checkChannel(expect(3, replyChannel, "string"))
    expect(4, message, "string")
    self._inner:justRequest("send", {
        receiverUuid = receiver,
        channel = channel,
        replyChannel = replyChannel,
        data = message,
    })
end

--- Starts listening on a channel.
--- @param channel string The channel to open.
--- @return boolean wasOpen Whether the channel was already open.
--- @throws If the number of open channels is at the maximum limit.
--- @async
function Session:open(channel)
    checkChannel(expect(1, channel, "string"))
    local response = self._inner:request("open", { channel = channel })
    if response.okResponse then
        return response.okResponse.channelPrevState.wasOpen
    else
        local emsg = response.errResponse and response.errResponse.message
        error(emsg or "unknown server error", 2)
    end
end

--- Stops listening on a channel.
--- @param channel string The channel to close.
--- @return boolean wasOpen Whether the channel was already open.
--- @async
function Session:close(channel)
    checkChannel(expect(1, channel, "string"))
    local response = self._inner:request("close", { channel = channel })
    if response.okResponse then
        return response.okResponse.channelPrevState.wasOpen
    else
        local emsg = response.errResponse and response.errResponse.message
        error(emsg or "unknown server error", 2)
    end
end

--- Checks whether this session is listening on a channel.
--- @param channel string The channel.
--- @return boolean isOpen Whether the channel is open.
--- @async
function Session:isOpen(channel)
    checkChannel(expect(1, channel, "string"))
    local response = self._inner:request("isOpen", { channel = channel })
    if response.okResponse then
        return response.okResponse.channelPrevState.wasOpen
    else
        local emsg = response.errResponse and response.errResponse.message
        error(emsg or "unknown server error", 2)
    end
end

--- Sends a shutdown signal to the server, closing the session. The close event
--- may still fire afterwards.
function Session:shutdown()
    self._inner:justRequest("shutdown", {})
    if redrun.getstate(self._inner.task) then
        os.queueEvent("unet_closed", self._inner.sessionId)
        redrun.kill(self._inner.task)
    end
end

--- Returns a unique ID for this session.
--- @return string
function Session:id()
    return self._inner.sessionId
end

--- Returns the session owner's player UUID.
--- @return string
function Session:uuid()
    return self._inner.playerId
end

--- Connects to the server and creates a new session.
--- @param token string Your unet token to authenticate with.
--- @param modem Modem? The modem to open the transport channel for listening.
--- @param timeout number? An optional timeout.
--- @return unetc.Session? session The created session, or nil on timeout.
--- @async
local function connect(token, modem, timeout)
    expect(1, token, "string")
    expect(2, modem, "table", "nil")
    expect(3, timeout, "number", "nil")

    rng.init(token)

    -- If not given, try to find a wireless modem that already is open. 
    if not modem then
        modem = peripheral.find("modem", function(_, t)
            return t.isWireless() and t.isOpen(MODEM_CHANNEL)
        end)
    end

    -- If not found yet, try to find any wireless modem.
    if not modem then
        modem = peripheral.find("modem", function(_, t)
            return t.isWireless()
        end)
    end

    -- If not found even then, error.
    if not modem then
        error("Could not find a modem to open")
    end

    modem.open(MODEM_CHANNEL)

    local state = newState(modem, token)

    local timerId = -1
    if timeout then
        timerId = os.startTimer(timeout)
    end

    -- The state sent the introduction, so now we wait for the hello packet.
    local uuid = nil
    local timeout = nil
    while true do
        local ev, p1, p2, _, p4 = os.pullEvent()
        if ev == "timer" and p1 == timerId then
            return
        elseif ev == "modem_message" and p2 == MODEM_CHANNEL then
            local data = state:parseTransport(p4)
            if data then
                local out = proto.serverMsg.deserialize(data)
                if not out then
                    os.cancelTimer(timerId)
                    error("the server sent an invalid packet")
                end
                local event = out.event
                if event then
                    local hello = event.hello
                    if hello then
                        uuid = hello.uuid
                        timeout = hello.timeout
                        if type(uuid) == "string" and
                            type(timeout) == "number"
                        then
                            os.cancelTimer(timerId)
                            break
                        end
                    end
                end
            end
        end
    end

    local inner = setmetatable({
        sessionId = rng.uuid4(),
        playerId = uuid,
        timeout = timeout,
        state = state,
        apiId = 0,
    }, InnerSessionMt)

    local outer = setmetatable({ _inner = inner }, SessionMt)
    local gc = setmetatable({}, { __mode = "v"})
    gc[1] = outer

    local function isActive()
        return #gc == 1
    end

    local function listener()
        return inner:listen(isActive)
    end

    inner.task = redrun.start(listener, "unet_listener")

    return outer
end

return {
    connect = connect,
}
