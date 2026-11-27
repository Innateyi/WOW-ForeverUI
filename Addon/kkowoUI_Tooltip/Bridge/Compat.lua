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

local function IsStandaloneLoaded()
    local fn = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(fn) ~= "function" then
        return false
    end
    local ok, loaded = pcall(fn, "PrettyTooltip")
    return ok and loaded == true
end

if IsStandaloneLoaded() then
    ns._yielded = true
end
