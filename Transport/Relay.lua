-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Transport/Relay.lua
-- The bus. Everything above this file talks in opcodes and payloads; everything
-- below it talks in chat messages.
--
-- Backends register themselves and advertise what they can do:
--
--   backend.name                  identifier for logs and /erp status
--   backend:IsReady()             connected and usable right now
--   backend:CanBroadcast()        can reach unknown peers
--   backend:Broadcast(frame)      send to everyone
--   backend:CanReach(fullName)    has a direct route to one named character
--   backend:SendTo(fullName, f)   use that route

local ADDON, ns = ...

local Relay = ns:NewModule("Relay")
ns.Relay = Relay

local Protocol = ns.Protocol
local Chunker = ns.Chunker
local Util = ns.Util

local backends = {}

-- Frames can legitimately arrive twice: a peer who is both a Battle.net friend
-- and a community member is reachable on two backends at once.
local recentFrames = {}
local RECENT_TTL = 60

function Relay:RegisterBackend(backend)
    backends[#backends + 1] = backend
    ns:Debug("registered transport %s", backend.name)
end

function Relay:Backends()
    return backends
end

--------------------------------------------------------------------------------
-- Outbound
--------------------------------------------------------------------------------

--- Chunk a body to suit one backend and hand each frame to `send`.
---
--- The message id is chosen once by the caller and reused across backends. A
--- peer reachable on two of them at once therefore sees the same id with
--- different chunk counts: the first complete copy wins, the other's chunks are
--- either suppressed as duplicates or expire as an incomplete buffer. Fresh ids
--- per backend would instead deliver the message twice, which is harmless for a
--- profile and very much not for a line of chat.
local function sendVia(backend, body, id, send)
    local chunks = Chunker:Split(body, backend.maxFrameLength)
    for index = 1, #chunks do
        send(Protocol.BuildFrame(id, index, #chunks, chunks[index]))
    end
end

--- Send to every peer that can hear us.
function Relay:Broadcast(opcode, payload)
    if not ns.db.enabled then return false end

    local body = Protocol.BuildBody(opcode, payload)
    local id = Protocol.NextId()
    local delivered = false

    for _, backend in ipairs(backends) do
        if backend.CanBroadcast and backend:CanBroadcast() and backend:IsReady() then
            sendVia(backend, body, id, function(frame) backend:Broadcast(frame) end)
            delivered = true
        end
    end

    if not delivered then
        ns:Debug("no broadcast-capable transport for %s", opcode)
    end
    return delivered
end

--- Send to one character. Falls back to a broadcast when no direct route exists,
--- which is the normal case for someone we only know through the community.
function Relay:SendTo(fullName, opcode, payload)
    if not ns.db.enabled then return false end

    local body = Protocol.BuildBody(opcode, payload)
    local id = Protocol.NextId()

    for _, backend in ipairs(backends) do
        if backend.CanReach and backend:IsReady() and backend:CanReach(fullName) then
            sendVia(backend, body, id, function(frame) backend:SendTo(fullName, frame) end)
            ns:Debug("sent %s to %s via %s", opcode, fullName, backend.name)
            return true
        end
    end

    return self:Broadcast(opcode, payload)
end

--------------------------------------------------------------------------------
-- Inbound
--------------------------------------------------------------------------------

local function isDuplicate(frame)
    local key = ("%s/%s/%d"):format(frame.sender, frame.id, frame.seq)
    local now = GetTime()

    if recentFrames[key] and recentFrames[key] > now then return true end
    recentFrames[key] = now + RECENT_TTL

    -- Opportunistic sweep; the table only grows while traffic is flowing.
    if math.random() < 0.05 then
        for otherKey, expiry in pairs(recentFrames) do
            if expiry < now then recentFrames[otherKey] = nil end
        end
    end
    return false
end

--- Called by backends with a raw chat message. Anything that is not a
--- well-formed frame of ours is silently ignored.
function Relay:Incoming(text, context)
    if not ns.db.enabled then return end

    local frame = Protocol.ParseFrame(text)
    if not frame then return end
    if frame.sender == Util.PlayerFullName() then return end

    -- Addon-channel transports report a server-authenticated sender. Where we
    -- have one, the name claimed inside the frame has to match it -- which
    -- makes party, raid and guild traffic the only path in this addon that
    -- cannot be spoofed. Community frames carry no such witness.
    if context and context.verifiedSender and frame.sender ~= context.verifiedSender then
        ns:Debug("dropping frame from %s claiming to be %s",
            context.verifiedSender, frame.sender)
        return
    end

    if isDuplicate(frame) then return end

    local body = Chunker:Feed(frame)
    if not body then return end

    local opcode, payload = Protocol.SplitBody(body)
    if not opcode then
        ns:Debug("unparseable body from %s", frame.sender)
        return
    end

    ns:Debug("recv %s from %s (%s)", opcode, frame.sender, context and context.backend or "?")
    ns:Fire("RELAY_MESSAGE", frame.sender, frame.faction, opcode, payload, context)
end
