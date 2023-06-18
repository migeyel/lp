local cbb = require "cbb"
local rng = require "unet.common.rng"
local stateLib = require "unet.server.state"
local repeater = require "unet.server.repeater"

local state = stateLib.read()

local UUID_URL = "https://api.mojang.com/users/profiles/minecraft/"

---@type { [string]: string? }
local tokens = state.tokens or {}
state.tokens = tokens

for uuid, token in pairs(tokens) do
    repeater.resetUser(uuid, token)
end

---@param ctx cbb.Context
local function handleTokenRegenCmd(ctx)
    local uuid = ctx.data.user.uuid
    local token = rng.uuid4()
    state.tokens[uuid] = token
    stateLib.write(state)
    repeater.resetUser(uuid, token)
    return ctx.replyMd("A new token has been generated!")
end

---@param ctx cbb.Context
local function handleTokenCmd(ctx)
    local uuid = ctx.data.user.uuid
    local token = state.tokens[uuid]
    if not token then
        token = rng.uuid4()
        state.tokens[uuid] = token
        stateLib.write(state)
        repeater.resetUser(uuid, token)
    end
    return ctx.replyMd("[token]" .. token .. "[/token]")
end

---@param ctx cbb.Context
local function uuidCmd(ctx)
    local name = ctx.args.username
    if #name < 2 or #name > 16 or not name:match("^[a-zA-Z0-9_]*$") then
        return ctx.reply({
            text = ("Error: the username %q isn't valid"):format(name),
            color = cbb.colors.RED,
        })
    end

    local h = http.get(UUID_URL .. name)
    if not h then
        return ctx.reply({
            text = "An error has occurred while fetching the UUID",
            color = cbb.colors.RED,
        })
    end
    local s = h.readAll()
    h.close()

    local uuid = textutils.unserializeJSON(s or "{}").id
    if #uuid == 32 then
        local b0, b1, b2, b3, b4 = ("c8c4c4c4c12"):unpack(uuid)
        uuid = b0 .. "-" .. b1 .. "-" .. b2 .. "-" .. b3 .. "-" .. b4
    end

    -- No sanitization needed for name since it's validated already.
    return ctx.replyMd(name .. "'s UUID is `" .. uuid .. "`.")
end

---@param ctx cbb.Context
local function aboutCmd(ctx)
    ctx.reply(
        {
            text = "UNet is a currently WIP service for sending modem messages "
                .. "directly to another player's computer. Messages are "
                .. "encrypted and the sender is authenticated to the receiver."
                .. "\nYou can see the available commands by using ",
        },
        {
            text = "\\unet help",
            color = cbb.colors.GRAY,
        },
        {
            text = ".",
        }
    )
end

local root = cbb.literal("unet") "unet" {
    execute = aboutCmd,
    cbb.literal("about") "about" {
        help = "Describes what unet is",
        execute = aboutCmd,
    },
    cbb.literal("help") "help" {
        help = "Provides this help message",
        execute = function(ctx)
            return cbb.sendHelpTopic(1, ctx)
        end,
    },
    cbb.literal("token") "token" {
        help = "Provides your user token",
        execute = handleTokenCmd,
        cbb.literal("regenerate") "regenerate" {
            help = "Revokes and regenerates your user token",
            execute = handleTokenRegenCmd,
        }
    },
    cbb.literal("uuid") "uuid" {
        cbb.string "username" {
            help = "Provides a player's UUID",
            execute = uuidCmd,
        }
    }
}

while true do
    local e = { os.pullEvent() }
    if e[1] == "modem_message" then
        pcall(repeater.onModemMessage, e)
    elseif e[1] == "command" then
        pcall(cbb.execute, root, "unet", e)
    end
end
