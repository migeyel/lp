local PATH = "/state.lst"
local NEW_PATH = "/state.lst.new"

local function write(obj)
    local s = textutils.serialize(obj, { allow_repetitions = true })

    local f = fs.open(NEW_PATH, "wb")
    f.write(s)
    f.close()

    fs.delete(PATH)
    fs.move(NEW_PATH, PATH)
end

local function read()
    if fs.exists(PATH) then
        fs.delete(NEW_PATH)
    elseif fs.exists(NEW_PATH) then
        fs.move(NEW_PATH, PATH)
    else
        return {}
    end

    local f = fs.open(PATH, "rb")
    local s = f.readAll() or ""
    f.close()

    local t, e = textutils.unserialize(s)
    assert(type(t) == "table", e or ("couldn't deserialize " .. PATH))
    return t
end

return {
    read = read,
    write = write,
}
