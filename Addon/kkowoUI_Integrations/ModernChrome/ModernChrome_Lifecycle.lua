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
local windowPolish = MC.windowPolish
local QueueCharacterBarsRefresh = MC.QueueCharacterBarsRefresh
local RefreshAllModernHUD = MC.RefreshAllModernHUD
local ScheduleBootRefresh = MC.ScheduleBootRefresh

function mod:OnDisable()
    MC.CancelBootRefresh()
    swingGuard.Remove()
    cdmPosGuard.Remove()
    StopWorldRefreshTicker()
    RestoreWorldTextScale()
    ExpandFriendsIfEnabled()
    if F.ApplyDamageFont then
        F.ApplyDamageFont("default", true)
    end
    RestoreFittedAuraTimers()
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

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local themeDB = F.db and F.db.theme or { accentMode = "class", combatFadeAlpha = 0.18 }
    local _, h

    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "全局主题色模式",
        tooltip = "默认以当前角色的职业颜色作为主题色，也可切换为跟随 EllesmereUI 主色。",
        values = { class = "职业主题色（默认）", eui = "跟随 EllesmereUI 主色" },
        order = { "class", "eui" },
        getValue = function() return themeDB.accentMode or "class" end,
        setValue = function(v)
            themeDB.accentMode = v
            if F.NotifyModulesTheme then F.NotifyModulesTheme() end
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "战斗淡出透明度",
        tooltip = "开启战斗自动淡出的模块在进入战斗后的目标透明度。",
        min = 0.0, max = 0.6, step = 0.05,
        getValue = function() return themeDB.combatFadeAlpha or 0.18 end,
        setValue = function(v)
            themeDB.combatFadeAlpha = v
            -- 系统栏/任务按钮条等在 OnThemeChanged 里才把新透明度推给战斗淡出管理器
            if F.NotifyModulesTheme then F.NotifyModulesTheme() end
        end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "角色面板进度条统一扁平风",
        tooltip = "把声望列表行与详情条（派系色）、技能列表行与详情条（职业色/满级金）、宠物经验条统一为 MerfinMain 现代扁平条。",
        getValue = function() return db.flatCharBars ~= false end,
        setValue = function(v) db.flatCharBars = v == true; RefreshAllCharacterBars() end,
    }, {
        type = "toggle",
        text = "增益计时文字防重叠",
        tooltip = "自动按图标宽度微调 Buff/Debuff 剩余时间字号，避免 60m30m 重叠。",
        getValue = function() return db.fitBuffTimers ~= false end,
        setValue = function(v) db.fitBuffTimers = v == true; QueueAuraFit() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "统一资源条 / 挥砍计时器 / 施法条风格",
        tooltip = "将 EUI 职业资源、生命/能量条、挥砍计时器与施法条统一为 249px 等宽 + 职业主题色 + 纤细现代比例（不改位置，关闭即还原原设置）。",
        getValue = function() return db.unifyResourceBars ~= false end,
        setValue = function(v)
            db.unifyResourceBars = v == true
            if v then ApplyUnifiedResourceBars(true) else RestoreResourceBarsStyle(true) end
        end,
    }, {
        type = "toggle",
        text = "加高好友列表窗口",
        tooltip = "打开好友面板时适度增高，减少翻页滚动。",
        getValue = function() return db.expandFriends ~= false end,
        setValue = function(v) db.expandFriends = v == true; ExpandFriendsIfEnabled() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "现代化遗漏暴雪按钮（退出载具/返回墓地等）",
        tooltip = "重做丑陋木纹退出载具按钮、复古返回墓地按钮，并同步开启额外技能钮与呼吸/疲劳/假死条的现代扁平皮肤。",
        getValue = function() return db.modernBlizzHUD ~= false end,
        setValue = function(v) db.modernBlizzHUD = v == true; RefreshAllModernHUD() end,
    }, {
        type = "toggle",
        text = "隐藏老旧暴雪耐久度小人图",
        tooltip = "已在次要属性下方整齐显示耐久度百分比，隐藏屏幕右侧突兀的复古黄红小人图标。",
        getValue = function() return db.hideBlizzDurability ~= false end,
        setValue = function(v) db.hideBlizzDurability = v == true; ApplyBlizzDurabilityVisibility() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "角色属性面板重设计（去挡人绿字 + 装等耐久卡）",
        tooltip = "关闭遮挡 3D 人物模型的装备长绿字堆叠、装等收入装备格底角、将头顶漂浮耐久移入右侧顶部玻璃卡片，并全面优化右侧属性栏排版与色彩。",
        getValue = function() return db.cleanCharSheet ~= false end,
        setValue = function(v)
            db.cleanCharSheet = v == true
            pcall(windowPolish.ApplyCharacterSheetRedesign)
        end,
    }, {
        type = "slider",
        text = "角色属性栏字号",
        tooltip = "放大角色面板右侧「概况 / 主要属性 / 武器 / 防御」列表文字与数值（EUI 默认 10px 偏小，推荐 13px）。",
        min = 11, max = 16, step = 1,
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
        text = "角色模型按钮仅悬停中间人物时显示",
        tooltip = "修复鼠标划过左右装备格时缩放/旋转按钮不停闪现的问题：仅光标落入中间 3D 人物区域时才显示控制栏。",
        getValue = function() return db.centerModelControls ~= false end,
        setValue = function(v)
            db.centerModelControls = v == true
            pcall(windowPolish.ApplyCharacterSheetRedesign)
        end,
    }, {
        type = "toggle",
        text = "鸿蒙字体全界面防顶切修正",
        tooltip = "为角色等级、技能详情、声望详情、任务、邮件、商人等界面的滚动文本与定高文字补充顶部留白，解决鸿蒙字体字身偏高导致的顶部裁切。",
        getValue = function() return db.harmonyFontGuard ~= false end,
        setValue = function(v)
            db.harmonyFontGuard = v == true
            pcall(windowPolish.ApplyFontClipGuard)
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "角色面板精修（列表缩进/复选框/PvP 框）",
        tooltip = "为声望与技能子项增加层级缩进对齐，将声望详情复选框与 PvP 奖励棕色浮雕框统一为现代黑曜石扁平风。",
        getValue = function() return db.charFramePolish ~= false end,
        setValue = function(v) db.charFramePolish = v == true; RefreshAllCharacterBars() end,
    }, {
        type = "toggle",
        text = "高清矢量宠物快乐度图标",
        tooltip = "将宠物框体旁模糊的老版快乐度像素图替换为 128px 高清矢量徽章，完整保留点击喂食菜单与提示。",
        getValue = function() return db.hdPetHappy ~= false end,
        setValue = function(v) db.hdPetHappy = v == true; RefreshHDPetHappiness() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "小地图 NPC 图标去重（交由 Polestar 统一显示）",
        tooltip = "同时安装 Polestar 与 Questie 时，自动关闭 Questie 重复的城镇 NPC 图标（飞行点/旅店/邮箱/修理/银行/拍卖/训练师等），统一使用 Polestar 清晰图标；Questie 的任务感叹号与问号完整保留。",
        getValue = function() return db.dedupMinimapNPC ~= false end,
        setValue = function(v)
            db.dedupMinimapNPC = v == true
            if v then ApplyQuestieTownsfolkDedup(true) end
        end,
    }, {
        type = "toggle",
        text = "世界地图底部坐标去重（保留 Polestar 单套）",
        tooltip = "同时安装 Polestar 与 Leatrix_Maps 时，自动隐藏 Leatrix_Maps / 暴雪重叠的世界地图底部坐标，只保留 Polestar 清晰单套坐标栏。",
        getValue = function() return db.dedupWorldMapCoords ~= false end,
        setValue = function(v)
            db.dedupWorldMapCoords = v == true
            pcall(windowPolish.ApplyWorldMapCoordsDedup)
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "静音射箭/攻击时角色喊声（「啊/哈」声）",
        tooltip = "使用游戏内置静音接口仅屏蔽当前角色射箭、挥砍时的发声喊叫，不影响弓弦、技能音效或 NPC/BOSS 语音，实时生效无需重载。",
        getValue = function() return db.muteAttackGrunts ~= false end,
        setValue = function(v)
            db.muteAttackGrunts = v == true
            pcall(windowPolish.ApplyCombatSoundMute)
        end,
    }, {
        type = "toggle",
        text = "同时静音拉弓吱嘎声",
        tooltip = "额外屏蔽拉弓时的重复吱嘎音效（保留箭矢离弦与命中音效），实时生效。",
        getValue = function() return db.muteBowPullback == true end,
        setValue = function(v)
            db.muteBowPullback = v == true
            pcall(windowPolish.ApplyCombatSoundMute)
        end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "飞行计时器去重",
        tooltip = "自动解决 Polestar 黑影卡片与 EUI 极简细线飞行条重复叠加的问题（推荐保留 EUI 细线飞行条）。",
        values = {
            keep_eui      = "保留 EUI 极简细线条（隐藏 Polestar 重复框）",
            keep_polestar = "保留 Polestar 卡片（隐藏 EUI 飞行条）",
            both          = "不干预（两者均保留）",
        },
        order = { "keep_eui", "keep_polestar", "both" },
        getValue = function() return db.flightTimerMode or "keep_eui" end,
        setValue = function(v) db.flightTimerMode = v; ApplyFlightTimerDedup() end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "战斗伤害字体（仅改伤害/治疗数字）",
        tooltip = "仅修改头顶飘出的战斗伤害/治疗/闪避字体（内置完整简体中文防方框），其余界面字体 100% 保持原样。\n切换后重新登录角色或重启游戏生效。",
        values = {
            youshe  = "优设标题黑（AION 2 锐利斜体·推荐）",
            smiley  = "得意黑 SmileySans（现代修长斜体）",
            default = "保持游戏原生字体",
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
                    F.Print("战斗伤害字体已切换，重新登录角色后生效（仅影响伤害数字，其他字体不变）。")
                else
                    F.Print("战斗伤害字体已保存，完全退出并重启一次游戏后即可加载新字体文件。")
                end
            end
        end,
    }, {
        type = "toggle",
        text = "同步美化 BugSack 与冲突弹窗",
        tooltip = "同步美化 BugSack，并在检测到 EUI DataBars（与底部系统栏重叠）或 EUI 冷却管理器（与 ArcAuras 冲突）同时启用时弹窗询问停用。",
        getValue = function() return db.conflictCheck ~= false end,
        setValue = function(v) db.conflictCheck = v == true; db.skinBugSack = v == true; SkinBugSackIfReady() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "训练师/野兽训练自动隐藏「已学会」技能",
        tooltip = "打开职业训练师或猎人野兽训练窗口时自动取消勾选「已学会」，不再满屏显示旧技能（打开期间仍可点右上角过滤器临时查看）。",
        getValue = function() return db.trainerHideUsed ~= false end,
        setValue = function(v) db.trainerHideUsed = v == true end,
    }, {
        type = "toggle",
        text = "同时隐藏「暂不可学」技能（只看最新可学）",
        tooltip = "打开训练师/野兽训练窗口时一并隐藏等级未到的技能，只显示当前可直接学习的最新技能。",
        getValue = function() return db.trainerHideUnavailable ~= false end,
        setValue = function(v) db.trainerHideUnavailable = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "战斗飘字智能分级（受伤大字 / 经验小字）",
        tooltip = "自动拉开飘字层级：自身受伤数字默认加大至 34px 更醒目，2D 经验/声望自动缩为 15px，同时温和收敛 3D 世界飘字缩放（绝不影响其他界面字体）。",
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
        text = "3D 打怪伤害/世界飘字缩放",
        tooltip = "实时调节 3D 头顶打怪伤害与击杀经验的整体缩放（同步 WorldTextScale_v2；默认 1.00 原尺寸清晰显示，脱战立即生效）。",
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
        text = "自身受伤飘字字号",
        tooltip = "实时调节角色自身受到物理/法术伤害时的滚动飘字大小（默认 34，暴击自动更大），调大更易察觉掉血。",
        min = 20, max = 48, step = 1,
        getValue = function() return db.incomingDamageSize or 34 end,
        setValue = function(v) db.incomingDamageSize = math_floor(v + 0.5) end,
    }, {
        type = "slider",
        text = "2D 经验/声望飘字字号",
        tooltip = "实时调节 2D 滚动战斗文字中经验值、声望与荣誉提示的字号（默认 15，小巧不抢镜）。",
        min = 12, max = 24, step = 1,
        getValue = function() return db.combatXPSize or 15 end,
        setValue = function(v) db.combatXPSize = math_floor(v + 0.5) end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "dropdown",
        text = "3D 打怪伤害飘字弹道",
        tooltip = "打怪伤害均由暴雪原生引擎渲染（零插件延迟）；但远程箭矢飞行 + 1.5 倍散射弧线会让数字起飞体感略慢。切换「经典直出」可让命中数字第一时间干脆上浮。",
        values = {
            keep    = "保持游戏默认（1.5x 散射弧线）",
            compact = "紧凑爆发（1.0x 小弧线）",
            classic = "经典干脆直出（0 散射·观感最快）",
        },
        order = { "keep", "compact", "classic" },
        getValue = function() return db.damageArcMode or "keep" end,
        setValue = function(v)
            db.damageArcMode = v
            ApplyWorldTextScale()
        end,
    }, blank)
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "美化并下移「世界刷新」倒计时提示框",
        tooltip = "美化无限服自带的世界刷新倒计时提示条，移至标记条正下方避开经验条；普通左键仍可立即刷新，Shift+左键可自由拖动。",
        getValue = function() return db.skinWorldRefresh ~= false end,
        setValue = function(v)
            db.skinWorldRefresh = v == true
            RefreshWorldRefreshBanner()
        end,
    }, blank)
    y = y - h
    return y
end

