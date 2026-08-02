-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Transport/AddonLink.lua
-- Ordinary addon messages over party, raid, instance and guild.
--
-- These channels became cross-faction when grouping and guilds did, which makes
-- them by far the best transport available: no community to join, no friend
-- request, and the server reports who actually sent each message. They are the
-- only path in the addon where a sender cannot lie about their name.
--
-- Both backends live in one file because CHAT_MSG_ADDON is a single event
-- carrying every distribution; registering it twice would process each message
-- twice.
--
-- The catch is size. The server caps an addon message at 255 characters against
-- a community message's several thousand, so these backends declare a much
-- smaller frame and the chunker splits accordingly.

local ADDON, ns = ...

local AddonLink = ns:NewModule("AddonLink")
ns.AddonLink = AddonLink

local Relay = ns.Relay
local Util = ns.Util

local PREFIX = "ERP1"
local MAX_FRAME = 240 -- 255 minus room for the prefix and a safety margin

--------------------------------------------------------------------------------
-- Rosters
--------------------------------------------------------------------------------

local groupMembers = {} -- fullName -> true
local guildMembers = {} -- fullName -> true

local function refreshGroup()
    wipe(groupMembers)

    local count = GetNumGroupMembers() or 0
    if count == 0 then return end

    -- raid1..raidN includes the player; party1..partyN-1 does not.
    local prefix, last = "party", count - 1
    if IsInRaid() then prefix, last = "raid", count end

    for index = 1, last do
        local fullName = Util.UnitFullName(prefix .. index)
        if fullName then groupMembers[fullName] = true end
    end
end

local function refreshGuild()
    wipe(guildMembers)
    if not IsInGuild() then return end

    local total = GetNumGuildMembers() or 0
    for index = 1, total do
        -- The roster reports names already qualified with a realm.
        local fullName, _, _, _, _, _, _, _, online = GetGuildRosterInfo(index)
        if fullName and online then guildMembers[fullName] = true end
    end
end

--------------------------------------------------------------------------------
-- Group backend
--------------------------------------------------------------------------------

local Group = { name = "group", maxFrameLength = MAX_FRAME }
AddonLink.Group = Group

--- Instance groups have their own distribution and do not accept PARTY/RAID.
local function groupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

function Group:IsReady()
    return ns.db.useGroup == true and groupChannel() ~= nil
end

function Group:CanBroadcast()
    return true
end

function Group:Broadcast(frame)
    local channel = groupChannel()
    if not channel then return end
    AddonLink.queue:Push(channel, frame)
end

function Group:CanReach(fullName)
    return groupMembers[fullName] == true
end

-- A group message already reaches every member, so a directed send is the same
-- call. It costs the rest of the party one small message they will ignore.
function Group:SendTo(_, frame)
    self:Broadcast(frame)
end

--------------------------------------------------------------------------------
-- Guild backend
--------------------------------------------------------------------------------

local Guild = { name = "guild", maxFrameLength = MAX_FRAME }
AddonLink.Guild = Guild

function Guild:IsReady()
    return ns.db.useGuild == true and IsInGuild()
end

function Guild:CanBroadcast()
    return true
end

function Guild:Broadcast(frame)
    AddonLink.queue:Push("GUILD", frame)
end

function Guild:CanReach(fullName)
    return guildMembers[fullName] == true
end

function Guild:SendTo(_, frame)
    self:Broadcast(frame)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function AddonLink:CHAT_MSG_ADDON(prefix, text, channel, sender)
    if prefix ~= PREFIX then return end

    local backend = (channel == "GUILD") and Guild.name or Group.name
    Relay:Incoming(text, {
        backend = backend,
        -- The server, not the sender, decides what goes here.
        verifiedSender = sender,
    })
end

function AddonLink:GROUP_ROSTER_UPDATE()
    refreshGroup()
end

function AddonLink:OnGuildChanged()
    if self.guildRefreshPending then return end
    self.guildRefreshPending = true
    -- Roster updates arrive in bursts, and the data is only valid after the
    -- client has been asked to fetch it.
    C_Timer.After(2, function()
        self.guildRefreshPending = false
        refreshGuild()
    end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function AddonLink:OnEnable()
    self.queue = Util.NewQueue(4, 8, function(channel, frame)
        C_ChatInfo.SendAddonMessage(PREFIX, frame, channel)
    end)

    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

    self:RegisterEvent("CHAT_MSG_ADDON")
    self:RegisterEvent("GROUP_ROSTER_UPDATE")
    self:RegisterEvent("GUILD_ROSTER_UPDATE", self.OnGuildChanged)
    self:RegisterEvent("PLAYER_GUILD_UPDATE", self.OnGuildChanged)

    Relay:RegisterBackend(Group)
    Relay:RegisterBackend(Guild)

    refreshGroup()
    if IsInGuild() then
        pcall(C_GuildInfo.GuildRoster)
        self:OnGuildChanged()
    end
end

function AddonLink:GroupCount()
    local count = 0
    for _ in pairs(groupMembers) do count = count + 1 end
    return count
end

function AddonLink:GuildCount()
    local count = 0
    for _ in pairs(guildMembers) do count = count + 1 end
    return count
end
