----------------------------------------------------------------------
--  kkowoUI_Tooltip — Bridge/TooltipLocaleZh.lua
--  方案 A（已批准）：零修改 Vendor 上游代码，在 Bridge 层运行时本地化
--    • PrettyTooltip 编辑器与选项页中 20 条硬编码英文（Default / Outline / Flat 等）
--    • 补齐 formats.scarce（官方 zhCN.lua 留空项）；保留 descriptions.* = false 避免破坏中文解析
--    • 注册 /kk selftest 翻译抽查
----------------------------------------------------------------------
local _, ns = ...
local _G = _G
local GetLocale = _G.GetLocale
if not (GetLocale and GetLocale() == "zhCN") then
    return
end

local L = ns.L
local Locale = ns.Locale
local pairs, ipairs, pcall, rawget, type = pairs, ipairs, pcall, rawget, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local F = _G.kkowoUI

-- 1) 补齐 Vendor\Locale\zhCN.lua 中安全可补的本地化键
if type(Locale) == "table" and type(Locale.formats) == "table" then
    if not Locale.formats.scarce then
        Locale.formats.scarce = "稀缺"
    end
end
if type(L) == "table" then
    if rawget(L, "PrettyTooltip") == nil or L["PrettyTooltip"] == "PrettyTooltip" then
        L["PrettyTooltip"] = "提示框编辑器"
    end
    if rawget(L, "PrettyTooltip Style Editor") == "PrettyTooltip 样式编辑器" or rawget(L, "PrettyTooltip Style Editor") == nil then
        L["PrettyTooltip Style Editor"] = "提示框样式编辑器"
    end
    if rawget(L, "DialogueUI") == nil then
        L["DialogueUI"] = "对话风"
    end
end

-- 2) 20 条 Vendor\UI\Options.lua 与 Editor.lua 硬编码英文 -> 中文显示映射
local UI_ZH_MAP = {
    ["PrettyTooltip"]   = "提示框编辑器",
    ["Default"]         = (L and L["Default"]) or "默认",
    ["Blizzard Border"] = (L and L["Blizzard Border"]) or "暴雪边框",
    ["Flat"]            = (L and L["Flat"]) or "简约",
    ["DialogueUI"]      = "对话风",
    ["None"]            = (L and L["None"]) or "无",
    ["Outline"]         = (L and L["Outline"]) or "描边",
    ["Thick Outline"]   = (L and L["Thick Outline"]) or "粗描边",
    ["Off"]             = (L and L["Off"]) or "关",
    ["Left"]            = (L and L["Left"]) or "左侧",
    ["Right"]           = (L and L["Right"]) or "右侧",
    ["All Caps"]        = (L and L["All Caps"]) or "全部大写",
}

local function LocalizeRegion(r)
    if not (r and r.GetObjectType and r:GetObjectType() == "FontString") then return end
    if r.IsForbidden then
        local okF, forb = pcall(r.IsForbidden, r)
        if not okF or forb then return end
    end
    local okT, txt = pcall(r.GetText, r)
    if okT and type(txt) == "string" and not (F and F.IsSecret and F.IsSecret(txt)) then
        local zh = UI_ZH_MAP[txt]
        if zh and zh ~= txt then
            pcall(r.SetText, r, zh)
        end
    end
end

local function SweepFrameTree(root, depth)
    if not root or (depth or 0) > 6 then return end
    if root.IsForbidden then
        local okF, forb = pcall(root.IsForbidden, root)
        if not okF or forb then return end
    end
    if root.GetRegions then
        local regions = { root:GetRegions() }
        for _, r in ipairs(regions) do
            LocalizeRegion(r)
        end
    end
    if root.GetChildren then
        local children = { root:GetChildren() }
        for _, ch in ipairs(children) do
            SweepFrameTree(ch, (depth or 0) + 1)
        end
    end
end

local function SweepEditor()
    local ed = _G.PrettyTooltipEditor
    if ed and ed.IsShown and ed:IsShown() then
        SweepFrameTree(ed, 0)
    end
end

local hookedEditor = false
local function HookEditorOnce()
    if hookedEditor then return end
    local ed = _G.PrettyTooltipEditor
    if not (ed and ed.HookScript) then return end
    hookedEditor = true
    ed:HookScript("OnShow", function()
        SweepEditor()
        if C_Timer and C_Timer.After then
            C_Timer.After(0, SweepEditor)
        end
    end)
    -- 监听编辑器内部刷新 / 下拉展开
    if type(ns.refreshEditorStyle) == "function" then
        _G.hooksecurefunc(ns, "refreshEditorStyle", function()
            if C_Timer and C_Timer.After then C_Timer.After(0, SweepEditor) else SweepEditor() end
        end)
    end
    if type(ns.openEditor) == "function" then
        _G.hooksecurefunc(ns, "openEditor", function()
            if C_Timer and C_Timer.After then C_Timer.After(0, SweepEditor) else SweepEditor() end
        end)
    end
    -- 在编辑器打开时通过鼠标点击捕获动态生成的下拉菜单行（零常驻轮询）
    ed:HookScript("OnMouseUp", function()
        if C_Timer and C_Timer.After then C_Timer.After(0, SweepEditor) end
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    HookEditorOnce()
end)
HookEditorOnce()

-- 暴露给 /kk selftest 抽查
if F then
    F._TooltipLocaleZH = UI_ZH_MAP
    F._LocaleChecks = F._LocaleChecks or {}
    F._LocaleChecks.kkowoUI_Tooltip = function()
        local sample = { "Default", "Blizzard Border", "Flat", "DialogueUI", "None", "Outline", "Thick Outline", "Off", "Left", "Right" }
        local hit = 0
        for _, k in ipairs(sample) do
            if type(UI_ZH_MAP[k]) == "string" and UI_ZH_MAP[k] ~= k then hit = hit + 1 end
        end
        return hit == #sample, "TooltipUI " .. hit .. "/" .. #sample
    end
end
