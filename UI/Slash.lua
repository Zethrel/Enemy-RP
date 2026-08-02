-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- UI/Slash.lua
-- /erp command surface. Configuration lives here rather than in an options
-- panel because the settings that matter are one-time (which community to use)
-- and are easier to paste to a guild than to describe as a click path.

local ADDON, ns = ...

local Slash = ns:NewModule("Slash")

local Util = ns.Util
local Cache = ns.Cache
local Bridge = ns.Bridge

local function usage()
    ns:Print("commands:")
    ns:Print("  |cffffff00/erp|r - show the roster window")
    ns:Print("  |cffffff00/erp status|r - connection and cache summary")
    ns:Print("  |cffffff00/erp clubs|r - list Battle.net communities you belong to")
    ns:Print("  |cffffff00/erp club <name>|r - use that community as the relay")
    ns:Print("  |cffffff00/erp stream <name>|r - use a specific channel in it")
    ns:Print("  |cffffff00/erp who|r - characters seen in the last 10 minutes")
    ns:Print("  |cffffff00/erp fetch <name>|r - request a full profile now")
    ns:Print("  |cffffff00/erp forget <name>|r - drop a cached profile")
    ns:Print("  |cffffff00/erp on|r / |cffffff00off|r - enable or disable the relay")
    ns:Print("  |cffffff00/erp chat|r - cross-faction chat settings")
    ns:Print("  |cffffff00/erp debug|r - toggle verbose logging")
    ns:Print("  |cffffff00/erp reset|r - restore defaults and clear the cache")
end

local CHAT_TYPES = { say = "SAY", emote = "EMOTE", yell = "YELL", textemote = "TEXT_EMOTE" }

local function chatUsage()
    ns:Print("chat relay is %s",
        ns.db.chatEnabled and "|cff40ff40on|r" or "|cffff4040off|r")

    local sending, showing = {}, {}
    for word, chatType in pairs(CHAT_TYPES) do
        if ns.db.chatSend[chatType] then sending[#sending + 1] = word end
        if ns.db.chatShow[chatType] then showing[#showing + 1] = word end
    end
    table.sort(sending)
    table.sort(showing)

    ns:Print("  sending: %s", #sending > 0 and table.concat(sending, ", ") or "nothing")
    ns:Print("  showing: %s", #showing > 0 and table.concat(showing, ", ") or "nothing")
    ns:Print("  range: %d yards, %d for yells", ns.db.chatRangeSay, ns.db.chatRangeYell)
    ns:Print("  elixir of tongues required: %s", ns.db.requireTongues and "yes" or "no")
    ns:Print("|cffffff00/erp chat on|off|r, |cffffff00send <type>|r, |cffffff00show <type>|r,")
    ns:Print("|cffffff00range <yards>|r, |cffffff00prefix <text>|r, |cffffff00tongues|r")
    ns:Print("types: say, emote, yell, textemote")
end

local function chatCommand(argument)
    local word, rest = argument:match("^(%S*)%s*(.-)$")
    word = word:lower()

    if word == "" then
        chatUsage()
    elseif word == "on" or word == "off" then
        ns.db.chatEnabled = (word == "on")
        ns:Print("chat relay %s", word)
    elseif word == "send" or word == "show" then
        local chatType = CHAT_TYPES[rest:lower()]
        if not chatType then
            ns:Print("|cffff4040unknown chat type '%s'|r - say, emote, yell, textemote", rest)
            return
        end
        local setting = (word == "send") and ns.db.chatSend or ns.db.chatShow
        setting[chatType] = not setting[chatType]
        ns:Print("%s %s: %s", word == "send" and "sending" or "showing",
            rest:lower(), setting[chatType] and "on" or "off")
    elseif word == "range" then
        local yards = tonumber(rest)
        if not yards or yards <= 0 then
            ns:Print("usage: /erp chat range <yards>")
            return
        end
        ns.db.chatRangeSay = yards
        ns:Print("say and emote range set to %d yards", yards)
    elseif word == "prefix" then
        ns.db.chatPrefix = rest
        ns:Print("prefix set to '%s'", rest)
    elseif word == "tongues" then
        ns.db.requireTongues = not ns.db.requireTongues
        ns:Print("elixir of tongues %s",
            ns.db.requireTongues and "now required to understand the other faction"
            or "no longer required")
    else
        chatUsage()
    end
end

local function status()
    ns:Print("version %s, protocol %d, relay %s",
        ns.VERSION, ns.PROTOCOL, ns.db.enabled and "|cff40ff40on|r" or "|cffff4040off|r")

    local host = Bridge:HostAddon()
    ns:Print("roleplay addon: %s", host or "|cffff4040none detected|r")

    local channels = ns.ClubLink:ListChannels()
    local sending = ns.ClubLink.channel
    if sending then
        ns:Print("community: |cff40ff40%s|r / %s (listening on %d)",
            sending.clubName or "?", sending.streamName or "?", #channels)
    elseif #channels > 0 then
        ns:Print("community: listening on %d, |cffffff00none to send to yet|r - /erp clubs",
            #channels)
    else
        ns:Print("community: |cffffff00none joined|r")
    end

    ns:Print("chat relay: %s", ns.db.chatEnabled and "|cff40ff40on|r" or "|cffff4040off|r")
    ns:Print("group: %s, guild: %s, battle.net friends: %d",
        ns.AddonLink.Group:IsReady()
            and ("|cff40ff40" .. ns.AddonLink:GroupCount() .. " nearby|r") or "not grouped",
        ns.AddonLink.Guild:IsReady()
            and ("|cff40ff40" .. ns.AddonLink:GuildCount() .. " online|r") or "none",
        ns.BNetLink:RouteCount())
    ns:Print("cached profiles: %d, transfers in progress: %d",
        Cache:Count(), ns.Chunker:PendingCount())
end

local function listClubs()
    local channels = ns.ClubLink:ListChannels()
    if #channels == 0 then
        ns:Print("you are not in any Battle.net communities.")
        ns:Print("join one that other Enemy RP users are in and it will be picked")
        ns:Print("up automatically -- no command needed.")
        return
    end

    ns:Print("listening on %d Battle.net %s:",
        #channels, #channels == 1 and "community" or "communities")
    for _, channel in ipairs(channels) do
        local state
        if channel.sending then
            state = "|cff40ff40sending here|r"
        elseif channel.active then
            state = "|cffffff00relay traffic seen|r"
        elseif channel.dedicated then
            state = "|cff80c0ffdedicated relay channel|r"
        else
            state = "|cff808080listening only|r"
        end
        ns:Print("  %s / %s - %s", channel.clubName or "?", channel.streamName or "?", state)
    end

    if not ns.ClubLink.channel then
        ns:Print("|cff808080nothing is sent into a community until relay traffic is seen")
        ns:Print("there, or the channel is named 'relay', or you name one with")
        ns:Print("/erp club <name>.|r")
    end
end

local function who()
    local roster = Cache:Roster(600)
    if #roster == 0 then
        ns:Print("nobody seen recently.")
        return
    end
    ns:Print("seen in the last 10 minutes:")
    for _, entry in ipairs(roster) do
        local mapName = entry.map and C_Map.GetMapInfo(entry.map)
        ns:Print("  %s%s|r (%s)%s",
            entry.faction == "H" and "|cffff4040" or "|cff4080ff",
            entry.fullName,
            mapName and mapName.name or "unknown",
            entry.hasProfile and "" or " |cff808080no profile yet|r")
    end
end

local handlers = {}

handlers.status = status
handlers.clubs = listClubs
handlers.who = who
handlers.chat = chatCommand

handlers.club = function(argument)
    if argument == "" then
        ns:Print("usage: /erp club <community name>")
        return
    end
    ns.db.clubName = argument
    ns.db.clubId = nil
    ns.ClubLink:OnClubsChanged()
    local channel = ns.ClubLink.channel
    if channel then
        ns:Print("relaying through |cff40ff40%s|r / %s",
            channel.clubName or "?", channel.streamName or "?")
    else
        ns:Print("|cffff4040no Battle.net community named '%s'|r - try /erp clubs", argument)
    end
end

handlers.stream = function(argument)
    ns.db.streamName = argument ~= "" and argument or nil
    ns.ClubLink:OnClubsChanged()
    local channel = ns.ClubLink.channel
    if channel then
        ns:Print("using channel %s", channel.streamName or "?")
    else
        ns:Print("|cffff4040could not bind that channel|r")
    end
end

handlers.fetch = function(argument)
    local fullName = Util.QualifyName(argument)
    if not fullName then
        ns:Print("usage: /erp fetch <name>")
        return
    end
    if ns.Sync:RequestFull(fullName, true) then
        ns:Print("requested %s", fullName)
    else
        ns:Print("|cffff4040no way to reach %s right now|r", fullName)
    end
end

handlers.forget = function(argument)
    local fullName = Util.QualifyName(argument)
    if not fullName then return end
    Cache:Forget(fullName)
    ns:Fire("ROSTER_UPDATED")
    ns:Print("forgot %s", fullName)
end

handlers.on = function()
    ns.db.enabled = true
    ns:Print("relay enabled.")
end

handlers.off = function()
    ns.db.enabled = false
    ns:Print("relay disabled.")
end

handlers.debug = function()
    ns.db.debug = not ns.db.debug
    ns:Print("debug logging %s", ns.db.debug and "on" or "off")
end

handlers.reset = function()
    ns.Config:Reset()
    ns:Fire("ROSTER_UPDATED")
    ns:Print("settings and cache reset.")
end

handlers.help = usage

function Slash:OnEnable()
    SLASH_ENEMYRP1 = "/erp"
    SLASH_ENEMYRP2 = "/enemyrp"

    SlashCmdList.ENEMYRP = function(input)
        local command, argument = (input or ""):match("^(%S*)%s*(.-)%s*$")
        command = (command or ""):lower()

        if command == "" then
            ns.Roster:Toggle()
            return
        end

        local handler = handlers[command]
        if handler then
            handler(argument or "")
        else
            ns:Print("|cffff4040unknown command '%s'|r", command)
            usage()
        end
    end
end
