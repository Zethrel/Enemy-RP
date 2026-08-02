-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Core/Util.lua
-- Small helpers shared across modules: identity, hashing, and a rate-limited
-- send queue. No state that needs saving lives here.

local ADDON, ns = ...

local Util = {}
ns.Util = Util

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

local myFullName, myFaction

--- "Name-Realm" using the normalized (space- and punctuation-free) realm name,
--- which is the same key MSP addons use for their character tables.
function Util.PlayerFullName()
    if not myFullName then
        local name = UnitName("player")
        local realm = GetNormalizedRealmName()
        if not name or not realm then return nil end
        myFullName = name .. "-" .. realm
    end
    return myFullName
end

--- "A", "H", or "N" for neutral/unknown. One character keeps frames short.
function Util.PlayerFactionCode()
    if not myFaction then
        local faction = UnitFactionGroup("player")
        myFaction = (faction == "Alliance" and "A") or (faction == "Horde" and "H") or nil
    end
    return myFaction or "N"
end

--- Resolve a unit token to "Name-Realm", or nil if it is not a player.
function Util.UnitFullName(unit)
    if not UnitIsPlayer(unit) then return nil end
    local name, realm = UnitFullName(unit)
    if not name or name == "" then return nil end
    if not realm or realm == "" then realm = GetNormalizedRealmName() end
    return name .. "-" .. realm
end

function Util.UnitFactionCode(unit)
    local faction = UnitFactionGroup(unit)
    return (faction == "Alliance" and "A") or (faction == "Horde" and "H") or "N"
end

--- Attach the player's own realm to a bare name so `/erp show Bob` works.
function Util.QualifyName(name)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    local realm = GetNormalizedRealmName()
    return realm and (name .. "-" .. realm) or name
end

function Util.ShortName(fullName)
    return (fullName or ""):match("^([^-]+)") or fullName
end

--------------------------------------------------------------------------------
-- Version numbers
--
-- Mary Sue Protocol field versions are not counters. Total RP 3 assigns large
-- random values, routinely above 2^31, and WoW's Lua pushes %d through a signed
-- 32-bit integer -- formatting one that way raises "integer overflow attempting
-- to store N" and takes the addon down. Versions are therefore rendered with
-- %.0f, which has no such limit and no exponent, and are never passed to %d.
--------------------------------------------------------------------------------

-- Beyond this, a Lua number can no longer represent consecutive integers, so a
-- version would not survive its own round trip.
local MAX_VERSION = 2 ^ 53

local function isFinite(number)
    return number == number and number ~= math.huge and number ~= -math.huge
end

--- Render a version for the wire. Anything unusable becomes 0, which the
--- protocol already means as "unversioned".
function Util.FormatVersion(version)
    version = tonumber(version)
    if not version or not isFinite(version) or version < 0 or version > MAX_VERSION then
        version = 0
    end
    return ("%.0f"):format(version)
end

--- Parse a version off the wire, or nil if it could not be one. A peer is free
--- to send four hundred digits; tonumber turns that into infinity, and an
--- infinite version would poison every later comparison and format.
function Util.ToVersion(text)
    local version = tonumber(text)
    if not version or not isFinite(version) then return nil end
    if version < 0 or version > MAX_VERSION then return nil end
    return math.floor(version)
end

--------------------------------------------------------------------------------
-- Hashing
--------------------------------------------------------------------------------

local bxor = bit.bxor

--- FNV-1a, 32-bit, rendered as lowercase hex. Used to fingerprint a profile so
--- peers can tell "changed" from "unchanged" without shipping the payload.
function Util.Hash(str)
    local hash = 2166136261
    for i = 1, #str do
        -- bxor returns a signed 32-bit value; the modulo pulls it back to
        -- unsigned so the multiply below stays predictable.
        hash = bxor(hash, str:byte(i)) % 4294967296
        -- hash * 16777619 would exceed Lua 5.1's exact integer range, so the
        -- prime is split: 16777619 == 2^24 + 403.
        hash = ((hash % 256) * 16777216 + hash * 403) % 4294967296
    end
    return ("%08x"):format(hash)
end

--------------------------------------------------------------------------------
-- Rate-limited send queue
--
-- Battle.net community chat is throttled server-side and dropping messages is
-- silent, so every outbound path funnels through one of these token buckets.
--------------------------------------------------------------------------------

local Queue = {}
Queue.__index = Queue

--- rate: messages per second. burst: how many may go out back to back.
function Util.NewQueue(rate, burst, sender)
    return setmetatable({
        rate = rate,
        burst = burst,
        tokens = burst,
        last = GetTime(),
        sender = sender,
        items = {},
        head = 1,
        tail = 0,
    }, Queue)
end

function Queue:Push(...)
    self.tail = self.tail + 1
    self.items[self.tail] = { ... }
    self:Flush()
end

function Queue:Size()
    return self.tail - self.head + 1
end

function Queue:Clear()
    self.items = {}
    self.head, self.tail = 1, 0
end

function Queue:Flush()
    local now = GetTime()
    self.tokens = math.min(self.burst, self.tokens + (now - self.last) * self.rate)
    self.last = now

    while self.head <= self.tail and self.tokens >= 1 do
        local item = self.items[self.head]
        self.items[self.head] = nil
        self.head = self.head + 1
        self.tokens = self.tokens - 1

        local ok, err = pcall(self.sender, unpack(item))
        if not ok then ns:Error("send failed -- %s", tostring(err)) end
    end

    if self.head > self.tail then
        self.head, self.tail = 1, 0
        self.scheduled = false
        return
    end

    if not self.scheduled then
        self.scheduled = true
        local wait = (1 - self.tokens) / self.rate
        C_Timer.After(math.max(wait, 0.1), function()
            self.scheduled = false
            self:Flush()
        end)
    end
end
