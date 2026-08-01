-- Core/Init.lua
-- Addon namespace, module registry, event plumbing and the internal message bus.
--
-- Every other file does `local ADDON, ns = ...` and hangs itself off `ns`.
-- Modules are plain tables created with ns:NewModule(); the registry drives
-- initialization order (which is simply load order from the .toc).

local ADDON, ns = ...

local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

ns.ADDON = ADDON
ns.VERSION = GetMetadata(ADDON, "Version") or "dev"

-- Bumped whenever the wire format changes incompatibly. Also baked into the
-- frame magic (see Core/Protocol.lua) so old clients simply ignore new frames.
ns.PROTOCOL = 1

ns.modules = {}
ns.moduleList = {}

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff8080ff[EnemyRP]|r "

function ns:Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

function ns:Error(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cffff4040" .. msg .. "|r")
end

function ns:Debug(fmt, ...)
    if not (ns.db and ns.db.debug) then return end
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. "|cff808080" .. msg .. "|r")
end

--------------------------------------------------------------------------------
-- Game event dispatch
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local listeners = {} -- event -> array of { module, handler }

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local bucket = listeners[event]
    if not bucket then return end
    for i = 1, #bucket do
        local entry = bucket[i]
        local ok, err = pcall(entry.handler, entry.module, ...)
        if not ok then
            ns:Error("error in %s:%s -- %s", entry.module.name, event, tostring(err))
        end
    end
end)

--------------------------------------------------------------------------------
-- Internal message bus
--
-- Deliberately separate from game events: modules talk to each other through
-- named messages so that, for example, Sync never has to know which transport
-- backend a frame arrived on.
--------------------------------------------------------------------------------

local subscribers = {} -- message -> array of { module, handler }

function ns:On(message, module, handler)
    local bucket = subscribers[message]
    if not bucket then
        bucket = {}
        subscribers[message] = bucket
    end
    bucket[#bucket + 1] = { module = module, handler = handler }
end

function ns:Fire(message, ...)
    local bucket = subscribers[message]
    if not bucket then return end
    for i = 1, #bucket do
        local entry = bucket[i]
        local ok, err = pcall(entry.handler, entry.module, ...)
        if not ok then
            ns:Error("error handling %s in %s -- %s", message, entry.module.name, tostring(err))
        end
    end
end

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------

local Module = {}
Module.__index = Module

function Module:RegisterEvent(event, handler)
    handler = handler or self[event]
    assert(handler, ("%s has no handler for %s"):format(self.name, event))

    local bucket = listeners[event]
    if not bucket then
        bucket = {}
        listeners[event] = bucket
        eventFrame:RegisterEvent(event)
    end
    for i = 1, #bucket do
        if bucket[i].module == self then return end
    end
    bucket[#bucket + 1] = { module = self, handler = handler }
end

function Module:UnregisterEvent(event)
    local bucket = listeners[event]
    if not bucket then return end
    for i = #bucket, 1, -1 do
        if bucket[i].module == self then
            table.remove(bucket, i)
        end
    end
    if #bucket == 0 then
        listeners[event] = nil
        eventFrame:UnregisterEvent(event)
    end
end

--- Subscribe to an internal bus message. Handler defaults to self["On"..message].
function Module:Listen(message, handler)
    handler = handler or self["On" .. message]
    assert(handler, ("%s has no handler for message %s"):format(self.name, message))
    ns:On(message, self, handler)
end

function ns:NewModule(name)
    assert(not ns.modules[name], "duplicate module " .. name)
    local module = setmetatable({ name = name }, Module)
    ns.modules[name] = module
    ns.moduleList[#ns.moduleList + 1] = module
    return module
end

--------------------------------------------------------------------------------
-- Lifecycle
--
-- OnInitialize runs once saved variables exist; OnEnable runs once the world is
-- loaded and the player's identity (name, realm, faction) is reliable.
--------------------------------------------------------------------------------

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("ADDON_LOADED")
bootstrap:RegisterEvent("PLAYER_LOGIN")
bootstrap:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        self:UnregisterEvent("ADDON_LOADED")
        for _, module in ipairs(ns.moduleList) do
            if module.OnInitialize then
                local ok, err = pcall(module.OnInitialize, module)
                if not ok then ns:Error("init %s -- %s", module.name, tostring(err)) end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        for _, module in ipairs(ns.moduleList) do
            if module.OnEnable then
                local ok, err = pcall(module.OnEnable, module)
                if not ok then ns:Error("enable %s -- %s", module.name, tostring(err)) end
            end
        end
        ns:Fire("READY")
    end
end)
