-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Profile/Sync.lua
-- The policy layer: who we announce ourselves to, whose profile we ask for,
-- and what we answer when asked.
--
-- The shape is deliberately the same as MSP's own: a cheap presence broadcast
-- carrying version markers, and a directed request/response for the payload.
-- Profiles change rarely, so almost all traffic is heartbeats.

local ADDON, ns = ...

local Sync = ns:NewModule("Sync")
ns.Sync = Sync

local Relay = ns.Relay
local Protocol = ns.Protocol
local Cache = ns.Cache
local Bridge = ns.Bridge
local Util = ns.Util

local OPCODE = Protocol.OPCODE

-- Do not ask the same character again while an answer might still be in flight.
local REQUEST_COOLDOWN = 15
local outstanding = {} -- fullName -> expiry

-- Inbound request accounting, so one peer cannot make us flood the relay.
local requestBudget = {} -- fullName -> { count, windowStart }

--------------------------------------------------------------------------------
-- Outbound: presence
--------------------------------------------------------------------------------

function Sync:SendHeartbeat()
    if not ns.db.enabled then return end

    local mapId = C_Map.GetBestMapForUnit("player") or 0
    local payload = Protocol.EncodeHeartbeat(
        mapId, Bridge:GetMyTooltipVersion(), Bridge:Fingerprint())

    Relay:Broadcast(OPCODE.HEARTBEAT, payload)
end

local function scheduleHeartbeat()
    local interval = ns.db.heartbeatInterval or 90
    -- Jitter keeps a busy zone from bunching every client onto the same second.
    local delay = interval + math.random() * interval * 0.25
    C_Timer.After(delay, function()
        if ns.db.enabled then Sync:SendHeartbeat() end
        scheduleHeartbeat()
    end)
end

--------------------------------------------------------------------------------
-- Outbound: requests
--------------------------------------------------------------------------------

--- Ask a character for fields. `fields` defaults to the tooltip set.
function Sync:Request(fullName, fields, force)
    if not fullName or fullName == Util.PlayerFullName() then return false end

    local now = GetTime()
    if not force and (outstanding[fullName] or 0) > now then return false end

    fields = fields or Bridge.TOOLTIP_FIELDS
    local known = Cache:KnownVersions(fullName, fields)
    local payload = Protocol.EncodeRequest(fullName, known)

    ns:Debug("requesting %d fields from %s", #fields, fullName)
    local sent = Relay:SendTo(fullName, OPCODE.REQUEST, payload)

    -- Only start the cooldown once something actually went out; a request that
    -- found no transport should be retryable as soon as one appears.
    outstanding[fullName] = sent and (now + REQUEST_COOLDOWN) or nil
    return sent
end

function Sync:RequestFull(fullName, force)
    return self:Request(fullName, Bridge.ALL_FIELDS, force)
end

--------------------------------------------------------------------------------
-- Inbound
--------------------------------------------------------------------------------

local function withinBudget(sender)
    local limit = ns.db.requestsPerMinute or 6
    local now = GetTime()
    local budget = requestBudget[sender]

    if not budget or now - budget.windowStart > 60 then
        requestBudget[sender] = { count = 1, windowStart = now }
        return true
    end

    budget.count = budget.count + 1
    return budget.count <= limit
end

function Sync:HandleHeartbeat(sender, faction, payload)
    local mapId, tooltipVersion, token = Protocol.DecodeHeartbeat(payload)
    if not mapId then return end

    local changed = Cache:Touch(sender, faction, mapId, tooltipVersion, token)
    ns:Fire("ROSTER_UPDATED")

    if not ns.db.autoFetch or not changed then return end
    if ns.db.sameMapOnly and mapId ~= (C_Map.GetBestMapForUnit("player") or 0) then return end

    self:Request(sender)
end

function Sync:HandleRequest(sender, payload)
    local target, known = Protocol.DecodeRequest(payload)
    if not target then return end
    if target ~= Util.PlayerFullName() then return end

    if not withinBudget(sender) then
        ns:Debug("ignoring request flood from %s", sender)
        return
    end

    local entries = Bridge:CollectFields(known)
    if #entries == 0 then
        ns:Debug("%s already has current data", sender)
        return
    end

    Relay:SendTo(sender, OPCODE.RESPONSE, Protocol.EncodeFields(entries))
end

function Sync:HandleResponse(sender, faction, payload)
    local entries = Protocol.DecodeFields(payload)
    if #entries == 0 then return end

    -- Drop anything outside the known field set rather than letting a peer
    -- write arbitrary keys into the local RP addon's character table.
    local accepted = {}
    for _, entry in ipairs(entries) do
        if Bridge.IsKnownField(entry.field) then
            accepted[#accepted + 1] = entry
        end
    end
    if #accepted == 0 then return end

    outstanding[sender] = nil

    local record = Cache:Get(sender, true)
    record.faction = faction or record.faction
    Cache:SetFields(sender, accepted)
    Bridge:Inject(sender, accepted)

    ns:Debug("stored %d fields for %s", #accepted, sender)
    ns:Fire("PROFILE_UPDATED", sender)
    ns:Fire("ROSTER_UPDATED")
end

function Sync:OnRELAY_MESSAGE(sender, faction, opcode, payload)
    if opcode == OPCODE.HEARTBEAT then
        self:HandleHeartbeat(sender, faction, payload)
    elseif opcode == OPCODE.REQUEST then
        self:HandleRequest(sender, payload)
    elseif opcode == OPCODE.RESPONSE then
        self:HandleResponse(sender, faction, payload)
    elseif opcode == OPCODE.FAREWELL then
        local record = Cache:Get(sender)
        if record then record.map = nil end
        ns:Fire("ROSTER_UPDATED")
    end
end

--------------------------------------------------------------------------------
-- Local triggers
--------------------------------------------------------------------------------

--- Looking at someone is the strongest signal that their profile matters right
--- now, so it bypasses the same-map and auto-fetch settings.
function Sync:InspectUnit(unit)
    if not ns.db.enabled then return end
    if not UnitIsPlayer(unit) then return end
    if UnitFactionGroup(unit) == UnitFactionGroup("player") then return end

    local fullName = Util.UnitFullName(unit)
    if not fullName then return end

    local record = Cache:Get(fullName)
    if record and record.fetched and (time() - record.fetched) < 300 then return end

    self:Request(fullName)
end

function Sync:UPDATE_MOUSEOVER_UNIT()
    self:InspectUnit("mouseover")
end

function Sync:PLAYER_TARGET_CHANGED()
    self:InspectUnit("target")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Sync:OnEnable()
    self:Listen("RELAY_MESSAGE")
    self:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    self:RegisterEvent("PLAYER_TARGET_CHANGED")

    -- Communities and the friends list are still settling right after login.
    C_Timer.After(12, function()
        if ns.db.enabled then self:SendHeartbeat() end
    end)
    scheduleHeartbeat()
end
