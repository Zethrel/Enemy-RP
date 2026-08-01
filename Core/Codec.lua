-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Core/Codec.lua
-- Makes arbitrary profile values safe to carry inside a Battle.net chat message.
--
-- Constraints the wire format has to respect:
--   * the message must stay valid UTF-8 or the server may mangle it,
--   * newlines and other control characters cannot survive chat transport,
--   * `|` would be read as a UI escape sequence by anything that renders it,
--   * `~`, `^` and `%` are reserved as our own field separators and escape char.
--
-- Almost all profile data is ordinary text, so the default is percent-escaping,
-- which is close to 1:1 in size. Anything that is not valid UTF-8 falls back to
-- base64 at the usual 4/3 cost.

local ADDON, ns = ...

local Codec = {}
ns.Codec = Codec

local floor = math.floor

--------------------------------------------------------------------------------
-- Percent escaping
--------------------------------------------------------------------------------

function Codec.EscapeValue(value)
    return (value:gsub("[%%|~%^%c\127]", function(char)
        return ("%%%02X"):format(char:byte())
    end))
end

function Codec.UnescapeValue(text)
    return (text:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

--------------------------------------------------------------------------------
-- Base64
--------------------------------------------------------------------------------

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local decodeTable = {}
for index = 1, #ALPHABET do
    decodeTable[ALPHABET:sub(index, index)] = index - 1
end

local function symbol(value)
    return ALPHABET:sub(value + 1, value + 1)
end

function Codec.Base64Encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local packed = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = symbol(floor(packed / 262144) % 64)
            .. symbol(floor(packed / 4096) % 64)
            .. (b and symbol(floor(packed / 64) % 64) or "=")
            .. (c and symbol(packed % 64) or "=")
    end
    return table.concat(out)
end

function Codec.Base64Decode(text)
    text = text:gsub("[^A-Za-z0-9+/=]", "")
    local out = {}
    for i = 1, #text, 4 do
        local v1 = decodeTable[text:sub(i, i)]
        local v2 = decodeTable[text:sub(i + 1, i + 1)]
        if not v1 or not v2 then return nil end
        -- Padding characters are absent from the table, so a nil here is
        -- exactly the signal that this quad encodes fewer than three bytes.
        local v3 = decodeTable[text:sub(i + 2, i + 2)]
        local v4 = decodeTable[text:sub(i + 3, i + 3)]

        local packed = v1 * 262144 + v2 * 4096 + (v3 or 0) * 64 + (v4 or 0)
        out[#out + 1] = string.char(floor(packed / 65536) % 256)
        if v3 then out[#out + 1] = string.char(floor(packed / 256) % 256) end
        if v4 then out[#out + 1] = string.char(packed % 256) end
    end
    return table.concat(out)
end

--------------------------------------------------------------------------------
-- UTF-8 validation
--------------------------------------------------------------------------------

function Codec.IsValidUTF8(text)
    local index, length = 1, #text
    while index <= length do
        local lead = text:byte(index)
        local continuations
        if lead < 0x80 then
            continuations = 0
        elseif lead >= 0xC2 and lead <= 0xDF then
            continuations = 1
        elseif lead >= 0xE0 and lead <= 0xEF then
            continuations = 2
        elseif lead >= 0xF0 and lead <= 0xF4 then
            continuations = 3
        else
            return false
        end
        for offset = 1, continuations do
            local byte = text:byte(index + offset)
            if not byte or byte < 0x80 or byte > 0xBF then return false end
        end
        index = index + continuations + 1
    end
    return true
end

--------------------------------------------------------------------------------
-- Public interface
--------------------------------------------------------------------------------

--- Encode one profile value for the wire. The result contains no separator
--- characters, so callers can join packed values freely.
function Codec.Pack(value)
    if type(value) ~= "string" then value = tostring(value) end

    if not Codec.IsValidUTF8(value) then
        return "b:" .. Codec.Base64Encode(value)
    end

    local escaped = Codec.EscapeValue(value)
    if #escaped > #value * 1.4 then
        return "b:" .. Codec.Base64Encode(value)
    end
    return "t:" .. escaped
end

--- Reverse Codec.Pack. Returns nil on anything malformed rather than raising,
--- because the input is by definition attacker-controlled.
function Codec.Unpack(text)
    if type(text) ~= "string" then return nil end
    local mode, body = text:match("^(%a):(.*)$")
    if mode == "t" then
        return Codec.UnescapeValue(body)
    elseif mode == "b" then
        return Codec.Base64Decode(body)
    end
    return nil
end
