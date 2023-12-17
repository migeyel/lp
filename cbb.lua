local expect = require "cc.expect"

--- An ingame user.
--- @class IngameUser
--- @field type "ingame"
--- The player's UUID.
--- @field uuid string
--- The player's name, as it is displayed ingame.
--- @field displayName string
--- The rank of the player.
--- @field group "default" | "admin"
--- The player's preferred pronouns, as set by command, or nil if unset.
--- @field pronouns string?
--- The namespaced registry key of the player's world, or nil if unknonwn.
--- @field world string?
--- Whether the player is AFK.
--- @field afk boolean
--- Whether the player is some other player's alt account.
--- @field alt boolean
--- Whether the player is a bot account or not.
--- @field bot boolean
--- The current public tier of the player's supporter status. This value is:
--- - 0 if the player is not a supporter or has opted out of showing their tag.
--- - 1 for a Tier 1 supporter.
--- - 2 for a Tier 2 supporter.
--- - 3 for a Tier 3 supporter. 
--- @field supporter number

--- @class ChatboxCommandEventData
--- @field event "command"
--- @field user IngameUser
--- @field command string
--- @field args string[]
--- @field ownerOnly boolean
--- @field time string

--- @alias ChatboxCommandEvent { [1]: "command", [2]: string, [3]: string, [4]: string[], [5]: ChatboxCommandEventData }

--- @class cbb.Token A token from a command invocation.
--- @field value string The value that the token carries.
--- @field start number The first character on the stream where the token is.
--- @field finish number The last character on the stream where the token is.

--- @class cbb.Context The context that is passed into the execute function.
--- @field user string The sender username, as was seen in the event.
--- @field reply fun(...: cbb.FormattedBlock) Replies with formatted blocks.
--- @field replyRaw fun(text: string) Replies with a raw format message.
--- @field replyMd fun(text: string) Replies with a raw markdown message.
--- @field replyErr fun(msg: string, t: cbb.Token?) Points out an error.
--- @field argTokens table<string, cbb.Token> The token each argument matched.
--- @field data ChatboxCommandEventData The raw event, as was seen.
--- @field args table<string, any> The arguments that were set on the path.
--- @field path cbb.Node[] The nodes that matched on the path.
--- @field tokens cbb.Token[] The tokens that were used to match the path.

--- @class cbb.NodeType The type of a command node (string, number, ...).
--- @field desc string Short text describing what this type is.
--- @field tstr string? An optional single word description for the argument.
--- @field parse fun(cbb.Token): any Returns a parsed value, or nil on failure.
--- @field literal string? The literal value, if the type is a literal.

--- @class cbb.Node A node on the command tree.
--- @field execute fun(ctx: cbb.Context)? The execution function
--- @field name string The name of the node argument.
--- @field kwargs table The remaining arguments that were in the definition.
--- @field children cbb.Node[] The node's children.
--- @field type cbb.NodeType The node's type.

--- @class cbb.Definition A node definiton in the Lua source.
--- @field execute fun(ctx: cbb.Context)? A function to run.
--- @field [number] cbb.Node A child argument of the command.
--- @field [string] any Extra values that get put in the node's kwargs field.

--- A builder that gets called in the CBB syntax to make a node.
--- @alias cbb.Builder fun(argname: string): fun(def: cbb.Definition): cbb.Node

--- @param ty cbb.NodeType
--- @return fun(string): fun(def: cbb.Definition): cbb.Node
local function makeBuilder(ty)
    return function(name)
        expect.expect(1, name, "string")

        --- @param def cbb.Definition
        --- @return cbb.Node
        return function(def)
            local out = {
                name = name,
                execute = expect.field(def, "execute", "function", "nil"),
                children = {},
                kwargs = {},
                type = ty,
            }

            local keys = {}
            for k, v in pairs(def) do
                if type(k) == "number" then
                    keys[#keys + 1] = k
                elseif k ~= "execute" then
                    out.kwargs[k] = v
                end
            end
            table.sort(keys)

            for i = 1, #keys do
                out.children[#out.children + 1] = def[keys[i]]
            end

            return out
        end
    end
end

--- Recognizes integers and returns them.
--- @type cbb.Builder
local integer = makeBuilder {
    desc = "an integer",
    tstr = "integer",
    parse = function(t)
        local d = tonumber(t.value)
        if d and d % 1 == 0 then
            return d
        end
    end,
}

--- Recognizes numbers and returns them.
--- @type cbb.Builder
local number = makeBuilder {
    desc = "a number",
    tstr = "number",
    parse = function(t)
        local d = tonumber(t.value)
        if d then
            return d
        end
    end,
}

--- Recognizes many Lua expressions that result numbers and returns them.
--- @type cbb.Builder
local numberExpr = number

--- Recognizes many Lua expressions that result integers and returns them.
--- @type cbb.Builder
local integerExpr = integer

--- Recognizes strings and returns them.
--- @type cbb.Builder
local string = makeBuilder {
    desc = "a string",
    tstr = "string",
    parse = function(t) return t.value end,
}

--- Constructs a type representing a literal value.
--- @param value string The literal to use.
--- @return fun(argname: string): fun(def:cbb.Definition): cbb.Node
local function literal(value)
    expect.expect(1, value, "string")
    return makeBuilder {
        desc = "\"" .. value .. "\"",
        literal = value,
        parse = function(s)
            if s.value == value then
                return s
            end
        end
    }
end

--- Turns a string into a stream of Tokens, or nil plus an error message.
--- @param input string
--- @return cbb.Token[]?, string?
local function tokenize(input)
    -- 0: normal input
    -- 1: inside a quote
    -- 2: normal input after \
    -- 3: inside a quote after \
    local state = 0
    local word = ""
    local lastStart = 1
    local tokens = {} --- @type cbb.Token[]
    for i = 1, #input do
        local c = input:sub(i, i)
        if state == 0 then
            if c == " " then
                if #word > 0 then
                    tokens[#tokens + 1] = {
                        value = word,
                        start = lastStart,
                        finish = i - 1,
                    }
                end
                lastStart = i + 1
                word = ""
                state = 0
            elseif c == '"' then
                if #word > 0 then
                    tokens[#tokens + 1] = {
                        value = word,
                        start = lastStart,
                        finish = i - 1,
                    }
                end
                lastStart = i
                word = ""
                state = 1
            elseif c == "\\" then
                state = 2
            else
                word = word .. c
            end
        elseif state == 1 then
            if c == '"' then
                tokens[#tokens + 1] = {
                    value = word,
                    start = lastStart,
                    finish = i,
                }
                lastStart = i + 1
                word = ""
                state = 0
            elseif c == "\\" then
                state = 3
            else
                word = word .. c
            end
        elseif state == 2 then
            word = word .. c
            state = 0
        elseif state == 3 then
            word = word .. c
            state = 1
        end
    end
    if state == 0 then
        if #word > 0 then
            tokens[#tokens + 1] = {
                value = word,
                start = lastStart,
                finish = #input,
            }
        end
        return tokens
    elseif state == 1 then
        return nil, "unterminated quote"
    elseif state == 2 or state == 3 then
        return nil, "unterminated escape character"
    end
end

--- All possible chatbox character formats.
--- @enum cbb.Format
local formats = {
    OBFUSCATED = "k",
    BOLD = "l",
    STRIKETHROUGH = "m",
    UNDERLINE = "n",
    ITALIC = "o",
}

local rFormats = {
    ["k"] = "k",
    ["l"] = "l",
    ["m"] = "m",
    ["n"] = "n",
    ["o"] = "o",
}

--- All possible chatbox character colors.
--- @enum cbb.Color
local colors = {
    BLACK = "0",
    DARK_BLUE = "1",
    DARK_GREEN = "2",
    DARK_AQUA = "3",
    DARK_RED = "4",
    DARK_PURPLE = "5",
    GOLD = "6",
    GRAY = "7",
    DARK_GRAY = "8",
    BLUE = "9",
    GREEN = "a",
    AQUA = "b",
    RED = "c",
    LIGHT_PURPLE = "d",
    YELLOW = "e",
    WHITE = "f",
}

local rColors = {
    ["0"] = "0",
    ["1"] = "1",
    ["2"] = "2",
    ["3"] = "3",
    ["4"] = "4",
    ["5"] = "5",
    ["6"] = "6",
    ["7"] = "7",
    ["8"] = "8",
    ["9"] = "9",
    ["a"] = "a",
    ["b"] = "b",
    ["c"] = "c",
    ["d"] = "d",
    ["e"] = "e",
    ["f"] = "f",
}

--- A JSON-like object that contains a formatted colored text fragment.
--- @class cbb.FormattedBlock
--- @field text string The text.
--- @field color cbb.Color? The text color, or white by default.
--- @field formats cbb.Format[]? The text formats, or none by default.

--- Performs chatbox.tell(), taking a stream of block entries as an input.
--- @param user string
--- @param name string
--- @param ... cbb.FormattedBlock
local function tell(user, name, ...)
    expect.expect(1, user, "string")
    expect.expect(2, name, "string")
    local out = {}
    for i, v in ipairs({ ... }) do
        expect.expect(2 + i, v, "table")
        local fmtstr = "&" .. (rColors[v.color] or colors.WHITE)
        if type(v.formats) == "table" then
            for _, fmt in ipairs(v.formats) do
                if rFormats[fmt] then
                    fmtstr = fmtstr .. "&" .. fmt
                end
            end
        end
        out[i] = fmtstr .. tostring(v.text):gsub("&", "&" .. fmtstr)
    end
    chatbox.tell(user, table.concat(out), name, nil, "format")
end

--- Given several nodes, returns an error message that says how to reach them.
--- @param nodes cbb.Node[]
--- @return string
local function buildOptionReport(nodes)
    local descs = {}
    for i = 1, #nodes do
        descs[i] = nodes[i].type.desc
    end

    if #descs == 0 then
        return "expected end of input but an extra argument was given"
    end

    if #descs == 1 then
        return "expected " .. descs[1]
    end

    local copy = { table.unpack(descs, 1, 6) }
    local removed = #descs - #copy
    if removed == 0 then
        return "expected one of: " .. table.concat(copy, ", ")
    else
        return "expected one of: " .. table.concat(copy, ", ")
            .. ", ... (" .. removed .. " more choices)"
    end
end

--- Executes a command given a root node and the command event.
--- @param name string
--- @param root cbb.Node
--- @param event ChatboxCommandEvent
local function execute(root, name, event)
    expect.expect(1, root, "table")
    expect.expect(2, name, "string")
    expect.expect(3, event, "table")

    if not root.type.literal then
        error("Root node must be a literal", 2)
    end

    local _, user, cmd, input, data = table.unpack(event)
    input = table.concat(input, " ")

    if cmd ~= root.type.literal then
        return
    end

    --- Replies a formatted block stream to the sending user.
    --- @param ... cbb.FormattedBlock
    local function reply(...)
        return tell(user, name, ...)
    end

    --- Wraps chatbox.tell(..., "format") to the sending user.
    --- @param text string
    local function replyRaw(text)
        return chatbox.tell(user, text, name, nil, "format")
    end

    --- Wraps chatbox.tell(..., "markdown") to the sending user.
    --- @param text string
    local function replyMd(text)
        return chatbox.tell(user, text, name, nil, "markdown")
    end

    local tokens, err = tokenize(input)
    if not tokens then
        return reply(
            {
                text = "Error: " .. err .. "\n",
                color = colors.RED,
            },
            {
                text = "\\" .. cmd .. " " .. input,
                color = colors.GRAY,
            },
            {
                text = " <- here",
                color = colors.RED,
            }
        )
    end

    --- Points out that a token has a wrong value.
    --- @param message string
    --- @param token cbb.Token?
    local function replyErr(message, token)
        expect.expect(1, message, "string")
        expect.expect(1, token, "table", "nil")

        if not token then
            return reply({
                text = "Error: " .. message,
                color = colors.RED,
            })
        end

        local at = nil
        for i, v in ipairs(tokens) do if v == token then at = i end end
        if not at then
            error("replyErr was called with a token that doesn't exist", 2)
        end

        local prefix
        if #tokens >= 2 and at >= 2 then
            prefix = "\n\\" .. cmd .. " " .. input:sub(1, tokens[at - 1].finish)
        else
            prefix = "\n\\" .. cmd
        end

        local suffix
        if #tokens >= 2 and at + 1 <= #tokens then
            suffix = input:sub(tokens[at + 1].start)
        else
            suffix = ""
        end

        return reply(
            {
                text = "Error: " .. message,
                color = colors.RED,
            },
            {
                text = prefix .. " ",
                color = colors.GRAY,
            },
            {
                text = input:sub(tokens[at].start, tokens[at].finish),
                color = colors.RED,
                formats = { formats.UNDERLINE },
            },
            {
                text = " <- here ",
                color = colors.RED,
            },
            {
                text = suffix,
                color = colors.GRAY,
            }
        )
    end

    local path = { root } ---@type cbb.Node[]
    local args = {} ---@type table<string, any>
    local argTokens = {} ---@type table<string, cbb.Token>
    for i = 1, #tokens do
        local passed = false
        for j = 1, #path[i].children do
            local value = path[i].children[j].type.parse(tokens[i])
            if value then
                path[i + 1] = path[i].children[j]
                args[path[i + 1].name] = value
                argTokens[path[i + 1].name] = tokens[i]
                passed = true
                break
            end
        end

        if not passed then
            return replyErr(buildOptionReport(path[i].children), tokens[i])
        end
    end

    if not path[#path].execute then
        if #path[#path].children == 0 then
            return reply(
                {
                    text = "Error: this command node is not yet implemented",
                    color = colors.RED,
                }
            )
        end
        local report = buildOptionReport(path[#path].children)
        local prefix
        if #input == 0 then
            prefix = "\n\\" .. cmd
        else
            prefix = "\n\\" .. cmd .. " " .. input
        end
        return reply(
            {
                text = "Error: incomplete command, " .. report,
                color = colors.RED,
            },
            {
                text = prefix,
                color = colors.GRAY,
            },
            {
                text = " _ <- here",
                color = colors.RED,
            }
        )
    end

    --- @type cbb.Context
    local ctx = {
        reply = reply,
        replyRaw = replyRaw,
        replyMd = replyMd,
        replyErr = replyErr,
        data = data,
        args = args,
        argTokens = argTokens,
        path = path,
        user = user,
        tokens = tokens,
    }

    return path[#path].execute(ctx)
end

--- Sends out a help topic on branches starting at a given node.
--- @param level number The number of parents to walk up before expanding.
--- @param ctx cbb.Context The context for the current execution.
local function sendHelpTopic(level, ctx)
    expect.expect(1, level, "number")
    expect.expect(2, ctx, "table")

    --- @param out cbb.FormattedBlock[]
    --- @param path cbb.Node[]
    local function walk(out, path)
        local last = path[#path]
        if last.kwargs.help then
            local cmd = {}
            for i = 1, #path do
                local node = path[i]
                if node.type.literal then
                    cmd[i] = node.name
                else
                    cmd[i] = "<" .. node.name .. ":" .. node.type.tstr .. ">"
                end
            end
            out[#out + 1] = {
                text = "\n\\" .. table.concat(cmd, " "),
                color = colors.GRAY,
            }
            out[#out + 1] = {
                text = "\n" .. last.kwargs.help,
                color = colors.WHITE,
            }
        end
        for i = 1, #last.children do
            path[#path + 1] = last.children[i]
            walk(out, path)
            path[#path] = nil
        end
    end

    local out = {}
    local path = { table.unpack(ctx.path, 1, #ctx.path - level) }
    walk(out, path)

    ctx.reply(table.unpack(out))
end

return {
    colors = colors,
    formats = formats,
    literal = literal,
    string = string,
    integer = integer,
    number = number,
    numberExpr = numberExpr,
    integerExpr = integerExpr,
    sendHelpTopic = sendHelpTopic,
    tell = tell,
    execute = execute,
}
