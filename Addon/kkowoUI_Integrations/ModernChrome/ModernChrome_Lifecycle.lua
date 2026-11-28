----------------------------------------------------------------------
--  kkowoUI_Integrations — ModernChrome/ModernChrome_Lifecycle.lua
--  ModernChrome 生命周期事件注册与 /kk 选项面板
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local MC = F._MC
if not MC then return end

local math_floor, math_max, math_min, pcall, type = math.floor, math.max, math.min, pcall, type
local C_Timer = C_Timer
local mod = MC.mod

local SetupCharacterBars = MC.SetupCharacterBars
local RefreshAllCharacterBars = MC.RefreshAllCharacterBars
local PolishCharacterStatsFontSize = MC.PolishCharacterStatsFontSize
local QueueAuraFit = MC.QueueAuraFit
local RestoreFittedAuraTimers = MC.RestoreFittedAuraTimers
local SetupFriendsHook = MC.SetupFriendsHook
local ExpandFriendsIfEnabled = MC.ExpandFriendsIfEnabled
local SkinBugSackIfReady = MC.SkinBugSackIfReady
local RunConflictDiagnostics = MC.RunConflictDiagnostics
local ApplyUnifiedResourceBars = MC.ApplyUnifiedResourceBars
local RestoreResourceBarsStyle = MC.RestoreResourceBarsStyle
local swingGuard = MC.swingGuard
local cdmPosGuard = MC.cdmPosGuard
local SkinVehicleLeaveButton = MC.SkinVehicleLeaveButton
local ApplyBlizzDurabilityVisibility = MC.ApplyBlizzDurabilityVisibility
local ApplyFlightTimerDedup = MC.ApplyFlightTimerDedup
local ApplyQuestieTownsfolkDedup = MC.ApplyQuestieTownsfolkDedup
local RestoreQuestieTownsfolkDedup = MC.RestoreQuestieTownsfolkDedup
local RefreshHDPetHappiness = MC.RefreshHDPetHappiness
local HookTrainerFrameIfReady = MC.HookTrainerFrameIfReady
local BeginTrainerOpenSession = MC.BeginTrainerOpenSession
local ResetTrainerSession = MC.ResetTrainerSession
local ApplyWorldTextScale = MC.ApplyWorldTextScale
local RestoreWorldTextScale = MC.RestoreWorldTextScale
local HookCombatTextSizing = MC.HookCombatTextSizing
local RefreshWorldRefreshBanner = MC.RefreshWorldRefreshBanner
local StopWorldRefreshTicker = MC.StopWorldRefreshTicker
local EnsureWorldRefreshTicker = MC.EnsureWorldRefreshTicker
local StopWorldRefreshDrag = MC.StopWorldRefreshDrag
local windowPolish = MC.windowPolish
local RestoreEUICastNames = MC.RestoreEUICastNames
local QueueCharacterBarsRefresh = MC.QueueCharacterBarsRefresh
local RefreshAllModernHUD = MC.RefreshAllModernHUD
local ScheduleBootRefresh = MC.ScheduleBootRefresh

function mod:OnDisable()
    MC.CancelBootRefresh()
    swingGuard.Remove()
    cdmPosGuard.Remove()
    StopWorldRefreshTicker()
    if StopWorldRefreshDrag then StopWorldRefreshDrag() end
    RestoreWorldTextScale()
    ExpandFriendsIfEnabled()
    if F.ApplyDamageFont then
        F.ApplyDamageFont("default", true)
    end
    RestoreFittedAuraTimers()
    if RestoreEUICastNames then pcall(RestoreEUICastNames) end
    if RestoreQuestieTownsfolkDedup then pcall(RestoreQuestieTownsfolkDedup) end
    if RestoreResourceBarsStyle then pcall(RestoreResourceBarsStyle, false) end
    pcall(windowPolish.ApplyCombatSoundMute)
    RefreshAllModernHUD()
    RefreshAllCharacterBars()
end

function mod:OnEnable()
    local db = self:GetDB()
    if not db.v3WorldTextScaleMigrated then
        db.v3WorldTextScaleMigrated = true
        if db.worldTextScale == 0.85 then
            db.worldTextScale = 1.00
        end
    end
    if not db.v4CharStatSizeMigrated then
        db.v4CharStatSizeMigrated = true
        if db.charStatFontSize == 12 then
            db.charStatFontSize = 13
        end
    end
    -- 同步仅影响战斗伤害/治疗浮动文字的字体（绝不动其他 UI 字体）
    if F.ApplyDamageFont then
        F.ApplyDamageFont(db.damageFont or "youshe", true)
    end
    ApplyWorldTextScale()
    HookCombatTextSizing()
    EnsureWorldRefreshTicker()
    -- 登录即完成 ScrollBox 与详情条挂钩，首次点击声望/技能/PvP 0ms 生效无卡顿
    SetupCharacterBars()
    SetupFriendsHook()
    HookTrainerFrameIfReady()
    RefreshAllModernHUD()
    self:RegisterEvent("TRAINER_SHOW", function()
        HookTrainerFrameIfReady()
        BeginTrainerOpenSession()
    end)
    self:RegisterEvent("TRAINER_UPDATE", MC.HandleTrainerUpdate)
    self:RegisterEvent("TRAINER_CLOSED", ResetTrainerSession)
    self:RegisterEvent("ADDON_LOADED", function(_, _, addonName)
        if addonName == "Blizzard_TrainerUI" then
            HookTrainerFrameIfReady()
            local ctf = _G.ClassTrainerFrame
            if ctf and ctf:IsShown() then
                BeginTrainerOpenSession()
            end
        elseif addonName == "Blizzard_CombatText" then
            HookCombatTextSizing()
        elseif addonName == "Blizzard_AuctionHouseUI" then
            windowPolish.HookAuctionHouse()
        elseif addonName == "Blizzard_MailFrame" then
            windowPolish.HookMail()
        end
        if type(addonName) == "string" and addonName:sub(1, 9) == "Blizzard_" then
            C_Timer.After(0.05, function()
                if mod._active then pcall(windowPolish.ApplyFontClipGuard) end
            end)
        end
    end)
    self:RegisterEvent("AUCTION_HOUSE_SHOW", windowPolish.HookAuctionHouse)
    self:RegisterEvent("MAIL_SHOW", windowPolish.HookMail)
    self:RegisterEvent("SEND_MAIL_MONEY_CHANGED", windowPolish.HookMail)
    self:RegisterEvent("MAIL_SEND_INFO_UPDATE", windowPolish.HookMail)
    self:RegisterEvent("MERCHANT_SHOW", windowPolish.HookMerchant)
    self:RegisterEvent("MERCHANT_UPDATE", windowPolish.HookMerchant)
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        C_Timer.After(0.5, RefreshWorldRefreshBanner)
    end)
    self:RegisterEvent("CHAT_MSG_SYSTEM", function(_, _, msg)
        local plain = F.PlainString(msg, nil)
        if plain and (plain:find("刷新", 1, true) or plain:lower():find("refresh", 1, true)) then
            RefreshWorldRefreshBanner()
            C_Timer.After(0.2, RefreshWorldRefreshBanner)
            C_Timer.After(0.8, RefreshWorldRefreshBanner)
        end
    end)
    self:RegisterEvent("UI_INFO_MESSAGE", function(_, _, _, msg)
        local plain = F.PlainString(msg, nil)
        if plain and (plain:find("刷新", 1, true) or plain:lower():find("refresh", 1, true)) then
            RefreshWorldRefreshBanner()
            C_Timer.After(0.2, RefreshWorldRefreshBanner)
        end
    end)
    self:RegisterUnitEvent("UNIT_AURA", "player", QueueAuraFit)
    self:RegisterUnitEvent("UNIT_HAPPINESS", "pet", RefreshHDPetHappiness)
    self:RegisterUnitEvent("UNIT_PET", "player", function()
        RefreshHDPetHappiness()
        C_Timer.After(0.2, RefreshHDPetHappiness)
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, _, isInitialLogin, isReloadingUi)
        pcall(SetupCharacterBars)
        pcall(ApplyWorldTextScale)
        pcall(QueueAuraFit)
        pcall(ApplyUnifiedResourceBars, false)
        pcall(swingGuard.Install)
        pcall(swingGuard.Heal, nil)
        pcall(cdmPosGuard.Install)
        pcall(cdmPosGuard.VerifyAll)
        RefreshAllModernHUD()
        ScheduleBootRefresh(true)
        -- 冲突诊断弹窗只在登录/重载时检查一次，过传送门、副本读条不再重复弹出
        if isInitialLogin or isReloadingUi then
            C_Timer.After(4, function()
                if mod._active then RunConflictDiagnostics() end
            end)
        end
        -- Questie 城镇 NPC 去重每次读条后都要强制重扫：Questie 会按「已学专业」重新加回训练师图标，
        -- 只在登录时扫一次的话，过一次传送门小地图 NPC 又会和 Polestar 重复
        C_Timer.After(5.5, function()
            if mod._active then pcall(ApplyQuestieTownsfolkDedup, true) end
        end)
    end)
    self:RegisterEvent("PLAYER_CONTROL_LOST", function()
        SkinVehicleLeaveButton()
        C_Timer.After(0, SkinVehicleLeaveButton)
        C_Timer.After(0.15, SkinVehicleLeaveButton)
        C_Timer.After(0.55, SkinVehicleLeaveButton)
    end)
    self:RegisterEvent("PLAYER_CONTROL_GAINED", SkinVehicleLeaveButton)
    self:RegisterEvent("UPDATE_BONUS_ACTIONBAR", SkinVehicleLeaveButton)
    -- 只关心玩家自己上下载具（原先未过滤单位，团队/战场里每个队友上下载具都会触发）
    self:RegisterUnitEvent("UNIT_ENTERED_VEHICLE", "player", SkinVehicleLeaveButton)
    self:RegisterUnitEvent("UNIT_EXITED_VEHICLE", "player", SkinVehicleLeaveButton)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        if StopWorldRefreshDrag then StopWorldRefreshDrag() end
    end)
    self:RegisterEvent("UI_SCALE_CHANGED", QueueAuraFit)
    -- 声望变化（刷怪时战斗中频繁触发）只在声望面板可见时才重绘角色面板进度条
    self:RegisterEvent("UPDATE_FACTION", function()
        local rf = _G.ReputationFrame
        if rf and rf.IsVisible and rf:IsVisible() then
            QueueCharacterBarsRefresh()
        end
    end)
    QueueAuraFit()
    swingGuard.Install()
    cdmPosGuard.Install()
    pcall(ApplyUnifiedResourceBars, false)
    pcall(swingGuard.Heal, nil)
    pcall(cdmPosGuard.VerifyAll)
    ScheduleBootRefresh(false)
end

function mod:OnRefresh()
    RefreshAllCharacterBars()
    RefreshAllModernHUD()
end

function mod:OnThemeChanged()
    RefreshAllCharacterBars()
    SkinBugSackIfReady()
    RefreshAllModernHUD()
end

local SLICE_TITLES = {
    theme     = "外观与界面统一",
    character = "人物面板与训练师",
    map       = "地图与飞行去重",
    audio     = "攻击与拉弓静音",
}

function mod:GetSliceTitle(slice)
    return SLICE_TITLES[slice] or self.title
end

function mod:BuildOptionsSection(slice, W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local themeDB = F.db and F.db.theme or { accentMode = "class", combatFadeAlpha = 0.18 }
    local _, h
    local function disabledWhenOff() return not mod:IsEnabled() end
    local offTip = "需先在「界面外观 → 主题与圆角」启用外观与界面统一。"

    if slice == "theme" then
        _, h = W:DualRow(parent, y, enableSlot, {
            type = "dropdown",
            text = "全局主题色模式",
            tooltip = "默认使用当前职业颜色作为主题色，也可改为跟随 EUI 主色。",
            values = { class = "职业主题色（默认）", eui = "跟随 EUI 主色" },
            order = { "class", "eui" },
            getValue = function() return themeDB.accentMode or "class" end,
            setValue = function(v)
                themeDB.accentMode = v
                if F.NotifyModulesTheme then F.NotifyModulesTheme() end
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "dropdown",
            text = "战斗伤害字体",
            tooltip = "仅更换头顶伤害与治疗数字字体，重登角色或重启游戏生效。",
            values = {
                youshe  = "优设标题黑（推荐）",
                smiley  = "得意黑 SmileySans",
                default = "游戏原生字体",
            },
            order = { "youshe", "smiley", "default" },
            getValue = function() return db.damageFont or "youshe" end,
            setValue = function(v)
                db.damageFont = v
                if F.ApplyDamageFont then
                    local ready = F.ApplyDamageFont(v, true)
                    if v == "default" then
                        F.Print("已恢复游戏原生伤害字体，重新登录角色后生效。")
                    elseif ready then
                        F.Print("已切换战斗伤害字体，重新登录角色后生效。")
                    else
                        F.Print("已保存战斗伤害字体，重启游戏后生效。")
                    end
                end
            end,
        }, {
            type = "dropdown",
            text = "伤害飘字弹道",
            tooltip = "切换伤害数字上浮弧度，经典直出可让命中数字第一时间上浮。",
            values = {
                keep    = "游戏默认（1.5x 弧线）",
                compact = "紧凑爆发（1.0x 小弧线）",
                classic = "经典直出（无散射）",
            },
            order = { "keep", "compact", "classic" },
            getValue = function() return db.damageArcMode or "keep" end,
            setValue = function(v)
                db.damageArcMode = v
                ApplyWorldTextScale()
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "战斗飘字分级",
            tooltip = "放大自身受伤数字、缩小经验声望飘字，拉清战斗信息层级。",
            getValue = function() return db.smartCombatText ~= false end,
            setValue = function(v)
                db.smartCombatText = v == true
                if v then
                    ApplyWorldTextScale()
                    HookCombatTextSizing()
                else
                    RestoreWorldTextScale()
                end
            end,
        }, {
            type = "slider",
            text = "伤害飘字缩放",
            tooltip = "调节头顶打怪伤害与击杀经验的整体缩放，脱战立即生效。",
            min = 0.50, max = 2.00, step = 0.05,
            getValue = function() return db.worldTextScale or 1.00 end,
            setValue = function(v)
                db.worldTextScale = math_floor(v * 100 + 0.5) / 100
                ApplyWorldTextScale()
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "slider",
            text = "自身受伤字号",
            tooltip = "调节自身受到伤害时的滚动飘字大小，默认 34。",
            min = 20, max = 48, step = 1,
            getValue = function() return db.incomingDamageSize or 34 end,
            setValue = function(v) db.incomingDamageSize = math_floor(v + 0.5) end,
        }, {
            type = "slider",
            text = "经验声望字号",
            tooltip = "调节滚动战斗文字中经验、声望与荣誉提示字号，默认 15。",
            min = 12, max = 24, step = 1,
            getValue = function() return db.combatXPSize or 15 end,
            setValue = function(v) db.combatXPSize = math_floor(v + 0.5) end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "鸿蒙字体防顶切",
            tooltip = "为角色、任务、邮件与商人等界面文字补充顶部留白防裁切。",
            getValue = function() return db.harmonyFontGuard ~= false end,
            setValue = function(v)
                db.harmonyFontGuard = v == true
                pcall(windowPolish.ApplyFontClipGuard)
            end,
        }, {
            type = "toggle",
            text = "世界刷新提示条",
            tooltip = "美化并下移世界刷新倒计时条，支持 Shift+左键自由拖动。",
            getValue = function() return db.skinWorldRefresh ~= false end,
            setValue = function(v)
                db.skinWorldRefresh = v == true
                RefreshWorldRefreshBanner()
            end,
        })
        y = y - h

        local function buildAdv(w, p, curY, blk)
            local _, rh
            _, rh = w:DualRow(p, curY, {
                type = "slider",
                text = "战斗淡出透明度",
                tooltip = "开启战斗自动淡出的模块在进入战斗后的目标透明度。",
                min = 0.0, max = 0.6, step = 0.05,
                getValue = function() return themeDB.combatFadeAlpha or 0.18 end,
                setValue = function(v)
                    themeDB.combatFadeAlpha = v
                    if F.NotifyModulesTheme then F.NotifyModulesTheme() end
                end,
            }, {
                type = "toggle",
                text = "美化报错与弹窗",
                tooltip = "美化报错口袋界面，并在检测到插件功能重叠时弹出提示。",
                getValue = function() return db.conflictCheck ~= false end,
                setValue = function(v) db.conflictCheck = v == true; db.skinBugSack = v == true; SkinBugSackIfReady() end,
            })
            curY = curY - rh

            _, rh = w:DualRow(p, curY, {
                type = "toggle",
                text = "重做旧暴雪按钮",
                tooltip = "美化退出载具、返回墓地按钮以及额外技能钮与疲劳计时条。",
                getValue = function() return db.modernBlizzHUD ~= false end,
                setValue = function(v) db.modernBlizzHUD = v == true; RefreshAllModernHUD() end,
            }, {
                type = "toggle",
                text = "隐藏耐久度小人",
                tooltip = "隐藏屏幕右侧原版耐久度小人图标，保留属性区耐久显示。",
                getValue = function() return db.hideBlizzDurability ~= false end,
                setValue = function(v) db.hideBlizzDurability = v == true; ApplyBlizzDurabilityVisibility() end,
            })
            curY = curY - rh

            _, rh = w:DualRow(p, curY, {
                type = "toggle",
                text = "统一资源施法条",
                tooltip = "将 EUI 资源、挥砍与施法条统一为等宽与职业色，关闭即还原。",
                getValue = function() return db.unifyResourceBars ~= false end,
                setValue = function(v)
                    db.unifyResourceBars = v == true
                    if v then ApplyUnifiedResourceBars(true) else RestoreResourceBarsStyle(true) end
                end,
            }, {
                type = "toggle",
                text = "增益计时防重叠",
                tooltip = "按图标宽度微调增益与减益剩余时间字号，避免文字重叠。",
                getValue = function() return db.fitBuffTimers ~= false end,
                setValue = function(v) db.fitBuffTimers = v == true; QueueAuraFit() end,
            })
            curY = curY - rh

            _, rh = w:DualRow(p, curY, {
                type = "toggle",
                text = "高清宠物快乐度",
                tooltip = "替换模糊的老版宠物快乐度图标，保留点击喂食菜单。",
                getValue = function() return db.hdPetHappy ~= false end,
                setValue = function(v) db.hdPetHappy = v == true; RefreshHDPetHappiness() end,
            }, blk)
            curY = curY - rh
            return curY
        end
        if type(F.BuildAdvancedSection) == "function" then
            y = F.BuildAdvancedSection("mc:theme", W, parent, y, buildAdv, blank)
        else
            y = buildAdv(W, parent, y, blank)
        end
        return y
    end

    if slice == "character" then
        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "重排人物属性页",
            tooltip = "去除遮挡模型的长绿字，装等收入格角并优化右侧属性排版。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.cleanCharSheet ~= false end,
            setValue = function(v)
                db.cleanCharSheet = v == true
                pcall(windowPolish.ApplyCharacterSheetRedesign)
            end,
        }, {
            type = "slider",
            text = "属性栏字号 (px)",
            tooltip = "调整人物面板右侧属性列表字号，推荐 13px。",
            min = 11, max = 16, step = 1,
            disabled = disabledWhenOff,
            getValue = function() return math_max(11, math_min(16, F.PlainNumber(db.charStatFontSize, 13))) end,
            setValue = function(v)
                db.charStatFontSize = math_floor(v + 0.5)
                pcall(windowPolish.ApplyCharacterSheetRedesign)
                PolishCharacterStatsFontSize()
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "训练师藏已学会",
            tooltip = "打开职业或野兽训练师时自动取消勾选已学会的技能。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.trainerHideUsed ~= false end,
            setValue = function(v) db.trainerHideUsed = v == true end,
        }, {
            type = "toggle",
            text = "训练师藏不可学",
            tooltip = "打开训练师时隐藏等级未到的技能，只显示当前可学项。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.trainerHideUnavailable ~= false end,
            setValue = function(v) db.trainerHideUnavailable = v == true end,
        })
        y = y - h

        local function buildAdv(w, p, curY)
            local _, rh
            _, rh = w:DualRow(p, curY, {
                type = "toggle",
                text = "面板进度条扁平",
                tooltip = "将声望、技能与宠物经验进度条统一为简洁扁平风格。",
                disabled = disabledWhenOff,
                getValue = function() return db.flatCharBars ~= false end,
                setValue = function(v) db.flatCharBars = v == true; RefreshAllCharacterBars() end,
            }, {
                type = "toggle",
                text = "模型按钮防误触",
                tooltip = "仅鼠标移至中间 3D 人物区域时显示旋转与缩放按钮。",
                disabled = disabledWhenOff,
                getValue = function() return db.centerModelControls ~= false end,
                setValue = function(v)
                    db.centerModelControls = v == true
                    pcall(windowPolish.ApplyCharacterSheetRedesign)
                end,
            })
            curY = curY - rh

            _, rh = w:DualRow(p, curY, {
                type = "toggle",
                text = "人物面板细节",
                tooltip = "增加声望与技能列表层级缩进，统一复选框与 PvP 框样式。",
                disabled = disabledWhenOff,
                getValue = function() return db.charFramePolish ~= false end,
                setValue = function(v) db.charFramePolish = v == true; RefreshAllCharacterBars() end,
            }, {
                type = "toggle",
                text = "加高好友列表窗口",
                tooltip = "打开好友面板时适度增高，减少翻页滚动。",
                disabled = disabledWhenOff,
                getValue = function() return db.expandFriends ~= false end,
                setValue = function(v) db.expandFriends = v == true; ExpandFriendsIfEnabled() end,
            })
            curY = curY - rh
            return curY
        end
        if type(F.BuildAdvancedSection) == "function" then
            y = F.BuildAdvancedSection("mc:char", W, parent, y, buildAdv, blank)
        else
            y = buildAdv(W, parent, y)
        end
        return y
    end

    if slice == "map" then
        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "小地图图标去重",
            tooltip = "关闭任务助手重复的城镇服务图标，统一由北极星指南显示。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.dedupMinimapNPC ~= false end,
            setValue = function(v)
                db.dedupMinimapNPC = v == true
                if v then
                    ApplyQuestieTownsfolkDedup(true)
                elseif RestoreQuestieTownsfolkDedup then
                    RestoreQuestieTownsfolkDedup()
                end
            end,
        }, {
            type = "toggle",
            text = "大地图坐标去重",
            tooltip = "隐藏大地图底部重叠坐标，仅保留北极星指南单套坐标。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.dedupWorldMapCoords ~= false end,
            setValue = function(v)
                db.dedupWorldMapCoords = v == true
                pcall(windowPolish.ApplyWorldMapCoordsDedup)
            end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "dropdown",
            text = "飞行计时器去重",
            tooltip = "解决北极星指南与 EUI 飞行计时条重叠，推荐保留 EUI。",
            disabled = disabledWhenOff,
            values = {
                keep_eui      = "保留 EUI 细线条（推荐）",
                keep_polestar = "保留北极星卡片",
                both          = "两者均保留",
            },
            order = { "keep_eui", "keep_polestar", "both" },
            getValue = function() return db.flightTimerMode or "keep_eui" end,
            setValue = function(v) db.flightTimerMode = v; ApplyFlightTimerDedup() end,
        }, blank)
        y = y - h
        return y
    end

    if slice == "audio" then
        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "静音角色攻击喊",
            tooltip = "屏蔽角色射箭与挥砍时的喊声，不影响技能与首领语音。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.muteAttackGrunts ~= false end,
            setValue = function(v)
                db.muteAttackGrunts = v == true
                pcall(windowPolish.ApplyCombatSoundMute)
            end,
        }, {
            type = "toggle",
            text = "静音拉弓吱嘎声",
            tooltip = "额外屏蔽拉弓时的重复吱嘎声，保留离弦与命中音效。",
            disabled = disabledWhenOff,
            disabledTooltip = offTip,
            getValue = function() return db.muteBowPullback == true end,
            setValue = function(v)
                db.muteBowPullback = v == true
                pcall(windowPolish.ApplyCombatSoundMute)
            end,
        })
        y = y - h
        return y
    end

    return y
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    y = self:BuildOptionsSection("theme", W, parent, y, enableSlot, blank)
    y = self:BuildOptionsSection("character", W, parent, y, enableSlot, blank)
    y = self:BuildOptionsSection("map", W, parent, y, enableSlot, blank)
    y = self:BuildOptionsSection("audio", W, parent, y, enableSlot, blank)
    return y
end

