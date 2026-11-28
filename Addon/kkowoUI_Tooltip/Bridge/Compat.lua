----------------------------------------------------------------------
--  kkowoUI_Tooltip — Bridge/Compat.lua
--  MIT 合规内嵌 PrettyTooltip 引擎桥接层：
--    1) 动态计算本插件目录的 Vendor\art\ 贴图路径，兼容改名与打包
--    2) 若玩家目录里仍误开独立版 PrettyTooltip，自动让位避免双重 Hook
----------------------------------------------------------------------
local addonName, ns = ...
local _G = _G

ns._addonName = addonName
ns._artPath = "Interface\\AddOns\\" .. addonName .. "\\Vendor\\art\\"

local function IsStandaloneActive()
    local ca = _G.C_AddOns
    local isLoaded = (ca and ca.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(isLoaded) == "function" then
        local ok, loaded = pcall(isLoaded, "PrettyTooltip")
        if ok and loaded == true then
            return true
        end
    end
    local getState = (ca and ca.GetAddOnEnableState) or _G.GetAddOnEnableState
    if type(getState) == "function" then
        local guid = _G.UnitGUID and _G.UnitGUID("player") or nil
        local ok, state
        if guid then
            ok, state = pcall(getState, "PrettyTooltip", guid)
            if ok and type(state) == "number" and state > 0 then
                return true
            end
        end
        ok, state = pcall(getState, "PrettyTooltip")
        if ok and type(state) == "number" and state > 0 then
            return true
        end
    end
    return false
end

if IsStandaloneActive() then
    ns._yielded = true
end
