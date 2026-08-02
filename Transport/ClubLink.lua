-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Transport/ClubLink.lua
-- Battle.net community backend: the only channel that reaches a stranger on the
-- other faction. Everything else needs you to already share a group, a guild or
-- a friends list.
--
-- Listening and sending are deliberately asymmetric.
--
-- It listens on one channel in *every* Battle.net community the player belongs
-- to, so joining a community is the entire setup -- no slash command, nothing to
-- configure, nothing to forget.
--
-- It will not send into a channel until it has grounds to believe Enemy RP is
-- welcome there: either the player named it explicitly, or relay traffic has
-- already been seen on it, or it is literally called "relay". Broadcasting into
-- some unrelated community would dump raw protocol frames into the chat window
-- of every member who does not run the addon.

local ADDON, ns = ...

local ClubLink = ns:NewModule("ClubLink")
ns.ClubLink = ClubLink

local Relay = ns.Relay
local Protocol = ns.Protocol
local Util = ns.Util

ClubLink.name = "community"

-- Channels we listen on: at most one per community, keyed "clubId/streamId".
local monitored = {}

-- Channels relay traffic has actually been seen on this session.
local active = {}

local function key(clubId, streamId)
    return clubId .. "/" .. streamId
end

--------------------------------------------------------------------------------
-- Discovery
--------------------------------------------------------------------------------

--- The channel worth listening on in one community: a dedicated "relay" if the
--- community has one, otherwise its general channel.
local function pickStream(clubId)
    local streams = C_Club.GetStreams(clubId)
    if not streams then return nil end

    local wanted = ns.db.streamName
    local general, relay

    for _, stream in ipairs(streams) do
        local name = (stream.name or ""):lower()
        if wanted and name == wanted:lower() then return stream, true end
        if name == "relay" then relay = stream end
        if stream.streamType == Enum.ClubStreamType.General then general = stream end
    end

    if relay then return relay, true end
    return general, false
end

--- Rebuild the listen set and focus each channel. CLUB_MESSAGE_ADDED only fires
--- for focused streams, so this has to happen for messages to arrive at all.
function ClubLink:Monitor()
    wipe(monitored)

    local clubs = C_Club.GetSubscribedClubs()
    if not clubs then return end

    for _, club in ipairs(clubs) do
        if club.clubType == Enum.ClubType.BattleNet then
            local stream, dedicated = pickStream(club.clubId)
            if stream then
                monitored[key(club.clubId, stream.streamId)] = {
                    clubId = club.clubId,
                    streamId = stream.streamId,
                    clubName = club.name,
                    streamName = stream.name,
                    dedicated = dedicated,
                }
                pcall(C_Club.FocusStream, club.clubId, stream.streamId)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Choosing where to send
--------------------------------------------------------------------------------

local function explicitChannel()
    local wantedName, pinnedId = ns.db.clubName, ns.db.clubId
    if not wantedName and not pinnedId then return nil end

    for _, channel in pairs(monitored) do
        if pinnedId and channel.clubId == pinnedId then return channel end
        if wantedName and channel.clubName
            and channel.clubName:lower() == wantedName:lower() then
            return channel
        end
    end
    return nil
end

--- Priority: what the player asked for, then what we learned last session, then
--- what is demonstrably live, then an unambiguous opt-in by channel name.
function ClubLink:Resolve()
    local chosen = explicitChannel()

    if not chosen and ns.db.learnedClubId then
        chosen = monitored[key(ns.db.learnedClubId, ns.db.learnedStreamId or 0)]
    end

    if not chosen then
        for channelKey, channel in pairs(monitored) do
            if active[channelKey] then chosen = channel break end
        end
    end

    if not chosen then
        for _, channel in pairs(monitored) do
            if channel.dedicated then chosen = channel break end
        end
    end

    local changed = not self.channel or not chosen
        or self.channel.clubId ~= chosen.clubId
        or self.channel.streamId ~= chosen.streamId

    self.channel = chosen

    if chosen then
        ns.db.learnedClubId = chosen.clubId
        ns.db.learnedStreamId = chosen.streamId
        if changed then
            ns:Debug("relay sending through %s / %s",
                chosen.clubName or "?", chosen.streamName or "?")
        end
    end

    return chosen ~= nil
end

--------------------------------------------------------------------------------
-- Backend interface
--------------------------------------------------------------------------------

function ClubLink:IsReady()
    return self.channel ~= nil
end

function ClubLink:CanBroadcast()
    return true
end

function ClubLink:Broadcast(frame)
    self.queue:Push(frame)
end

-- A community reaches everyone in it, but not by character name: the club knows
-- Battle.net accounts, not who is logged in. Directed sends stay elsewhere.
ClubLink.CanReach = nil

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function ClubLink:CLUB_MESSAGE_ADDED(clubId, streamId, messageId)
    local channelKey = key(clubId, streamId)
    local channel = monitored[channelKey]
    if not channel then return end

    local info = C_Club.GetMessageInfo(clubId, streamId, messageId)
    if not info or type(info.content) ~= "string" then return end
    if info.content:sub(1, #Protocol.MAGIC) ~= Protocol.MAGIC then return end

    -- Seeing a frame here is what makes this channel safe to send into.
    if not active[channelKey] then
        active[channelKey] = true
        ns:Debug("relay traffic found in %s / %s",
            channel.clubName or "?", channel.streamName or "?")
        self:Resolve()
    end

    Relay:Incoming(info.content, {
        backend = self.name,
        clubId = clubId,
        author = info.author,
    })

    pcall(C_Club.AdvanceStreamViewMarker, clubId, streamId)
end

function ClubLink:OnClubsChanged()
    self:Monitor()
    self:Resolve()
end

--------------------------------------------------------------------------------
-- Chat suppression
--------------------------------------------------------------------------------

local function suppressRelayChat(_, _, text)
    if type(text) == "string" and text:sub(1, #Protocol.MAGIC) == Protocol.MAGIC then
        return true
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ClubLink:OnEnable()
    self.queue = Util.NewQueue(2, 4, function(frame)
        if not self.channel then return end
        C_Club.SendMessage(self.channel.clubId, self.channel.streamId, frame)
    end)

    ChatFrame_AddMessageEventFilter("CHAT_MSG_COMMUNITIES_CHANNEL", suppressRelayChat)

    self:RegisterEvent("CLUB_MESSAGE_ADDED")
    self:RegisterEvent("INITIAL_CLUBS_LOADED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_ADDED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_REMOVED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_STREAMS_LOADED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_STREAM_SUBSCRIBED", self.OnClubsChanged)

    Relay:RegisterBackend(self)
    self:OnClubsChanged()

    -- Clubs are usually still loading at PLAYER_LOGIN.
    C_Timer.After(5, function() self:OnClubsChanged() end)
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

--- Every monitored community and what we know about it, for `/erp clubs`.
function ClubLink:ListChannels()
    local out = {}
    for channelKey, channel in pairs(monitored) do
        out[#out + 1] = {
            clubName = channel.clubName,
            streamName = channel.streamName,
            dedicated = channel.dedicated,
            active = active[channelKey] == true,
            sending = self.channel ~= nil
                and self.channel.clubId == channel.clubId
                and self.channel.streamId == channel.streamId,
        }
    end
    table.sort(out, function(a, b) return (a.clubName or "") < (b.clubName or "") end)
    return out
end
