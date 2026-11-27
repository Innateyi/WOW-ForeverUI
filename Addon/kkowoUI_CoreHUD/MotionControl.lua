----------------------------------------------------------------------
--  kkowoUI — Modules/MotionControl.lua
--  「动效与视觉增强」总控中心：
--    • 一键总开关（关闭时自动无损休眠全部动效子模块，零事件/零 OnUpdate 占用）
--    • 全局圆角半径、全职业渐变风格切换、以及一键恢复默认（带 EUI 确认弹窗）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, pairs, pcall, type, math_floor = ipairs, pairs, pcall, type, math.floor

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
    title = "圆角与动效",
    desc = "统一设置全局圆角半径与职业色渐变风格，关闭即恢复原样。",
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
                elseif sub._active then
                    sub:Disable()
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
            local old = F.db.modules[k]
            local fresh = F.DeepCopy(sub.defaults)
            if fresh.enabled == nil then
                fresh.enabled = true
            end
            -- defaults 已是最新版本默认值：所有 ^v%d+ 一次性迁移标记保持为 true，避免下次 /reload 重跑旧迁移覆盖用户设置
            for dk, dv in pairs(fresh) do
                if type(dk) == "string" and dk:find("^v%d+") and type(dv) == "boolean" then
                    fresh[dk] = true
                end
            end
            -- saved* 是模块改动 EUI 存档前备份的「用户原值」（如 EUI 姓名板圆角）：重置绝不能丢，
            -- 否则下次会把已被改过的值当成原值，停用后再也还原不回用户自己的设置
            if type(old) == "table" then
                for key, val in pairs(old) do
                    if type(key) == "string" and key:find("^saved") and val ~= nil then
                        fresh[key] = val
                    end
                end
                -- 原地覆写旧表，确保当前打开的设置页缓存的 db 引用即时生效不孤立
                for key in pairs(old) do
                    old[key] = nil
                end
                for key, val in pairs(fresh) do
                    old[key] = val
                end
            else
                F.db.modules[k] = fresh
            end
        end
    end
    -- 清空新增 HUD 自定义拖动坐标并立即归位
    local posKeys = { "CoreHUD", "PetHUD", "TopTargetHUD", "SwingTimerHUD", "CastbarOverlay" }
    if F.DB and F.DB.ClearPosition then
        for _, pk in ipairs(posKeys) do
            F.DB.ClearPosition(pk)
        end
    end
    if F.Mover and F.Mover.ApplyRegistered then
        for _, pk in ipairs(posKeys) do
            F.Mover.ApplyRegistered(pk)
        end
    end
    if mod:IsEnabled() and not mod._active then
        mod:Enable()
    elseif not mod:IsEnabled() and mod._active then
        mod:Disable()
    else
        SyncSubModules()
    end
    RefreshAllMotion()
    local EUI = _G.EllesmereUI
    if EUI and EUI.RefreshPage then pcall(EUI.RefreshPage, EUI, true) end
    F.Print("已恢复动效与圆角默认设置。")
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
        tooltip = "统一调整双翼、施法条、动作条、增益与提示框的圆角弧度。",
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
        tooltip = "将动效开关、圆角与位置恢复默认，不影响 EUI 自身配置。",
        onClick = function()
            local EUI = _G.EllesmereUI
            if EUI and EUI.ShowConfirmPopup then
                EUI:ShowConfirmPopup({
                    title = "重置动效默认",
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
