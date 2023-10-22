local proto = require "unet.common.proto"
local helpers = require "unet.common.helpers"

local MAX_CHANNEL_LEN = 32

--- Session expiration time, in ms.
local SESSION_EXPIRE_MS = 30000

---@return string
local function makeSessionDeletionPacket()
    return proto.serverMsg.serialize {
        version = 1,
        event = {
            closed = {},
        },
    }
end

---@param session unet2.Session
local function onSessionCreation(session)
    session:transmit(proto.serverMsg.serialize {
        version = 1,
        event = {
            hello = {
                uuid = session.user.uuid,
                timeout = SESSION_EXPIRE_MS,
            },
        },
    })
end

---@param msg string
---@param usersByUuid table<string, unet2.User>
---@param session unet2.Session
local function onUserMsg(msg, usersByUuid, session)
    local user = session.user
    local data = proto.userMsg.deserialize(msg)

    if not data then return end
    if data.version ~= 1 then return end

    local request = data.request
    if not request then return end

    --- Transmits an error response.
    local function txErr(key, inner)
        return session:transmit(proto.serverMsg.serialize {
            version = 1,
            errResponse = {
                requestId = request.id,
                [key] = inner,
            },
        })
    end

    --- Transmits an ok response.
    local function txOk(key, inner)
        return session:transmit(proto.serverMsg.serialize {
            version = 1,
            okResponse = {
                requestId = request.id,
                [key] = inner,
            },
        })
    end

    --- Makes a request assertion. Transmits invalidRequest and returns true if
    --- the assertion fails.
    local function rnot(value)
        if value then
            return false
        else
            session:transmit(proto.serverMsg.serialize {
                version = 1,
                errResponse = {
                    requestId = request.id,
                    invalidRequest = {},
                },
            })
            return true
        end
    end

    if request.ping then
        print(session.user.uuid:sub(1, 8), "ping")
        return session:transmit(proto.serverMsg.serialize {
            version = 1,
            okResponse = {
                requestId = request.id,
                pong = {},
            },
        })
    elseif request.open then
        if rnot(request.open.channel) then return end
        if rnot(#request.open.channel <= MAX_CHANNEL_LEN) then return end
        print(session.user.uuid:sub(1, 8), "open", request.open.channel)
        local wasOpen = user.sessions[request.open.channel] ~= nil
        local openOk = session:tryOpenChannel(request.open.channel)
        if openOk then
            return txOk("channelPrevState", { wasOpen = wasOpen })
        else
            return txErr("tooManyOpenChannels", {})
        end
    elseif request.close then
        if rnot(request.close.channel) then return end
        if rnot(#request.close.channel <= MAX_CHANNEL_LEN) then return end
        print(session.user.uuid:sub(1, 8), "close", request.close.channel)
        local wasOpen = user.sessions[request.close.channel] ~= nil
        session:closeChannel(request.close.channel)
        return txOk("channelPrevState", { wasOpen = wasOpen })
    elseif request.isOpen then
        if rnot(request.isOpen.channel) then return end
        if rnot(#request.isOpen.channel <= MAX_CHANNEL_LEN) then return end
        print(session.user.uuid:sub(1, 8), "isOpen", request.isOpen.channel)
        local isOpen = user.sessions[request.isOpen.channel] ~= nil
        return txOk("channelPrevState", { wasOpen = isOpen })
    elseif request.send then
        if rnot(request.send.receiverUuid) then return end
        if rnot(helpers.isValidUuid(request.send.receiverUuid)) then return end
        if rnot(request.send.channel) then return end
        if rnot(#request.send.channel <= MAX_CHANNEL_LEN) then return end
        if rnot(request.send.replyChannel) then return end
        if rnot(#request.send.replyChannel <= MAX_CHANNEL_LEN) then return end
        if rnot(request.send.data) then return end
        local receiver = usersByUuid[request.send.receiverUuid]
        if not receiver then return end
        local recvSession = receiver.sessions[request.send.channel]
        if not recvSession then return end
        print(session.user.uuid:sub(1, 8), "tx", request.send.receiverUuid:sub(1, 8))
        recvSession:transmit(proto.serverMsg.serialize {
            version = 1,
            event = {
                message = {
                    senderUuid = user.uuid,
                    channel = request.send.channel,
                    replyChannel = request.send.replyChannel,
                    data = request.send.data,
                },
            },
        })
    elseif request.shutdown then
        print(session.user.uuid:sub(1, 8), "shutdown")
        session:delete()
    end
end

return {
    SESSION_EXPIRE_MS = SESSION_EXPIRE_MS,
    onUserMsg = onUserMsg,
    onSessionCreation = onSessionCreation,
    makeSessionDeletionPacket = makeSessionDeletionPacket,
}
