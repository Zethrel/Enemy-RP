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
