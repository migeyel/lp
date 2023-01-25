--- Canonical JSON done lazily.

local function patch(obj)
    if type(obj) ~= "table" then return end

    local keys = {}
    for k, v in pairs(obj) do
        patch(v)
        keys[#keys + 1] = k
    end

    table.sort(keys)
    local knext = {}
    for i = 1, #keys do
        knext[keys[i]] = keys[i + 1]
    end

    setmetatable(obj, {
        __pairs = function(t)
            return function(_, i)
                if i ~= nil then
                    return knext[i], t[knext[i]]
                else
                    return keys[1], t[keys[1]]
                end
            end, t, nil
        end,
    })
end

local function serialize(obj)
    obj = textutils.unserializeJSON(textutils.serializeJSON(obj))
    patch(obj)
    return textutils.serializeJSON(obj)
end

return {
    serialize = serialize,
}
