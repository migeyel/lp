local expect = require "cc.expect".expect

local rol = bit32.lrotate
local shr = bit32.rshift
local bxor = bit32.bxor
local bnot = bit32.bnot
local band = bit32.band
local unpack = unpack or table.unpack

local function primes(n, exp)
    local out = {}
    local p = 2
    for i = 1, n do
        out[i] = bxor(p ^ exp % 1 * 2 ^ 32)
        repeat p = p + 1 until 2 ^ p % p == 2
    end
    return out
end

local K = primes(64, 1 / 3)
local H0 = primes(8, 1 / 2)

return function(data)
    expect(1, data, "string")

    -- Pad input
    local bitlen = #data * 8
    local padlen = -(#data + 9) % 64
    data = data .. "\x80" .. ("\0"):rep(padlen) .. (">I8"):pack(bitlen)

    -- Digest
    local K = K
    local h0, h1, h2, h3, h4, h5, h6, h7 = unpack(H0)
    for i = 1, #data, 64 do
        local w = { (">I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4"):unpack(data, i) }

        -- Message schedule
        for j = 17, 64 do
            local wf = w[j - 15]
            local w2 = w[j - 2]
            local s0 = bxor(rol(wf, 25), rol(wf, 14), shr(wf, 3))
            local s1 = bxor(rol(w2, 15), rol(w2, 13), shr(w2, 10))
            w[j] = w[j - 16] + s0 + w[j - 7] + s1
        end

        -- Block
        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for j = 1, 64 do
            local s1 = bxor(rol(e, 26), rol(e, 21), rol(e, 7))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = h + s1 + ch + K[j] + w[j]
            local s0 = bxor(rol(a, 30), rol(a, 19), rol(a, 10))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = s0 + maj

            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2
        end

        -- Feed-forward
        h0 = (h0 + a) % 2 ^ 32
        h1 = (h1 + b) % 2 ^ 32
        h2 = (h2 + c) % 2 ^ 32
        h3 = (h3 + d) % 2 ^ 32
        h4 = (h4 + e) % 2 ^ 32
        h5 = (h5 + f) % 2 ^ 32
        h6 = (h6 + g) % 2 ^ 32
        h7 = (h7 + h) % 2 ^ 32
    end

    return (">I4I4I4I4I4I4I4I4"):pack(h0, h1, h2, h3, h4, h5, h6, h7)
end
