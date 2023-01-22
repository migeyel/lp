--- Disk-based state-keeping.
--
-- Unlike with the world, fs writes are flushed almost immediately to disk,
-- rather than waiting for an autosave.
--
-- We only mitigate the more frequent autosave rollbacks, since full world
-- backup restores are so catastrophic that it's almost impossible to prevent at
-- least some damage.
--
-- This state library is toughened against potential crashes. It saves the file
-- completely into an auxiliary ".new" path, before deleting the old one and
-- moving the new one in, hopefully atomically.

local function writeFile(path, t)
    local s = textutils.serialize(t, { allow_repetitions = true })
    local f = assert(fs.open(path, "wb"))
    f.write(s)
    f.close()
end

local function readFile(path)
    local f = assert(fs.open(path, "rb"))
    local s = f.readAll(path)
    f.close()
    local t, e = textutils.unserialize(s or "")
    assert(type(t) == "table", e or ("couldn't deserialize " .. path))
    return t
end

local function copy(t)
    return textutils.unserialize(textutils.serialize(t))
end

local PATH = "/lp.lst"
local NEW_PATH = "/lp.lst.new"

local mainState = nil
if fs.exists(PATH) then
    fs.delete(NEW_PATH)
    mainState = readFile(PATH)
elseif fs.exists(NEW_PATH) then
    fs.move(NEW_PATH, PATH)
    mainState = readFile(PATH)
else
    mainState = {}
    writeFile(PATH, mainState)
end

local function open(index)
    local out = copy(mainState[index] or {})

    local mtIdx = {
        _index = index,

        commit = function()
            mainState[index] = copy(out)
            writeFile(NEW_PATH, mainState)
            fs.delete(PATH)
            fs.move(NEW_PATH, PATH)
        end,

        --- Commits several states atomically.
        commitMany = function(...)
            for i, v in pairs({ ... }) do mainState[v._index] = copy(v) end
            writeFile(NEW_PATH, mainState)
            fs.delete(PATH)
            fs.move(NEW_PATH, PATH)
        end
    }

    return setmetatable(out, { __index = mtIdx })
end

return {
    open = open,
}
