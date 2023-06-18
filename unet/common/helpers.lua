local function pad(msg, prefixlen, minlen, blocksize)
    local l = math.max(#msg + prefixlen + 1, minlen)
    local e = math.floor(math.log(l, 2))
    local s = math.floor(math.log(e, 2)) + 1
    local z = e - s
    local m = l + -l % 2 ^ z
    local mm = math.ceil((m - prefixlen) / blocksize) * blocksize
    return msg .. "\x80" .. ("\0"):rep(mm - #msg - 1)
end

---@param msg string
---@return string | nil
local function unpad(msg)
    if not msg then return end
    for i = #msg, 1, -1 do
        local b = msg:byte(i)
        if b == 0 then
        elseif b == 0x80 then
            return msg:sub(1, i - 1)
        else
            return
        end
    end
end

local UUID_PAT = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

---@param s string
local function isValidUuid(s)
    return s:match(UUID_PAT) and s:lower() == s
end

return {
    pad = pad,
    unpad = unpad,
    isValidUuid = isValidUuid,
}
