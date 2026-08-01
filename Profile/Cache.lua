-- Profile/Cache.lua
-- Stores what we know about cross-faction characters, and survives a reload.
--
-- Persisting profiles matters more here than it does for same-faction RP: a
-- relayed profile costs a round trip through Battle.net, so throwing the cache
-- away at logout would mean re-fetching the same crowd every evening.

local ADDON, ns = ...

local Cache = ns:NewModule("Cache")
ns.Cache = Cache

local Util = ns.Util

--- Returns the stored record for a character, creating it if asked.
function Cache:Get(fullName, create)
    local profiles = ns.db.profiles
    local record = profiles[fullName]
    if not record and create then
        record = { fields = {}, versions = {}, seen = time() }
        profiles[fullName] = record
    end
    return record
end

--- Record presence. Returns true when the peer's fingerprint changed, which is
--- the signal that their profile is worth re-fetching.
function Cache:Touch(fullName, faction, mapId, tooltipVersion, token)
    local record = self:Get(fullName, true)
    local stale = record.token ~= token or record.tooltipVersion ~= tooltipVersion

    record.faction = faction or record.faction
    record.map = mapId
    record.tooltipVersion = tooltipVersion
    record.token = token
    record.seen = time()

    return stale
end

function Cache:SetFields(fullName, entries)
    local record = self:Get(fullName, true)
    local changed = false

    for _, entry in ipairs(entries) do
        if record.versions[entry.field] ~= entry.version
            or record.fields[entry.field] ~= entry.value
        then
            record.fields[entry.field] = entry.value ~= "" and entry.value or nil
            record.versions[entry.field] = entry.version
            changed = true
        end
    end

    record.fetched = time()
    record.seen = time()
    return changed
end

--- Versions we already hold for the given fields, so a request can ask the peer
--- to skip anything unchanged.
function Cache:KnownVersions(fullName, fields)
    local record = self:Get(fullName)
    local known = {}
    for _, field in ipairs(fields) do
        known[field] = (record and record.versions[field]) or 0
    end
    return known
end

function Cache:Forget(fullName)
    ns.db.profiles[fullName] = nil
end

--- Characters seen recently, newest first. `withinSeconds` filters by last
--- heartbeat; pass nil for everything cached.
function Cache:Roster(withinSeconds)
    local cutoff = withinSeconds and (time() - withinSeconds) or nil
    local out = {}

    for fullName, record in pairs(ns.db.profiles) do
        if not cutoff or (record.seen or 0) >= cutoff then
            out[#out + 1] = {
                fullName = fullName,
                faction = record.faction,
                map = record.map,
                seen = record.seen or 0,
                hasProfile = record.fields and next(record.fields) ~= nil,
                name = record.fields and record.fields.NA or Util.ShortName(fullName),
            }
        end
    end

    table.sort(out, function(a, b) return a.seen > b.seen end)
    return out
end

function Cache:Count()
    local count = 0
    for _ in pairs(ns.db.profiles) do count = count + 1 end
    return count
end

--------------------------------------------------------------------------------
-- Pruning
--------------------------------------------------------------------------------

function Cache:Prune()
    local profiles = ns.db.profiles
    local cutoff = time() - (ns.db.cacheDays or 14) * 86400

    for fullName, record in pairs(profiles) do
        if (record.seen or 0) < cutoff then profiles[fullName] = nil end
    end

    local limit = ns.db.cacheLimit or 500
    local names = {}
    for fullName in pairs(profiles) do names[#names + 1] = fullName end
    if #names <= limit then return end

    table.sort(names, function(a, b)
        return (profiles[a].seen or 0) > (profiles[b].seen or 0)
    end)
    for index = limit + 1, #names do
        profiles[names[index]] = nil
    end
end

function Cache:OnEnable()
    self:Prune()
end
