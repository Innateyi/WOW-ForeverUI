----------------------------------------------------------------------
--  kkowoUI_Integrations — NameplateSmart.lua
--  独立模块：姓名板与主城减卡优化（从原 ModernChrome.lua 独立拆分）
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end

local ipairs, pairs, pcall, tostring, type = ipairs, pairs, pcall, tostring, type
local C_Timer = C_Timer

----------------------------------------------------------------------
--  独立子模块：nameplateSmart — 姓名板与主城减卡优化
--  （内嵌在已加载文件内，支持游戏内 /reload 即刻生效，无需重启客户端）
--  • 压制 EUI「友方仅名称」模式强制开启 UnitNameFriendlyPlayerName=1 的问题
--  • 默认主城 / 休整区自动隐藏友方玩家 ID、公会/头衔与友方玩家姓名板，大幅减卡
--  • 支持：主城隐藏 / 仅副本显示 / 全局隐藏 / 不干预 + 可选主城隐藏友方 NPC 姓名板
--  • 可选统一 45 码外原生 NPC 名称（保持默认 / 仅任务 NPC / 全部关闭）
----------------------------------------------------------------------
do
    local npMod = F.RegisterModule("nameplateSmart", {
        title = "主城姓名板减卡",
        desc = "在主城自动或全局隐藏友方玩家名与公会，缓解人群卡顿。",
        group = "visual",
        order = 15,
        defaults = {
            enabled = true,
            friendlyMode = "city_hide",     -- "city_hide" | "instance_only" | "always_hide" | "keep"
            hideGuildTitle = true,          -- 隐藏友方玩家 ID 时同步隐藏公会/头衔
            guildTitleAlways = false,       -- 公会/头衔在所有地方都隐藏（含自己名字下方的公会），不只在主城
            hideCityNpcPlates = false,      -- 主城/休整区同时隐藏友方 NPC 姓名板（卫兵/商人等）
            distantNpcMode = "keep",        -- "keep" | "quest_only" | "hide_all"
            savedFriendly = nil,
            savedNpcPlates = nil,
            savedDistantNpc = nil,
        },
    })

    local FRIENDLY_NAME_CVARS = {
        "UnitNameFriendlyPlayerName",
        "nameplateShowFriendlyPlayers",
        "nameplateShowFriends",
    }
    local FRIENDLY_EXTRA_CVARS = {
        "UnitNamePlayerGuild",
        "UnitNamePlayerPVPTitle",
    }
    local FRIENDLY_NPC_PLATE_CVARS = {
        "nameplateShowFriendlyNPCs",
        "nameplateShowFriendlyNpcs",
    }
    local WATCHED_NP_CVARS = {
        UnitNameFriendlyPlayerName = true,
        nameplateShowFriendlyPlayers = true,
        nameplateShowFriends = true,
        nameplateShowFriendlyNPCs = true,
        nameplateShowFriendlyNpcs = true,
        UnitNamePlayerGuild = true,
        UnitNamePlayerPVPTitle = true,
    }
    local DISTANT_NPC_CVARS = {
        "UnitNameNPC",
        "UnitNameHostleNPC",
        "UnitNameInteractiveNPC",
        "UnitNameFriendlySpecialNPCName",
        "UnitNameNonCombatCreatureName",
    }

    local euiHideHooked = false
    local writingSelf = false
    -- [cvar] = { value, t }：记录本模块最近一次写入，CVAR_UPDATE 即便晚于 SetCVar 返回才派发，也不会被误判为玩家手动修改
    local selfWrites = {}
    local euiGuardUntil = 0
    local manualOverrides = {}
    local lastShouldHide = false

    local function ClearManualOverrides()
        for k in pairs(manualOverrides) do
            manualOverrides[k] = nil
        end
    end

    local function ArmEUIGuard(seconds)
        local now = _G.GetTime and _G.GetTime() or 0
        local untilT = now + (seconds or 4.5)
        if untilT > euiGuardUntil then
            euiGuardUntil = untilT
        end
    end

    local function SafeGetCVar(name)
        local CV = _G.C_CVar
        if CV and CV.GetCVar then
            local ok, v = pcall(CV.GetCVar, name)
            if ok then return F.PlainString(v, nil) end
        elseif _G.GetCVar then
            local ok, v = pcall(_G.GetCVar, name)
            if ok then return F.PlainString(v, nil) end
        end
        return nil
    end

    local CVAR_ALIAS_PARTNER = {
        nameplateShowFriendlyPlayers = "nameplateShowFriends",
        nameplateShowFriends         = "nameplateShowFriendlyPlayers",
        nameplateShowFriendlyNPCs    = "nameplateShowFriendlyNpcs",
        nameplateShowFriendlyNpcs    = "nameplateShowFriendlyNPCs",
    }

    local function SafeSetCVar(name, value)
        local cur = SafeGetCVar(name)
        if cur == nil then return false end
        local want = tostring(value)
        if cur == want then return true end
        writingSelf = true
        local now = _G.GetTime and _G.GetTime() or 0
        selfWrites[name] = { value = want, t = now }
        local partner = CVAR_ALIAS_PARTNER[name]
        if partner then
            selfWrites[partner] = { value = want, t = now }
        end
        local ok = false
        local CV = _G.C_CVar
        if CV and CV.SetCVar then
            ok = pcall(CV.SetCVar, name, want)
        elseif _G.SetCVar then
            ok = pcall(_G.SetCVar, name, want)
        end
        writingSelf = false
        return ok
    end

    local function IsInCombatInstance()
        if not _G.GetInstanceInfo then return false end
        local _, iType = _G.GetInstanceInfo()
        return iType == "party" or iType == "raid" or iType == "scenario" or iType == "arena" or iType == "pvp"
    end

    local function IsInCityOrRest()
        if IsInCombatInstance() then return false end
        return (_G.IsResting and _G.IsResting()) and true or false
    end

    local function SnapshotCVars(store, list)
        local snap = type(store) == "table" and store or {}
        for _, name in ipairs(list) do
            if snap[name] == nil then
                local cur = SafeGetCVar(name)
                if cur ~= nil then
                    snap[name] = cur
                end
            end
        end
        return snap
    end

    local function RestoreCVars(store)
        if type(store) ~= "table" then return end
        for name, orig in pairs(store) do
            if orig ~= nil then
                SafeSetCVar(name, orig)
            end
        end
    end

    local function ApplyFriendlyPolicy(db)
        local mode = db.friendlyMode or "city_hide"
        local shouldHide = false
        if mode == "always_hide" then
            shouldHide = true
        elseif mode == "city_hide" then
            shouldHide = IsInCityOrRest()
        elseif mode == "instance_only" then
            shouldHide = not IsInCombatInstance()
        end

        -- 离开隐藏区域（例如走出主城）时重置单次手动放行标记
        if lastShouldHide and not shouldHide then
            ClearManualOverrides()
        end
        lastShouldHide = shouldHide

        -- 「公会/头衔始终隐藏」独立于主城策略：单独快照 savedGuild，关掉后原样还原。
        -- 先于下面的友方策略处理，切换模式时公会/头衔的原值不会被对方的快照吃掉
        local alwaysGuild = db.hideGuildTitle ~= false and db.guildTitleAlways == true
        if alwaysGuild then
            if type(db.savedFriendly) == "table" then
                for _, name in ipairs(FRIENDLY_EXTRA_CVARS) do
                    if db.savedFriendly[name] ~= nil then
                        db.savedGuild = type(db.savedGuild) == "table" and db.savedGuild or {}
                        if db.savedGuild[name] == nil then db.savedGuild[name] = db.savedFriendly[name] end
                        db.savedFriendly[name] = nil
                    end
                end
            end
            db.savedGuild = SnapshotCVars(db.savedGuild, FRIENDLY_EXTRA_CVARS)
            for _, name in ipairs(FRIENDLY_EXTRA_CVARS) do
                if not manualOverrides[name] then
                    SafeSetCVar(name, "0")
                end
            end
        elseif db.savedGuild then
            RestoreCVars(db.savedGuild)
            db.savedGuild = nil
        end

        if shouldHide then
            db.savedFriendly = SnapshotCVars(db.savedFriendly, FRIENDLY_NAME_CVARS)
            if db.hideGuildTitle ~= false and not alwaysGuild then
                db.savedFriendly = SnapshotCVars(db.savedFriendly, FRIENDLY_EXTRA_CVARS)
            end
            for _, name in ipairs(FRIENDLY_NAME_CVARS) do
                if not manualOverrides[name] then
                    SafeSetCVar(name, "0")
                end
            end
            if db.hideGuildTitle ~= false then
                for _, name in ipairs(FRIENDLY_EXTRA_CVARS) do
                    if not manualOverrides[name] then
                        SafeSetCVar(name, "0")
                    end
                end
            elseif db.savedFriendly then
                -- 仍在主城但用户取消了「同时隐藏公会/头衔」：立即把这两项还原，而不是等离开主城
                for _, name in ipairs(FRIENDLY_EXTRA_CVARS) do
                    local orig = db.savedFriendly[name]
                    if orig ~= nil then
                        SafeSetCVar(name, orig)
                        db.savedFriendly[name] = nil
                    end
                end
            end
        elseif db.savedFriendly then
            RestoreCVars(db.savedFriendly)
            db.savedFriendly = nil
        end

        local hideNpcPlates = (db.hideCityNpcPlates == true) and IsInCityOrRest()
        if hideNpcPlates then
            db.savedNpcPlates = SnapshotCVars(db.savedNpcPlates, FRIENDLY_NPC_PLATE_CVARS)
            for _, name in ipairs(FRIENDLY_NPC_PLATE_CVARS) do
                if not manualOverrides[name] then
                    SafeSetCVar(name, "0")
                end
            end
        elseif db.savedNpcPlates then
            RestoreCVars(db.savedNpcPlates)
            db.savedNpcPlates = nil
        end
    end

    local function ApplyDistantNpcPolicy(db)
        local mode = db.distantNpcMode or "keep"
        if mode == "keep" then
            if db.savedDistantNpc then
                RestoreCVars(db.savedDistantNpc)
                db.savedDistantNpc = nil
            end
            return
        end
        db.savedDistantNpc = SnapshotCVars(db.savedDistantNpc, DISTANT_NPC_CVARS)
        SafeSetCVar("UnitNameNPC", "0")
        SafeSetCVar("UnitNameHostleNPC", "0")
        SafeSetCVar("UnitNameInteractiveNPC", "0")
        SafeSetCVar("UnitNameNonCombatCreatureName", "0")
        if mode == "quest_only" then
            SafeSetCVar("UnitNameFriendlySpecialNPCName", "1")
        else
            SafeSetCVar("UnitNameFriendlySpecialNPCName", "0")
        end
    end

    local function ApplyAll()
        if not npMod._active then return end
        F.RunOutOfCombat("FUI_NameplateSmart", function()
            if not npMod._active then return end
            local db = npMod:GetDB()
            ApplyFriendlyPolicy(db)
            ApplyDistantNpcPolicy(db)
        end)
    end

    local function RestoreAll()
        F.RunOutOfCombat("FUI_NameplateSmart", function()
            local db = npMod:GetDB()
            if db.savedFriendly then
                RestoreCVars(db.savedFriendly)
                db.savedFriendly = nil
            end
            if db.savedNpcPlates then
                RestoreCVars(db.savedNpcPlates)
                db.savedNpcPlates = nil
            end
            if db.savedGuild then
                RestoreCVars(db.savedGuild)
                db.savedGuild = nil
            end
            if db.savedDistantNpc then
                RestoreCVars(db.savedDistantNpc)
                db.savedDistantNpc = nil
            end
        end)
    end

    local function HookEUIHideOnce()
        if euiHideHooked then return end
        local EUI = _G.EllesmereUI
        if EUI and EUI.RegisterOnHide then
            euiHideHooked = true
            pcall(EUI.RegisterOnHide, EUI, function()
                ArmEUIGuard(2.5)
                C_Timer.After(0.25, ApplyAll)
            end)
        end
    end

    local MODE_ORDER = { "city_hide", "always_hide", "instance_only", "keep" }
    local MODE_LABELS = {
        city_hide     = "主城/休整区自动隐藏",
        always_hide   = "全局彻底隐藏友方 ID",
        instance_only = "仅副本内显示（主城+野外隐藏）",
        keep          = "不干预（交由游戏与 EUI）",
    }

    function npMod:CycleFriendlyMode(explicitMode)
        local db = self:GetDB()
        local alias = {
            city = "city_hide",
            off = "always_hide",
            hide = "always_hide",
            dungeon = "instance_only",
            instance = "instance_only",
            on = "keep",
            keep = "keep",
        }
        local target = explicitMode and (alias[explicitMode] or (MODE_LABELS[explicitMode] and explicitMode)) or nil
        if not target then
            local cur = db.friendlyMode or "city_hide"
            local idx = 1
            for i, m in ipairs(MODE_ORDER) do
                if m == cur then idx = i; break end
            end
            target = MODE_ORDER[(idx % #MODE_ORDER) + 1]
        end
        db.friendlyMode = target
        ClearManualOverrides()
        ApplyAll()
        F.Print("友方玩家名字策略已切换为：|cff5fd3a6" .. (MODE_LABELS[target] or target) .. "|r")
    end

    function npMod:OnEnable()
        local QueueApply = F.Debounce(0.25, ApplyAll)
        ArmEUIGuard(4.5)
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
            ArmEUIGuard(4.5)
            ApplyAll()
            C_Timer.After(0.6, ApplyAll)
            C_Timer.After(2.0, ApplyAll)
            C_Timer.After(3.5, ApplyAll)
            C_Timer.After(1.0, HookEUIHideOnce)
        end)
        self:RegisterEvent("PLAYER_UPDATE_RESTING", ApplyAll)
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
            ArmEUIGuard(3.0)
            ApplyAll()
            C_Timer.After(1.0, ApplyAll)
        end)
        -- 战斗中被推迟的 ApplyAll 已由 F.RunOutOfCombat 在 PLAYER_REGEN_ENABLED 统一补跑，无需每次脱战再查一遍 CVar
        self:RegisterEvent("CVAR_UPDATE", function(_, _, cvar, val)
            if not WATCHED_NP_CVARS[cvar] then return end
            local pendingSelf = selfWrites[cvar]
            selfWrites[cvar] = nil
            if writingSelf then return end
            if pendingSelf then
                local written = F.PlainString(val, nil) or SafeGetCVar(cvar)
                local age = (_G.GetTime and _G.GetTime() or 0) - pendingSelf.t
                if written == pendingSelf.value and age < 2 then return end
            end
            local db = npMod:GetDB()
            local settingsOpen = _G.SettingsPanel and _G.SettingsPanel.IsShown and _G.SettingsPanel:IsShown()
            local euiOpen = _G.EllesmereUI and _G.EllesmereUI._mainFrame
                and _G.EllesmereUI._mainFrame.IsShown and _G.EllesmereUI._mainFrame:IsShown()
            local now = _G.GetTime and _G.GetTime() or 0
            local inGuardWindow = (now <= euiGuardUntil) or euiOpen

            -- 玩家在暴雪「选项 → 姓名板」点击勾选框，或平时按 Shift+V 等快捷键修改：
            -- 绝不自动取消勾选，同步记录到快照并在本次停留期间放行
            if settingsOpen or not inGuardWindow then
                local cur = F.PlainString(val, nil) or SafeGetCVar(cvar)
                if cur ~= nil then
                    local aliases = (cvar == "nameplateShowFriends" or cvar == "nameplateShowFriendlyPlayers")
                        and { "nameplateShowFriends", "nameplateShowFriendlyPlayers" }
                        or (cvar == "nameplateShowFriendlyNPCs" or cvar == "nameplateShowFriendlyNpcs")
                        and { "nameplateShowFriendlyNPCs", "nameplateShowFriendlyNpcs" }
                        or { cvar }
                    for _, k in ipairs(aliases) do
                        if type(db.savedFriendly) == "table" and db.savedFriendly[k] ~= nil then
                            db.savedFriendly[k] = cur
                        end
                        if type(db.savedNpcPlates) == "table" and db.savedNpcPlates[k] ~= nil then
                            db.savedNpcPlates[k] = cur
                        end
                        if type(db.savedGuild) == "table" and db.savedGuild[k] ~= nil then
                            db.savedGuild[k] = cur
                        end
                        if cur == "1" then
                            manualOverrides[k] = true
                        else
                            manualOverrides[k] = nil
                        end
                    end
                    if cur == "1" and (db.friendlyMode or "city_hide") ~= "keep" and lastShouldHide then
                        F.PrintOnce("np_manual_override",
                            "已保留你手动开启的友方姓名/姓名板设置（本次已暂停主城自动隐藏）。如需永久交由游戏设置管理，请在 /kk → 姓名板与主城减卡优化 选「不干预」，或输入 /kk friendly keep。")
                    end
                end
                return
            end

            -- 仅在登录/切图/关闭 EUI 设置的短暂保护窗口内，压制 EUI 自动写回
            if not manualOverrides[cvar] then
                QueueApply()
            end
        end)

        ApplyAll()
        C_Timer.After(0.6, ApplyAll)
        C_Timer.After(1.0, HookEUIHideOnce)
        C_Timer.After(2.0, ApplyAll)
    end

    function npMod:OnDisable()
        ClearManualOverrides()
        lastShouldHide = false
        RestoreAll()
    end

    function npMod:BuildOptions(W, parent, y, enableSlot, blank)
        local db = self:GetDB()
        local _, h
        _, h = W:DualRow(parent, y, enableSlot, {
            type = "dropdown",
            text = "友方名字策略",
            tooltip = "控制友方玩家名字显示时机以缓解卡顿，可用 /kk friendly 切换。",
            values = {
                city_hide     = "主城/休整区自动隐藏（推荐）",
                instance_only = "仅副本内显示（主城+野外隐藏）",
                always_hide   = "全局彻底隐藏友方 ID",
                keep          = "不干预（交由游戏与 EUI）",
            },
            order = { "city_hide", "instance_only", "always_hide", "keep" },
            getValue = function() return db.friendlyMode or "city_hide" end,
            setValue = function(v) db.friendlyMode = v; ClearManualOverrides(); ApplyAll() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "隐藏公会与头衔",
            tooltip = "隐藏友方玩家 ID 时一并关闭公会与头衔渲染，主城帧数提升更明显。",
            getValue = function() return db.hideGuildTitle ~= false end,
            setValue = function(v) db.hideGuildTitle = v == true; ClearManualOverrides(); ApplyAll() end,
        }, {
            type = "toggle",
            text = "主城藏友方NPC",
            tooltip = "在主城隐藏卫兵与商人姓名板提升帧率，离开主城自动恢复。",
            getValue = function() return db.hideCityNpcPlates == true end,
            setValue = function(v) db.hideCityNpcPlates = v == true; ClearManualOverrides(); ApplyAll() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "全局藏公会头衔",
            tooltip = "在野外与副本也隐藏公会和头衔，需先开启隐藏公会与头衔。",
            getValue = function() return db.guildTitleAlways == true end,
            setValue = function(v) db.guildTitleAlways = v == true; ClearManualOverrides(); ApplyAll() end,
        }, blank)
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "dropdown",
            text = "远处NPC名称",
            tooltip = "关闭 45 码外原版 NPC 名称，仅在姓名板范围内统一显示。",
            values = {
                keep       = "保持当前游戏设置",
                quest_only = "仅显示远处任务/特殊 NPC",
                hide_all   = "关闭远处原生字（视觉最统一）",
            },
            order = { "keep", "quest_only", "hide_all" },
            getValue = function() return db.distantNpcMode or "keep" end,
            setValue = function(v) db.distantNpcMode = v; ApplyAll() end,
        }, blank)
        y = y - h
        return y
    end
end
