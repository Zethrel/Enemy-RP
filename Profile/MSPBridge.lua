-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Profile/MSPBridge.lua
-- Adapter between this addon and whatever roleplay addon the player runs.
--
-- Total RP 3, MyRolePlay and XRP all speak Mary Sue Protocol and all expose it
-- through the shared `msp` table, so targeting that table rather than any one
-- addon's internals means a Horde Total RP user and an Alliance XRP user see
-- each other with no special casing. It also means this file is the only place
-- that needs to change if a new RP addon shows up.

local ADDON, ns = ...

local Bridge = ns:NewModule("MSPBridge")
ns.Bridge = Bridge

local Util = ns.Util

--- Fields that populate a mouseover tooltip. Cheap and requested often.
Bridge.TOOLTIP_FIELDS = {
    "VP", "VA", "NA", "NH", "NI", "NT", "RA", "RC", "IC", "CU", "CO", "FR", "FC",
}

--- Everything else: the body of the profile, fetched when someone actually
--- opens it.
Bridge.FULL_FIELDS = {
    "AE", "AG", "AH", "AW", "DE", "HB", "HH", "HI", "MO",
}

Bridge.ALL_FIELDS = {}
do
    for _, field in ipairs(Bridge.TOOLTIP_FIELDS) do
        Bridge.ALL_FIELDS[#Bridge.ALL_FIELDS + 1] = field
    end
    for _, field in ipairs(Bridge.FULL_FIELDS) do
        Bridge.ALL_FIELDS[#Bridge.ALL_FIELDS + 1] = field
    end
end

local VALID_FIELD = {}
for _, field in ipairs(Bridge.ALL_FIELDS) do VALID_FIELD[field] = true end
VALID_FIELD.TT = true

function Bridge.IsKnownField(field)
    return VALID_FIELD[field] == true
end

--------------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------------

function Bridge:IsAvailable()
    local msp = _G.msp
    return type(msp) == "table" and type(msp.char) == "table"
end

--- Best-effort name of the RP addon backing the msp table, for /erp status.
function Bridge:HostAddon()
    if _G.TRP3_API then return "Total RP 3" end
    if _G.xrp then return "XRP" end
    if _G.mrp or _G.msp_RPAddOn then return _G.msp_RPAddOn or "MyRolePlay" end
    return self:IsAvailable() and "unknown (msp present)" or nil
end

--------------------------------------------------------------------------------
-- Reading the local player's profile
--------------------------------------------------------------------------------

function Bridge:GetMyField(field)
    local msp = _G.msp
    if type(msp) ~= "table" then return nil, 0 end
    local value = msp.my and msp.my[field]
    local version = (msp.myver and msp.myver[field]) or 0
    return value, version
end

function Bridge:GetMyTooltipVersion()
    local _, version = self:GetMyField("TT")
    return version or 0
end

--- Short hash over every field we would ever send. Peers compare this against
--- the last value they saw to decide whether a re-fetch is worth a round trip;
--- it catches edits that an addon forgot to bump a version number for.
function Bridge:Fingerprint()
    local parts = {}
    for _, field in ipairs(self.ALL_FIELDS) do
        local value, version = self:GetMyField(field)
        parts[#parts + 1] = ("%s=%d:%s"):format(
            field, version or 0, value ~= nil and tostring(value) or "")
    end
    return Util.Hash(table.concat(parts, "\30"))
end

--- Build response entries for a request. `known` maps field to the version the
--- requester already has, so unchanged fields cost nothing but their absence.
function Bridge:CollectFields(known)
    local entries = {}

    for field, knownVersion in pairs(known) do
        if VALID_FIELD[field] then
            local value, version = self:GetMyField(field)
            version = version or 0
            value = (value ~= nil) and tostring(value) or ""

            -- An empty unversioned field carries no information, so saying
            -- nothing is the same answer at zero cost. Otherwise: version 0
            -- means "unversioned", which cannot be compared, so always resend.
            local worthSending = (value ~= "" or version ~= 0)
                and (version == 0 or knownVersion ~= version)

            if worthSending then
                entries[#entries + 1] = { field = field, version = version, value = value }
            end
        end
    end

    return entries
end

--------------------------------------------------------------------------------
-- Handing a received profile to the local RP addon
--------------------------------------------------------------------------------

local function fireCallbacks(msp, fullName, entries)
    local callback = msp.callback
    if type(callback) ~= "table" then return end

    if type(callback.updated) == "table" then
        for _, handler in ipairs(callback.updated) do
            for _, entry in ipairs(entries) do
                pcall(handler, fullName, entry.field, entry.value)
            end
        end
    end

    if type(callback.received) == "table" then
        for _, handler in ipairs(callback.received) do
            pcall(handler, fullName)
        end
    end
end

--- Write a relayed profile into the msp character table so the local RP addon
--- renders it exactly like a same-faction one. Returns false when no RP addon
--- is loaded, in which case the profile still lives in our own cache.
function Bridge:Inject(fullName, entries)
    if not self:IsAvailable() then return false end
    if #entries == 0 then return true end

    local msp = _G.msp
    local ok, record = pcall(function() return msp.char[fullName] end)
    if not ok or type(record) ~= "table" then return false end

    record.supported = true
    record.scantime = GetTime()

    local now = GetTime()
    for _, entry in ipairs(entries) do
        if type(record.field) == "table" then record.field[entry.field] = entry.value end
        if type(record.ver) == "table" then record.ver[entry.field] = entry.version end
        if type(record.time) == "table" then record.time[entry.field] = now end
    end

    fireCallbacks(msp, fullName, entries)
    return true
end
