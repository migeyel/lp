local lproto = require "lproto"

-- A message sent from the user to the server.
local userMsg = lproto.message {
    -- The protocol version, the current supported value is 1.
    version = lproto.uint32 (1),

    -- A user API request.
    request = lproto.message {
        -- An ID that will be echoed in the response.
        id = lproto.uint53 (1),

        -- Pings the server.
        -- Expected responses:
        -- OK: pong
        ping = lproto.message { } (5),

        -- Open a channel for listening.
        -- Expected responses:
        -- OK: channelPrevState
        -- ERR: tooManyOpenChannels
        open = lproto.message {
            channel = lproto.bytes (1),
        } (2),

        -- Closes a channel for listening.
        -- Expected responses:
        -- OK: channelPrevState
        close = lproto.message {
            channel = lproto.bytes (1),
        } (4),

        -- Checks if a channel is open.
        -- Expected responses:
        -- OK: channelPrevState
        isOpen = lproto.message {
            channel = lproto.bytes (1),
        } (3),

        -- Sends a message to another player UUID.
        -- No response is expected.
        send = lproto.message {
            receiverUuid = lproto.bytes (1),
            channel = lproto.bytes (2),
            replyChannel = lproto.bytes (3),
            data = lproto.bytes (4),
        } (6),

        -- Shuts down the session.
        -- No response is expected, except for a potential `closed` event.
        shutdown = lproto.message {} (7),
    } (2),
}

-- A message sent from the server to the user.
local serverMsg = lproto.message {
    -- The protocol version, the current supported value is 1.
    version = lproto.uint32 (1),

    -- An asynchronous event triggered from the server.
    event = lproto.message {
        -- The session has been closed by some reason.
        closed = lproto.message {} (1),

        -- A message has been sent to the user.
        message = lproto.message {
            senderUuid = lproto.bytes (1),
            channel = lproto.bytes (2),
            replyChannel = lproto.bytes (3),
            data = lproto.bytes (4),
        } (2),

        -- An event sent when a new session is created.
        hello = lproto.message {
            -- The user's player UUID.
            uuid = lproto.bytes (1),

            -- The session inactivity timeout, in milliseconds.
            timeout = lproto.uint53 (2),
        } (3),
    } (2),

    -- A successful response to a user request.
    okResponse = lproto.message {
        -- The original request ID.
        requestId = lproto.uint53 (1),

        -- Ping response.
        pong = lproto.message {} (2),

        -- Reports the previous state from a channel.
        channelPrevState = lproto.message {
            wasOpen = lproto.bool (1),
        } (3),
    } (3),

    -- An error response to a user request.
    errResponse = lproto.message {
        -- The original request ID.
        requestId = lproto.uint53 (1),

        -- A human-readable error message.
        message = lproto.bytes (3),

        -- The given request was malformed in some way.
        invalidRequest = lproto.message {} (2),

        -- Too many channels were tried to be open.
        tooManyOpenChannels = lproto.message {} (4),
    } (4),
}

return {
    userMsg = userMsg,
    serverMsg = serverMsg,
}
