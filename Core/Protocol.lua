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
        parts[index] = ("%s^%d^%s"):format(
            entry.field, entry.version or 0, Codec.Pack(entry.value or ""))
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
            if value then
                entries[#entries + 1] = {
                    field = field,
                    version = tonumber(version),
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
        parts[#parts + 1] = ("%s=%d"):format(field, version or 0)
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
        known[field] = tonumber(version)
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
    return ("%d %d %s"):format(mapId or 0, tooltipVersion or 0, fingerprint or "0")
end

function Protocol.DecodeHeartbeat(payload)
    if type(payload) ~= "string" then return nil end
    local mapId, tooltipVersion, fingerprint = payload:match("^(%d+) (%d+) (%w+)$")
    if not mapId then return nil end
    return tonumber(mapId), tonumber(tooltipVersion), fingerprint
end
