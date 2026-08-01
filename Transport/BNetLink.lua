-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Transport/BNetLink.lua
-- Direct backend for Battle.net friends. Addon payloads sent this way ignore
-- faction entirely, so two friends can exchange profiles with no community at
-- all -- and when a community is configured, this route still wins for anyone
-- on the friends list because it is point to point instead of a broadcast.

local ADDON, ns = ...

local BNetLink = ns:NewModule("BNetLink")
ns.BNetLink = BNetLink

local Relay = ns.Relay
local Util = ns.Util

BNetLink.name = "bnet"

local PREFIX = "ERP1"

-- "Name-Realm" -> Battle.net game account id of a friend currently on that
-- character. Rebuilt from the friends list; never persisted, since game account
-- ids are only meaningful for the current session.
local routes = {}

--------------------------------------------------------------------------------
-- Friends list
--------------------------------------------------------------------------------

--- The friends list reports realms as they are displayed ("Moon Guard"), while
--- every other name in this addon is normalized ("MoonGuard").
local function normalizeRealm(realm)
    if not realm then return nil end
    return (realm:gsub("[%s%p]", ""))
end

function BNetLink:RefreshRoutes()
    wipe(routes)

    local total = BNGetNumFriends and BNGetNumFriends() or 0
    for index = 1, total do
        local accountInfo = C_BattleNet.GetFriendAccountInfo(index)
        if accountInfo then
            local numGameAccounts = C_BattleNet.GetFriendNumGameAccounts(index) or 0
            for gameIndex = 1, numGameAccounts do
                local game = C_BattleNet.GetFriendGameAccountInfo(index, gameIndex)
                if game
                    and game.clientProgram == BNET_CLIENT_WOW
                    and game.wowProjectID == WOW_PROJECT_MAINLINE
                    and game.isOnline
                    and game.characterName
                    and game.gameAccountID
                then
                    local realm = normalizeRealm(game.realmName) or GetNormalizedRealmName()
                    routes[game.characterName .. "-" .. realm] = game.gameAccountID
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Backend interface
--------------------------------------------------------------------------------

function BNetLink:IsReady()
    return ns.db.useBattleNetFriends == true
end

-- No broadcast: spamming every friend on every heartbeat would be rude and slow.
BNetLink.CanBroadcast = nil

function BNetLink:CanReach(fullName)
    return routes[fullName] ~= nil
end

function BNetLink:SendTo(fullName, frame)
    local gameAccountID = routes[fullName]
    if not gameAccountID then return end
    self.queue:Push(gameAccountID, frame)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function BNetLink:BN_CHAT_MSG_ADDON(prefix, text, _, sender)
    if prefix ~= PREFIX then return end
    Relay:Incoming(text, { backend = self.name, bnetSender = sender })
end

function BNetLink:OnFriendsChanged()
    if self.refreshPending then return end
    self.refreshPending = true
    -- The friends list fires in bursts during login and zoning.
    C_Timer.After(2, function()
        self.refreshPending = false
        self:RefreshRoutes()
    end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function BNetLink:OnEnable()
    self.queue = Util.NewQueue(3, 6, function(gameAccountID, frame)
        BNSendGameData(gameAccountID, PREFIX, frame)
    end)

    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

    self:RegisterEvent("BN_CHAT_MSG_ADDON")
    self:RegisterEvent("BN_FRIEND_INFO_CHANGED", self.OnFriendsChanged)
    self:RegisterEvent("BN_FRIEND_ACCOUNT_ONLINE", self.OnFriendsChanged)
    self:RegisterEvent("BN_FRIEND_ACCOUNT_OFFLINE", self.OnFriendsChanged)
    self:RegisterEvent("FRIENDLIST_UPDATE", self.OnFriendsChanged)

    Relay:RegisterBackend(self)
    self:RefreshRoutes()
end

function BNetLink:RouteCount()
    local count = 0
    for _ in pairs(routes) do count = count + 1 end
    return count
end
