----------------------------------------------------------------------
--  kkowoUI — Modules/AuctionSkin.lua
--  拍卖行精简合并与现代排版统一（暴雪原生现代拍卖行 × Auctionator 压价与市价扫描）：
--    • 保留暴雪原版完整的三大核心页签（均已由 EUI 深度现代换肤，图标风格与背包 100% 一致）：
--      - 「购买」：完整左侧分类树（武器/护甲/消耗品/商品/配方…）、搜索与过滤
--      - 「出售」：右键背包直接放入、右键物品格直接放回背包、自动列市价并填最低一口价
--      - 「拍卖」：我的拍卖与我的竞标
--    • 隐藏 Auctionator 重复且缺分类的「购物 / 出售」与纯英文介绍页「Auctionator」，
--      仅保留暴雪原版所没有的互补功能合并为第 4 页签「压价扫描」（底页为 Cancelling），
--      并在顶部工具栏内置「扫描市价 + 实时百分比进度」按钮（为悬停估价与防误卖供数）。
--    • 不劫持背包右键，确保暴雪原版「右键放入 / 右键放回」100% 原生顺畅；
--      同时保留停用或关闭合并时无损恢复全部 7 页签的能力。
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_abs, pcall, setmetatable, type =
    ipairs, math.abs, pcall, setmetatable, type
local C_Timer = C_Timer

local mod = F.RegisterModule("auctionSkin", {
    title = "拍卖行合并与界面统一",
    desc = "保留功能完整的暴雪原版「购买（含分类列表）/ 出售（右键放入与放回）/ 拍卖」三大页签，隐藏 Auctionator 重复页签，仅将互补的「压价检查 + 全服市价扫描」合并为第 4 页签「压价扫描」。",
    group = "theme",
    order = 35,
    defaults = {
        enabled = true,
        mergeTabs = true,          -- 合并去重：保留暴雪购买/出售/拍卖 + 第 4 页「压价扫描」
        v2BlizzPrimaryAH = false,  -- 一次性迁移：将此前改过的 Auctionator 背包右键快捷方式恢复为 alt left click，避免劫持原版右键出售
    },
})

local WEAK = { __mode = "k" }
local done = setmetatable({}, WEAK)
local refHooked = setmetatable({}, WEAK)
local origTabLabel = setmetatable({}, WEAK)
local origTabHeader = setmetatable({}, WEAK)
local moneyHooked = setmetatable({}, WEAK)

local ahHooked = false
local applyQueued = false
local syncQueued = false
local scanBtnRef = nil
local scanStatusFS = nil
local scanBusHooked = false
local scanEventSink = {}

local LayoutTabRow
local QueueSync

local function SkinAPI()
    return F.Theme and F.Theme.GetSkinAPI and F.Theme.GetSkinAPI() or nil
end

local function IsForbiddenRaw(f) return f:IsForbidden() end
local function Usable(o)
    if type(o) ~= "table" then return false end
    local ok, forb = pcall(IsForbiddenRaw, o)
    return ok and not forb
end

local function Call(fn, ...)
    if type(fn) == "function" then pcall(fn, ...) end
end

local function GetFontPath()
    return (F.Theme and F.Theme.GetFont and F.Theme.GetFont()) or _G.STANDARD_TEXT_FONT or "Fonts\\ARKai_T.ttf"
end

local function ApplyCleanFont(fs, size, r, g, b, a, flags)
    if not (Usable(fs) and fs.SetFont) then return end
    pcall(fs.SetFont, fs, GetFontPath(), size or 12, flags or "")
    if fs.SetShadowColor then pcall(fs.SetShadowColor, fs, 0, 0, 0, 0.90) end
    if fs.SetShadowOffset then pcall(fs.SetShadowOffset, fs, 1, -1) end
    if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "MIDDLE") end
    if r then pcall(fs.SetTextColor, fs, r, g, b, a or 1) end
end

local function AuctionatorTabs()
    local c = _G.AuctionatorAHTabsContainer
    local tabs = c and c.Tabs
    if type(tabs) == "table" and #tabs > 0 then return tabs end
    return nil
end

----------------------------------------------------------------------
--  1) 页签识别与合并：暴雪「购买 / 出售 / 拍卖」+ 互补第 4 页「压价扫描」
----------------------------------------------------------------------
local BLIZZ_TAB_NAMES = {
    "AuctionHouseFrameBuyTab",
    "AuctionHouseFrameSellTab",
    "AuctionHouseFrameAuctionsTab",
}

local function IdentifyTabKey(tab)
    if not Usable(tab) then return nil end
    if tab == _G.AuctionatorTabs_Shopping then return "Shopping" end
    if tab == _G.AuctionatorTabs_Selling then return "Selling" end
    if tab == _G.AuctionatorTabs_Cancelling then return "Cancelling" end
    if tab == _G.AuctionatorTabs_Auctionator then return "Auctionator" end
    local nm = tab.GetName and F.PlainString(tab:GetName(), "") or ""
    if nm:find("AuctionatorTabs_Shopping", 1, true) then return "Shopping" end
    if nm:find("AuctionatorTabs_Selling", 1, true) then return "Selling" end
    if nm:find("AuctionatorTabs_Cancelling", 1, true) then return "Cancelling" end
    if nm:find("AuctionatorTabs_Auctionator", 1, true) then return "Auctionator" end
    local ref = tab.frameRef
    local rn = Usable(ref) and ref.GetName and F.PlainString(ref:GetName(), "") or ""
    if rn == "AuctionatorShoppingFrame" then return "Shopping" end
    if rn == "AuctionatorSellingFrame" then return "Selling" end
    if rn == "AuctionatorCancellingFrame" then return "Cancelling" end
    if rn == "AuctionatorConfigFrame" then return "Auctionator" end
    return nil
end

local function ShouldMergeTabs()
    return mod._active and mod:GetDB().mergeTabs ~= false and AuctionatorTabs() ~= nil
end

local function LastBlizzardTab(ah)
    local list = ah and ah.Tabs
    if type(list) ~= "table" then return nil end
    for i = #list, 1, -1 do
        local t = list[i]
        if Usable(t) and t:IsShown() then return t end
    end
    return nil
end

local function EnsureBlizzTabsVisible(ah)
    local seen = {}
    for _, name in ipairs(BLIZZ_TAB_NAMES) do
        local bt = _G[name]
        if Usable(bt) then
            seen[bt] = true
            bt:Show()
        end
    end
    if ah and type(ah.Tabs) == "table" then
        for _, bt in ipairs(ah.Tabs) do
            if Usable(bt) and not seen[bt] then bt:Show() end
        end
    end
end

-- 避免 Auctionator 的 Hooks.lua 在合并模式下用右键劫持走暴雪原版的「右键放入出售 / 右键放回」
local function RestoreAuctionatorRightClickIfNeeded()
    local A = _G.Auctionator
    if not (type(A) == "table" and A.Config and A.Config.Options and A.Config.Shortcuts) then return end
    local opt = A.Config.Options.SELLING_BAG_SELECT_SHORTCUT
    local rightVal = A.Config.Shortcuts.RIGHT_CLICK
    local altLeftVal = A.Config.Shortcuts.ALT_LEFT_CLICK or "alt left click"
    if not (opt and rightVal and type(A.Config.Get) == "function" and type(A.Config.Set) == "function") then return end
    local ok, cur = pcall(A.Config.Get, opt)
    if ok and cur == rightVal then
        pcall(A.Config.Set, opt, altLeftVal)
    end
end

local function PolishWindowHeader(ah)
    if not Usable(ah) then return end
    local title = _G.AuctionHouseFrameTitleText
        or (Usable(ah.TitleContainer) and ah.TitleContainer.TitleText)
        or ah.TitleText
    if Usable(title) then
        ApplyCleanFont(title, 14, 0.94, 0.95, 0.98, 1)
    end
    local mf = ah.MoneyFrame
    if Usable(mf) then
        for _, k in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
            local btn = mf[k]
            if Usable(btn) then
                local fs = btn.GetFontString and btn:GetFontString()
                if Usable(fs) then ApplyCleanFont(fs, 12) end
            end
        end
    end
end

local function PolishTabLabel(t)
    if not Usable(t) then return end
    local EUI = _G.EllesmereUI
    local bsNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIBlizzardSkin
    local ffd = bsNS and bsNS.WSkin and bsNS.WSkin.FFD
    local td = type(ffd) == "table" and ffd[t] or nil
    if td and Usable(td.label) then
        ApplyCleanFont(td.label, 12)
        if td.label.ClearAllPoints and td.label.SetPoint then
            td.label:ClearAllPoints()
            td.label:SetPoint("CENTER", t, "CENTER", 0, -1)
        end
    else
        local fs = t.GetFontString and t:GetFontString()
        if Usable(fs) then ApplyCleanFont(fs, 12) end
    end
end

LayoutTabRow = function()
    local ah = _G.AuctionHouseFrame
    local tabs = AuctionatorTabs()
    if not Usable(ah) then return end

    EnsureBlizzTabsVisible(ah)
    for _, name in ipairs(BLIZZ_TAB_NAMES) do
        PolishTabLabel(_G[name])
    end

    if not tabs then
        PolishWindowHeader(ah)
        return
    end

    local merge = ShouldMergeTabs()
    local refTab = LastBlizzardTab(ah) or _G.AuctionHouseFrameBuyTab
    local h = (Usable(refTab) and F.PlainNumber(refTab:GetHeight(), 0)) or 28
    if h < 24 then h = 28 end

    local gap = 1
    local EUI = _G.EllesmereUI
    local PP = EUI and EUI.PP
    local scaleRef = Usable(refTab) and refTab or ah
    local es = F.PlainNumber(scaleRef.GetEffectiveScale and scaleRef:GetEffectiveScale(), 0)
    if PP and type(PP.perfect) == "number" and es > 0.1 and es < 10 then
        gap = PP.perfect / es
    end

    local prev = LastBlizzardTab(ah)
    for _, t in ipairs(tabs) do
        if Usable(t) then
            local key = IdentifyTabKey(t)
            if origTabLabel[t] == nil and t.GetText then
                origTabLabel[t] = F.PlainString(t:GetText(), "")
            end
            if origTabHeader[t] == nil and type(t.tabHeader) == "string" then
                origTabHeader[t] = t.tabHeader
            end

            if merge and key ~= "Cancelling" then
                -- 隐藏重复的「购物 / 出售」与英文介绍页「Auctionator」；若当前停留在被隐藏页则安全切回暴雪「购买」
                t:Hide()
                if Usable(t.frameRef) and t.frameRef:IsShown() then
                    t.frameRef:Hide()
                    local buyTab = _G.AuctionHouseFrameBuyTab
                    if Usable(buyTab) and buyTab.Click then pcall(buyTab.Click, buyTab) end
                end
            else
                t:Show()
                if key == "Cancelling" then
                    local origLbl = origTabLabel[t]
                    local wantLabel = merge and "压价扫描" or ((origLbl and origLbl ~= "" and origLbl) or "取消")
                    local origHdr = origTabHeader[t]
                    local wantHeader = merge and "拍卖行 · 压价与市价扫描" or ((origHdr and origHdr ~= "" and origHdr) or "Auctionator - 取消")
                    t.tabHeader = wantHeader
                    if t.SetText and F.PlainString(t.GetText and t:GetText(), "") ~= wantLabel then
                        pcall(t.SetText, t, wantLabel)
                    end
                    if _G.PanelTemplates_TabResize then
                        pcall(_G.PanelTemplates_TabResize, t, 24, nil, 84)
                    end
                    if Usable(t.frameRef) and t.frameRef:IsShown() and ah.SetTitle then
                        pcall(ah.SetTitle, ah, wantHeader)
                    end
                elseif not merge and origTabLabel[t] and origTabLabel[t] ~= "" and t.SetText then
                    if F.PlainString(t.GetText and t:GetText(), "") ~= origTabLabel[t] then
                        pcall(t.SetText, t, origTabLabel[t])
                    end
                    if origTabHeader[t] then t.tabHeader = origTabHeader[t] end
                end
                if h > 0 then t:SetHeight(h) end
                t:ClearAllPoints()
                if prev then
                    t:SetPoint("LEFT", prev, "RIGHT", gap, 0)
                else
                    t:SetPoint("BOTTOMLEFT", ah, "BOTTOMLEFT", 20, -28)
                end
                if mod._active then PolishTabLabel(t) end
                prev = t
            end
        end
    end
    if mod._active then PolishWindowHeader(ah) end
end

local function SyncEUIZoneDividers(ah, anyOurs, isConfigPage)
    if not Usable(ah) then return end
    local EUI = _G.EllesmereUI
    local bsNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIBlizzardSkin
    local ffd = bsNS and bsNS.WSkin and bsNS.WSkin.FFD
    local ad = type(ffd) == "table" and ffd[ah] or nil
    if not ad then return end

    if anyOurs then
        if ad.railHost then ad.railHost:Hide() end
        if ad.sellHost then ad.sellHost:Hide() end
    else
        local isSell = false
        for _, k in ipairs({ "ItemSellFrame", "CommoditiesSellFrame", "WoWTokenSellFrame" }) do
            local v = ah[k]
            if Usable(v) and v:IsShown() then isSell = true; break end
        end
        if ad.railHost then ad.railHost:SetShown(not isSell) end
        if ad.sellHost then ad.sellHost:SetShown(isSell) end
    end

    local host = ad.zoneHost
    if Usable(host) and host.GetRegions then
        local regs = { host:GetRegions() }
        for i = 1, #regs do
            local r = regs[i]
            if r and r.GetPoint then
                local pt = r:GetPoint(1)
                if pt == "TOPLEFT" then
                    r:SetShown(not (anyOurs or isConfigPage))
                end
            end
        end
    end
end

local function SyncTabSelection()
    syncQueued = false
    if not mod._active then return end
    local S = SkinAPI()
    local tabs = AuctionatorTabs()
    if not (S and S.SetTabSelection and tabs) then return end
    local anyOurs = false
    local isConfigPage = false
    for _, t in ipairs(tabs) do
        local ref = t.frameRef
        local sel = Usable(ref) and ref:IsShown() or false
        if sel then
            anyOurs = true
            if type(ref.AuthorHeading) == "table" or type(ref.OptionsButton) == "table" then
                isConfigPage = true
            end
        end
        Call(S.SetTabSelection, t, sel and true or false)
    end
    local ah = _G.AuctionHouseFrame
    if anyOurs and ah and type(ah.Tabs) == "table" then
        for _, bt in ipairs(ah.Tabs) do
            if Usable(bt) then Call(S.SetTabSelection, bt, false) end
        end
    end
    SyncEUIZoneDividers(ah, anyOurs, isConfigPage)
    PolishWindowHeader(ah)
end

QueueSync = function()
    if syncQueued then return end
    syncQueued = true
    C_Timer.After(0, SyncTabSelection)
end

----------------------------------------------------------------------
--  2) 内置全服市价扫描按钮（集成在「压价扫描」顶部，零重叠进度显示）
----------------------------------------------------------------------
local function EnsureScanProgressListener()
    if scanBusHooked then return end
    local A = _G.Auctionator
    if not (type(A) == "table" and A.EventBus and A.EventBus.Register) then return end
    local evs = {}
    if A.FullScan and A.FullScan.Events then
        for _, k in ipairs({ "ScanStart", "ScanProgress", "ScanComplete", "ScanFailed" }) do
            if A.FullScan.Events[k] then evs[#evs + 1] = A.FullScan.Events[k] end
        end
    end
    if A.IncrementalScan and A.IncrementalScan.Events then
        for _, k in ipairs({ "ScanStart", "ScanProgress", "ScanComplete", "ScanFailed" }) do
            if A.IncrementalScan.Events[k] then evs[#evs + 1] = A.IncrementalScan.Events[k] end
        end
    end
    if #evs == 0 then return end
    scanBusHooked = true
    function scanEventSink:ReceiveEvent(ev, data)
        if not (mod._active and ShouldMergeTabs() and Usable(scanStatusFS)) then return end
        local fEv = A.FullScan and A.FullScan.Events or {}
        local iEv = A.IncrementalScan and A.IncrementalScan.Events or {}
        if ev == fEv.ScanStart or ev == iEv.ScanStart then
            scanStatusFS:SetText("扫描中 0%")
        elseif ev == fEv.ScanProgress or ev == iEv.ScanProgress then
            local pct = F.PlainNumber(data, 0)
            scanStatusFS:SetText("扫描中 " .. tostring(math.floor(pct * 100)) .. "%")
        elseif ev == fEv.ScanComplete or ev == iEv.ScanComplete then
            scanStatusFS:SetText("扫描完成")
            C_Timer.After(3, function()
                if mod._active and Usable(scanStatusFS) and scanStatusFS:GetText() == "扫描完成" then
                    scanStatusFS:SetText("")
                end
            end)
        else
            scanStatusFS:SetText("")
        end
    end
    pcall(A.EventBus.Register, A.EventBus, scanEventSink, evs)
end

local function TriggerMarketScan()
    local A = _G.Auctionator
    if type(A) ~= "table" or not A.State then return end
    local useRep = false
    if A.Config and A.Config.Options and A.Config.Options.REPLICATE_SCAN ~= nil and type(A.Config.Get) == "function" then
        local ok, val = pcall(A.Config.Get, A.Config.Options.REPLICATE_SCAN)
        useRep = ok and val == true
    end
    if useRep and A.State.FullScanFrameRef and A.State.FullScanFrameRef.InitiateScan then
        pcall(A.State.FullScanFrameRef.InitiateScan, A.State.FullScanFrameRef)
    elseif A.State.IncrementalScanFrameRef and A.State.IncrementalScanFrameRef.InitiateScan then
        pcall(A.State.IncrementalScanFrameRef.InitiateScan, A.State.IncrementalScanFrameRef)
    elseif A.State.FullScanFrameRef and A.State.FullScanFrameRef.InitiateScan then
        pcall(A.State.FullScanFrameRef.InitiateScan, A.State.FullScanFrameRef)
    end
end

local function EnsureInlineMarketScanButton(page, refreshBtn)
    if not Usable(page) then return end
    if not scanBtnRef then
        local btn = CreateFrame("Button", "kkowoUI_AHMarketScanBtn", page)
        btn:SetSize(84, 22)
        F.Theme.StyleButton(btn, 12)
        btn:SetText("扫描市价")
        btn:SetScript("OnClick", TriggerMarketScan)
        btn:SetScript("OnEnter", function(self)
            local gt = _G.GameTooltip
            if gt then
                gt:SetOwner(self, "ANCHOR_BOTTOM", 0, -4)
                gt:AddLine("全服市价扫描", 1, 1, 1)
                gt:AddLine("更新全服拍卖行价格数据库，用于物品悬停估价与背包清理防误卖。", 0.78, 0.84, 0.90, true)
                gt:Show()
            end
        end)
        btn:SetScript("OnLeave", function()
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        scanBtnRef = btn

        local fs = page:CreateFontString(nil, "OVERLAY")
        ApplyCleanFont(fs, 12, 0.56, 0.94, 0.92, 1)
        fs:SetPoint("RIGHT", btn, "LEFT", -10, 0)
        fs:SetText("")
        scanStatusFS = fs
    end
    scanBtnRef:ClearAllPoints()
    if Usable(refreshBtn) then
        scanBtnRef:SetPoint("RIGHT", refreshBtn, "LEFT", -8, 0)
    else
        scanBtnRef:SetPoint("TOPRIGHT", page, "TOPRIGHT", -48, -42)
    end
    scanBtnRef:SetShown(ShouldMergeTabs())
    if Usable(scanStatusFS) then scanStatusFS:SetShown(ShouldMergeTabs()) end
    EnsureScanProgressListener()
end

----------------------------------------------------------------------
--  3) 通用控件换肤（滚动条去灰框 + 11px 表头 + 金额对齐 + 刷新图标先后顺序修正）
----------------------------------------------------------------------
local function IsTabButton(o)
    return (o.LeftActive or o.LeftDisabled) ~= nil
end

local function IsPanelButton(o)
    return o.Left ~= nil and o.Middle ~= nil and o.Right ~= nil and not IsTabButton(o)
end

local function IsDropdown(o)
    return o.Arrow ~= nil and o.Background ~= nil and o.Text ~= nil
end

local function IsScrollBar(o)
    local track = o.Track
    return track ~= nil and (o.Back ~= nil or o.Forward ~= nil or o.Thumb ~= nil
        or (type(track) == "table" and track.Thumb ~= nil))
end

local function IsInset(o)
    return o.Bg ~= nil and (o.NineSlice ~= nil or o.layoutType == "InsetFrameTemplate")
end

local function IsMoneyEditBox(eb)
    if not Usable(eb) then return false end
    local p = eb.GetParent and eb:GetParent()
    if type(p) == "table" and (p.GoldBox == eb or p.SilverBox == eb or p.CopperBox == eb) then
        return true
    end
    return false
end

local function FindCoinTexture(eb)
    local coin = eb.texture or eb.Icon
    if coin and coin.IsObjectType and coin:IsObjectType("Texture") then return coin end
    if eb.GetRegions then
        for _, r in ipairs({ eb:GetRegions() }) do
            if r and r.IsObjectType and r:IsObjectType("Texture") then
                local atlas = r.GetAtlas and F.PlainString(r:GetAtlas(), "") or ""
                if atlas:lower():find("coin", 1, true) then return r end
                local tex = r.GetTexture and r:GetTexture()
                if type(tex) == "string" and (tex:find("Coin", 1, true) or tex:find("MoneyFrame", 1, true)) then
                    return r
                end
                local rw = F.PlainNumber(r.GetWidth and r:GetWidth(), 0)
                local rh = F.PlainNumber(r.GetHeight and r:GetHeight(), 0)
                if rw >= 8 and rw <= 18 and rh >= 8 and rh <= 18 and math_abs(rw - rh) <= 3 then
                    return r
                end
            end
        end
    end
    return nil
end

local function PolishMoneyEditBox(eb)
    if not Usable(eb) then return end
    local coin = FindCoinTexture(eb)
    if coin then
        pcall(coin.SetAlpha, coin, 1)
        pcall(coin.Show, coin)
        if coin.SetSize then pcall(coin.SetSize, coin, 13, 13) end
        pcall(coin.ClearAllPoints, coin)
        pcall(coin.SetPoint, coin, "RIGHT", eb, "RIGHT", -5, 0)
        if coin.SetDrawLayer then pcall(coin.SetDrawLayer, coin, "OVERLAY", 3) end
    end
    if eb.SetHeight then pcall(eb.SetHeight, eb, 22) end
    if eb.SetFont then pcall(eb.SetFont, eb, GetFontPath(), 12, "") end
    if eb.SetShadowColor then pcall(eb.SetShadowColor, eb, 0, 0, 0, 0.90) end
    if eb.SetShadowOffset then pcall(eb.SetShadowOffset, eb, 1, -1) end
    if eb.SetJustifyH then pcall(eb.SetJustifyH, eb, "RIGHT") end
    if eb.SetJustifyV then pcall(eb.SetJustifyV, eb, "MIDDLE") end
    if eb.SetTextInsets then pcall(eb.SetTextInsets, eb, 4, coin and 22 or 6, 1, 0) end
    if eb.HasFocus and not eb:HasFocus() and eb.GetText and eb.SetText then
        local txt = F.PlainString(eb:GetText(), nil)
        if txt ~= nil then pcall(eb.SetText, eb, txt) end
    end
    if not moneyHooked[eb] and eb.HookScript then
        moneyHooked[eb] = true
        eb:HookScript("OnShow", function(self) if mod._active then PolishMoneyEditBox(self) end end)
        eb:HookScript("OnEditFocusLost", function(self) if mod._active then PolishMoneyEditBox(self) end end)
    end
end

local function PolishScrollBar(S, sb)
    if not Usable(sb) then return end
    Call(S.ScrollBar, sb)
    if sb.GetRegions then
        for _, r in ipairs({ sb:GetRegions() }) do
            if Usable(r) and r.IsObjectType and r:IsObjectType("Texture") then
                pcall(r.SetAlpha, r, 0)
            end
        end
    end
    if Usable(sb.Background) and sb.Background.SetAlpha then pcall(sb.Background.SetAlpha, sb.Background, 0) end
    for _, key in ipairs({ "Back", "Forward" }) do
        local b = sb[key]
        if Usable(b) then
            for _, g in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture", "GetHighlightTexture" }) do
                local t = b[g] and b[g](b)
                if Usable(t) and t.SetAlpha then pcall(t.SetAlpha, t, 0) end
            end
            if Usable(b.Texture) and b.Texture.SetAlpha then pcall(b.Texture.SetAlpha, b.Texture, 0) end
            if b.SetAlpha then pcall(b.SetAlpha, b, 0) end
            if b.EnableMouse then pcall(b.EnableMouse, b, false) end
        end
    end
end

local function PolishSortHeaders(S, list)
    if not (Usable(list) and Usable(list.HeaderContainer)) then return end
    Call(S.SortHeaderBar, list)
    local hc = list.HeaderContainer
    if hc.SetHeight then pcall(hc.SetHeight, hc, 22) end
    local EUI = _G.EllesmereUI
    local bsNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIBlizzardSkin
    local ffd = bsNS and bsNS.WSkin and bsNS.WSkin.FFD
    local sd = type(ffd) == "table" and ffd[list] or nil
    if sd and Usable(sd.strip) then
        pcall(sd.strip.SetColorTexture, sd.strip, 0.05, 0.06, 0.08, 0.80)
        pcall(sd.strip.SetHeight, sd.strip, 22)
    end
    if hc.GetChildren then
        for _, col in ipairs({ hc:GetChildren() }) do
            if Usable(col) then
                if col.SetHeight then pcall(col.SetHeight, col, 22) end
                local fs = col.Text or (col.GetFontString and col:GetFontString())
                if Usable(fs) then
                    ApplyCleanFont(fs, 11, 0.82, 0.87, 0.94, 0.96)
                    if fs.SetWordWrap then pcall(fs.SetWordWrap, fs, false) end
                end
            end
        end
    end
end

local function PolishButtonFont(btn, size)
    if not Usable(btn) then return end
    local fs = btn.Text or (btn.GetFontString and btn:GetFontString())
    if Usable(fs) then ApplyCleanFont(fs, size or 12) end
end

-- 先铺平按钮底板，再直接绘制白色去色刷新图标（公开 SkinAPI 不含 RefreshGlyph，必须自绘以防空白框体）
local refreshIcons = setmetatable({}, { __mode = "k" })

local function PolishRefreshButton(S, btn)
    if not Usable(btn) then return end
    if not done[btn] then
        done[btn] = true
        if S and S.Button then Call(S.Button, btn) end
    end
    local glyph = refreshIcons[btn]
    if not glyph then
        glyph = btn:CreateTexture(nil, "OVERLAY", nil, 5)
        glyph:SetSize(14, 14)
        glyph:SetPoint("CENTER", btn, "CENTER", 0, 0)
        local hasAtlas = _G.C_Texture and _G.C_Texture.GetAtlasInfo and _G.C_Texture.GetAtlasInfo("UI-RefreshButton")
        if hasAtlas and glyph.SetAtlas then
            pcall(glyph.SetAtlas, glyph, "UI-RefreshButton", false)
        else
            pcall(glyph.SetTexture, glyph, "Interface\\Buttons\\UI-RefreshButton")
        end
        if glyph.SetDesaturated then pcall(glyph.SetDesaturated, glyph, true) end
        pcall(glyph.SetVertexColor, glyph, 0.90, 0.93, 0.98, 0.90)
        refreshIcons[btn] = glyph
        if btn.HookScript then
            btn:HookScript("OnEnter", function(self)
                if not mod._active then return end
                local ic = refreshIcons[self]
                if ic then ic:SetVertexColor(1, 1, 1, 1) end
            end)
            btn:HookScript("OnLeave", function(self)
                if not mod._active then return end
                local ic = refreshIcons[self]
                if ic then ic:SetVertexColor(0.90, 0.93, 0.98, 0.90) end
            end)
        end
    end
    if glyph then
        glyph:SetAlpha(1)
        glyph:Show()
    end
end

local function GetTypeRaw(o) return o:GetObjectType() end
local function IsMultiLineRaw(o) return o:IsMultiLine() end

local function SkinWidget(S, o)
    if Usable(o.HeaderContainer) then PolishSortHeaders(S, o) end
    if done[o] then
        if IsMoneyEditBox(o) then PolishMoneyEditBox(o) end
        return
    end
    local ok, otype = pcall(GetTypeRaw, o)
    if not ok then return end
    if otype == "EditBox" then
        done[o] = true
        local okM, ml = pcall(IsMultiLineRaw, o)
        if not (okM and ml) then
            Call(S.EditBox, o)
            if IsMoneyEditBox(o) then
                PolishMoneyEditBox(o)
            else
                if o.SetHeight then pcall(o.SetHeight, o, 22) end
                if o.SetFont then pcall(o.SetFont, o, GetFontPath(), 12, "") end
                if o.SetJustifyV then pcall(o.SetJustifyV, o, "MIDDLE") end
                if o.SetTextInsets then pcall(o.SetTextInsets, o, 6, 6, 1, 0) end
            end
        end
    elseif otype == "CheckButton" then
        done[o] = true
        if F.PlainNumber(o:GetWidth(), 0) >= 20 then Call(S.Checkbox, o) end
    elseif otype == "Button" then
        if IsTabButton(o) then
            done[o] = true
            Call(S.Tab, o)
            PolishButtonFont(o, 11.5)
        elseif IsPanelButton(o) then
            done[o] = true
            Call(S.Button, o)
            Call(S.StateButtonLabel, o)
            PolishButtonFont(o, 12)
        elseif IsDropdown(o) then
            done[o] = true
            Call(S.Dropdown, o)
        end
    elseif otype == "Frame" or otype == "EventFrame" then
        if IsScrollBar(o) then
            done[o] = true
            PolishScrollBar(S, o)
        elseif IsInset(o) then
            done[o] = true
            Call(S.Inset, o)
            Call(S.Panel, o, { inset = true })
        end
    end
end

local function Walk(S, f, depth)
    if depth > 9 or not Usable(f) then return end
    SkinWidget(S, f)
    if Usable(f.ScrollTarget) then return end
    local kids = { f:GetChildren() }
    for i = 1, #kids do
        Walk(S, kids[i], depth + 1)
    end
end

-- 压价扫描页精修 + 集成全服「扫描市价」按钮（顶栏左搜右钮同一中线齐平，彻底杜绝总金额与按钮重叠）
local function PolishCancellingPage(S, page)
    if not Usable(page) then return end
    if Usable(page.SearchFilter) then
        page.SearchFilter:SetSize(168, 22)
        page.SearchFilter:ClearAllPoints()
        page.SearchFilter:SetPoint("TOPLEFT", page, "TOPLEFT", 16, -46)
        if page.SearchFilter.SetFont then pcall(page.SearchFilter.SetFont, page.SearchFilter, GetFontPath(), 12, "") end
        if page.SearchFilter.SetJustifyV then pcall(page.SearchFilter.SetJustifyV, page.SearchFilter, "MIDDLE") end
    end
    if Usable(page.Total) then
        ApplyCleanFont(page.Total, 11.5, 0.88, 0.91, 0.96, 0.96)
        if page.Total.SetHeight then pcall(page.Total.SetHeight, page.Total, 22) end
        page.Total:ClearAllPoints()
        if Usable(page.SearchFilter) then
            page.Total:SetPoint("LEFT", page.SearchFilter, "RIGHT", 14, 0)
        else
            page.Total:SetPoint("TOPLEFT", page, "TOPLEFT", 196, -46)
        end
    end
    if Usable(page.ResultsListing) then
        PolishSortHeaders(S, page.ResultsListing)
    end
    local refreshBtn = nil
    if page.GetChildren then
        for _, ch in ipairs({ page:GetChildren() }) do
            if Usable(ch) and ch ~= scanBtnRef and ch.GetObjectType and ch:GetObjectType() == "Button" then
                local w = F.PlainNumber(ch:GetWidth(), 0)
                if w > 0 and w <= 34 then
                    refreshBtn = ch
                    ch:SetSize(22, 22)
                    ch:ClearAllPoints()
                    ch:SetPoint("TOPRIGHT", page, "TOPRIGHT", -18, -46)
                    PolishRefreshButton(S, ch)
                    break
                end
            end
        end
    end
    EnsureInlineMarketScanButton(page, refreshBtn)
end

-- 配置页（仅在用户手动关闭合并、查看原版 7 页签时生效）：修复 40% 重叠
local function PolishConfigPage(page)
    if not Usable(page) then return end
    local scanBtn = page.ScanButton
    if Usable(scanBtn) then
        scanBtn:SetHeight(22)
        PolishButtonFont(scanBtn, 12)
        if page.GetChildren then
            for _, ch in ipairs({ page:GetChildren() }) do
                if Usable(ch) and ch ~= scanBtn and Usable(ch.Text)
                    and not Usable(ch.HeadingText) and type(ch.ReceiveEvent) == "function" then
                    ch:SetHeight(18)
                    ch:ClearAllPoints()
                    ch:SetPoint("BOTTOMLEFT", scanBtn, "TOPLEFT", 0, 6)
                    ch:SetPoint("BOTTOMRIGHT", scanBtn, "TOPRIGHT", 0, 6)
                    ApplyCleanFont(ch.Text, 12, 0.56, 0.94, 0.92, 1)
                    if ch.Text.SetJustifyH then pcall(ch.Text.SetJustifyH, ch.Text, "CENTER") end
                    ch.Text:ClearAllPoints()
                    ch.Text:SetAllPoints(ch)
                    break
                end
            end
        end
    end
end

local function SkinPage(ref)
    local S = SkinAPI()
    if not (S and Usable(ref)) then return end
    Walk(S, ref, 0)
    local rn = ref.GetName and F.PlainString(ref:GetName(), "") or ""
    if rn == "AuctionatorCancellingFrame" or Usable(ref.UndercutScanContainer) then
        PolishCancellingPage(S, ref)
    elseif rn == "AuctionatorConfigFrame" or Usable(ref.ScanButton) then
        PolishConfigPage(ref)
    end
end

local function OnPageShow(ref)
    if not mod._active then return end
    C_Timer.After(0, function()
        if mod._active and Usable(ref) and ref:IsShown() then SkinPage(ref) end
    end)
    QueueSync()
end

local function OnPageHide()
    if mod._active then QueueSync() end
end

----------------------------------------------------------------------
--  4) 入口与生命周期
----------------------------------------------------------------------
local function ApplyAll()
    applyQueued = false
    if not mod._active then return end
    local S = SkinAPI()
    local ah = _G.AuctionHouseFrame
    if not (S and Usable(ah)) then return end

    local db = mod:GetDB()
    if not db.v2BlizzPrimaryAH then
        db.v2BlizzPrimaryAH = true
        RestoreAuctionatorRightClickIfNeeded()
    elseif ShouldMergeTabs() then
        RestoreAuctionatorRightClickIfNeeded()
    end

    if not ahHooked and type(ah.SetDisplayMode) == "function" then
        ahHooked = true
        _G.hooksecurefunc(ah, "SetDisplayMode", function()
            if mod._active then QueueSync() end
        end)
    end

    local tabs = AuctionatorTabs()
    if tabs then
        for _, t in ipairs(tabs) do
            if Usable(t) then
                if not done[t] then
                    done[t] = true
                    Call(S.Tab, t)
                end
                local ref = t.frameRef
                if Usable(ref) and not refHooked[ref] then
                    refHooked[ref] = true
                    ref:HookScript("OnShow", OnPageShow)
                    ref:HookScript("OnHide", OnPageHide)
                end
                if Usable(ref) and ref:IsShown() then SkinPage(ref) end
            end
        end
    end
    if Usable(scanBtnRef) then scanBtnRef:SetShown(ShouldMergeTabs()) end
    if Usable(scanStatusFS) then scanStatusFS:SetShown(ShouldMergeTabs()) end
    LayoutTabRow()
    SyncTabSelection()
end

local function QueueApply()
    if applyQueued then return end
    applyQueued = true
    C_Timer.After(0.08, ApplyAll)
    C_Timer.After(0.45, function()
        if mod._active and _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() then
            ApplyAll()
        end
    end)
end

function mod:OnEnable()
    self:RegisterEvent("AUCTION_HOUSE_SHOW", QueueApply)
    if _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() then
        QueueApply()
    end
end

function mod:OnDisable()
    if Usable(scanBtnRef) then scanBtnRef:Hide() end
    if Usable(scanStatusFS) then scanStatusFS:Hide() end
    SyncEUIZoneDividers(_G.AuctionHouseFrame, false, false)
    LayoutTabRow()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "精简重复页签（以暴雪原版为主 + 保留压价扫描）",
        tooltip = "保留暴雪原版完整好用的「购买（含分类列表）/ 出售（支持右键放入与放回）/ 拍卖」，隐藏 Auctionator 重复的购物/出售与英文介绍页，仅在末尾保留第 4 页「压价扫描」（内置全服市价扫描按钮）。",
        getValue = function() return db.mergeTabs ~= false end,
        setValue = function(v)
            db.mergeTabs = v == true
            if Usable(scanBtnRef) then scanBtnRef:SetShown(ShouldMergeTabs()) end
            if Usable(scanStatusFS) then scanStatusFS:SetShown(ShouldMergeTabs()) end
            if db.mergeTabs then RestoreAuctionatorRightClickIfNeeded() end
            if _G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown() then
                ApplyAll()
            end
        end,
    })
    y = y - h
    return y
end
