local expect = require "cc.expect".expect

local bxor = bit32.bxor
local btest = bit32.btest
local rol = bit32.lrotate
local spack = string.pack
local sunpack = string.unpack

local function double(k0, k1, k2, k3)
    return
        bxor(k0 * 2, btest(k3, 2 ^ 31) and 0x87 or 0),
        bxor(k1 * 2, k0 * 2 ^ -31),
        bxor(k2 * 2, k1 * 2 ^ -31),
        bxor(k3 * 2)
end

local function pi(v0, v1, v2, v3)
    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = v2 + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1 v1 = bxor(v2, rol(v1, 7))
    v0 = rol(v0, 16) + v3 v3 = bxor(v0, rol(v3, 13))

    v0 = v0 + v1 v1 = bxor(v0, rol(v1, 5))
    v2 = rol(v2, 16) + v3 v3 = bxor(v2, rol(v3, 8))
    v2 = v2 + v1
    v0 = rol(v0, 16) + v3

    return v0, bxor(v2, rol(v1, 7)), rol(v2, 16), bxor(v0, rol(v3, 13))
end

local paddings = {}
for i = 1, 16 do
    paddings[i] = "\x80" .. ("\0"):rep((-1 - i) % 16)
end

return function(k)
    if type(k) ~= "string" then expect(1, k, "string") end
    if #k ~= 16 then error("wrong key length", 2) end

    local k00, k01, k02, k03 = sunpack("<I4I4I4I4", k)
    local k10, k11, k12, k13 = double(k00, k01, k02, k03)
    local k20, k21, k22, k23 = double(k10, k11, k12, k13)

    return function(m)
        if type(m) ~= "string" then expect(2, m, "string") end

        -- Pad
        local l = #m
        local r = l % 16
        local l0, l1, l2, l3
        if r ~= 0 then
            m = m .. paddings[r]
            l0 = k10
            l1 = k11
            l2 = k12
            l3 = k13
        elseif l ~= 0 then
            l0 = k20
            l1 = k21
            l2 = k22
            l3 = k23
        else
            m = paddings[16]
            l0 = k10
            l1 = k11
            l2 = k12
            l3 = k13
        end

        -- Digest
        local h0, h1, h2, h3 = k00, k01, k02, k03
        for i = 1, #m - 16, 16 do
            local m0, m1, m2, m3 = sunpack("<I4I4I4I4", m, i)
            h0, h1, h2, h3 = pi(
                bxor(h0, m0),
                bxor(h1, m1),
                bxor(h2, m2),
                bxor(h3, m3)
            )
        end

        -- Last block
        local m0, m1, m2, m3 = sunpack("<I4I4I4I4", m, -16)
        h0, h1, h2, h3 = pi(
            bxor(h0, m0, l0),
            bxor(h1, m1, l1),
            bxor(h2, m2, l2),
            bxor(h3, m3, l3)
        )

        return spack("<I4I4I4I4",
            bxor(h0, l0),
            bxor(h1, l1),
            bxor(h2, l2),
            bxor(h3, l3)
        )
    end
end
