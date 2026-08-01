-- Transport/ClubLink.lua
-- Battle.net community backend: the only channel in the game that carries data
-- between an Alliance and a Horde character who are not grouped.
--
-- The community is ordinary chat as far as the server is concerned, so relay
-- frames would show up in the player's chat window. Two things prevent that:
-- a chat message filter for the docked frames, and a preference for a dedicated
-- stream (one named "relay") that nobody reads by hand.

local ADDON, ns = ...

local ClubLink = ns:NewModule("ClubLink")
ns.ClubLink = ClubLink

local Relay = ns.Relay
local Protocol = ns.Protocol
local Util = ns.Util

ClubLink.name = "community"

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

local function findClub()
    local wanted = ns.db.clubName
    local pinnedId = ns.db.clubId

    local clubs = C_Club.GetSubscribedClubs()
    if not clubs then return nil end

    for _, club in ipairs(clubs) do
        if club.clubType == Enum.ClubType.BattleNet then
            if pinnedId and club.clubId == pinnedId then return club end
            if wanted and club.name and club.name:lower() == wanted:lower() then return club end
        end
    end
    return nil
end

local function findStream(clubId)
    local streams = C_Club.GetStreams(clubId)
    if not streams then return nil end

    local wanted = ns.db.streamName
    local general, relay

    for _, stream in ipairs(streams) do
        local streamName = (stream.name or ""):lower()
        if wanted and streamName == wanted:lower() then return stream end
        if streamName == "relay" then relay = stream end
        if stream.streamType == Enum.ClubStreamType.General then general = stream end
    end

    -- A dedicated stream keeps relay traffic out of whatever channel members
    -- actually read; general is the fallback so the addon still works untuned.
    return relay or general
end

function ClubLink:Resolve()
    local club = findClub()
    if not club then
        self.clubId, self.streamId = nil, nil
        return false
    end

    local stream = findStream(club.clubId)
    if not stream then
        self.clubId, self.streamId = nil, nil
        return false
    end

    local changed = self.clubId ~= club.clubId or self.streamId ~= stream.streamId
    self.clubId, self.streamId = club.clubId, stream.streamId
    self.clubDisplayName = club.name
    self.streamDisplayName = stream.name

    -- Persist the club id so a renamed community keeps working. The stream is
    -- deliberately not persisted: re-deriving it every login is cheap and
    -- cannot go stale against a club the id no longer belongs to.
    ns.db.clubId = club.clubId

    if changed then
        ns:Debug("relay bound to %s / %s", club.name or "?", stream.name or "?")
        self:Focus()
    end
    return true
end

--- CLUB_MESSAGE_ADDED only fires for focused streams, so the addon has to focus
--- the relay stream itself rather than relying on the Communities UI.
function ClubLink:Focus()
    if not self.clubId then return end
    pcall(C_Club.FocusStream, self.clubId, self.streamId)
end

--------------------------------------------------------------------------------
-- Backend interface
--------------------------------------------------------------------------------

function ClubLink:IsReady()
    return self.clubId ~= nil and self.streamId ~= nil
end

function ClubLink:CanBroadcast()
    return true
end

function ClubLink:Broadcast(frame)
    self.queue:Push(frame)
end

-- A community reaches everyone in it, but not by character name: the club knows
-- Battle.net accounts, not who is logged in. Directed sends stay with BNetLink.
ClubLink.CanReach = nil

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function ClubLink:CLUB_MESSAGE_ADDED(clubId, streamId, messageId)
    if clubId ~= self.clubId or streamId ~= self.streamId then return end

    local info = C_Club.GetMessageInfo(clubId, streamId, messageId)
    if not info or not info.content then return end

    Relay:Incoming(info.content, {
        backend = self.name,
        clubId = clubId,
        author = info.author,
    })

    -- Keep the relay stream from accumulating an unread badge.
    pcall(C_Club.AdvanceStreamViewMarker, clubId, streamId)
end

function ClubLink:CLUB_STREAM_SUBSCRIBED(clubId, streamId)
    if clubId == self.clubId and streamId == self.streamId then self:Focus() end
end

function ClubLink:OnClubsChanged()
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
        if not self:IsReady() then return end
        C_Club.SendMessage(self.clubId, self.streamId, frame)
    end)

    ChatFrame_AddMessageEventFilter("CHAT_MSG_COMMUNITIES_CHANNEL", suppressRelayChat)

    self:RegisterEvent("CLUB_MESSAGE_ADDED")
    self:RegisterEvent("CLUB_STREAM_SUBSCRIBED")
    self:RegisterEvent("INITIAL_CLUBS_LOADED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_ADDED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_REMOVED", self.OnClubsChanged)
    self:RegisterEvent("CLUB_STREAMS_LOADED", self.OnClubsChanged)

    Relay:RegisterBackend(self)
    self:Resolve()

    -- Clubs are often still loading at PLAYER_LOGIN.
    C_Timer.After(5, function() self:Resolve() end)
end

--- Candidate communities for `/erp clubs`.
function ClubLink:ListCandidates()
    local out = {}
    local clubs = C_Club.GetSubscribedClubs() or {}
    for _, club in ipairs(clubs) do
        if club.clubType == Enum.ClubType.BattleNet then
            out[#out + 1] = { clubId = club.clubId, name = club.name, members = club.memberCount }
        end
    end
    return out
end
