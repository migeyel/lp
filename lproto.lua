local expect = require "cc.expect"

local field = expect.field
local expect = expect.expect
local typeof = type

local spack = string.pack
local sunpack = string.unpack

-- Creates a new encoding state.
local function newEncodingState()
    return {
        -- Encoding is performed by appending our objects into an array of
        -- strings. Calling table.concat() on this buffer yields the output.
        b = {},

        -- The total number of bytes currently in the buffer. Used to discover
        -- the length of embedded messages after encoding them.
        n = 0,
    }
end

-- Pushes bytes to be encoded into an encoding state.
local function encodeBytes(state, bytes)
    local buffer = state.b
    buffer[#buffer + 1] = bytes
    state.n = state.n + #bytes
end

-- Pulls bytes from a slice starting at some position.
-- Decoding is simpler, and just requires keeping track of where we are.
local function decodeBytes(slice, startPosition, length)
    local newStartPosition = startPosition + length
    local endPosition = newStartPosition - 1

    -- The new starting position can be up to the string length (the last char).
    -- Anything larger must result in an error.
    if newStartPosition > #slice + 1 then
        error("EOI reached when decoding")
    end

    return slice:sub(startPosition, endPosition), newStartPosition
end

-- Encoding of integers is done using a variable-length coding.
-- Integers are encoded in little-endian as bytes:
-- - The most significant bit determines if there are remaining bytes.
-- - The least significant 7 bits contain the value in base 128.

-- Lookup table from a byte to its character.
local byteToString = {}
for i = 0, 255 do byteToString[i] = string.char(i) end

-- Encodes an integer into an encoding state.
local function encodeInteger(state, integer)
    local byteToString = byteToString

    while integer >= 128 do
        local remainder = integer % 128
        integer = (integer - remainder) / 128
        encodeBytes(state, byteToString[remainder + 128])
    end

    -- Last byte.
    encodeBytes(state, byteToString[integer])
end

-- Decodes an integer from a string at some position.
-- The modulus argument is a power-of-2 number to reduce the result by. Protobuf
-- requires wrapping around these, which isn't supported with floats alone.
-- Byte number decoding uses string.unpack(), since it has the same interface as
-- decodeBytes().
local function decodeInteger(slice, startPosition, modulus)
    local position = startPosition

    -- multiplier is used for decoding in little-endian without bit-shifts.
    local integer = 0
    local multiplier = 1

    while true do
        -- string.unpack() throws a clean error when the slice ends, so we don't
        -- need to assert anything.
        local byte
        byte, position = sunpack("B", slice, position)

        if byte >= 128 then
            -- More bytes to come.
            integer = integer + (byte - 128) * multiplier % modulus
        else
            -- Last byte.
            return integer + byte * multiplier % modulus, position
        end

        multiplier = multiplier * 128 % modulus
    end
end

-- The serialization of types makes use of a common interface. All serializable
-- types implement it. The interface has the following fields:
--
-- _fieldNumber: number | nil
-- The field number this instance takes on the message embedding it.
--
-- _isRepeated: boolean | nil
-- Whether this instance is a repeated type.
--
-- _wireType: number
-- The type passed on the wire. These values are specified by ProtoBuf.
-- - 0 is an integer type.
-- - 1 is an 8-byte fixed length type.
-- - 2 is a type preceded by its length, as an integer.
-- - 3 and 4 are deprecated group types not implemented here.
-- - 5 is a 4-byte fixed length type.
--
-- _check: function(recursionTracker, value) → value
-- Canonicalizes values of this type. Throws an error whenever the value is
-- invalid or recursive.
--
-- _encode: function(state, value) → newValue
-- Encodes a value into a state. newValue is used for collections. If newValue
-- isn't nil, it must be encoded again, including the preceding field number.
--
-- _decode: function(slice, position, value) → newValue, newPosition
-- Decodes a value from a slice. The value argument is what the same field had
-- beforehand, used for decoding collections.

-- Builds a repeated type out of a non-repeated type.
local function makeRepeatedType(type)
    local individualCheck = type._check
    local individualEncode = type._encode
    local individualDecode = type._decode

    return {
        _fieldNumber = type._fieldNumber,
        _isRepeated = true,
        _wireType = type._wireType,

        _check = function(recursionTracker, values)
            expect(1, values, "table")

            -- We copy the values and add an n entry to keep track of where in
            -- encoding we are.
            local newValues = {n = 1}
            for i, v in ipairs(values) do
                newValues[i] = individualCheck(recursionTracker, v)
            end

            if #newValues > 0 then return newValues end
        end,

        _encode = function(state, values)
            local n = values.n

            individualEncode(state, values[n])
            values.n = values.n + 1

            -- We keep encoding until n == #values, at which we return nil.
            if n ~= #values then return values end
        end,

        _decode = function(slice, position, values)
            -- First call sets values to nil, initialize an empty table.
            values = values or {}
            values[#values + 1], position = individualDecode(slice, position)
            return values, position
        end,
    }
end

-- Makes types able to be "called" with specific syntax for configuration.
-- Like this: message { field = uint32 (1) { repeated = true } }
-- - (1) represents a field number assignment.
-- - { repeated = true } represents an assigment to _isRepeated.
local function makeCallableType(type)
    local metatable = {
        __call = function(_, argument)
            expect(1, argument, "number", "table")

            local newInstance = {}
            for i, v in pairs(type) do newInstance[i] = v end

            if typeof(argument) == "number" then
                -- Set the field number.
                newInstance._fieldNumber = argument
            else
                -- Transform into repeated type.
                local isRepeated = field(argument, "repeated", "boolean")

                if newInstance._isRepeated and not isRepeated then
                    error("can't unset repeated field")
                end

                if isRepeated then
                    newInstance = makeRepeatedType(newInstance)
                end
            end

            return makeCallableType(newInstance)
        end,
    }

    return setmetatable(type, metatable)
end

-- Makes integer-like types given a power-of-2 modulus.
local function makeIntegerType(modulus, isSigned)
    local out = {
        _wireType = 0,

        _check = function(_, value)
            expect(1, value, "number")
            value = value % modulus
            assert(value == value, "invalid number to encode as integer")
            return value - value % 1
        end,
    }

    if isSigned then
        function out._encode(state, value)
            -- ZigZag encode the number. This makes numbers with small absolute
            -- value take less space, no matter the sign.
            if value + value >= modulus then
                encodeInteger(state, (value * -2 % modulus - 1) % modulus)
            else
                encodeInteger(state, value * 2 % modulus)
            end
        end

        function out._decode(slice, position, _)
            local value, newPosition = decodeInteger(slice, position, modulus)
            if value % 2 == 1 then
                return (value + 1) * -0.5, newPosition
            else
                return value * 0.5, newPosition
            end
        end
    else
        function out._encode(state, value)
            encodeInteger(state, value)
        end

        function out._decode(slice, position, _)
            return decodeInteger(slice, position, modulus)
        end
    end

    return makeCallableType(out)
end

-- Makes types for floating-point numbers.
local function makeFloatingPoint(formatCharacter, wireType)
    return makeCallableType {
        _wireType = wireType,

        _check = function(_, value)
            return expect(1, value, "number")
        end,

        _encode = function(state, value)
            encodeBytes(state, spack(formatCharacter, value))
        end,

        _decode = function(slice, position, _)
            -- string.unpack() checks for range, so no need to assert anything.
            return sunpack(formatCharacter, slice, position)
        end,
    }
end

local exports = {
    uint32 = makeIntegerType(2 ^ 32),
    sint32 = makeIntegerType(2 ^ 32, true),

    -- 64-bit integers don't fit in a number, so we reduce them to 53-bit.
    uint53 = makeIntegerType(2 ^ 53),
    sint53 = makeIntegerType(2 ^ 53, true),

    double = makeFloatingPoint("d", 1),
    float = makeFloatingPoint("f", 5),
}

exports.bool = makeCallableType {
    _wireType = 0,

    _check = function(_, value)
        return expect(1, value, "boolean")
    end,

    _encode = function(state, value)
        if value then
            encodeInteger(state, 1)
        else
            encodeInteger(state, 0)
        end
    end,

    _decode = function(slice, position, _)
        -- We use 2⁶⁴ as a modulus here, despite the fact that it doesn't fit.
        -- This is because ProtoBuf requires 64-bit decoding for booleans. The
        -- function _will_ lose precision, but that doesn't matter since we're
        -- checking only for the value not being 0.
        local value, newPosition = decodeInteger(slice, position, 2 ^ 64)
        return value ~= 0, newPosition
    end,
}

exports.bytes = makeCallableType {
    _wireType = 2,

    _check = function(_, value)
        return expect(1, value, "string")
    end,

    _encode = function(state, value)
        encodeInteger(state, #value)
        encodeBytes(state, value)
    end,

    _decode = function(slice, position, _)
        local length, position = decodeInteger(slice, position, 2 ^ 32)
        return decodeBytes(slice, position, length)
    end,
}

-- Encodes a type into a field. Requires a non-nil field number.
local function encodeFieldHandlePacked(state, type, value)
    -- Handle packed representation.
    -- TODO Explictly unpacked types. (why though?)
    local isPacked = type._wireType ~= 2 and type._isRepeated and #value > 1
    if isPacked then
        -- Encode the tag with wireType 2.
        encodeInteger(state, 8 * type._fieldNumber + 2)

        -- Encode a dummy length value to change after we discover the length.
        encodeBytes(state, "")
        local lengthPosition = #state.b
        local oldLength = state.n

        -- Encode elements.
        while value ~= nil do
            value = type._encode(state, value)
        end

        -- Update the dummy length.
        local lengthBuffer = newEncodingState()
        encodeInteger(lengthBuffer, state.n - oldLength)
        local lengthString = table.concat(lengthBuffer.b)
        state.b[lengthPosition] = lengthString
        state.n = state.n + #lengthString
    else
        while value ~= nil do
            -- Encode the tag and value.
            encodeInteger(state, 8 * type._fieldNumber + type._wireType)
            value = type._encode(state, value)
        end
    end
end

-- Decodes a field. Requires a non-nil field number.
-- Since the type is defined by the tag, we defer to the embedder message to
-- resolve the type and give it to us, as well as the wireType in the tag.
local function decodeFieldHandlePacked(slice, position, type, wireType, value)
    -- We need to handle packed types, regardless of whether our type is
    -- repeated or not. Fortunately, repeated fields already handle their own
    -- repetition.
    local isPacked = type._wireType ~= 2 and wireType == 2
    if isPacked then
        -- Decode the length.
        local length, position = decodeInteger(slice, position, 2 ^ 32)
        local endPosition = position + length

        -- Decode elements.
        while position < endPosition do
            value, position = type._decode(slice, position, value)
        end

        return value, position
    else
        -- Decode the single element.
        return type._decode(slice, position, value)
    end
end

-- Message types are parameterized by a message definition.
function exports.message(definition)
    local types = {}
    local keys = {}
    local fieldNumbers = {} -- An array of used fields for encoding in order.

    local function processDefinition(definition)
        for key, type in pairs(definition) do
            local fieldNumber = type._fieldNumber
            assert(fieldNumber, "field type is missing a field number")
            assert(not types[key], "repeated field key")
            assert(not keys[fieldNumber], "repeated field number")
            types[key] = type
            keys[fieldNumber] = key
            fieldNumbers[#fieldNumbers + 1] = fieldNumber
        end

        -- fieldNumbers is meant to be kept in order.
        table.sort(fieldNumbers)
    end

    processDefinition(definition)

    local function encodeUnsized(state, values)
        for _, fieldNumber in ipairs(fieldNumbers) do
            local key = keys[fieldNumber]
            if values[key] then
                encodeFieldHandlePacked(state, types[key], values[key])
            end
        end
    end

    local function decodeUnsized(slice, position, length, values)
        -- First call sets values to nil, initialize an empty table.
        values = values or {}

        local endPosition = position + length

        -- Decode fields.
        while position < endPosition do
            -- Decode tag.
            local tag
            tag, position = decodeInteger(slice, position, 2 ^ 32)
            local wireType = tag % 8
            local field = (tag - wireType) / 8
            local key = keys[field]
            if key then
                -- Known type, decode using the definition.
                values[key], position = decodeFieldHandlePacked(
                    slice,
                    position,
                    types[key],
                    wireType,
                    values[key]
                )
            else
                -- Unknown type, skip.
                if wireType == 0 then
                    local _
                    _, position = decodeInteger(slice, position, 1)
                elseif wireType == 1 then
                    position = position + 8
                elseif wireType == 2 then
                    local len, _
                    len, position = decodeInteger(slice, position, 1 / 0)
                    _, position = decodeBytes(slice, position, len)
                elseif wireType == 5 then
                    position = position + 4
                else
                    error("unknown wire type")
                end
            end
        end

        -- Fill in empty repeated fields with {}.
        for name, type in pairs(types) do
            if type._isRepeated and not values[name] then
                values[name] = {}
            end
        end

        return values, position
    end

    local outputType = makeCallableType {
        _wireType = 2,

        _check = function(recursionTracker, values)
            expect(1, values, "table")

            -- Check if the type is recursive.
            if recursionTracker[values] then
                error("cannot encode type with recursive entries")
            end

            recursionTracker[values] = true

            local newValues = {}
            for key, value in pairs(values) do
                local type = types[key]
                if type then
                    newValues[key] = type._check(recursionTracker, value)
                end
            end

            recursionTracker[values] = nil

            return newValues
        end,

        _encode = function(state, values)
            -- Encode a dummy length to change after we discover the length.
            -- TODO This is redundant.
            encodeBytes(state, "")
            local lengthPosition = #state.b
            local oldLength = state.n

            encodeUnsized(state, values)

            -- Update the dummy length.
            local lengthBuffer = newEncodingState()
            encodeInteger(lengthBuffer, state.n - oldLength)
            local lengthString = table.concat(lengthBuffer.b)
            state.b[lengthPosition] = lengthString
            state.n = state.n + #lengthString
        end,

        _decode = function(slice, position, values)
            local length, position = decodeInteger(slice, position, 2 ^ 32)
            return decodeUnsized(slice, position, length, values)
        end
    }

    local outputMetatable = getmetatable(outputType)

    outputMetatable.__index = {
        serialize = function(values)
            local buffer = newEncodingState()
            encodeUnsized(buffer, outputType._check({}, values))
            return table.concat(buffer.b)
        end,

        deserialize = function(string)
            local out, _ = decodeUnsized(string, 1, #string, nil)
            return out
        end,
    }

    function outputMetatable.__newindex(_, key, type)
        processDefinition { [key] = type }
    end

    return setmetatable(outputType, outputMetatable)
end

return exports
