local expect  = require "cc.expect".expect

local bxor = bit32.bxor
local rol = bit32.lrotate

--- Encrypts/Decrypts data using ChaCha20.
--
-- @tparam string key A 32-byte random key.
-- @tparam string nonce A 12-byte per-message unique nonce.
-- @tparam string message A plaintext or ciphertext.
-- @tparam[opt=20] number rounds The number of ChaCha20 rounds to use.
-- @tparam[opt=1] number offset The block offset to generate the keystream at.
-- @treturn string The resulting ciphertext or plaintext.
--
local function crypt(key, nonce, message, rounds, offset)
    expect(1, key, "string")
    assert(#key == 32, "key length must be 32")
    expect(2, nonce, "string")
    assert(#nonce == 12, "nonce length must be 12")
    expect(3, message, "string")
    rounds = expect(4, rounds, "number", "nil") or 20
    assert(rounds % 2 == 0, "round number must be even")
    assert(rounds >= 8, "round number must be no smaller than 8")
    assert(rounds <= 20, "round number must be no larger than 20")
    offset = expect(5, offset, "number", "nil") or 1
    assert(offset % 1 == 0, "offset must be an integer")
    assert(offset >= 0, "offset must be nonnegative")
    assert(#message + 64 * offset <= 2 ^ 38, "offset too large")

    -- Build the state block.
    local i0, i1, i2, i3 = 0x61707865, 0x3320646e, 0x79622d32, 0x6b206574
    local k0, k1, k2, k3, k4, k5, k6, k7 = ("<I4I4I4I4I4I4I4I4"):unpack(key, 1)
    local cr, n0, n1, n2 = offset, ("<I4I4I4"):unpack(nonce, 1)

    -- Pad the message.
    local padded = message .. ("\0"):rep(-#message % 64)

    -- Expand and combine.
    local out = {}
    local idx = 1
    for i = 1, #padded / 64 do
        -- Copy the block.
        local s00, s01, s02, s03 = i0, i1, i2, i3
        local s04, s05, s06, s07 = k0, k1, k2, k3
        local s08, s09, s10, s11 = k4, k5, k6, k7
        local s12, s13, s14, s15 = cr, n0, n1, n2

        -- Iterate.
        for _ = 1, rounds, 2 do
            s00 = s00 + s04 s12 = rol(bxor(s12, s00), 16)
            s08 = s08 + s12 s04 = rol(bxor(s04, s08), 12)
            s00 = s00 + s04 s12 = rol(bxor(s12, s00), 8)
            s08 = s08 + s12 s04 = rol(bxor(s04, s08), 7)

            s01 = s01 + s05 s13 = rol(bxor(s13, s01), 16)
            s09 = s09 + s13 s05 = rol(bxor(s05, s09), 12)
            s01 = s01 + s05 s13 = rol(bxor(s13, s01), 8)
            s09 = s09 + s13 s05 = rol(bxor(s05, s09), 7)

            s02 = s02 + s06 s14 = rol(bxor(s14, s02), 16)
            s10 = s10 + s14 s06 = rol(bxor(s06, s10), 12)
            s02 = s02 + s06 s14 = rol(bxor(s14, s02), 8)
            s10 = s10 + s14 s06 = rol(bxor(s06, s10), 7)

            s03 = s03 + s07 s15 = rol(bxor(s15, s03), 16)
            s11 = s11 + s15 s07 = rol(bxor(s07, s11), 12)
            s03 = s03 + s07 s15 = rol(bxor(s15, s03), 8)
            s11 = s11 + s15 s07 = rol(bxor(s07, s11), 7)

            s00 = s00 + s05 s15 = rol(bxor(s15, s00), 16)
            s10 = s10 + s15 s05 = rol(bxor(s05, s10), 12)
            s00 = s00 + s05 s15 = rol(bxor(s15, s00), 8)
            s10 = s10 + s15 s05 = rol(bxor(s05, s10), 7)

            s01 = s01 + s06 s12 = rol(bxor(s12, s01), 16)
            s11 = s11 + s12 s06 = rol(bxor(s06, s11), 12)
            s01 = s01 + s06 s12 = rol(bxor(s12, s01), 8)
            s11 = s11 + s12 s06 = rol(bxor(s06, s11), 7)

            s02 = s02 + s07 s13 = rol(bxor(s13, s02), 16)
            s08 = s08 + s13 s07 = rol(bxor(s07, s08), 12)
            s02 = s02 + s07 s13 = rol(bxor(s13, s02), 8)
            s08 = s08 + s13 s07 = rol(bxor(s07, s08), 7)

            s03 = s03 + s04 s14 = rol(bxor(s14, s03), 16)
            s09 = s09 + s14 s04 = rol(bxor(s04, s09), 12)
            s03 = s03 + s04 s14 = rol(bxor(s14, s03), 8)
            s09 = s09 + s14 s04 = rol(bxor(s04, s09), 7)
        end

        -- Decode message block.
        local m00, m01, m02, m03, m04, m05, m06, m07
        local m08, m09, m10, m11, m12, m13, m14, m15

        m00, m01, m02, m03, m04, m05, m06, m07,
        m08, m09, m10, m11, m12, m13, m14, m15, idx =
            ("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4"):unpack(padded, idx)

        -- Feed-forward and combine.
        out[i] = ("<I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4I4"):pack(
            bxor(m00, s00 + i0), bxor(m01, s01 + i1),
            bxor(m02, s02 + i2), bxor(m03, s03 + i3),
            bxor(m04, s04 + k0), bxor(m05, s05 + k1),
            bxor(m06, s06 + k2), bxor(m07, s07 + k3),
            bxor(m08, s08 + k4), bxor(m09, s09 + k5),
            bxor(m10, s10 + k6), bxor(m11, s11 + k7),
            bxor(m12, s12 + cr), bxor(m13, s13 + n0),
            bxor(m14, s14 + n1), bxor(m15, s15 + n2)
        )

        -- Increment counter.
        cr = cr + 1
    end

    return table.concat(out):sub(1, #message)
end

--- Computes a Poly1305 message authentication code.
--
-- @tparam string key A 32-byte single-use random key.
-- @tparam string message The message to authenticate.
-- @treturn string The 16-byte authentication tag.
--
local function mac(key, message)
    expect(1, key, "string")
    assert(#key == 32, "key length must be 32")
    expect(2, message, "string")

    -- Pad message.
    local pbplen = #message - 15
    if #message % 16 ~= 0 or #message == 0 then
        message = message .. "\1"
        message = message .. ("\0"):rep(-#message % 16)
    end

    -- Decode r.
    local R0, R1, R2, R3 = ("<I4I4I4I4"):unpack(key, 1)

    -- Clamp and shift.
    R0 = R0 % 2 ^ 28
    R1 = (R1 - R1 % 4) % 2 ^ 28 * 2 ^ 32
    R2 = (R2 - R2 % 4) % 2 ^ 28 * 2 ^ 64
    R3 = (R3 - R3 % 4) % 2 ^ 28 * 2 ^ 96

    -- Split.
    local r0 = R0 % 2 ^ 18   local r1 = R0 - r0
    local r2 = R1 % 2 ^ 50   local r3 = R1 - r2
    local r4 = R2 % 2 ^ 82   local r5 = R2 - r4
    local r6 = R3 % 2 ^ 112  local r7 = R3 - r6

    -- Generate scaled key.
    local S1 = 5 / 2 ^ 130 * R1
    local S2 = 5 / 2 ^ 130 * R2
    local S3 = 5 / 2 ^ 130 * R3

    -- Split.
    local s2 = S1 % 2 ^ -80  local s3 = S1 - s2
    local s4 = S2 % 2 ^ -48  local s5 = S2 - s4
    local s6 = S3 % 2 ^ -16  local s7 = S3 - s6

    local h0, h1, h2, h3, h4, h5, h6, h7 = 0, 0, 0, 0, 0, 0, 0, 0

    for i = 1, #message, 16 do
        -- Decode message block.
        local m0, m1, m2, m3 = ("<I4I4I4I4"):unpack(message, i)

        -- Shift message and add.
        local x0 = h0 + h1 + m0
        local x2 = h2 + h3 + m1 * 2 ^ 32
        local x4 = h4 + h5 + m2 * 2 ^ 64
        local x6 = h6 + h7 + m3 * 2 ^ 96

        -- Apply per-block padding when applicable.
        if i <= pbplen then x6 = x6 + 2 ^ 128 end

        -- Multiply
        h0 = x0 * r0 + x2 * s6 + x4 * s4 + x6 * s2
        h1 = x0 * r1 + x2 * s7 + x4 * s5 + x6 * s3
        h2 = x0 * r2 + x2 * r0 + x4 * s6 + x6 * s4
        h3 = x0 * r3 + x2 * r1 + x4 * s7 + x6 * s5
        h4 = x0 * r4 + x2 * r2 + x4 * r0 + x6 * s6
        h5 = x0 * r5 + x2 * r3 + x4 * r1 + x6 * s7
        h6 = x0 * r6 + x2 * r4 + x4 * r2 + x6 * r0
        h7 = x0 * r7 + x2 * r5 + x4 * r3 + x6 * r1

        -- Carry.
        local y0 = h0 + 3 * 2 ^ 69  - 3 * 2 ^ 69   h0 = h0 - y0  h1 = h1 + y0
        local y1 = h1 + 3 * 2 ^ 83  - 3 * 2 ^ 83   h1 = h1 - y1  h2 = h2 + y1
        local y2 = h2 + 3 * 2 ^ 101 - 3 * 2 ^ 101  h2 = h2 - y2  h3 = h3 + y2
        local y3 = h3 + 3 * 2 ^ 115 - 3 * 2 ^ 115  h3 = h3 - y3  h4 = h4 + y3
        local y4 = h4 + 3 * 2 ^ 133 - 3 * 2 ^ 133  h4 = h4 - y4  h5 = h5 + y4
        local y5 = h5 + 3 * 2 ^ 147 - 3 * 2 ^ 147  h5 = h5 - y5  h6 = h6 + y5
        local y6 = h6 + 3 * 2 ^ 163 - 3 * 2 ^ 163  h6 = h6 - y6  h7 = h7 + y6
        local y7 = h7 + 3 * 2 ^ 181 - 3 * 2 ^ 181  h7 = h7 - y7

        -- Reduce carry overflow into first limb.
        h0 = h0 + 5 / 2 ^ 130 * y7
    end

    -- Carry canonically.
    local c0 = h0 % 2 ^ 16   h1 = h0 - c0 + h1
    local c1 = h1 % 2 ^ 32   h2 = h1 - c1 + h2
    local c2 = h2 % 2 ^ 48   h3 = h2 - c2 + h3
    local c3 = h3 % 2 ^ 64   h4 = h3 - c3 + h4
    local c4 = h4 % 2 ^ 80   h5 = h4 - c4 + h5
    local c5 = h5 % 2 ^ 96   h6 = h5 - c5 + h6
    local c6 = h6 % 2 ^ 112  h7 = h6 - c6 + h7
    local c7 = h7 % 2 ^ 130

    -- Reduce carry overflow.
    h0 = c0 + 5 / 2 ^ 130 * (h7 - c7)
    c0 = h0 % 2 ^ 16
    c1 = h0 - c0 + c1

    -- Canonicalize.
    if      c7 == 0x3ffff * 2 ^ 112
        and c6 == 0xffff * 2 ^ 96
        and c5 == 0xffff * 2 ^ 80
        and c4 == 0xffff * 2 ^ 64
        and c3 == 0xffff * 2 ^ 48
        and c2 == 0xffff * 2 ^ 32
        and c1 == 0xffff * 2 ^ 16
        and c0 >= 0xfffb
    then
        c7, c6, c5, c4, c3, c2, c1, c0 = 0, 0, 0, 0, 0, 0, 0, c0 - 0xfffb
    end

    -- Decode s.
    local s0, s1, s2, s3 = ("<I4I4I4I4"):unpack(key, 17)

    -- Add.
    local t0 =           s0          + c0 + c1  local u0 = t0 % 2 ^ 32
    local t1 = t0 - u0 + s1 * 2 ^ 32 + c2 + c3  local u1 = t1 % 2 ^ 64
    local t2 = t1 - u1 + s2 * 2 ^ 64 + c4 + c5  local u2 = t2 % 2 ^ 96
    local t3 = t2 - u2 + s3 * 2 ^ 96 + c6 + c7  local u3 = t3 % 2 ^ 128

    -- Encode.
    return ("<I4I4I4I4"):pack(u0, u1 / 2 ^ 32, u2 / 2 ^ 64, u3 / 2 ^ 96)
end

--- Encrypts a message.
--
-- @tparam string key A 32-byte random key.
-- @tparam string nonce A 12-byte per-message unique nonce.
-- @tparam string message The message to be encrypted.
-- @tparam string aad Arbitrary associated data to authenticate on decryption.
-- @tparam[opt=20] number rounds The number of ChaCha20 rounds to use.
-- @treturn string The ciphertext.
-- @treturn string The 16-byte authentication tag.
--
local function encrypt(key, nonce, message, aad, rounds)
    expect(1, key, "string")
    assert(#key == 32, "key length must be 32")
    expect(2, nonce, "string")
    assert(#nonce == 12, "nonce length must be 12")
    expect(3, message, "string")
    expect(4, aad, "string")
    rounds = expect(5, rounds, "number", "nil") or 20
    assert(rounds % 2 == 0, "round number must be even")
    assert(rounds >= 8, "round number must be no smaller than 8")
    assert(rounds <= 20, "round number must be no larger than 20")

    -- Generate auth key and encrypt.
    local msgLong = ("\0"):rep(64) .. message
    local ctxLong = crypt(key, nonce, msgLong, rounds, 0)
    local authKey = ctxLong:sub(1, 32)
    local ciphertext = ctxLong:sub(65)

    -- Authenticate.
    local pad1 = ("\0"):rep(-#aad % 16)
    local pad2 = ("\0"):rep(-#ciphertext % 16)
    local aadLen = ("<I8"):pack(#aad)
    local ctxLen = ("<I8"):pack(#ciphertext)
    local combined = aad .. pad1 .. ciphertext .. pad2 .. aadLen .. ctxLen
    local tag = mac(authKey, combined)

    return ciphertext, tag
end

--- Decrypts a message.
--
-- @tparam string key The key used on encryption.
-- @tparam string nonce The nonce used on encryption.
-- @tparam string ciphertext The ciphertext to be decrypted.
-- @tparam string aad The arbitrary associated data used on encryption.
-- @tparam string tag The authentication tag returned on encryption.
-- @tparam[opt=20] number rounds The number of rounds used on encryption.
-- @treturn[1] string The decrypted plaintext.
-- @treturn[2] nil If authentication has failed.
--
local function decrypt(key, nonce, tag, ciphertext, aad, rounds)
    expect(1, key, "string")
    assert(#key == 32, "key length must be 32")
    expect(2, nonce, "string")
    assert(#nonce == 12, "nonce length must be 12")
    expect(3, tag, "string")
    assert(#tag == 16, "tag length must be 16")
    expect(4, ciphertext, "string")
    expect(5, aad, "string")
    rounds = expect(6, rounds, "number", "nil") or 20
    assert(rounds % 2 == 0, "round number must be even")
    assert(rounds >= 8, "round number must be no smaller than 8")
    assert(rounds <= 20, "round number must be no larger than 20")

    -- Generate auth key.
    local authKey = crypt(key, nonce, ("\0"):rep(32), rounds, 0)

    -- Check tag.
    local pad1 = ("\0"):rep(-#aad % 16)
    local pad2 = ("\0"):rep(-#ciphertext % 16)
    local aadLen = ("<I8"):pack(#aad)
    local ctxLen = ("<I8"):pack(#ciphertext)
    local combined = aad .. pad1 .. ciphertext .. pad2 .. aadLen .. ctxLen
    local t1, t2, t3, t4 = ("<I4I4I4I4"):unpack(tag, 1)
    local u1, u2, u3, u4 = ("<I4I4I4I4"):unpack(mac(authKey, combined), 1)
    local eq = bxor(t1, u1) + bxor(t2, u2) + bxor(t3, u3) + bxor(t4, u4)
    if eq ~= 0 then return nil end

    -- Decrypt
    return crypt(key, nonce, ciphertext, rounds)
end

return {
    crypt = crypt,
    encrypt = encrypt,
    decrypt = decrypt,
}
