-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- tests/wow.lua
-- A small stand-in for the parts of the WoW client this addon touches, so the
-- protocol can be exercised outside the game. It is not a general purpose
-- emulator: it implements exactly the API surface the addon uses, and it lets a
-- test spin up several independent "clients" that talk to each other.

local wow = {}

--------------------------------------------------------------------------------
-- Shared world state
--------------------------------------------------------------------------------

local world = {
    clock = 1000,
    clients = {},
    clubMessages = {},   -- messageId -> { clubId, streamId, content }
    nextMessageId = 1,
    bnetMessages = 0,
    timers = {},
    nextTimerId = 1,
}
wow.world = world

function wow.reset()
    world.clock = 1000
    world.clients = {}
    world.clubMessages = {}
    world.nextMessageId = 1
    world.bnetMessages = 0
    world.timers = {}
end

--- Run every timer due within `seconds`, stepping the clock as it goes so
--- handlers observe a plausible passage of time.
function wow.advance(seconds)
    local target = world.clock + seconds
    while true do
        local soonest, soonestIndex
        for index, timer in pairs(world.timers) do
            if timer.at <= target and (not soonest or timer.at < soonest.at) then
                soonest, soonestIndex = timer, index
            end
        end
        if not soonest then break end

        world.clock = math.max(world.clock, soonest.at)
        if soonest.interval then
            soonest.at = world.clock + soonest.interval
        else
            world.timers[soonestIndex] = nil
        end
        soonest.callback()
    end
    world.clock = target
end

local function schedule(delay, callback, interval)
    local id = world.nextTimerId
    world.nextTimerId = id + 1
    world.timers[id] = { at = world.clock + delay, callback = callback, interval = interval }
    return id
end

--------------------------------------------------------------------------------
-- Bit library (Lua 5.1 has none; the addon only needs bxor)
--------------------------------------------------------------------------------

local function bxor(a, b)
    a, b = a % 4294967296, b % 4294967296
    local result, bitValue = 0, 1
    for _ = 1, 32 do
        local aBit, bBit = a % 2, b % 2
        if aBit ~= bBit then result = result + bitValue end
        a, b = (a - aBit) / 2, (b - bBit) / 2
        bitValue = bitValue * 2
    end
    -- The real bit library returns a signed 32-bit value; matching that keeps
    -- the addon's normalization path under test.
    if result >= 2147483648 then result = result - 4294967296 end
    return result
end

--------------------------------------------------------------------------------
-- Client construction
--------------------------------------------------------------------------------

local INHERITED = {
    "string", "table", "math", "os", "pairs", "ipairs", "type", "tostring",
    "tonumber", "select", "pcall", "xpcall", "assert", "error", "next", "unpack",
    "setmetatable", "getmetatable", "rawget", "rawset", "print", "loadstring",
}

local function newFrame(env)
    local frame = { events = {}, scripts = {}, points = {}, shown = false }

    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:SetScript(name, handler) self.scripts[name] = handler end
    function frame:GetScript(name) return self.scripts[name] end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:IsShown() return self.shown end

    -- Layout and decoration calls are no-ops: the tests never render anything.
    local noop = function() end
    for _, method in ipairs({
        "SetSize", "SetPoint", "SetMovable", "EnableMouse", "RegisterForDrag",
        "SetClampedToScreen", "SetHeight", "SetWidth", "SetText", "SetJustifyH",
        "SetHighlightTexture", "EnableMouseWheel", "SetShown", "StartMoving",
        "StopMovingOrSizing", "SetTitle", "CreateFontString", "SetOwner",
        "AddLine",
    }) do
        frame[method] = noop
    end
    frame.CreateFontString = function() return newFrame(env) end

    env.__frames[#env.__frames + 1] = frame
    return frame
end

--- Create one simulated game client. `spec` carries name, realm, faction and
--- the msp profile the client should advertise.
function wow.newClient(spec)
    local env = {}
    env.__frames = {}
    env.__spec = spec
    env._G = env

    for _, key in ipairs(INHERITED) do env[key] = _G[key] end

    env.bit = { bxor = bxor }
    env.GetTime = function() return world.clock end
    env.time = function() return math.floor(world.clock) + 1700000000 end
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.strsplit = function() error("strsplit is not stubbed; use string.match") end

    env.DEFAULT_CHAT_FRAME = {
        AddMessage = function(_, message)
            if env.__verbose then print(("[%s] %s"):format(spec.name, message)) end
        end,
    }

    env.C_AddOns = { GetAddOnMetadata = function() return "0.1.0-test" end }

    ---------------------------------------------------------------- identity --
    env.UnitName = function(unit) return unit == "player" and spec.name or nil end
    env.UnitFullName = function(unit)
        if unit == "player" then return spec.name, spec.normalizedRealm end
        local peer = spec.units and spec.units[unit]
        return peer and peer.name, peer and peer.realm
    end
    env.UnitIsPlayer = function(unit)
        return unit == "player" or (spec.units and spec.units[unit]) ~= nil
    end
    env.UnitFactionGroup = function(unit)
        if unit == "player" then return spec.faction end
        local peer = spec.units and spec.units[unit]
        return peer and peer.faction
    end
    env.GetNormalizedRealmName = function() return spec.normalizedRealm end

    ------------------------------------------------------------------ frames --
    env.CreateFrame = function() return newFrame(env) end
    env.UIParent = {}
    env.UISpecialFrames = {}
    env.GameTooltip = newFrame(env)
    env.GameTooltip_Hide = function() end
    env.ChatFrame_AddMessageEventFilter = function(_, filter)
        env.__chatFilter = filter
    end
    env.SlashCmdList = {}

    ------------------------------------------------------------------- chat ---
    env.UnitGUID = function(unit)
        return unit == "player" and ("Player-" .. spec.name) or nil
    end
    env.ChatTypeInfo = {
        SAY = { r = 1, g = 1, b = 1 },
        EMOTE = { r = 1, g = 0.5, b = 0.25 },
        YELL = { r = 1, g = 0.25, b = 0.25 },
        TEXT_EMOTE = { r = 1, g = 0.5, b = 0.25 },
    }
    env.CHAT_SAY_GET = "%s says: "
    env.CHAT_YELL_GET = "%s yells: "
    env.CHAT_EMOTE_GET = "%s "
    env.C_FriendList = {
        IsIgnored = function(name) return (spec.ignored or {})[name] == true end,
    }
    env.C_UnitAuras = {
        GetPlayerAuraBySpellID = function(spellId)
            return spec.auras and spec.auras[spellId] or nil
        end,
    }

    -- One chat window, registered for every relayed chat type, recording what
    -- it was asked to display.
    env.__chatLog = {}
    env.CHAT_FRAMES = { "ChatFrame1" }
    env.ChatFrame1 = {
        IsEventRegistered = function(_, event)
            return event:match("^CHAT_MSG_") ~= nil
        end,
        AddMessage = function(_, line)
            env.__chatLog[#env.__chatLog + 1] = line
        end,
    }

    ------------------------------------------------------------------ timers --
    env.C_Timer = {
        After = function(delay, callback) schedule(delay, callback) end,
        NewTicker = function(interval, callback)
            schedule(interval, callback, interval)
            return { Cancel = function() end }
        end,
    }

    -------------------------------------------------------------------- maps --
    -- Maps live on a continent and scale map units to yards. Two points 0.01
    -- apart on map 84 are therefore 10 yards apart, which makes range
    -- assertions readable.
    local MAPS = {
        [84] = { continent = 13, scale = 1000 },   -- Stormwind
        [85] = { continent = 13, scale = 1000 },   -- Orgrimmar, same continent
        [1] = { continent = 12, scale = 1000 },    -- somewhere else entirely
    }

    env.CreateVector2D = function(x, y)
        return { x = x, y = y, GetXY = function(self) return self.x, self.y end }
    end

    env.C_Map = {
        GetBestMapForUnit = function() return spec.mapId or 84 end,
        GetMapInfo = function(id) return { name = "Map " .. tostring(id) } end,
        GetPlayerMapPosition = function(_, unit)
            if unit ~= "player" or not spec.position then return nil end
            return env.CreateVector2D(spec.position.x, spec.position.y)
        end,
        GetWorldPosFromMapPos = function(mapId, position)
            local map = MAPS[mapId]
            if not map then return nil end
            local x, y = position:GetXY()
            return map.continent, env.CreateVector2D(x * map.scale, y * map.scale)
        end,
    }

    ------------------------------------------------------------------- clubs --
    env.Enum = {
        ClubType = { BattleNet = 1, Character = 2, Guild = 3, Other = 4 },
        ClubStreamType = { General = 1, Guild = 2, Officer = 3, Other = 4 },
    }
    env.C_Club = {
        GetSubscribedClubs = function()
            return { { clubId = 99, name = "Cross Faction RP", clubType = 1, memberCount = 12 } }
        end,
        GetStreams = function()
            return {
                { streamId = 1, name = "General", streamType = 1 },
                { streamId = 2, name = "relay", streamType = 4 },
            }
        end,
        FocusStream = function() end,
        AdvanceStreamViewMarker = function() end,
        GetMessageInfo = function(_, _, messageId)
            local stored = world.clubMessages[messageId]
            return stored and { content = stored.content, author = { name = spec.name } } or nil
        end,
        SendMessage = function(clubId, streamId, content)
            local messageId = world.nextMessageId
            world.nextMessageId = messageId + 1
            world.clubMessages[messageId] = { clubId = clubId, streamId = streamId, content = content }

            for _, other in ipairs(world.clients) do
                other.fire("CLUB_MESSAGE_ADDED", clubId, streamId, messageId)
            end
        end,
    }

    -------------------------------------------------------------- battle.net --
    env.BNET_CLIENT_WOW = "WoW"
    env.WOW_PROJECT_MAINLINE = 1
    env.C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end }

    env.BNGetNumFriends = function() return #(spec.friends or {}) end
    env.C_BattleNet = {
        GetFriendAccountInfo = function(index)
            return (spec.friends or {})[index] and { bnetAccountID = index } or nil
        end,
        GetFriendNumGameAccounts = function(index)
            return (spec.friends or {})[index] and 1 or 0
        end,
        GetFriendGameAccountInfo = function(index)
            local friend = (spec.friends or {})[index]
            if not friend then return nil end
            return {
                clientProgram = "WoW",
                wowProjectID = 1,
                isOnline = true,
                characterName = friend.name,
                realmName = friend.realm,       -- display form, with spaces
                gameAccountID = friend.gameAccountID,
            }
        end,
    }
    env.BNSendGameData = function(gameAccountID, prefix, message)
        world.bnetMessages = world.bnetMessages + 1
        for _, other in ipairs(world.clients) do
            if other.gameAccountID == gameAccountID then
                other.fire("BN_CHAT_MSG_ADDON", prefix, message, "WHISPER", spec.name)
            end
        end
    end

    ------------------------------------------------------------------- msp ----
    if spec.msp then
        env.msp = {
            my = spec.msp.my,
            myver = spec.msp.myver,
            char = setmetatable({}, {
                __index = function(store, key)
                    local record = { field = {}, ver = {}, time = {} }
                    rawset(store, key, record)
                    return record
                end,
            }),
            callback = { received = {}, updated = {} },
        }
    end

    ------------------------------------------------------------------- wiring --
    local client = {
        env = env,
        name = spec.name,
        fullName = spec.name .. "-" .. spec.normalizedRealm,
        gameAccountID = spec.gameAccountID,
    }

    function client.fire(event, ...)
        for _, frame in ipairs(env.__frames) do
            if frame.events[event] and frame.scripts.OnEvent then
                frame.scripts.OnEvent(frame, event, ...)
            end
        end
    end

    world.clients[#world.clients + 1] = client
    return client
end

--------------------------------------------------------------------------------
-- Loading the addon into a client
--------------------------------------------------------------------------------

local FILES = {
    "Core/Init.lua", "Core/Util.lua", "Core/Config.lua", "Core/Codec.lua",
    "Core/Protocol.lua", "Core/Chunker.lua", "Core/Geo.lua",
    "Transport/Relay.lua", "Transport/ClubLink.lua", "Transport/BNetLink.lua",
    "Profile/Cache.lua", "Profile/MSPBridge.lua", "Profile/Sync.lua",
    "Chat/Outbound.lua", "Chat/Inbound.lua",
    "UI/Slash.lua", "UI/Roster.lua",
}

function wow.load(client, root)
    local ns = {}
    client.ns = ns

    for _, file in ipairs(FILES) do
        local chunk = assert(loadfile(root .. "/" .. file))
        setfenv(chunk, client.env)
        chunk("EnemyRP", ns)
    end

    client.fire("ADDON_LOADED", "EnemyRP")
    client.fire("PLAYER_LOGIN")
    return ns
end

return wow
