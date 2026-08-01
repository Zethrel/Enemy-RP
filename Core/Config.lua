-- Core/Config.lua
-- Saved variables and defaults. Exposes the live table as ns.db.

local ADDON, ns = ...

local Config = ns:NewModule("Config")

local DEFAULTS = {
    debug = false,
    enabled = true,

    -- Battle.net community used as the cross-faction bus. These four are listed
    -- for documentation only -- nil defaults never reach the saved variables.
    --
    -- clubId is remembered once resolved so a renamed community keeps working;
    -- the stream is re-derived every login from streamName, or, when that is
    -- unset, by preferring a channel called "relay" over the general one.
    clubName = nil,
    clubId = nil,
    streamName = nil,

    -- Relay to cross-faction Battle.net friends directly, no community needed.
    useBattleNetFriends = true,

    -- Largest single relay frame. Community chat accepts more, but staying well
    -- under the limit avoids server-side truncation surprises.
    maxFrameLength = 900,

    -- Seconds between presence broadcasts, plus random jitter up to a quarter of
    -- that so a crowded zone does not sync everyone onto the same tick.
    heartbeatInterval = 90,

    -- Pull a profile automatically when a heartbeat shows it changed, instead of
    -- waiting for the player to mouse over someone.
    autoFetch = true,

    -- Ignore peers whose heartbeat puts them on a different map.
    sameMapOnly = true,

    -- Answer at most this many profile requests per requester per minute.
    requestsPerMinute = 6,

    -- Cached profiles: dropped after this many days unseen, and pruned to this
    -- many entries (least recently seen first).
    cacheDays = 14,
    cacheLimit = 500,

    profiles = {}, -- fullName -> { faction, fields, versions, seen, map, token }
}

local function applyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            applyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

function Config:OnInitialize()
    EnemyRPDB = EnemyRPDB or {}
    applyDefaults(EnemyRPDB, DEFAULTS)
    ns.db = EnemyRPDB
end

function Config:Reset()
    wipe(EnemyRPDB)
    applyDefaults(EnemyRPDB, DEFAULTS)
    ns.db = EnemyRPDB
end

ns.Config = Config
ns.DEFAULTS = DEFAULTS
