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

local function framesFor(body)
    local chunks = Chunker:Split(body)
    local id = Protocol.NextId()
    local frames = {}
    for index = 1, #chunks do
        frames[index] = Protocol.BuildFrame(id, index, #chunks, chunks[index])
    end
    return frames
end

--- Send to every peer that can hear us.
function Relay:Broadcast(opcode, payload)
    if not ns.db.enabled then return false end

    local frames = framesFor(Protocol.BuildBody(opcode, payload))
    local delivered = false

    for _, backend in ipairs(backends) do
        if backend.CanBroadcast and backend:CanBroadcast() and backend:IsReady() then
            for _, frame in ipairs(frames) do
                backend:Broadcast(frame)
            end
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

    for _, backend in ipairs(backends) do
        if backend.CanReach and backend:IsReady() and backend:CanReach(fullName) then
            for _, frame in ipairs(framesFor(Protocol.BuildBody(opcode, payload))) do
                backend:SendTo(fullName, frame)
            end
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
