local band, bor, bnot, bxor, rol = bit32.band, bit32.bor, bit32.bnot, bit32.bxor, bit32.lrotate

local S = {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20, 5,  9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
}

local K = {}
for i = 1, 64 do
    K[i] = math.floor(2 ^ 32 * math.abs(math.sin(i)))
end

return function(m)
    m = m .. "\x80" .. ("\0"):rep(-(#m + 9) % 64) .. ("<I8"):pack(8 * #m)
    local a, b, c, d = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for i = 1, #m, 64 do
        local block = {}
        for j = 0, 15 do block[j] = ("<I4"):unpack(m, 4 * j + i) end
        local A, B, C, D = a, b, c, d
        for j = 1, 64 do
            local F, g
            if j <= 16 then
                F = bxor(D, band(B, bxor(C, D)))
                g = j - 1
            elseif j <= 32 then
                F = bxor(C, band(D, bxor(B, C)))
                g = (5 * j - 4) % 16
            elseif j <= 48 then
                F = bxor(B, C, D)
                g = (3 * j + 2) % 16
            else
                F = bxor(C, bor(B, bnot(D)))
                g = (7 * j - 7) % 16
            end
            F = (F + A + K[j] + block[g]) % 2 ^ 32
            A = D
            D = C
            C = B
            B = (B + rol(F, S[j])) % 2 ^ 32
        end
        a = (a + A) % 2 ^ 32
        b = (b + B) % 2 ^ 32
        c = (c + C) % 2 ^ 32
        d = (d + D) % 2 ^ 32
    end
    return (("<I4I4I4I4"):pack(a, b, c, d)
        :gsub(".", function(h) return ("%02x"):format(h:byte()) end))
end
