-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Chat/Inbound.lua
-- Shows relayed chat from the other faction.
--
-- This is the least trusted path in the addon. Everything else it receives ends
-- up in a cache or a profile field; this ends up rendered in the player's chat
-- frame, where an unescaped `|H` would become a clickable link of the sender's
-- choosing. Text is therefore stripped of every escape sequence before display,
-- keeping the readable part of links and discarding the rest.
--
-- None of it is authenticated. A community member can claim any name and any
-- position. Range checks and rate limits make relayed chat behave, they do not
-- make it trustworthy.

local ADDON, ns = ...

local Inbound = ns:NewModule("ChatIn")
ns.ChatIn = Inbound

local Protocol = ns.Protocol
local Cache = ns.Cache
local Geo = ns.Geo
local Util = ns.Util

local MAX_DISPLAY_LENGTH = 500

-- A roleplay name is peer-supplied too. Nothing stops someone setting a
-- thousand-character one, and it would land in everybody's chat frame.
local MAX_NAME_LENGTH = 40

local FACTION_COLOR = {
    A = "|cff4080ff",
    H = "|cffff4040",
    N = "|cffffff00",
}

local heard = {} -- sender -> array of receive times, for rate limiting

--------------------------------------------------------------------------------
-- Sanitizing
--------------------------------------------------------------------------------

--- Render peer-supplied text inert while keeping it readable.
---
--- Chat arriving from the server is sanitized by the client; text an addon
--- passes to AddMessage is not. Colour codes and textures are dropped, and
--- hyperlinks collapse to the text they displayed, so `|Hitem:...|h[Sword]|h`
--- becomes `[Sword]`. Whatever survives cannot be an escape sequence.
function Inbound.Sanitize(text)
    if type(text) ~= "string" then return "" end

    text = text:gsub("%c", " ")
    text = text:gsub("|[cC]%x%x%x%x%x%x%x%x", "")
    text = text:gsub("|[rR]", "")
    text = text:gsub("|[Hh].-|[Hh](.-)|[Hh]", "%1")
    text = text:gsub("|[Tt].-|[Tt]", "")
    text = text:gsub("|[Aa].-|[Aa]", "")

    -- What remains is either `||`, which AddMessage renders as one literal
    -- pipe, or a lone pipe that would swallow the character after it. Park the
    -- well-formed pairs, drop the rest, put the pairs back: the result can
    -- still show a pipe but can no longer open an escape sequence. \1 is safe
    -- as a placeholder because control characters were removed above.
    text = text:gsub("||", "\1")
    text = text:gsub("|", "")
    text = text:gsub("\1", "||")

    if #text > MAX_DISPLAY_LENGTH then
        text = text:sub(1, MAX_DISPLAY_LENGTH) .. "..."
    end
    return text
end

--------------------------------------------------------------------------------
-- Gating
--------------------------------------------------------------------------------

local function withinBudget(sender)
    local limit = ns.db.chatMessagesPerMinute or 30
    local now = GetTime()

    local times = heard[sender]
    if not times then
        times = {}
        heard[sender] = times
    end

    for index = #times, 1, -1 do
        if now - times[index] > 60 then table.remove(times, index) end
    end

    if #times >= limit then return false end
    times[#times + 1] = now
    return true
end

local function isIgnored(sender)
    local ok, ignored = pcall(C_FriendList.IsIgnored, Util.ShortName(sender))
    return ok and ignored
end

--- Flavour gate: without the elixir, the other faction stays unintelligible.
local function canUnderstand()
    if not ns.db.requireTongues then return true end
    local spellId = ns.db.tonguesSpellId
    if not spellId then return true end

    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
    return ok and aura ~= nil
end

local function inRange(chatType, mapId, x, y)
    local limit = (chatType == "YELL") and (ns.db.chatRangeYell or 300)
        or (ns.db.chatRangeSay or 40)

    local distance = Geo.DistanceFromPlayer(mapId, x, y)
    -- An immeasurable distance means a different continent or a map the client
    -- cannot place; either way the speaker is not within earshot.
    if not distance then return false end
    return distance <= limit
end

--------------------------------------------------------------------------------
-- Display
--------------------------------------------------------------------------------

local function speakerName(sender, faction)
    local record = Cache:Get(sender)
    local name = record and record.fields and record.fields.NA
    name = Inbound.Sanitize(name or Util.ShortName(sender))
    if name == "" then name = Util.ShortName(sender) end
    if #name > MAX_NAME_LENGTH then name = name:sub(1, MAX_NAME_LENGTH) .. "..." end

    return (FACTION_COLOR[faction] or FACTION_COLOR.N) .. name .. "|r"
end

--- Blizzard's chat templates take the speaker and, in some locales, the message
--- too. Counting the placeholders keeps this working either way.
local function applyTemplate(template, fallback, name, text)
    template = (type(template) == "string" and template ~= "") and template or fallback

    local _, placeholders = template:gsub("%%s", "")
    local ok, line
    if placeholders >= 2 then
        ok, line = pcall(string.format, template, name, text)
    else
        ok, line = pcall(string.format, template, name)
        if ok then line = line .. text end
    end

    if not ok or not line then return fallback:format(name) .. text end
    return line
end

local function formatLine(chatType, name, text)
    if chatType == "TEXT_EMOTE" then return text end
    if chatType == "EMOTE" then
        return applyTemplate(CHAT_EMOTE_GET, "%s ", name, text)
    end
    if chatType == "YELL" then
        return applyTemplate(CHAT_YELL_GET, "%s yells: ", name, text)
    end
    return applyTemplate(CHAT_SAY_GET, "%s says: ", name, text)
end

--- Deliver to whichever chat windows the player has set up for that chat type,
--- so relayed say lands wherever their real say lands.
local function emit(chatType, line)
    local info = ChatTypeInfo and ChatTypeInfo[chatType] or { r = 1, g = 1, b = 1 }
    local event = "CHAT_MSG_" .. chatType
    local delivered = false

    for _, frameName in ipairs(CHAT_FRAMES or {}) do
        local chatFrame = _G[frameName]
        if chatFrame and chatFrame.IsEventRegistered and chatFrame:IsEventRegistered(event) then
            chatFrame:AddMessage(line, info.r, info.g, info.b)
            delivered = true
        end
    end

    if not delivered then
        DEFAULT_CHAT_FRAME:AddMessage(line, info.r, info.g, info.b)
    end
end

--------------------------------------------------------------------------------
-- Receipt
--------------------------------------------------------------------------------

function Inbound:OnRELAY_MESSAGE(sender, faction, opcode, payload)
    if opcode ~= Protocol.OPCODE.CHAT then return end
    if not ns.db.chatEnabled then return end

    -- Same-faction speakers are already audible through the game's own chat;
    -- relaying them would show every line twice.
    if faction == Util.PlayerFactionCode() then return end

    local chatType, mapId, x, y, text = Protocol.DecodeChat(payload)
    if not chatType then return end
    if not ns.db.chatShow[chatType] then return end

    if not withinBudget(sender) then
        ns:Debug("dropping chat flood from %s", sender)
        return
    end
    if isIgnored(sender) then return end
    if not inRange(chatType, mapId, x, y) then return end
    if not canUnderstand() then return end

    text = Inbound.Sanitize(text)
    if text == "" then return end

    -- Keep the roster honest about where people are, but only for characters a
    -- heartbeat already vouched for -- otherwise chat alone could fill the
    -- cache with names nobody has ever seen.
    local record = Cache:Get(sender)
    if record then
        record.seen = time()
        record.map = mapId
    end

    local line = (ns.db.chatPrefix or "") .. formatLine(chatType, speakerName(sender, faction), text)
    emit(chatType, line)

    ns:Fire("CHAT_RELAYED", sender, chatType)
end

function Inbound:OnEnable()
    self:Listen("RELAY_MESSAGE")
end
