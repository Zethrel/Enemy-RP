-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- UI/Roster.lua
-- A list of cross-faction characters the relay has heard from.
--
-- Displaying the profile itself is deliberately left to the player's roleplay
-- addon: once Profile/MSPBridge hands the fields over, Total RP 3 or XRP shows
-- them in its own window, which is what people already know how to read. This
-- window only answers "who is out there and have I got their profile yet".

local ADDON, ns = ...

local Roster = ns:NewModule("Roster")
ns.Roster = Roster

local Cache = ns.Cache
local Sync = ns.Sync

local ROW_COUNT = 14
local ROW_HEIGHT = 22
local RECENT_WINDOW = 900 -- characters seen in the last 15 minutes

local FACTION_COLOR = {
    A = "|cff4080ff",
    H = "|cffff4040",
    N = "|cffffff00",
}

local frame, rows
local offset = 0
local entries = {}

--------------------------------------------------------------------------------
-- Row behaviour
--------------------------------------------------------------------------------

local function rowTooltip(row)
    local record = row.fullName and Cache:Get(row.fullName)
    if not record then return end
    local fields = record.fields or {}

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(fields.NA or row.fullName, 1, 1, 1)
    if fields.NT then GameTooltip:AddLine(fields.NT, 0.8, 0.8, 0.8) end

    local descriptor = {}
    if fields.RA then descriptor[#descriptor + 1] = fields.RA end
    if fields.RC then descriptor[#descriptor + 1] = fields.RC end
    if #descriptor > 0 then
        GameTooltip:AddLine(table.concat(descriptor, " "), 0.6, 0.6, 0.6)
    end

    if fields.CU then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(fields.CU, 1, 0.82, 0, true)
    end

    GameTooltip:AddLine(" ")
    if record.fetched then
        GameTooltip:AddLine("Click to refresh the full profile.", 0.5, 0.5, 0.5)
    else
        GameTooltip:AddLine("Click to request this profile.", 0.5, 0.5, 0.5)
    end
    GameTooltip:Show()
end

local function rowClick(row)
    if not row.fullName then return end
    if Sync:RequestFull(row.fullName, true) then
        ns:Print("requested %s", row.fullName)
    else
        ns:Print("|cffff4040no relay available - check /erp status|r")
    end
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildFrame()
    frame = CreateFrame("Frame", "EnemyRPRosterFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(360, 60 + ROW_COUNT * ROW_HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    table.insert(UISpecialFrames, "EnemyRPRosterFrame") -- closes on Escape

    -- Blizzard has moved the title around between template revisions.
    if frame.SetTitle then
        frame:SetTitle("Enemy RP")
    elseif frame.TitleText then
        frame.TitleText:SetText("Enemy RP")
    end

    frame.empty = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    frame.empty:SetPoint("CENTER", 0, 10)
    frame.empty:SetText("Nobody heard from yet.")

    rows = {}
    for index = 1, ROW_COUNT do
        local row = CreateFrame("Button", nil, frame)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 12, -30 - (index - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", -12, -30 - (index - 1) * ROW_HEIGHT)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        row.name = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetJustifyH("LEFT")

        row.detail = row:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        row.detail:SetPoint("RIGHT", -4, 0)
        row.detail:SetJustifyH("RIGHT")

        row.name:SetPoint("RIGHT", row.detail, "LEFT", -8, 0)
        row.name:SetJustifyH("LEFT")

        row:SetScript("OnClick", rowClick)
        row:SetScript("OnEnter", rowTooltip)
        row:SetScript("OnLeave", GameTooltip_Hide)

        rows[index] = row
    end

    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        local maximum = math.max(0, #entries - ROW_COUNT)
        offset = math.min(maximum, math.max(0, offset - delta))
        Roster:Refresh()
    end)

    local announce = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    announce:SetSize(110, 20)
    announce:SetPoint("BOTTOMRIGHT", -10, 8)
    announce:SetText("Announce")
    announce:SetScript("OnClick", function() Sync:SendHeartbeat() end)
    announce:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Broadcast your presence so nearby players", 1, 1, 1, true)
        GameTooltip:AddLine("on the other faction can find your profile.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    announce:SetScript("OnLeave", GameTooltip_Hide)

    frame.status = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    frame.status:SetPoint("BOTTOMLEFT", 14, 14)
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function Roster:Refresh()
    if not frame or not frame:IsShown() then return end

    entries = Cache:Roster(RECENT_WINDOW)
    if offset > math.max(0, #entries - ROW_COUNT) then
        offset = math.max(0, #entries - ROW_COUNT)
    end

    frame.empty:SetShown(#entries == 0)

    for index = 1, ROW_COUNT do
        local row = rows[index]
        local entry = entries[index + offset]

        if entry then
            local color = FACTION_COLOR[entry.faction] or FACTION_COLOR.N
            local displayName = entry.name or entry.fullName
            row.name:SetText(color .. displayName .. "|r")
            row.fullName = entry.fullName

            local mapInfo = entry.map and C_Map.GetMapInfo(entry.map)
            local age = time() - entry.seen
            row.detail:SetText(("%s%s  |cff606060%dm|r"):format(
                entry.hasProfile and "" or "|cff808080?|r ",
                mapInfo and mapInfo.name or "",
                math.floor(age / 60)))

            row:Show()
        else
            row.fullName = nil
            row:Hide()
        end
    end

    frame.status:SetText(("%d nearby, %d cached"):format(#entries, Cache:Count()))
end

function Roster:Toggle()
    if not frame then buildFrame() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:Refresh()
    end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function Roster:OnEnable()
    -- Coalesce refreshes: a busy relay can update the roster many times a second.
    local queued = false
    local function request()
        if queued then return end
        queued = true
        C_Timer.After(0.5, function()
            queued = false
            Roster:Refresh()
        end)
    end

    self:Listen("ROSTER_UPDATED", request)
    self:Listen("PROFILE_UPDATED", request)
end
