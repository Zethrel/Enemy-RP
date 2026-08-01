-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Chat/Outbound.lua
-- Puts the player's own say, emote and yell on the relay.
--
-- This listens for the chat events rather than hooking SendChatMessage. The
-- events fire on what the server actually accepted, which means muted, throttled
-- and filtered messages never reach the relay, and messages sent by other addons
-- are picked up for free.

local ADDON, ns = ...

local Outbound = ns:NewModule("ChatOut")
ns.ChatOut = Outbound

local Relay = ns.Relay
local Protocol = ns.Protocol
local Cache = ns.Cache
local Geo = ns.Geo
local Util = ns.Util

-- Anyone heard from on our map inside this window counts as a potential
-- listener. Comfortably longer than a heartbeat interval so a quiet peer does
-- not flicker in and out of existence.
local LISTENER_WINDOW = 300

local sentTimes = {}

--------------------------------------------------------------------------------
-- Gating
--------------------------------------------------------------------------------

--- Broadcasting every line of a roleplay session to a community where no other
--- faction is present is pure noise. Cheap to check, and heartbeats keep the
--- roster current regardless of whether anyone is talking.
function Outbound:HasListeners()
    if not ns.db.chatOnlyWhenListeners then return true end

    local mapId = C_Map.GetBestMapForUnit("player")
    local myFaction = Util.PlayerFactionCode()

    for _, entry in ipairs(Cache:Roster(LISTENER_WINDOW)) do
        if entry.faction ~= myFaction and entry.map == mapId then return true end
    end
    return false
end

--- Our own flood protection, independent of the transport queue: a stuck macro
--- should not be able to fill a shared community channel.
local function withinBudget()
    local limit = ns.db.chatMessagesPerMinute or 30
    local now = GetTime()

    for index = #sentTimes, 1, -1 do
        if now - sentTimes[index] > 60 then table.remove(sentTimes, index) end
    end

    if #sentTimes >= limit then return false end
    sentTimes[#sentTimes + 1] = now
    return true
end

--------------------------------------------------------------------------------
-- Capture
--------------------------------------------------------------------------------

function Outbound:Relay(chatType, text)
    if not ns.db.enabled or not ns.db.chatEnabled then return false end
    if not ns.db.chatSend[chatType] then return false end
    if type(text) ~= "string" or text == "" then return false end

    local mapId, x, y = Geo.PlayerPosition()
    if not mapId then
        ns:Debug("chat not relayed: no map position here")
        return false
    end

    if not self:HasListeners() then
        ns:Debug("chat not relayed: nobody from the other faction is nearby")
        return false
    end

    if not withinBudget() then
        ns:Debug("chat not relayed: sending too fast")
        return false
    end

    local kind = Protocol.CHAT_KIND[chatType]
    return Relay:Broadcast(Protocol.OPCODE.CHAT,
        Protocol.EncodeChat(kind, mapId, x, y, text))
end

-- The chat events place the speaker's GUID at argument 12.
function Outbound:Capture(chatType, text, _, _, _, _, _, _, _, _, _, _, guid)
    if guid ~= UnitGUID("player") then return end
    self:Relay(chatType, text)
end

function Outbound:CHAT_MSG_SAY(...) self:Capture("SAY", ...) end
function Outbound:CHAT_MSG_EMOTE(...) self:Capture("EMOTE", ...) end
function Outbound:CHAT_MSG_YELL(...) self:Capture("YELL", ...) end

-- Predefined emotes (/wave, /bow) arrive already rendered as a sentence naming
-- the character, so they travel verbatim and are displayed unchanged.
function Outbound:CHAT_MSG_TEXT_EMOTE(...) self:Capture("TEXT_EMOTE", ...) end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Outbound:OnEnable()
    self:RegisterEvent("CHAT_MSG_SAY")
    self:RegisterEvent("CHAT_MSG_EMOTE")
    self:RegisterEvent("CHAT_MSG_YELL")
    self:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
end
