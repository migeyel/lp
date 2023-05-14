local expect = require "cc.expect"

---@class CommandNodeType
---@field desc string Short text describing what this command node does.
---@field tstr string? An optional single word description for the argument.
---@field parse fun(Token): any Parses and returns a value, or nil on failure.
---@field literal string? The literal value, if the type is a literal.

---@alias FormatBlockEntries FormatBlockEntry[]

---@class CommandCallContext
---@field user string
---@field reply fun(...: FormatBlockEntry)
---@field args table<string, any>
---@field path CommandTreeNode[]

---@class CommandTreeNode
---@field exeucte fun(ctx: CommandCallContext)?
---@field name string The name of the node argument.
---@field help string?
---@field children CommandTreeNode[]
---@field type CommandNodeType

---@class CommandTreeNodeDefinition
---@field help string? A help text describing the child.
---@field [number] CommandTreeNode A child argument of the command.
---@field execute fun(ctx: CommandCallContext)? A function to run.

---@param ty CommandNodeType
---@return fun(string): fun(def: CommandTreeNodeDefinition): CommandTreeNode
local function makeBuilder(ty)
    return function(name)
        expect(1, name, "string")
        return function(def)
            local out = {
                name = name,
                help = expect.field(def, "help", "string", "nil"),
                execute = expect.field(def, "execute", "function", "nil"),
                children = {},
                type = ty,
            }

            local keys = {}
            for k in pairs(def) do
                if type(k) == "number" then
                    keys[#keys + 1] = k
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

---@param t Token
---@return number?
local function evaluate(t)
    local pat = "^\27LuaQ\0\1\4\4\4\8\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\2\2\3\0\0"
        .. "\0\1\0\0\0\30\0\0\1\30\0\128\0\1\0\0\0\3(........)\0\0\0\0\0\0\0\0"
        .. "\0\0\0\0\0\0\0\0$"
    local f = load("return " .. t.value, "")
    if not f then return end
    local m = string.dump(f, true):match(pat)
    if not m then return end
    return (("d"):unpack(m))
end

local numberExpr = makeBuilder {
    desc = "a number expression",
    tstr = "numexpr",
    parse = evaluate,
}

local integerExpr = makeBuilder {
    desc = "an integer expression",
    tstr = "intexpr",
    parse = function(t)
        local d = evaluate(t)
        if d and d % 1 == 0 then
            return d
        end
    end,
}

local string = makeBuilder {
    desc = "a string",
    tstr = "string",
    parse = function(t) return t.value end,
}

local function literal(value)
    expect(1, value, "string")
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

---@class Token
---@field value string
---@field start number
---@field finish number

---@param input string
---@return Token[]?, string?
local function tokenize(input)
    -- 0: normal input
    -- 1: inside a quote
    -- 2: normal input after \
    -- 3: inside a quote after \
    local state = 0
    local word = ""
    local lastStart = 1
    local tokens = {} --- @type Token[]
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

---@enum ChatFormat
local formats = {
    OBFUSCATED = "k",
    BOLD = "l",
    STRIKETHROUGH = "m",
    UNDERLINE = "n",
    ITALIC = "o",
}

---@enum ChatColor
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

---@class FormatBlockEntry
---@field text string
---@field color ChatColor?
---@field formats ChatFormat[]?

---@param user string
---@param name string
---@param ... FormatBlockEntry
local function tell(user, name, ...)
    local out = {}
    for i, v in ipairs({ ... }) do
        local fmtstr = "&" .. (v.color or colors.WHITE)
        if v.formats then
            for _, fmt in ipairs(v.formats) do
                fmtstr = fmtstr .. "&" .. fmt
            end
        end
        out[i] = fmtstr .. v.text:gsub("&", "&" .. fmtstr)
    end
    chatbox.tell(user, table.concat(out), name, nil, "format")
end

---@param nodes CommandTreeNode[]
---@return string
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

---@param name string
---@param root CommandTreeNode
local function execute(root, name, event)
    if not root.type.literal then
        error("Root node must be a literal", 2)
    end

    local _, user, cmd, input = table.unpack(event)
    input = table.concat(input, " ")

    if cmd ~= root.type.literal then
        return
    end

    ---@param ... FormatBlockEntry
    local function reply(...)
        return tell(user, name, ...)
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

    local path = { root } ---@type CommandTreeNode[]
    local args = {} ---@type table<string, any>
    for i = 1, #tokens do
        local passed = false
        for j = 1, #path[i].children do
            local value = path[i].children[j].type.parse(tokens[i])
            if value then
                path[i + 1] = path[i].children[j]
                args[path[i + 1].name] = value
                passed = true
                break
            end
        end

        if not passed then
            local prefix, suffix
            if #tokens >= 2 then
                prefix = "\n\\" .. cmd .. " " .. input:sub(1, tokens[i - 1].finish)
                if i + 1 <= #tokens then
                    suffix = input:sub(tokens[i + 1].start)
                else
                    suffix = ""
                end
            else
                prefix = "\n\\" .. cmd
                suffix = ""
            end
            return reply(
                {
                    text = "Error: " .. buildOptionReport(path[i].children),
                    color = colors.RED,
                },
                {
                    text = prefix .. " ",
                    color = colors.GRAY,
                },
                {
                    text = input:sub(tokens[i].start, tokens[i].finish),
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

    ---@type CommandCallContext
    local ctx = {
        reply = reply,
        args = args,
        path = path,
        user = user,
    }

    return path[#path].execute(ctx)
end

---@param level number
---@param ctx CommandCallContext
local function sendHelpTopic(level, ctx)
    ---@param out FormatBlockEntry[]
    ---@param path CommandTreeNode[]
    local function walk(out, path)
        local last = path[#path]
        if last.help then
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
                text = "\n" .. last.help,
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
