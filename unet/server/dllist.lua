---@class Node
---@field _n Node
---@field _p Node
---@field _f boolean?
---@field data any
local Node = {}
local NodeMt = { __index = Node }

---@param data any
---@return Node
function Node:pushAfter(data)
    if self._f then error("attempted to use a deleted node", 2) end
    local next = self._n
    local new = setmetatable({ _n = next, _p = self, data = data }, NodeMt)
    self._n = new
    next._p = new
    return new
end

---@param data any
---@return Node
function Node:pushBefore(data)
    if self._f then error("attempted to use a deleted node", 2) end
    local prev = self._p
    local new = setmetatable({ _n = self, _p = prev, data = data }, NodeMt)
    self._p = new
    prev._n = new
    return new
end

function Node:delete()
    if self._f then error("attempted to use a deleted node", 2) end
    local prev = self._p
    local next = self._n
    prev._n = next
    next._p = prev
    self._f = true
end

---@return Node?
function Node:next()
    if self._f then error("attempted to use a deleted node", 2) end
    local next = self._n
    if next._n then return next end
end

---@return Node?
function Node:prev()
    if self._f then error("attempted to use a deleted node", 2) end
    local prev = self._p
    if prev._p then return prev end
end

---@class List
---@field _head Node
---@field _tail Node
local List = {}
local ListMt = { __index = List }

---@return boolean
function List:isEmpty()
    return self._head._n == self._tail
end

---@param data any
---@return Node
function List:pushFront(data)
    return self._head:pushAfter(data)
end

---@param data any
---@return Node
function List:pushBack(data)
    return self._tail:pushBefore(data)
end

---@return Node?
function List:first()
    local out = self._head._n
    if out ~= self._tail then return out end
end

---@return Node?
function List:last()
    local out = self._tail._p
    if out ~= self._head then return out end
end

---@return List
local function new()
    local list = {
        _head = setmetatable({}, NodeMt),
        _tail = setmetatable({}, NodeMt),
    }

    list._head._n = list._tail
    list._tail._p = list._head

    return setmetatable(list, ListMt)
end

return {
    new = new,
}
