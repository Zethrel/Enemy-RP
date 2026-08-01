-- Enemy RP -- cross-faction roleplay profiles for World of Warcraft
-- Copyright (C) 2026 Enemy RP contributors
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU General Public License as published by the Free Software
-- Foundation, either version 3 of the License, or (at your option) any later
-- version. See the LICENSE file for the full text.

-- Core/Geo.lua
-- Distance between two players who cannot see each other.
--
-- Relayed chat has to respect speech range or a whisper in Stormwind would be
-- audible in Orgrimmar. The receiver cannot measure the distance to someone the
-- client does not know exists, so the sender states its own position and the
-- receiver does the arithmetic.
--
-- Map positions are normalized 0..1 within a map, which says nothing about
-- yards -- the same offset is a different distance in a city and on a
-- continent. C_Map.GetWorldPosFromMapPos converts both ends onto a shared
-- continent grid measured in yards, which is what makes the comparison mean
-- anything.

local ADDON, ns = ...

local Geo = {}
ns.Geo = Geo

--- Where the player is, as (uiMapId, x, y). Returns nil anywhere the client
--- refuses to place the player on a map, which includes most instances.
function Geo.PlayerPosition()
    local mapId = C_Map.GetBestMapForUnit("player")
    if not mapId then return nil end

    local position = C_Map.GetPlayerMapPosition(mapId, "player")
    if not position then return nil end

    local x, y = position:GetXY()
    if not x or not y then return nil end
    -- The API reports 0,0 for "no idea", which is also a legal corner of a map;
    -- treating it as unknown costs nothing and avoids a wildly wrong distance.
    if x == 0 and y == 0 then return nil end

    return mapId, x, y
end

local function worldPosition(mapId, x, y)
    local ok, continentId, position = pcall(
        C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D(x, y))
    if not ok or not continentId or not position then return nil end

    local worldX, worldY = position:GetXY()
    if not worldX or not worldY then return nil end
    return continentId, worldX, worldY
end

--- Distance in yards, or nil when the two points cannot be compared -- either
--- map is unknown to the client, or they sit on different continents.
function Geo.Distance(mapA, xA, yA, mapB, xB, yB)
    local continentA, ax, ay = worldPosition(mapA, xA, yA)
    if not continentA then return nil end

    local continentB, bx, by = worldPosition(mapB, xB, yB)
    if not continentB then return nil end

    if continentA ~= continentB then return nil end

    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

--- Distance from the player to a stated position, or nil if either end is
--- unknown. Callers treat nil as out of range.
function Geo.DistanceFromPlayer(mapId, x, y)
    local myMap, myX, myY = Geo.PlayerPosition()
    if not myMap then return nil end
    return Geo.Distance(myMap, myX, myY, mapId, x, y)
end
