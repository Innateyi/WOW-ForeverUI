----------------------------------------------------------------------
--  kkowoUI — Core/Guard.lua
--  常驻核心守卫与总控运行时（无需加载 kkowoUI_Options 即可登录生效）：
--    • F.RunSlashCommand：12.1 兼容 hash_SlashCmdList + SlashCmdList 调度
--    • F.LaunchFromEUI：从 EUI 总控台打开子界面，关闭/ESC 后自动返回打开前页面
--    • 零补丁 ESC 关闭增强：BigWigs AceGUI + BugSack + SettingsPanel(GTFO/Auctionator/SAO)
--    • PatchGuard：登录后 4.5s 静默巡检仅剩的 3 个极简补丁
--    • DeadGuard：登录后 3s 自动停用被网易 DD 放回的正式服死目录 / 已替换旧插件
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, setmetatable, tostring, type =
    ipairs, pairs, pcall, setmetatable, tostring, type
local table_concat = table.concat
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local InCombatLockdown = InCombatLockdown

local mod = F.RegisterModule("controlHub", {
    title = "总控与体检守卫",
    desc = "集中打开常用插件，提供启动巡检、按键返回与重叠开关体检。",
    group = "hub",
    order = 1,
    defaults = {
        enabled = true,
        patchGuardAlert = true,
    },
})

-- ---------------------------------------------------------------------------
-- 1) 通用安全斜杠命令调度（12.1 优先查 hash_SlashCmdList，回退 SlashCmdList）
-- ---------------------------------------------------------------------------
function F.RunSlashCommand(slash, arg)
    if InCombatLockdown and InCombatLockdown() then
        F.Print("|cffe0a24b战斗中无法打开设置，脱战后再试。|r")
        return false
    end
    local target = tostring(slash or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if target == "" then
        return false
    end
    if target:sub(1, 1) ~= "/" then
        target = "/" .. target
    end
    local targetUpper = target:upper()
    local targetLower = target:lower()

    if type(_G.hash_SlashCmdList) == "table" then
        local hashed = _G.hash_SlashCmdList[targetUpper]
        if type(hashed) == "function" then
            local ok = pcall(hashed, arg or "")
            return ok
        end
    end

    if type(_G.SlashCmdList) == "table" then
        for key, handler in pairs(_G.SlashCmdList) do
            if type(handler) == "function" then
                local i = 1
                while i <= 16 do
                    local cmd = _G["SLASH_" .. key .. tostring(i)]
                    if not cmd then break end
                    if type(cmd) == "string" and cmd:lower() == targetLower then
                        local ok = pcall(handler, arg or "")
                        return ok
                    end
                    i = i + 1
                end
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- 2) 从 EUI 总控台启动子窗口，关闭（按 ESC 或点 X）后自动返回打开前的 EUI 页面
-- ---------------------------------------------------------------------------
local function IsSafeFrame(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function IsFrameShown(f)
    if not (IsSafeFrame(f) and type(f.IsShown) == "function") then return false end
    local ok, shown = pcall(f.IsShown, f)
    return ok and shown == true
end

local function IsEUIMainShown()
    local EUI = _G.EllesmereUI
    if type(EUI) ~= "table" then return false end
    if EUI._mainFrame then
        return IsFrameShown(EUI._mainFrame)
    end
    if type(EUI.IsShown) == "function" then
        local ok, shown = pcall(EUI.IsShown, EUI)
        if ok then return shown == true end
    end
    return false
end

local pendingReturnFrame = nil
local returnHooked = setmetatable({}, { __mode = "k" })
local overlayHooked = setmetatable({}, { __mode = "k" })
local overlaySavedLayer = setmetatable({}, { __mode = "k" })
local activeOverlayFrame = nil
local overlaySwallowFrame = nil
local euiMainShowHooked = false

local STRATA_ORDER = {
    BACKGROUND = 1,
    LOW = 2,
    MEDIUM = 3,
    HIGH = 4,
    DIALOG = 5,
    FULLSCREEN = 6,
    FULLSCREEN_DIALOG = 7,
    TOOLTIP = 8,
}

local function IsInUISpecialFrames(frame)
    local name = frame and frame.GetName and F.PlainString(frame:GetName(), nil)
    if not name or name == "" then return false end
    local special = _G.UISpecialFrames
    if type(special) ~= "table" then return false end
    for _, existing in ipairs(special) do
        if existing == name then return true end
    end
    return false
end

local function EnsureOverlaySwallowFrame()
    if overlaySwallowFrame then return overlaySwallowFrame end
    local sf = CreateFrame("Frame", "kkowoUI_OverlayEscSwallow", _G.UIParent)
    sf:SetSize(1, 1)
    sf:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", -10, 10)
    sf:EnableMouse(false)
    sf:Hide()
    local EUI = _G.EllesmereUI
    if EUI and type(EUI.RegisterEscapeClose) == "function" then
        pcall(EUI.RegisterEscapeClose, sf, { notOwned = true, modal = true })
    end
    overlaySwallowFrame = sf
    return sf
end

local function RestoreOverlayLayer(frame)
    local saved = frame and overlaySavedLayer[frame]
    if not saved then return end
    overlaySavedLayer[frame] = nil
    if InCombatLockdown and InCombatLockdown() then return end
    if IsSafeFrame(frame) then
        if saved.strata and frame.SetFrameStrata then pcall(frame.SetFrameStrata, frame, saved.strata) end
        if saved.level and frame.SetFrameLevel then pcall(frame.SetFrameLevel, frame, saved.level) end
    end
end

local function ClearOverlaySwallowDeferred()
    if not overlaySwallowFrame then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if overlaySwallowFrame and (not activeOverlayFrame or not IsFrameShown(activeOverlayFrame)) then
                overlaySwallowFrame:Hide()
            end
        end)
    else
        overlaySwallowFrame:Hide()
    end
end

local function EnsureEUIMainShowCancelHook()
    if euiMainShowHooked then return end
    local EUI = _G.EllesmereUI
    local mf = type(EUI) == "table" and EUI._mainFrame
    if mf and IsSafeFrame(mf) and mf.HookScript then
        euiMainShowHooked = true
        mf:HookScript("OnShow", function()
            pendingReturnFrame = nil
        end)
        mf:HookScript("OnHide", function()
            if overlaySwallowFrame and overlaySwallowFrame:IsShown() then
                overlaySwallowFrame:Hide()
            end
        end)
    end
end

local function OnTrackedFrameHide(self)
    if pendingReturnFrame ~= self then return end
    pendingReturnFrame = nil
    if not (C_Timer and C_Timer.After) then return end
    -- 延迟 0.04s 确保暴雪原生 HideUIPanel(SettingsPanel) 与 ESC 退出栈完全收尾后再恢复 EUI
    C_Timer.After(0.04, function()
        if InCombatLockdown and InCombatLockdown() then return end
        if IsEUIMainShown() then return end
        if IsFrameShown(_G.GameMenuFrame) then return end
        local EUI = _G.EllesmereUI
        if type(EUI) == "table" and type(EUI.Show) == "function" then
            pcall(EUI.Show, EUI)
        end
    end)
end

local function ArmReturnToEUI(frame)
    if not (frame and IsSafeFrame(frame) and frame.HookScript) then return false end
    pendingReturnFrame = frame
    if not returnHooked[frame] then
        returnHooked[frame] = true
        frame:HookScript("OnHide", OnTrackedFrameHide)
    end
    return true
end

local function OnOverlayFrameHide(self)
    RestoreOverlayLayer(self)
    if activeOverlayFrame == self then
        activeOverlayFrame = nil
        ClearOverlaySwallowDeferred()
    end
end

-- 将独立插件窗口叠放在 EUI 设置面板上层（EUI 保持打开零闪烁；按 ESC 仅关上层弹窗）
local function ArmOverlayAboveEUI(frame, closeFn)
    if not (frame and IsSafeFrame(frame)) then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    local EUI = _G.EllesmereUI
    local mf = type(EUI) == "table" and EUI._mainFrame or nil
    if not (mf and IsFrameShown(mf)) then return false end

    if activeOverlayFrame and activeOverlayFrame ~= frame then
        RestoreOverlayLayer(activeOverlayFrame)
    end
    activeOverlayFrame = frame

    -- 记录原层级并抬升到 EUI 主面板之上（高一档或同档 +30 级）
    if not overlaySavedLayer[frame] then
        overlaySavedLayer[frame] = {
            strata = frame.GetFrameStrata and F.PlainString(frame:GetFrameStrata(), nil) or nil,
            level  = frame.GetFrameLevel and F.PlainNumber(frame:GetFrameLevel(), nil) or nil,
        }
    end
    local euiStrata = mf.GetFrameStrata and F.PlainString(mf:GetFrameStrata(), "DIALOG") or "DIALOG"
    local euiLevel = mf.GetFrameLevel and F.PlainNumber(mf:GetFrameLevel(), 100) or 100
    local curStrata = frame.GetFrameStrata and F.PlainString(frame:GetFrameStrata(), "MEDIUM") or "MEDIUM"
    local targetStrata = (STRATA_ORDER[curStrata] or 3) > (STRATA_ORDER[euiStrata] or 5) and curStrata or euiStrata
    if frame.SetFrameStrata then pcall(frame.SetFrameStrata, frame, targetStrata) end
    if targetStrata == euiStrata and frame.SetFrameLevel then
        local curLevel = frame.GetFrameLevel and F.PlainNumber(frame:GetFrameLevel(), 0) or 0
        if curLevel <= euiLevel + 50 then
            pcall(frame.SetFrameLevel, frame, euiLevel + 60)
        end
    end
    if frame.Raise then pcall(frame.Raise, frame) end

    if not overlayHooked[frame] and frame.HookScript then
        overlayHooked[frame] = true
        frame:HookScript("OnHide", OnOverlayFrameHide)
    end

    if IsInUISpecialFrames(frame) then
        -- 窗口自身已在 UISpecialFrames：ESC 由暴雪关闭该窗口，同步用 modal 哨兵吞掉当帧 EUI EscapeProxy，避免底下的 EUI 一起被关
        local sf = EnsureOverlaySwallowFrame()
        if sf then sf:Show() end
    elseif EUI and type(EUI.RegisterEscapeClose) == "function" then
        -- 窗口不在 UISpecialFrames（如 BigWigs/BugSack/键位图）：重挂至 EUI ESC 栈最顶端，按一次 ESC 只关该弹窗
        if overlaySwallowFrame then overlaySwallowFrame:Hide() end
        if type(EUI._ForgetEscapeClose) == "function" then
            pcall(EUI._ForgetEscapeClose, frame)
        end
        pcall(EUI.RegisterEscapeClose, frame, {
            notOwned = true,
            onEscape = type(closeFn) == "function" and closeFn or nil,
        })
        local proxy = _G.EllesmereUI_EscapeProxy
        if proxy and proxy.Show then pcall(proxy.Show, proxy) end
    end
    return true
end

local function SnapshotShownUIParentChildren()
    local snap = {}
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return snap end
    local children = { ui:GetChildren() }
    for _, child in ipairs(children) do
        if IsFrameShown(child) then
            snap[child] = true
        end
    end
    return snap
end

local function FindNewlyOpenedWindow(beforeSnap)
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    local EUI = _G.EllesmereUI
    local euiMain = type(EUI) == "table" and EUI._mainFrame or nil
    local escProxy = _G.EllesmereUI_EscapeProxy
    local gameMenu = _G.GameMenuFrame
    local layoutFrame = _G.UIPanelLayoutFrame
    local children = { ui:GetChildren() }
    local best, bestArea = nil, 0
    for _, child in ipairs(children) do
        if not beforeSnap[child]
            and child ~= euiMain and child ~= escProxy and child ~= overlaySwallowFrame
            and child ~= gameMenu and child ~= layoutFrame
            and IsFrameShown(child) then
            local strata = child.GetFrameStrata and F.PlainString(child:GetFrameStrata(), "") or ""
            if strata ~= "TOOLTIP" and strata ~= "BACKGROUND" then
                local okW, w = pcall(child.GetWidth, child)
                local okH, h = pcall(child.GetHeight, child)
                w = okW and F.PlainNumber(w, 0) or 0
                h = okH and F.PlainNumber(h, 0) or 0
                if w >= 180 and h >= 120 then
                    local area = w * h
                    if area > bestArea then
                        best = child
                        bestArea = area
                    end
                end
            end
        end
    end
    return best
end

-- expectedFrameFn 可选：明确返回目标框体（如 _G.SettingsPanel / _G.PolestarOptions）。
-- opts.hideEUI = true（用于受暴雪保护的 SettingsPanel）：先隐 EUI、让暴雪原生处理 ESC、关闭后自动恢复 EUI；
-- 默认（独立插件窗口）：保持 EUI 在下层打开不闪烁，抬升子窗口至 EUI 上层并让 ESC 仅关闭上层弹窗。
function F.LaunchFromEUI(fn, expectedFrameFn, opts)
    opts = type(opts) == "table" and opts or {}
    local EUI = _G.EllesmereUI
    local wasOpen = IsEUIMainShown()
    if not wasOpen then
        fn()
        return
    end
    EnsureEUIMainShowCancelHook()
    local beforeSnap = SnapshotShownUIParentChildren()
    pendingReturnFrame = nil

    local hideEUI = opts.hideEUI == true
    if hideEUI and EUI and type(EUI.Hide) == "function" then
        pcall(EUI.Hide, EUI)
    end

    local armed = false
    local function resolveOpenedFrame()
        if type(expectedFrameFn) == "function" then
            local okE, exp = pcall(expectedFrameFn)
            if okE and exp and IsFrameShown(exp) then
                return exp
            end
        end
        return FindNewlyOpenedWindow(beforeSnap)
    end

    local function tryArm()
        if armed then return true end
        if hideEUI and IsEUIMainShown() then return true end
        local opened = resolveOpenedFrame()
        if not opened then return false end
        if hideEUI then
            armed = ArmReturnToEUI(opened)
        else
            armed = ArmOverlayAboveEUI(opened, opts.onEscape)
        end
        return armed
    end

    local function runAndTrack()
        fn()
        if tryArm() then return end
        if C_Timer and C_Timer.After then
            -- 兼容 LoD 首次加载（Polestar_Options / BigWigs_Options）或延迟打开的面板
            for _, delay in ipairs({ 0.04, 0.14, 0.36 }) do
                C_Timer.After(delay, function()
                    if not armed then tryArm() end
                end)
            end
        end
    end

    -- 保持同步在按钮硬件点击栈内调用（绝不经 C_Timer.After 延迟调 Settings.OpenToCategory，避免 12.1 触发界面行为失效）
    runAndTrack()
end

-- ---------------------------------------------------------------------------
-- 3) 零补丁 ESC 关闭增强：仅限第三方无保护框体（BigWigs AceGUI + BugSack）
--    严禁向受暴雪保护的 SettingsPanel 挂载自定义 Escape 代理，避免触发界面行为失效
-- ---------------------------------------------------------------------------
local bwEscOwner = {}
local bwHooked = false
local bugSackHooked = false

local function BindBugSackEscapeClose()
    local bf = _G.BugSackFrame
    if bf and IsSafeFrame(bf) then
        F.Theme.RegisterEscapeClose(bf, function()
            local bs = _G.BugSack
            if type(bs) == "table" and type(bs.CloseSack) == "function" then
                pcall(bs.CloseSack, bs)
            elseif _G.BugSackFrame and _G.BugSackFrame.Hide then
                pcall(_G.BugSackFrame.Hide, _G.BugSackFrame)
            end
        end)
    end
end

local function BindVisibleBigWigsFrame()
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return end
    local children = { ui:GetChildren() }
    for _, child in ipairs(children) do
        if IsFrameShown(child) then
            local obj = child.obj
            if type(obj) == "table" and obj.type == "Frame" then
                local titleObj = obj.titletext
                local title = titleObj and titleObj.GetText and F.PlainString(titleObj:GetText(), "") or ""
                if title:find("BigWigs", 1, true) then
                    F.Theme.RegisterEscapeClose(child, function(fr)
                        if fr.obj and type(fr.obj.Hide) == "function" then
                            pcall(fr.obj.Hide, fr.obj)
                        else
                            pcall(fr.Hide, fr)
                        end
                    end)
                end
            end
        end
    end
end

F._BindVisibleBigWigsFrame = BindVisibleBigWigsFrame

local function SetupThirdPartyEscapeClose()
    if not bwHooked then
        local loader = _G.BigWigsLoader
        if type(loader) == "table" and type(loader.RegisterMessage) == "function" then
            bwHooked = true
            pcall(loader.RegisterMessage, bwEscOwner, "BigWigs_OpenGUI", function()
                BindVisibleBigWigsFrame()
                if C_Timer and C_Timer.After then
                    C_Timer.After(0, BindVisibleBigWigsFrame)
                end
            end)
        end
    end

    if not bugSackHooked and type(_G.BugSack) == "table" then
        bugSackHooked = true
        if type(_G.BugSack.OpenSack) == "function" then
            _G.hooksecurefunc(_G.BugSack, "OpenSack", BindBugSackEscapeClose)
        end
        if type(_G.BugSack.OpenConfig) == "function" then
            _G.hooksecurefunc(_G.BugSack, "OpenConfig", BindBugSackEscapeClose)
        end
        BindBugSackEscapeClose()
    end
end

-- ---------------------------------------------------------------------------
-- 4) 启动功能巡检：运行时核验仅剩的 2 个底层加速模块是否健在
--    （原 polestar_zhcn_fill 已退役并转为运行时注入）
-- ---------------------------------------------------------------------------
function F.CheckPatches()
    local results = {}

    if F.IsAddOnLoaded("EllesmereUIChat") then
        local EUI = _G.EllesmereUI
        local chatNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIChat
        local ok = type(chatNS) == "table" and chatNS._kkowoFastTab == true and (chatNS._kkowoFastTabVer or 0) >= 5
        results[#results + 1] = {
            id = "eui_chat_tab_fast",
            name = "EUI 聊天标签瞬切 v5",
            ok = ok,
        }
    end

    if F.IsAddOnLoaded("Polestar") then
        local ps = _G.Polestar
        local okNav = type(ps) == "table" and ps._kkowoNavOpt == true
        results[#results + 1] = {
            id = "polestar_nav_optimize",
            name = "北极星寻路与怪区优化",
            ok = okNav,
        }
    end

    return results
end

-- ---------------------------------------------------------------------------
-- 5) DeadGuard：自动停用被 DD 放回的正式服死目录 / 已替换旧插件
-- ---------------------------------------------------------------------------
local DEAD_ADDONS = {
    "ArcUI", "163UI_Info", "QuestieTrace", "BlizzMove_Debug", "YaMedia",
    "EllesmereUIDataBars", "EllesmereUIMythicTimer", "EllesmereUIQuickdraw",
    "EllesmereUIAuraBuffReminders", "EllesmereUIFriends", "EllesmereUIGroupFinder",
    "Polestar_Arcade",
}
local ARC_ADDONS = { "ArcAuras", "ArcAuras_Finds", "ArcAuras_LFG" }
local REPLACED_BY = {
    VamoosesSlipstream = "VamoosesSlipstream_kkowo",
    PrettyTooltip = "kkowoUI_Tooltip",
}
local CDM_ADDON = "EllesmereUICooldownManager"

function F.SetAddOnEnabledSafely(name, enabled)
    local ca = _G.C_AddOns
    local fn = enabled and ((ca and ca.EnableAddOn) or _G.EnableAddOn)
        or ((ca and ca.DisableAddOn) or _G.DisableAddOn)
    if not fn then return end
    local getState = ca and ca.GetAddOnEnableState
    local guid = _G.UnitGUID and F.PlainString(_G.UnitGUID("player"), nil) or nil
    if guid then
        pcall(fn, name, guid)
    end
    local matched = false
    if getState then
        local ok, st = pcall(getState, name)
        if ok and type(st) == "number" then
            matched = enabled and (st > 0) or (st == 0)
        end
    end
    if not matched then
        pcall(fn, name)
    end
end

function F.PreferCDMOverArc()
    if not F.db then return false end
    if F.db.cdmReplacesArc == nil then
        F.db.cdmReplacesArc = (F.charDB and F.charDB.cdmEnabledOnce == true) or false
    end
    return F.db.cdmReplacesArc == true
end

local function ShowReloadOffer(msg)
    if not (_G.StaticPopupDialogs and _G.StaticPopup_Show) then return end
    if not _G.StaticPopupDialogs["KKOWOUI_ADDON_RELOAD"] then
        _G.StaticPopupDialogs["KKOWOUI_ADDON_RELOAD"] = {
            text = "%s",
            button1 = "立即重载",
            button2 = "稍后",
            OnAccept = function() if _G.ReloadUI then _G.ReloadUI() end end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    F.RunOutOfCombat("KKOWOUI_ADDON_RELOAD", function()
        _G.StaticPopup_Show("KKOWOUI_ADDON_RELOAD", msg)
    end)
end

function F.DisableDeadAddons(verbose)
    local ca = _G.C_AddOns
    local getState = ca and ca.GetAddOnEnableState
    local existsFn = ca and ca.DoesAddOnExist
    if not getState then return 0 end
    local guid = _G.UnitGUID and F.PlainString(_G.UnitGUID("player"), nil) or nil
    local function Exists(name)
        if not existsFn then return true end
        local okEx, ex = pcall(existsFn, name)
        return okEx and ex == true
    end
    local function State(name)
        local ok, st = pcall(getState, name, guid)
        if not ok then ok, st = pcall(getState, name) end
        return (ok and type(st) == "number") and st or nil
    end
    local preferCDM = F.PreferCDMOverArc()
    local list = {}
    for _, name in ipairs(DEAD_ADDONS) do list[#list + 1] = name end
    if preferCDM then
        for _, name in ipairs(ARC_ADDONS) do list[#list + 1] = name end
    end
    for orig, repl in pairs(REPLACED_BY) do
        local rs = Exists(repl) and State(repl)
        if rs and rs > 0 then list[#list + 1] = orig end
    end
    local off = {}
    for _, name in ipairs(list) do
        if Exists(name) then
            local st = State(name)
            if st and st > 0 then
                F.SetAddOnEnabledSafely(name, false)
                off[#off + 1] = name
            end
        end
    end
    local cdmOn = false
    if preferCDM and F.charDB and not F.charDB.cdmEnabledOnce then
        F.charDB.cdmEnabledOnce = true
        if Exists(CDM_ADDON) and State(CDM_ADDON) == 0 then
            F.SetAddOnEnabledSafely(CDM_ADDON, true)
            cdmOn = true
        end
    end
    if #off > 0 or cdmOn then
        if ca.SaveAddOns then pcall(ca.SaveAddOns) end
        local parts = {}
        if #off > 0 then parts[#parts + 1] = "已停用：" .. table_concat(off, "、") end
        if cdmOn then parts[#parts + 1] = "已启用：EUI 冷却管理器" end
        F.Print(table_concat(parts, "；") .. "（重载生效，/kk deadguard off 可关闭）")
        local liveChange = cdmOn
        for _, name in ipairs(off) do
            if F.IsAddOnLoaded(name) then liveChange = true end
        end
        if liveChange then
            ShowReloadOffer("|cffdca77fkkowoUI|r\n\n" .. table_concat(parts, "\n") .. "\n\n重载界面后生效，现在重载吗？")
        end
    elseif verbose then
        F.Print("没有需要停用的无效插件。")
    end
    return #off
end

-- ---------------------------------------------------------------------------
-- 生命周期：登录挂载 ESC 增强、DeadGuard 与 PatchGuard
-- ---------------------------------------------------------------------------
local guardFrame = nil

function mod:OnDisable()
    pendingReturnFrame = nil
end

function mod:OnEnable()
    SetupThirdPartyEscapeClose()
    if not guardFrame then
        guardFrame = CreateFrame("Frame")
        guardFrame:RegisterEvent("PLAYER_LOGIN")
        guardFrame:SetScript("OnEvent", function(self)
            self:UnregisterAllEvents()
            SetupThirdPartyEscapeClose()
            C_Timer.After(3.0, function()
                if F.db and F.db.autoDisableDeadAddons ~= false then
                    F.DisableDeadAddons(false)
                end
            end)
            C_Timer.After(4.5, function()
                SetupThirdPartyEscapeClose()
                if not (mod._active and mod:GetDB().patchGuardAlert ~= false) then
                    return
                end
                local missing = {}
                for _, p in ipairs(F.CheckPatches()) do
                    if not p.ok then missing[#missing + 1] = p.name end
                end
                if #missing > 0 then
                    F.Print("|cffffb84d以下功能可能被更新覆盖|r：" .. table_concat(missing, "、")
                        .. "；退出游戏后运行重打脚本恢复（/kk doctor 查看详情）。")
                end
            end)
        end)
    end
end
