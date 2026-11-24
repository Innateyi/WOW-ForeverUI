----------------------------------------------------------------------
--  ForeverUI — Core/Modules.lua
--  统一模块注册、生命周期、自动事件注销与第三方冲突自动让位
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type
local table_sort = table.sort
local CreateFrame = CreateFrame

local Modules = {}
F.Modules = Modules

local registry = {}
local orderList = {}

local ModuleProto = {}
ModuleProto.__index = ModuleProto

function ModuleProto:GetDB()
    return F.DB.GetModule(self.key)
end

function ModuleProto:IsEnabled()
    local db = self:GetDB()
    return db.enabled ~= false
end

function ModuleProto:IsYielded()
    if type(self.yieldIfLoaded) == "string" and F.IsAddOnLoaded(self.yieldIfLoaded) then
        return true, self.yieldIfLoaded
    end
    if type(self.yieldIfLoaded) == "table" then
        for _, addon in ipairs(self.yieldIfLoaded) do
            if F.IsAddOnLoaded(addon) then
                return true, addon
            end
        end
    end
    return false, nil
end

function ModuleProto:RegisterEvent(event, handler)
    if not self._eventFrame then
        local ef = CreateFrame("Frame")
        self._eventFrame = ef
        self._handlers = {}
        ef:SetScript("OnEvent", function(_, ev, ...)
            local fn = self._handlers[ev]
            if fn then
                fn(self, ev, ...)
            end
        end)
    end
    self._handlers[event] = handler
    pcall(self._eventFrame.RegisterEvent, self._eventFrame, event)
end

function ModuleProto:RegisterUnitEvent(event, unit1, unit2, handler)
    if type(unit2) == "function" then
        handler = unit2
        unit2 = nil
    end
    if not self._eventFrame then
        local ef = CreateFrame("Frame")
        self._eventFrame = ef
        self._handlers = {}
        ef:SetScript("OnEvent", function(_, ev, ...)
            local fn = self._handlers[ev]
            if fn then
                fn(self, ev, ...)
            end
        end)
    end
    self._handlers[event] = handler
    if unit2 then
        pcall(self._eventFrame.RegisterUnitEvent, self._eventFrame, event, unit1, unit2)
    else
        pcall(self._eventFrame.RegisterUnitEvent, self._eventFrame, event, unit1)
    end
end

function ModuleProto:UnregisterEvent(event)
    if self._eventFrame then
        pcall(self._eventFrame.UnregisterEvent, self._eventFrame, event)
    end
    if self._handlers then
        self._handlers[event] = nil
    end
end

function ModuleProto:UnregisterAllEvents()
    if self._eventFrame then
        self._eventFrame:UnregisterAllEvents()
    end
    if self._handlers then
        for k in pairs(self._handlers) do
            self._handlers[k] = nil
        end
    end
end

function ModuleProto:Enable()
    if self._active then
        return
    end
    local yielded, byAddon = self:IsYielded()
    if yielded then
        self._yieldedBy = byAddon
        return
    end
    self._yieldedBy = nil
    self._active = true
    if self.OnEnable then
        local ok, err = pcall(self.OnEnable, self)
        if not ok then
            self._active = false
            self:UnregisterAllEvents()
            F.Print("|cffff5555模块 [" .. self.title .. "] 启动失败：|r" .. tostring(err))
        end
    end
end

function ModuleProto:Disable()
    if not self._active then
        return
    end
    self._active = false
    self:UnregisterAllEvents()
    if self.OnDisable then
        pcall(self.OnDisable, self)
    end
end

function ModuleProto:SetEnabled(val)
    local db = self:GetDB()
    db.enabled = val == true
    if db.enabled then
        self:Enable()
    else
        self:Disable()
    end
end

function ModuleProto:Refresh()
    if self._active and self.OnRefresh then
        pcall(self.OnRefresh, self)
    end
end

function F.RegisterModule(key, spec)
    local mod = setmetatable(spec or {}, ModuleProto)
    mod.key = key
    mod.title = mod.title or key
    mod.group = mod.group or "utility"
    mod.order = mod.order or 50
    mod._active = false

    local defs = F.DeepCopy(mod.defaults or {})
    if defs.enabled == nil then
        defs.enabled = true
    end
    F.DB.RegisterDefaults(key, defs)

    registry[key] = mod
    orderList[#orderList + 1] = mod
    return mod
end

function Modules.Get(key)
    return registry[key]
end

function Modules.All()
    table_sort(orderList, function(a, b)
        if a.group ~= b.group then
            return a.group < b.group
        end
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.key < b.key
    end)
    return orderList
end

function F.NotifyModulesTheme()
    for _, mod in ipairs(orderList) do
        if mod._active and mod.OnThemeChanged then
            pcall(mod.OnThemeChanged, mod)
        end
    end
end

-- 启动引导：PLAYER_LOGIN 时统一初始化存档并启用已开启模块
local bootFrame = CreateFrame("Frame")
bootFrame:RegisterEvent("ADDON_LOADED")
bootFrame:RegisterEvent("PLAYER_LOGIN")
bootFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == F.NAME then
        F.DB.Init()
        self:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        if not F.db then
            F.DB.Init()
        end
        -- 若检测到旧版哈兰德同时启用，给出一次友好提示，避免双重生效
        if F.IsAddOnLoaded("EUI_Haalandtool") then
            F.Print("|cffffcc00提示：检测到 EUI_Haalandtool 仍在启用中。联调确认后建议在插件列表停用它，以免同类功能重复生效。|r")
        end
        for _, mod in ipairs(Modules.All()) do
            if mod:IsEnabled() then
                mod:Enable()
            end
        end
        if F.Mover and F.Mover.FlushRegistration then
            F.Mover.FlushRegistration()
        end
    end
end)
