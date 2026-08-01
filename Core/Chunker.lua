-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Core/Chunker.lua
-- Splits bodies that exceed one chat message and reassembles them on arrival.
--
-- Reassembly buffers are keyed by (sender, message id) and expire, because a
-- peer that logs out mid-transfer will never send the rest.

local ADDON, ns = ...

local Chunker = ns:NewModule("Chunker")
ns.Chunker = Chunker

local Protocol = ns.Protocol

local BUFFER_TIMEOUT = 30      -- seconds before an incomplete body is dropped
local MAX_BUFFERS_PER_SENDER = 4

local pending = {} -- "sender/id" -> { total, received, parts, expires, sender }

--------------------------------------------------------------------------------
-- Outbound
--------------------------------------------------------------------------------

--- How many payload bytes fit in one frame once framing overhead is removed.
local function chunkCapacity()
    local overhead = #Protocol.BuildFrame("0000", 255, 255, "")
    return math.max(64, (ns.db.maxFrameLength or 900) - overhead)
end

function Chunker:Split(body)
    local capacity = chunkCapacity()
    if #body <= capacity then return { body } end

    local chunks = {}
    for offset = 1, #body, capacity do
        chunks[#chunks + 1] = body:sub(offset, offset + capacity - 1)
    end
    return chunks
end

--------------------------------------------------------------------------------
-- Inbound
--------------------------------------------------------------------------------

--- Feed one parsed frame. Returns the complete body once the last chunk lands,
--- otherwise nil.
function Chunker:Feed(frame)
    if frame.total == 1 then return frame.chunk end

    local key = frame.sender .. "/" .. frame.id
    local buffer = pending[key]

    if not buffer then
        -- A hostile or broken peer could otherwise open unlimited buffers.
        local count = 0
        for _, other in pairs(pending) do
            if other.sender == frame.sender then count = count + 1 end
        end
        if count >= MAX_BUFFERS_PER_SENDER then
            ns:Debug("dropping chunk from %s: too many partial transfers", frame.sender)
            return nil
        end

        buffer = { total = frame.total, received = 0, parts = {}, sender = frame.sender }
        pending[key] = buffer
    end

    if buffer.total ~= frame.total then return nil end
    if buffer.parts[frame.seq] then return nil end

    buffer.parts[frame.seq] = frame.chunk
    buffer.received = buffer.received + 1
    buffer.expires = GetTime() + BUFFER_TIMEOUT

    if buffer.received < buffer.total then return nil end

    pending[key] = nil
    return table.concat(buffer.parts)
end

function Chunker:Forget(sender)
    for key, buffer in pairs(pending) do
        if buffer.sender == sender then pending[key] = nil end
    end
end

function Chunker:PendingCount()
    local count = 0
    for _ in pairs(pending) do count = count + 1 end
    return count
end

function Chunker:OnEnable()
    C_Timer.NewTicker(10, function()
        local now = GetTime()
        for key, buffer in pairs(pending) do
            if buffer.expires and buffer.expires < now then
                ns:Debug("discarding incomplete transfer from %s", buffer.sender)
                pending[key] = nil
            end
        end
    end)
end
