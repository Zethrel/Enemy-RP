-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Core/Protocol.lua
-- The wire format. See docs/PROTOCOL.md for the normative description.
--
-- Frame layout (one chat message):
--
--     ERP1 <sender> <faction> <id> <seq> <total> <chunk>#
--
-- Everything up to <chunk> is space free, so the frame splits on spaces with a
-- limit and the chunk keeps whatever spaces it contains. The trailing `#` is a
-- sentinel: chat transports may strip trailing whitespace, and without it a
-- chunk boundary that lands on a space would silently lose a byte.
--
-- Reassembled chunks form a body of `<OPCODE> <payload>`.

local ADDON, ns = ...

local Protocol = {}
ns.Protocol = Protocol

local Codec = ns.Codec
local Util = ns.Util

Protocol.MAGIC = "ERP" .. ns.PROTOCOL
Protocol.SENTINEL = "#"

Protocol.OPCODE = {
    HEARTBEAT = "HB", -- presence and profile fingerprint
    REQUEST   = "RQ", -- ask a named peer for fields
    RESPONSE  = "RS", -- deliver fields to the requester
    CHAT      = "CH", -- a line of say/emote/yell, with where it was spoken
    FAREWELL  = "BY", -- leaving; drop me from your roster
}

--------------------------------------------------------------------------------
-- Message identifiers
--------------------------------------------------------------------------------

local BASE36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function toBase36(value, width)
    local out = ""
    repeat
        out = BASE36:sub(value % 36 + 1, value % 36 + 1) .. out
        value = math.floor(value / 36)
    until value == 0
    while #out < width do out = "0" .. out end
    return out
end

local sessionTag = toBase36(math.random(0, 1295), 2)
local counter = 0

--- Four base36 characters. Reassembly is keyed on (sender, id), so ids only
--- need to be unique per sender within the reassembly window.
function Protocol.NextId()
    counter = (counter + 1) % 1296
    return sessionTag .. toBase36(counter, 2)
end

--------------------------------------------------------------------------------
-- Frames
--------------------------------------------------------------------------------

function Protocol.BuildFrame(id, seq, total, chunk)
    return ("%s %s %s %s %d %d %s%s"):format(
        Protocol.MAGIC,
        Util.PlayerFullName(),
        Util.PlayerFactionCode(),
        id,
        seq,
        total,
        chunk,
        Protocol.SENTINEL
    )
end

--- Returns a table describing the frame, or nil if it is not ours / malformed.
--- Never raises: every byte here came from a stranger.
function Protocol.ParseFrame(text)
    if type(text) ~= "string" then return nil end
    if text:sub(1, #Protocol.MAGIC + 1) ~= Protocol.MAGIC .. " " then return nil end
    if text:sub(-1) ~= Protocol.SENTINEL then return nil end

    -- Matched rather than split so the chunk keeps any leading space a chunk
    -- boundary happened to land on.
    local magic, sender, faction, id, seq, total, chunk =
        text:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$")
    if not chunk or magic ~= Protocol.MAGIC then return nil end

    seq, total = tonumber(seq), tonumber(total)
    if not seq or not total then return nil end
    if seq < 1 or total < 1 or seq > total or total > 255 then return nil end

    if not sender or not sender:match("^[^%s]+%-[^%s]+$") then return nil end
    if faction ~= "A" and faction ~= "H" and faction ~= "N" then return nil end
    if not id or not id:match("^%w+$") then return nil end

    return {
        sender = sender,
        faction = faction,
        id = id,
        seq = seq,
        total = total,
        chunk = chunk:sub(1, -2), -- drop the sentinel
    }
end

function Protocol.BuildBody(opcode, payload)
    return payload and payload ~= "" and (opcode .. " " .. payload) or opcode
end

function Protocol.SplitBody(body)
    local opcode, payload = body:match("^(%u%u) ?(.*)$")
    return opcode, payload
end

--------------------------------------------------------------------------------
-- Field payloads
--
-- A response payload is a `~` separated list of `FIELD^VERSION^PACKEDVALUE`.
-- Codec.Pack guarantees the packed value contains neither separator.
--------------------------------------------------------------------------------

function Protocol.EncodeFields(entries)
    local parts = {}
    for index = 1, #entries do
        local entry = entries[index]
        parts[index] = ("%s^%s^%s"):format(
            entry.field, Util.FormatVersion(entry.version), Codec.Pack(entry.value or ""))
    end
    return table.concat(parts, "~")
end

function Protocol.DecodeFields(payload)
    local entries = {}
    if type(payload) ~= "string" or payload == "" then return entries end

    for part in payload:gmatch("[^~]+") do
        local field, version, packed = part:match("^(%u%u)%^(%d+)%^(.*)$")
        if field then
            local value = Codec.Unpack(packed)
            version = Util.ToVersion(version)
            if value and version then
                entries[#entries + 1] = {
                    field = field,
                    version = version,
                    value = value,
                }
            end
        end
    end
    return entries
end

--------------------------------------------------------------------------------
-- Request payloads
--
-- `<target> FIELD=knownVersion,FIELD=knownVersion`. Sending the version we
-- already hold lets the responder skip fields that have not changed.
--------------------------------------------------------------------------------

function Protocol.EncodeRequest(target, known)
    local parts = {}
    for field, version in pairs(known) do
        parts[#parts + 1] = ("%s=%s"):format(field, Util.FormatVersion(version))
    end
    table.sort(parts)
    return target .. " " .. table.concat(parts, ",")
end

function Protocol.DecodeRequest(payload)
    if type(payload) ~= "string" then return nil end
    local target, list = payload:match("^(%S+) ?(.*)$")
    if not target then return nil end

    local known = {}
    for field, version in (list or ""):gmatch("(%u%u)=(%d+)") do
        known[field] = Util.ToVersion(version) or 0
    end
    return target, known
end

--------------------------------------------------------------------------------
-- Heartbeat payloads
--
-- `<mapId> <tooltipVersion> <fingerprint>` -- small enough to always fit one
-- frame, which is what keeps presence cheap.
--------------------------------------------------------------------------------

function Protocol.EncodeHeartbeat(mapId, tooltipVersion, fingerprint)
    return ("%d %s %s"):format(
        mapId or 0, Util.FormatVersion(tooltipVersion), fingerprint or "0")
end

function Protocol.DecodeHeartbeat(payload)
    if type(payload) ~= "string" then return nil end
    local mapId, tooltipVersion, fingerprint = payload:match("^(%d+) (%d+) (%w+)$")
    if not mapId then return nil end
    return tonumber(mapId), Util.ToVersion(tooltipVersion) or 0, fingerprint
end

--------------------------------------------------------------------------------
-- Chat payloads
--
-- `<kind> <mapId> <x> <y> <packedText>`. The position is the speaker's own,
-- stated so the receiver can apply speech range to someone the client cannot
-- see. Coordinates are map-normalized to four decimals, which is roughly a
-- yard on a continent map and far finer than any range check needs.
--------------------------------------------------------------------------------

Protocol.CHAT_KIND = {
    SAY        = "S",
    EMOTE      = "E",
    YELL       = "Y",
    TEXT_EMOTE = "T",
}

Protocol.CHAT_TYPE = {}
for chatType, kind in pairs(Protocol.CHAT_KIND) do
    Protocol.CHAT_TYPE[kind] = chatType
end

function Protocol.EncodeChat(kind, mapId, x, y, text)
    return ("%s %d %.4f %.4f %s"):format(kind, mapId or 0, x or 0, y or 0, Codec.Pack(text))
end

function Protocol.DecodeChat(payload)
    if type(payload) ~= "string" then return nil end

    local kind, mapId, x, y, packed =
        payload:match("^(%a) (%d+) (%d+%.%d+) (%d+%.%d+) (.+)$")
    if not kind or not Protocol.CHAT_TYPE[kind] then return nil end

    x, y = tonumber(x), tonumber(y)
    if not x or not y then return nil end
    -- Positions outside the map are either a bug or an attempt to dodge the
    -- range check by claiming to be everywhere.
    if x < 0 or x > 1 or y < 0 or y > 1 then return nil end

    local text = Codec.Unpack(packed)
    if not text or text == "" then return nil end

    return Protocol.CHAT_TYPE[kind], tonumber(mapId), x, y, text
end
