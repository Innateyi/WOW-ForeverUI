----------------------------------------------------------------------
--  kkowoUI — Modules/MotionControl.lua
--  「动效与视觉增强」总控中心：
--    • 一键总开关（关闭时自动无损休眠全部动效子模块，零事件/零 OnUpdate 占用）
--    • 全局圆角半径、全职业渐变风格切换、以及一键恢复默认（带 EUI 确认弹窗）
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pcall, math_floor = ipairs, pcall, math.floor

local MOTION_SUBMODULES = {
    "coreHUD",
    "lowHealthAlert",
    "castbarMotion",
    "swingTimerMotion",
    "actionBarMotion",
    "auraBarSkin",
    "nameplateMotion",
    "keybindBoard",
}

local mod = F.RegisterModule("motionFX", {
    title = "动效与视觉增强总控",
    desc = "统一控制 kkowoUI 全套圆角渐变、核心双翼 HUD、动态旋转技能球、施法/挥砍/动作条/姓名板动效与可视化键位图；关闭总开关可一键无损还原。",
    group = "motion",
    order = 1,
    defaults = {
        enabled = true,
        gradientStyle = "bright", -- "bright" = 职业色→柔白高光 | "dark" = 暗职业基调→亮职业色
        cornerRadius = 6,         -- 全局圆角半径（0~10px）
    },
})

local function SyncSubModules()
    local masterOn = mod._active == true
    for _, key in ipairs(MOTION_SUBMODULES) do
        local sub = F.Modules.Get(key)
        if sub then
            if masterOn then
                if sub:IsEnabled() then
                    if not sub._active then
                        sub:Enable()
                    else
                        sub:Refresh()
                    end
                end
            else
                if sub._active then
                    sub:Disable()
                end
            end
        end
    end
end

local function RefreshAllMotion()
    for _, key in ipairs(MOTION_SUBMODULES) do
        local sub = F.Modules.Get(key)
        if sub and sub._active then
            sub:Refresh()
        end
    end
    local tt = F.Modules.Get("tooltipStyle")
    if tt and tt._active then tt:Refresh() end
end

local function ResetAllMotionDefaults()
    if not (F.db and F.db.modules) then return end
    local keys = { "motionFX" }
    for _, k in ipairs(MOTION_SUBMODULES) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local sub = F.Modules.Get(k)
        if sub and sub.defaults then
            F.db.modules[k] = F.DeepCopy(sub.defaults)
            if F.db.modules[k].enabled == nil then
                F.db.modules[k].enabled = true
            end
        end
    end
    -- 清空新增 HUD 自定义拖动坐标
    if F.DB and F.DB.ClearPosition then
        F.DB.ClearPosition("CoreHUD")
        F.DB.ClearPosition("PetHUD")
        F.DB.ClearPosition("TopTargetHUD")
        F.DB.ClearPosition("SwingTimerHUD")
    end
    SyncSubModules()
    RefreshAllMotion()
    local EUI = _G.EllesmereUI
    if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI) end
    F.Print("已将「动效与视觉增强」全部参数恢复为默认值。")
end

function mod:OnEnable()
    SyncSubModules()
end

function mod:OnDisable()
    SyncSubModules()
end

function mod:OnThemeChanged()
    RefreshAllMotion()
end

function mod:OnRefresh()
    RefreshAllMotion()
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "职业色渐变风格",
        tooltip = "控制核心血蓝条、施法条、挥砍条与宠物/目标条的横向渐变基调。",
        values = {
            bright = "通透高光（职业色 → 柔白尾光）",
            dark   = "暗黑沉稳（深暗底色 → 职业亮色）",
        },
        order = { "bright", "dark" },
        getValue = function() return db.gradientStyle or "bright" end,
        setValue = function(v)
            db.gradientStyle = v
            RefreshAllMotion()
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "全局圆角半径（px）",
        tooltip = "统一调整核心血蓝条、施法条、动作条、增益图标与悬浮提示的圆角弧度（0 = 直角，推荐 6）。",
        min = 0, max = 10, step = 1,
        getValue = function() return F.PlainNumber(db.cornerRadius, 6) or 6 end,
        setValue = function(v)
            db.cornerRadius = math_floor(v + 0.5)
            RefreshAllMotion()
        end,
    }, {
        type = "labeledButton",
        text = "恢复动效默认设置",
        buttonText = "一键重置",
        width = 110,
        tooltip = "将所有动效开关、圆角与坐标恢复默认（绝不影响你现有的 EllesmereUI 配置与其它模块）。",
        onClick = function()
            local EUI = _G.EllesmereUI
            if EUI and EUI.ShowConfirmPopup then
                EUI:ShowConfirmPopup({
                    title = "恢复动效增强默认设置",
                    message = "仅重置 kkowoUI「动效与视觉增强」分区的参数与坐标，不会改动你的 EllesmereUI 原有布局与其它模块。确定继续？",
                    confirmText = "确认恢复",
                    cancelText = "取消",
                    onConfirm = ResetAllMotionDefaults,
                })
            else
                ResetAllMotionDefaults()
            end
        end,
    })
    y = y - h

    return y
end
