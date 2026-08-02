-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

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

    -- Learned from wherever relay traffic was last seen, so a returning player
    -- can send immediately instead of waiting to overhear a frame.
    learnedClubId = nil,
    learnedStreamId = nil,

    -- Relay to cross-faction Battle.net friends directly, no community needed.
    useBattleNetFriends = true,

    -- Party, raid and instance groups, and guild. Cross-faction and, unlike the
    -- community, sender-authenticated by the server -- so these are preferred
    -- for anyone reachable on them.
    useGroup = true,
    useGuild = true,

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

    ---------------------------------------------------------------- chat ------

    chatEnabled = true,

    -- Which of your own chat types get relayed, and which relayed types you
    -- want shown. Separate on purpose: reading the other faction without
    -- broadcasting yourself is a reasonable thing to want.
    chatSend = { SAY = true, EMOTE = true, YELL = true, TEXT_EMOTE = true },
    chatShow = { SAY = true, EMOTE = true, YELL = true, TEXT_EMOTE = true },

    -- Speech range in yards. The client's own values are roughly these; they
    -- are settings because relayed range is a judgement call, not a fact.
    chatRangeSay = 40,
    chatRangeYell = 300,

    -- Drop relayed lines from a sender past this many per minute.
    chatMessagesPerMinute = 30,

    -- Do not put your chat on the relay when no cross-faction player has been
    -- heard from on your map recently. Costs up to one heartbeat interval of
    -- silence when someone new arrives; saves broadcasting an entire roleplay
    -- session to a community where nobody is listening.
    chatOnlyWhenListeners = true,

    -- Prepended to every relayed line. Empty by default because relayed names
    -- are already faction-coloured, which native chat never is.
    chatPrefix = "",

    -- Only understand the other faction while Elixir of Tongues is up. Off by
    -- default; the spell id is a setting so it can be corrected without a code
    -- change if Blizzard ever reissues the item.
    requireTongues = false,
    tonguesSpellId = 7178,

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
