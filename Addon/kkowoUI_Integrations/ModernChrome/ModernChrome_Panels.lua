----------------------------------------------------------------------
--  kkowoUI_Integrations — ModernChrome/ModernChrome_Panels.lua
--  拍卖行/邮件/商人排版 + 鸿蒙字体防裁切 + 角色界面现代化重设计 + 施法条汉化
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local MC = F._MC
if not MC then return end

local ipairs, pairs, math_abs, math_floor, math_max, math_min, pcall, tonumber, tostring, type =
    ipairs, pairs, math.abs, math.floor, math.max, math.min, pcall, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local setmetatable = setmetatable
local mod = MC.mod

local RefreshAllCharacterBars = MC.RefreshAllCharacterBars
local SkinBugSackIfReady = MC.SkinBugSackIfReady
local SkinSkillsScrollBar = MC.SkinSkillsScrollBar
local ApplyBlizzDurabilityVisibility = MC.ApplyBlizzDurabilityVisibility
local ApplyEUIBuiltinHUDSkinsOnce = MC.ApplyEUIBuiltinHUDSkinsOnce
local ApplyFlightTimerDedup = MC.ApplyFlightTimerDedup
local ApplyQuestieTownsfolkDedup = MC.ApplyQuestieTownsfolkDedup
local ApplyUnifiedResourceBars = MC.ApplyUnifiedResourceBars
local RefreshHDPetHappiness = MC.RefreshHDPetHappiness
local SkinGhostFrame = MC.SkinGhostFrame
local SkinVehicleLeaveButton = MC.SkinVehicleLeaveButton
local StripZoneAbilityStyle = MC.StripZoneAbilityStyle
local cdmPosGuard = MC.cdmPosGuard
local swingGuard = MC.swingGuard
local HookCombatTextSizing = MC.HookCombatTextSizing
local HookTrainerFrameIfReady = MC.HookTrainerFrameIfReady
local RefreshWorldRefreshBanner = MC.RefreshWorldRefreshBanner

----------------------------------------------------------------------
--  8b) 拍卖行与发件箱排版修复（零污染、弱表管理）
--      • 拍卖行：修复「单价 / 每个物品」叠字 + 补齐无限服铜币框换肤与对齐
--      • 发件箱：EUI 去掉左上角圆形头像后，暴雪经典坐标仍把「收件人 / 主题」
--        向右挤了 ~60px，导致主题框捅出右边界且收件人框与「邮资」重叠；
--        按 MailFrame 实际宽度重排两行输入框与邮资，彻底对齐框体边缘。
----------------------------------------------------------------------
local windowPolish = {}
do
    local ahHooked = setmetatable({}, { __mode = "k" })
    local ahSkinnedCopper = setmetatable({}, { __mode = "k" })
    local ahOrigTopAnchor = setmetatable({}, { __mode = "k" })
    local ahFixedSub = setmetatable({}, { __mode = "k" })
    local ahPolishQueued = false
    local mailHooked = false
    local mailPolishQueued = false
    local merchantHooked = false
    local merchantPolishQueued = false

    local function FindMoneyCoinTexture(eb)
        local coin = eb.texture or eb.Icon
        if coin and coin.IsObjectType and coin:IsObjectType("Texture") then
            return coin
        end
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

    -- 统一拍卖行金/银/铜币输入框：
    --   • EUI 的 WSkin.EditBox -> FadeRegions 会把 GoldBox/SilverBox 的金币、银币图标透明度清零，
    --     且未换肤 CopperBox；这里为 CopperBox 补同款暗底边框，同时恢复三格的币标显示并让数字与币标居中对齐。
    local function PolishMoneyEditBox(eb, refBox, skinChrome)
        if not eb or (eb.IsForbidden and eb:IsForbidden()) then return end
        if refBox and refBox.GetHeight and eb.GetHeight and eb.SetHeight then
            local rh = F.PlainNumber(refBox:GetHeight(), 0)
            local ch = F.PlainNumber(eb:GetHeight(), 0)
            if rh > 10 and ch > 10 and math_abs(ch - rh) > 0.5 then
                pcall(eb.SetHeight, eb, rh)
            end
        end
        local coin = FindMoneyCoinTexture(eb)
        if skinChrome and not ahSkinnedCopper[eb] then
            ahSkinnedCopper[eb] = true

            -- 隐藏暴雪三段式金属边框，保留右侧铜币图标
            for _, k in ipairs({ "Left", "Right", "Middle", "Mid" }) do
                local r = eb[k]
                if r and r.SetAlpha then pcall(r.SetAlpha, r, 0) end
            end
            local name = eb.GetName and eb:GetName()
            if type(name) == "string" and name ~= "" then
                for _, suf in ipairs({ "Left", "Middle", "Right" }) do
                    local t = _G[name .. suf]
                    if t and t.SetAlpha then pcall(t.SetAlpha, t, 0) end
                end
            end
            if eb.GetRegions then
                for _, r in ipairs({ eb:GetRegions() }) do
                    if r and r ~= coin and r.IsObjectType and r:IsObjectType("Texture") then
                        local rw = F.PlainNumber(r.GetWidth and r:GetWidth(), 0)
                        local rh = F.PlainNumber(r.GetHeight and r:GetHeight(), 0)
                        local looksLikeCoin = rw > 4 and rw <= 18 and rh > 4 and rh <= 18 and math_abs(rw - rh) <= 4
                        if not looksLikeCoin and r.SetAlpha then
                            pcall(r.SetAlpha, r, 0)
                        end
                    end
                end
            end

            local bg = eb:CreateTexture(nil, "BACKGROUND", nil, -6)
            bg:SetColorTexture(0.02, 0.02, 0.02, 1)
            bg:SetAllPoints(eb)
            local borders = {
                { "TOPLEFT",    "TOPRIGHT",    0, 0, nil, 1 },
                { "BOTTOMLEFT", "BOTTOMRIGHT", 0, 0, nil, 1 },
                { "TOPLEFT",    "BOTTOMLEFT",  0, 0, 1, nil },
                { "TOPRIGHT",   "BOTTOMRIGHT", 0, 0, 1, nil },
            }
            for _, sp in ipairs(borders) do
                local ln = eb:CreateTexture(nil, "BORDER", nil, -7)
                ln:SetPoint(sp[1], eb, sp[1], sp[3], sp[4])
                ln:SetPoint(sp[2], eb, sp[2], sp[3], sp[4])
                if sp[5] then ln:SetWidth(sp[5]) end
                if sp[6] then ln:SetHeight(sp[6]) end
                ln:SetColorTexture(0.2, 0.2, 0.2, 1)
            end
        end

        -- 恢复被 EUI FadeRegions 隐藏的金/银币图标，并与铜币统一为 13×13 垂直居中靠右
        if coin then
            pcall(coin.SetAlpha, coin, 1)
            pcall(coin.Show, coin)
            if coin.SetSize then pcall(coin.SetSize, coin, 13, 13) end
            pcall(coin.ClearAllPoints, coin)
            pcall(coin.SetPoint, coin, "RIGHT", eb, "RIGHT", -5, 0)
            if coin.SetDrawLayer then pcall(coin.SetDrawLayer, coin, "OVERLAY", 3) end
        end
        if eb.SetFont then pcall(eb.SetFont, eb, F.Theme.GetFont(), 12, "") end
        if eb.SetShadowColor then pcall(eb.SetShadowColor, eb, 0, 0, 0, 0.90) end
        if eb.SetShadowOffset then pcall(eb.SetShadowOffset, eb, 1, -1) end
        -- 大号金额框右对齐紧贴币标并做 +1px 鸿蒙垂直居中补偿，避免数字孤立贴最左与币标脱节
        if eb.SetJustifyH then pcall(eb.SetJustifyH, eb, "RIGHT") end
        if eb.SetJustifyV then pcall(eb.SetJustifyV, eb, "MIDDLE") end
        if eb.SetTextInsets then pcall(eb.SetTextInsets, eb, 4, coin and 22 or 6, 1, 0) end
        if eb.HasFocus and not eb:HasFocus() and eb.GetText and eb.SetText then
            local txt = F.PlainString(eb:GetText(), nil)
            if txt ~= nil then pcall(eb.SetText, eb, txt) end
        end
    end

    local function PolishMoneyInputFrame(mi)
        if type(mi) ~= "table" then return end
        local ref = (type(mi.SilverBox) == "table" and mi.SilverBox)
            or (type(mi.GoldBox) == "table" and mi.GoldBox) or nil
        if type(mi.GoldBox) == "table" and mi.GoldBox:IsShown() then
            PolishMoneyEditBox(mi.GoldBox, nil, false)
        end
        if type(mi.SilverBox) == "table" and mi.SilverBox:IsShown() then
            PolishMoneyEditBox(mi.SilverBox, nil, false)
        end
        if type(mi.CopperBox) == "table" and mi.CopperBox:IsShown() then
            PolishMoneyEditBox(mi.CopperBox, ref, true)
        end
    end

    local function CollectVisibleFS(frame, out, seen)
        if not (frame and frame.GetRegions) then return end
        for _, r in ipairs({ frame:GetRegions() }) do
            if r and not seen[r] and r.IsObjectType and r:IsObjectType("FontString")
                and r.IsShown and r:IsShown() then
                local txt = F.PlainString(r.GetText and r:GetText(), "")
                if txt and txt ~= "" then
                    seen[r] = true
                    out[#out + 1] = r
                end
            end
        end
    end

    local function SeparatePriceLabels(sf, pi)
        if not (sf and pi) then return end
        local mi = pi.MoneyInputFrame
        local miLeft = mi and mi.GetLeft and F.PlainNumber(mi:GetLeft(), nil)

        -- 优先查找显式命名字段，同时扫描 PriceInput 及其父页签的可见 FontString，确保无论客户端模板怎么命名都能命中
        local topFS = pi.Label or pi.Text
        local subFS = pi.PerItemPostfix or pi.SubText or sf.PerItemPostfix or sf.SubText

        local list, seen = {}, {}
        CollectVisibleFS(pi, list, seen)
        CollectVisibleFS(sf, list, seen)
        -- 顺带扫描 PriceInput 的直接非输入框子框体（部分客户端把标签包在子层里）
        if pi.GetChildren then
            for _, ch in ipairs({ pi:GetChildren() }) do
                if ch and ch ~= mi then
                    CollectVisibleFS(ch, list, seen)
                end
            end
        end

        if topFS and not (topFS.IsShown and topFS:IsShown()) then topFS = nil end
        if subFS and not (subFS.IsShown and subFS:IsShown()) then subFS = nil end

        if not (topFS and subFS and topFS ~= subFS) then
            -- 按文本/几何位置找「单价」+「每个物品」或同一标签列内垂直重叠的一对文字
            local piTop = pi.GetTop and F.PlainNumber(pi:GetTop(), nil)
            local piBot = pi.GetBottom and F.PlainNumber(pi:GetBottom(), nil)
            local colCandidates = {}
            for _, fs in ipairs(list) do
                local l = F.PlainNumber(fs:GetLeft(), nil)
                local r = F.PlainNumber(fs:GetRight(), nil)
                local t = F.PlainNumber(fs:GetTop(), nil)
                local b = F.PlainNumber(fs:GetBottom(), nil)
                if l and r and t and b then
                    local inLeftCol = (not miLeft) or (r <= miLeft + 18)
                    local nearRow = (not (piTop and piBot)) or (t >= piBot - 24 and b <= piTop + 24)
                    if inLeftCol and nearRow then
                        colCandidates[#colCandidates + 1] = { fs = fs, l = l, r = r, t = t, b = b, txt = F.PlainString(fs:GetText(), "") }
                    end
                end
            end

            -- 1) 如果之前已配对过，直接沿用（不依赖固定字段名）
            if topFS and ahFixedSub[topFS] and ahFixedSub[topFS].IsShown and ahFixedSub[topFS]:IsShown() then
                subFS = ahFixedSub[topFS]
            else
                for _, cand in ipairs(colCandidates) do
                    local paired = ahFixedSub[cand.fs]
                    if paired and paired.IsShown and paired:IsShown() then
                        topFS, subFS = cand.fs, paired
                        break
                    end
                end
            end

            -- 2) 找带「每个物品 / Per Item」的副标签，或任意两段水平+垂直重叠的标签
            if not (topFS and subFS and topFS ~= subFS) then
                for i = 1, #colCandidates do
                    local a = colCandidates[i]
                    for j = i + 1, #colCandidates do
                        local b = colCandidates[j]
                        local hOverlap = math_min(a.r, b.r) - math_max(a.l, b.l)
                        local vOverlap = math_min(a.t, b.t) - math_max(a.b, b.b)
                        local isPerItemPair = a.txt:find("每个", 1, true) or b.txt:find("每个", 1, true)
                            or a.txt:lower():find("per item", 1, true) or b.txt:lower():find("per item", 1, true)
                        if hOverlap > 2 and (vOverlap > -2 or isPerItemPair) then
                            local aIsSub = a.txt:find("每个", 1, true) or a.txt:lower():find("per item", 1, true)
                            local bIsSub = b.txt:find("每个", 1, true) or b.txt:lower():find("per item", 1, true)
                            if aIsSub and not bIsSub then
                                topFS, subFS = b.fs, a.fs
                            elseif bIsSub and not aIsSub then
                                topFS, subFS = a.fs, b.fs
                            elseif a.t >= b.t then
                                topFS, subFS = a.fs, b.fs
                            else
                                topFS, subFS = b.fs, a.fs
                            end
                            break
                        end
                    end
                    if topFS and subFS then break end
                end
            end
        end

        if not (topFS and subFS and topFS ~= subFS) then return end
        if (topFS.IsForbidden and topFS:IsForbidden()) or (subFS.IsForbidden and subFS:IsForbidden()) then return end

        ahFixedSub[topFS] = subFS

        -- 记录主标签原始锚点（仅首次记录），确保反复打开/切换物品 100% 幂等不漂移；规避与副标签形成循环锚点
        local orig = ahOrigTopAnchor[topFS]
        if not orig and topFS.GetNumPoints and topFS:GetNumPoints() > 0 then
            local pts = {}
            local np = topFS:GetNumPoints()
            for i = 1, np do
                local p, rel, rp, x, y = topFS:GetPoint(i)
                if p and rel ~= subFS then
                    pts[#pts + 1] = { p, rel, rp, x or 0, y or 0 }
                end
            end
            if #pts > 0 then
                orig = pts
                ahOrigTopAnchor[topFS] = orig
            end
        end
        if orig then
            pcall(topFS.ClearAllPoints, topFS)
            for i = 1, #orig do
                local pt = orig[i]
                pcall(topFS.SetPoint, topFS, pt[1], pt[2], pt[3], pt[4], pt[5] + 5)
            end
        elseif mi or pi then
            pcall(topFS.ClearAllPoints, topFS)
            pcall(topFS.SetPoint, topFS, "RIGHT", mi or pi, "LEFT", -12, 5)
        end

        -- 副标签（「每个物品」）保持清晰小号字并紧贴主标签正下方 2px，彻底告别叠字
        if subFS.GetFont and subFS.SetFont then
            local okF, fPath, fSize, fFlags = pcall(subFS.GetFont, subFS)
            if okF and type(fPath) == "string" and fPath ~= "" then
                local curSz = F.PlainNumber(fSize, 12)
                if curSz > 11.5 then
                    pcall(subFS.SetFont, subFS, fPath, 11, type(fFlags) == "string" and fFlags or "")
                end
            end
        end
        local alignLeft = (topFS.GetJustifyH and topFS:GetJustifyH() == "LEFT")
        pcall(subFS.ClearAllPoints, subFS)
        if alignLeft then
            pcall(subFS.SetPoint, subFS, "TOPLEFT", topFS, "BOTTOMLEFT", 0, -2)
        else
            pcall(subFS.SetPoint, subFS, "TOPRIGHT", topFS, "BOTTOMRIGHT", 0, -2)
        end
    end

    local function PolishAuctionHouseNow()
        if not mod._active then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        local ah = _G.AuctionHouseFrame
        if not (type(ah) == "table" and ah:IsShown()) then return end
        for _, key in ipairs({ "CommoditiesSellFrame", "ItemSellFrame" }) do
            local sf = ah[key]
            if type(sf) == "table" and sf:IsShown() then
                for _, pk in ipairs({ "PriceInput", "SecondaryPriceInput" }) do
                    local pi = sf[pk]
                    if type(pi) == "table" and pi:IsShown() then
                        PolishMoneyInputFrame(pi.MoneyInputFrame)
                        SeparatePriceLabels(sf, pi)
                    end
                end
            end
        end
        -- 顺手补齐竞价区全部金/银/铜币输入框的币标与对齐（如存在且可见）
        for _, hostKey in ipairs({ "ItemBuyFrame", "AuctionsFrame" }) do
            local sub = ah[hostKey]
            local host = type(sub) == "table" and sub.BidFrame or nil
            if type(host) == "table" and type(host.BidAmount) == "table" and host.BidAmount:IsShown() then
                PolishMoneyInputFrame(host.BidAmount)
            end
        end
        for _, trio in ipairs({
            { "AuctionHouseFrameGold", "AuctionHouseFrameSilver", "AuctionHouseFrameCopper" },
            { "BidAmountGold",         "BidAmountSilver",         "BidAmountCopper" },
        }) do
            local gb, sb, cb = _G[trio[1]], _G[trio[2]], _G[trio[3]]
            if type(gb) == "table" and gb:IsShown() then PolishMoneyEditBox(gb, nil, false) end
            if type(sb) == "table" and sb:IsShown() then PolishMoneyEditBox(sb, nil, false) end
            if type(cb) == "table" and cb:IsShown() then PolishMoneyEditBox(cb, sb or gb, true) end
        end
    end

    local function QueuePolishAuctionHouse()
        if ahPolishQueued or not mod._active then return end
        ahPolishQueued = true
        C_Timer.After(0, function()
            ahPolishQueued = false
            pcall(PolishAuctionHouseNow)
            -- 晚一拍在 EUI WSkin.Debounce 之后复核一次，确保不被首帧换肤盖回
            C_Timer.After(0.08, function() pcall(PolishAuctionHouseNow) end)
        end)
    end

    windowPolish.HookAuctionHouse = function()
        local ah = _G.AuctionHouseFrame
        if type(ah) ~= "table" then return end
        if not ahHooked[ah] then
            ahHooked[ah] = true
            ah:HookScript("OnShow", QueuePolishAuctionHouse)
            if type(ah.SetDisplayMode) == "function" then
                _G.hooksecurefunc(ah, "SetDisplayMode", QueuePolishAuctionHouse)
            end
        end
        for _, key in ipairs({ "CommoditiesSellFrame", "ItemSellFrame" }) do
            local sf = ah[key]
            if type(sf) == "table" and not ahHooked[sf] then
                ahHooked[sf] = true
                sf:HookScript("OnShow", QueuePolishAuctionHouse)
                if type(sf.SetItem) == "function" then
                    _G.hooksecurefunc(sf, "SetItem", QueuePolishAuctionHouse)
                end
                if type(sf.UpdatePostState) == "function" then
                    _G.hooksecurefunc(sf, "UpdatePostState", QueuePolishAuctionHouse)
                end
            end
        end
        if ah:IsShown() then
            QueuePolishAuctionHouse()
        end
    end

    -- 发件箱重排：收件人 / 主题左移对齐信纸左边距，主题框严控在框内，邮资与收件人框垂直居中不重叠
    local function FindMailRegionByText(container, kw1, kw2)
        if not (container and container.GetRegions) then return nil end
        for _, r in ipairs({ container:GetRegions() }) do
            if r and r.IsObjectType and r:IsObjectType("FontString") then
                local txt = F.PlainString(r.GetText and r:GetText(), "")
                if txt and txt ~= "" then
                    if (kw1 and txt:find(kw1, 1, true)) or (kw2 and kw2 ~= "" and txt:find(kw2, 1, true)) then
                        return r
                    end
                end
            end
        end
        return nil
    end

    local function PolishSendMailNow()
        if not mod._active then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        local mf = _G.MailFrame
        local sf = _G.SendMailFrame
        local nameBox = _G.SendMailNameEditBox
        local subjBox = _G.SendMailSubjectEditBox
        if not (mf and sf and nameBox and subjBox and sf:IsShown()) then return end
        if (mf.IsForbidden and mf:IsForbidden()) or (sf.IsForbidden and sf:IsForbidden()) then return end

        local mfW = F.PlainNumber(mf:GetWidth(), 338)
        if mfW < 260 then mfW = 338 end

        -- 找到「收件人」「主题」「邮资」标签 FontString
        local toLbl = _G.SendMailNameEditBoxLabel
            or FindMailRegionByText(nameBox, "收件人", _G.SEND_MAIL_TO)
            or FindMailRegionByText(sf, "收件人", _G.SEND_MAIL_TO)
        local subjLbl = _G.SendMailSubjectEditBoxLabel
            or FindMailRegionByText(subjBox, "主题", _G.SUBJECT)
            or FindMailRegionByText(sf, "主题", _G.SUBJECT)
        local costFrame = _G.SendMailCostMoneyFrame
        local costLbl = _G.SendMailCostMoneyFrameLabel
            or FindMailRegionByText(sf, "邮资", _G.SEND_MAIL_COST)
            or (costFrame and FindMailRegionByText(costFrame, "邮资", _G.SEND_MAIL_COST))

        -- 垂直坐标：严控在标题栏（-30）与信纸区（SendMailScrollFrame）之间
        local rowH = 20
        local rowGap = 6
        local row1Top = -36
        local mfTop = F.PlainNumber(mf:GetTop(), nil)
        local scroll = _G.SendMailScrollFrame
        local scrollTop = scroll and F.PlainNumber(scroll:GetTop(), nil)
        if mfTop and scrollTop then
            local gapToBody = mfTop - scrollTop
            if gapToBody > 62 and gapToBody < 140 then
                local avail = gapToBody - 30 - 6
                local blockH = rowH * 2 + rowGap
                if avail >= blockH then
                    row1Top = -math_floor(30 + (avail - blockH) * 0.5 + 0.5)
                else
                    row1Top = -32
                end
            end
        end

        -- 计算左侧标签宽度，使「收件人: / 主题:」紧贴左侧信纸边距（约 14px）不再空出一大截
        local toW = toLbl and F.PlainNumber(toLbl.GetStringWidth and toLbl:GetStringWidth(), 44) or 44
        local subjW = subjLbl and F.PlainNumber(subjLbl.GetStringWidth and subjLbl:GetStringWidth(), 36) or 36
        local labelColW = math_max(40, math_min(72, math_floor(math_max(toW, subjW) + 0.5)))
        local editLeft = 14 + labelColW + 6
        local rightPad = 14

        -- 邮资区：靠右对齐 MailFrame 右内边，并与收件人输入框严格同一水平中线
        local row1MidY = row1Top - math_floor(rowH * 0.5)
        local costTotalW = 92
        if costFrame and costFrame.IsShown and costFrame:IsShown() then
            -- 对齐邮资金币/银币/铜币按钮内数字与币图标垂直中线
            for _, sfx in ipairs({ "GoldButton", "SilverButton", "CopperButton" }) do
                local cb = _G["SendMailCostMoneyFrame" .. sfx]
                local fs = cb and cb.GetFontString and cb:GetFontString()
                if fs then
                    if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "MIDDLE") end
                    pcall(fs.ClearAllPoints, fs)
                    pcall(fs.SetPoint, fs, "RIGHT", cb, "RIGHT", -13, -0.5)
                end
            end
            pcall(costFrame.ClearAllPoints, costFrame)
            pcall(costFrame.SetPoint, costFrame, "RIGHT", mf, "TOPRIGHT", -rightPad, row1MidY)
            local cfW = F.PlainNumber(costFrame:GetWidth(), 54)
            local clW = 0
            if costLbl and costLbl ~= costFrame then
                pcall(costLbl.ClearAllPoints, costLbl)
                pcall(costLbl.SetPoint, costLbl, "RIGHT", costFrame, "LEFT", -2, 0)
                clW = F.PlainNumber(costLbl.GetStringWidth and costLbl:GetStringWidth(), 32)
            end
            costTotalW = math_max(78, math_floor(cfW + clW + 8))
        end

        -- 收件人输入框：左侧对齐标签列，右侧给「邮资」留足 10px 间距
        local nameW = math_max(105, math_floor(mfW - editLeft - rightPad - costTotalW - 10))
        pcall(nameBox.SetHeight, nameBox, rowH)
        pcall(nameBox.SetWidth, nameBox, nameW)
        pcall(nameBox.ClearAllPoints, nameBox)
        pcall(nameBox.SetPoint, nameBox, "TOPLEFT", mf, "TOPLEFT", editLeft, row1Top)
        if toLbl and toLbl ~= nameBox then
            pcall(toLbl.ClearAllPoints, toLbl)
            pcall(toLbl.SetPoint, toLbl, "RIGHT", nameBox, "LEFT", -6, 0)
        end

        -- 主题输入框：与收件人左对齐，宽度精确收在 MailFrame 右内边（绝不捅出界面）
        local subjWBox = math_max(150, math_floor(mfW - editLeft - rightPad))
        pcall(subjBox.SetHeight, subjBox, rowH)
        pcall(subjBox.SetWidth, subjBox, subjWBox)
        pcall(subjBox.ClearAllPoints, subjBox)
        pcall(subjBox.SetPoint, subjBox, "TOPLEFT", nameBox, "BOTTOMLEFT", 0, -rowGap)
        if subjLbl and subjLbl ~= subjBox then
            pcall(subjLbl.ClearAllPoints, subjLbl)
            pcall(subjLbl.SetPoint, subjLbl, "RIGHT", subjBox, "LEFT", -6, 0)
        end

        -- 实测兜底：若邮资实测左缘与收件人右缘间距不足 8px，动态微收收件人框宽
        if costFrame and costFrame:IsShown() then
            local costLeft = (costLbl and costLbl:IsShown() and F.PlainNumber(costLbl:GetLeft(), nil))
                or F.PlainNumber(costFrame:GetLeft(), nil)
            local nameRight = F.PlainNumber(nameBox:GetRight(), nil)
            if costLeft and nameRight and (costLeft - nameRight) < 8 then
                local shrink = (8 - (costLeft - nameRight)) + 2
                local curW = F.PlainNumber(nameBox:GetWidth(), nameW)
                if curW - shrink >= 95 then
                    pcall(nameBox.SetWidth, nameBox, math_floor(curW - shrink))
                end
            end
        end
    end

    local function QueuePolishSendMail()
        if mailPolishQueued or not mod._active then return end
        mailPolishQueued = true
        C_Timer.After(0, function()
            mailPolishQueued = false
            pcall(PolishSendMailNow)
            C_Timer.After(0.06, function() pcall(PolishSendMailNow) end)
        end)
    end

    windowPolish.HookMail = function()
        local sf = _G.SendMailFrame
        if not sf then return end
        if not mailHooked then
            mailHooked = true
            sf:HookScript("OnShow", QueuePolishSendMail)
            if type(_G.MailFrameTab_OnClick) == "function" then
                _G.hooksecurefunc("MailFrameTab_OnClick", QueuePolishSendMail)
            end
            if type(_G.SendMailFrame_Update) == "function" then
                _G.hooksecurefunc("SendMailFrame_Update", QueuePolishSendMail)
            end
        end
        if sf:IsShown() then
            QueuePolishSendMail()
        end
    end

    -- 商人界面物品格排版：EUI 将 44px 物品卡的价格行上移 6px 并居中图标后，
    -- 换行的 2 行长物品名（配合鸿蒙字体较高行距）会从卡片上边框溢出 4–5px；
    -- 这里把名称严格锚定在卡片内顶边（y=-3，最大 2 行、11px 零额外行距），既不顶出上框也不压价格行。
    local function PolishMerchantTile(item)
        if not item or (item.IsForbidden and item:IsForbidden()) then return end
        if item.IsShown and not item:IsShown() then return end
        local name = item.GetName and item:GetName()
        local nameFS = item.Name or (type(name) == "string" and _G[name .. "Name"])
        if not nameFS or (nameFS.IsForbidden and nameFS:IsForbidden()) then return end

        local btn = item.ItemButton or (type(name) == "string" and _G[name .. "ItemButton"])
        local btnW = btn and F.PlainNumber(btn.GetWidth and btn:GetWidth(), 37) or 37
        if btnW < 20 or btnW > 60 then btnW = 37 end
        local leftX = math_floor(btnW + 6.5)

        if nameFS.GetFont and nameFS.SetFont then
            local okF, fPath, fSize, fFlags = pcall(nameFS.GetFont, nameFS)
            local curSz = okF and F.PlainNumber(fSize, 0) or 0
            if okF and type(fPath) == "string" and fPath ~= "" and curSz > 11 then
                pcall(nameFS.SetFont, nameFS, fPath, 11, type(fFlags) == "string" and fFlags or "")
            end
        end
        if nameFS.SetSpacing then pcall(nameFS.SetSpacing, nameFS, 0) end
        if nameFS.SetWordWrap then pcall(nameFS.SetWordWrap, nameFS, true) end
        if nameFS.SetMaxLines then pcall(nameFS.SetMaxLines, nameFS, 2) end
        if nameFS.SetJustifyH then pcall(nameFS.SetJustifyH, nameFS, "LEFT") end
        if nameFS.SetJustifyV then pcall(nameFS.SetJustifyV, nameFS, "TOP") end
        pcall(nameFS.ClearAllPoints, nameFS)
        pcall(nameFS.SetPoint, nameFS, "TOPLEFT", item, "TOPLEFT", leftX, -3)
        pcall(nameFS.SetPoint, nameFS, "TOPRIGHT", item, "TOPRIGHT", -5, -3)
        pcall(nameFS.SetHeight, nameFS, 24)
    end

    local function PolishMerchantNow()
        if not mod._active then return end
        local mf = _G.MerchantFrame
        if not (mf and mf:IsShown()) then return end
        if _G.EllesmereUIDB and _G.EllesmereUIDB.merchantShowAsList then return end
        local perPage = F.PlainNumber(_G.MERCHANT_ITEMS_PER_PAGE, 10)
        if perPage < 10 then perPage = 10 end
        if perPage > 12 then perPage = 12 end
        for i = 1, perPage do
            PolishMerchantTile(_G["MerchantItem" .. i])
        end
        for i = 1, 60 do
            local exTile = _G["EUI_MerchantPage" .. i]
            if not exTile then break end
            PolishMerchantTile(exTile)
        end
        PolishMerchantTile(_G.MerchantBuyBackItem)
    end

    local function QueuePolishMerchant()
        if merchantPolishQueued or not mod._active then return end
        merchantPolishQueued = true
        C_Timer.After(0, function()
            merchantPolishQueued = false
            pcall(PolishMerchantNow)
            C_Timer.After(0.06, function() pcall(PolishMerchantNow) end)
        end)
    end

    windowPolish.HookMerchant = function()
        local mf = _G.MerchantFrame
        if not mf then return end
        if not merchantHooked then
            merchantHooked = true
            mf:HookScript("OnShow", QueuePolishMerchant)
            for _, fnName in ipairs({ "MerchantFrame_Update", "MerchantFrame_UpdateMerchantInfo", "MerchantFrame_UpdateBuybackInfo" }) do
                if type(_G[fnName]) == "function" then
                    _G.hooksecurefunc(fnName, QueuePolishMerchant)
                end
            end
        end
        if mf:IsShown() then
            QueuePolishMerchant()
        end
    end

    -- 世界地图底部坐标去重：Polestar 与 Leatrix_Maps 同时开启时，Leatrix 会强开暴雪内置
    -- worldMapShowPlayerCoords / worldMapShowCursorCoords 并把坐标叠在 Polestar 底部栏下方导致双坐标重叠。
    local wmCoordsHooked = false
    local wmDedupActive = false
    local function HideBlizzAndLeatrixMapCoords()
        local wm = _G.WorldMapFrame
        if type(wm) ~= "table" then return end
        if type(wm.overlayFrames) == "table" then
            for _, fr in ipairs(wm.overlayFrames) do
                if type(fr) == "table" and fr.PlayerCoords and fr.CursorCoords then
                    local pc, cc, xc = fr.PlayerCoords, fr.CursorCoords, fr.CrosshairCoords
                    if type(pc) == "table" and pc.Hide then pcall(pc.Hide, pc) end
                    if type(cc) == "table" and cc.Hide then pcall(cc.Hide, cc) end
                    if type(xc) == "table" and xc.Hide then pcall(xc.Hide, xc) end
                    -- 若 Leatrix 主题模式把坐标挪进自建 footerFrame，一并收起
                    local p = type(pc) == "table" and pc.GetParent and pc:GetParent()
                    local canvas = wm.GetCanvasContainer and wm:GetCanvasContainer()
                    if type(p) == "table" and p ~= wm and p ~= fr and p ~= canvas and p.back and p.t and p.Hide then
                        pcall(p.Hide, p)
                    end
                end
            end
        end
        -- 收起 Leatrix_Maps 挂在 ScrollContainer 底部的半透明坐标底条（cFrame.back + cFrame.t）
        local sc = wm.ScrollContainer
        if type(sc) == "table" and sc.GetChildren then
            for _, ch in ipairs({ sc:GetChildren() }) do
                if type(ch) == "table" and ch.back and ch.t and not (ch.GetName and ch:GetName()) then
                    local h = F.PlainNumber(ch.GetHeight and ch:GetHeight(), 0)
                    if h >= 14 and h <= 24 and ch.Hide then
                        pcall(ch.Hide, ch)
                    end
                end
            end
        end
    end

    windowPolish.ApplyWorldMapCoordsDedup = function()
        local db = mod:GetDB()
        local want = mod._active and db.dedupWorldMapCoords ~= false
        local pDB = _G.PolestarDB
        local polestarCoordsOn = F.IsAddOnLoaded("Polestar")
            and not (type(pDB) == "table" and type(pDB.settings) == "table"
                and type(pDB.settings.maps) == "table" and pDB.settings.maps.worldMapCoords == false)
        local setCV = (_G.C_CVar and _G.C_CVar.SetCVar) or _G.SetCVar
        local getCV = (_G.C_CVar and _G.C_CVar.GetCVar) or _G.GetCVar
        wmDedupActive = want and polestarCoordsOn
        if wmDedupActive then
            local lm = _G.LeaMapsDB
            if type(lm) == "table" and lm.ShowCoords == "On" then
                lm.ShowCoords = "Off"
                db.wmDisabledLeatrix = true
            end
            if setCV and getCV then
                F.RunOutOfCombat("kkowoUI_WMCoordsDedup", function()
                    for _, cv in ipairs({ "worldMapShowPlayerCoords", "worldMapShowCursorCoords" }) do
                        local okV, v = pcall(getCV, cv)
                        if okV and v == "1" then
                            pcall(setCV, cv, "0")
                            db.wmDisabledCVars = type(db.wmDisabledCVars) == "table" and db.wmDisabledCVars or {}
                            db.wmDisabledCVars[cv] = true
                        end
                    end
                end)
            end
            HideBlizzAndLeatrixMapCoords()
            local wm = _G.WorldMapFrame
            if type(wm) == "table" and not wmCoordsHooked and wm.HookScript then
                wmCoordsHooked = true
                wm:HookScript("OnShow", function()
                    if mod._active and wmDedupActive then
                        HideBlizzAndLeatrixMapCoords()
                        C_Timer.After(0, HideBlizzAndLeatrixMapCoords)
                    end
                end)
            end
        else
            -- 去重不再需要（关了选项 / 停用模块 / Polestar 坐标关了或没装）：把我们关掉的坐标原样还回去，
            -- 否则会出现一套坐标都没有的情况。Leatrix 的开关重载后生效。
            if db.wmDisabledLeatrix then
                db.wmDisabledLeatrix = nil
                if type(_G.LeaMapsDB) == "table" then
                    _G.LeaMapsDB.ShowCoords = "On"
                end
            end
            if type(db.wmDisabledCVars) == "table" then
                local restoreList = db.wmDisabledCVars
                db.wmDisabledCVars = nil
                if setCV then
                    F.RunOutOfCombat("kkowoUI_WMCoordsDedup", function()
                        for cv in pairs(restoreList) do pcall(setCV, cv, "1") end
                    end)
                end
            end
        end
    end

    -- 静音角色攻击/射箭发声（经典 8 大种族男女 PlayerExertions Attack/Windup 官方 FileDataID）：
    -- 只静音角色自身挥砍/拉弓射箭时的「啊/哈」发声，不影响弓弦、技能音效、BOSS 与 NPC 语音，开关实时生效。
    local ATTACK_GRUNT_IDS = {
        Human_2    = { 542370, 542373, 542374, 951346, 951348, 951350, 951352, 951354, 951356, 951358, 1343336, 1343337, 1343338, 1343339, 1343340, 1343341 },
        Human_3    = { 542360, 542361, 542362, 542368, 951308, 951310, 951312, 951314, 951316, 951318, 1343369, 1343370, 1343371, 1343372, 1343373, 1343374, 1343375, 1343376, 1343377 },
        Dwarf_2    = { 542323, 542326, 542330, 542331, 951190, 951192, 951194, 951196, 951198, 951200, 1512844, 1512845, 1512846, 1512847 },
        Dwarf_3    = { 542310, 542315, 542316, 542318, 951142, 951144, 951146, 951148, 951150, 951152, 1512959, 1512960, 1512961, 1512962, 1512963 },
        NightElf_2 = { 542397, 542400, 542403, 542404, 951434, 951436, 951438, 951440, 951442, 951444 },
        NightElf_3 = { 542381, 542382, 542383, 542384, 951396, 951398, 951400, 951402, 951404, 951406 },
        Gnome_2    = { 542345, 542351, 542352, 542356, 951264, 951266, 951268, 951270, 951272, 951274, 1512986, 1512987, 1512988, 1512989, 1512990 },
        Gnome_3    = { 542334, 542335, 542336, 542339, 951228, 951230, 951232, 951234, 951236, 951238 },
        Orc_2      = { 542418, 542420, 542426, 951510, 951512, 951514, 951516, 951518, 951520 },
        Orc_3      = { 542405, 542406, 542415, 542416, 951480, 951482, 951484, 951486, 951488 },
        Scourge_2  = { 542488, 542492, 542493, 542495, 951764, 951766, 951768, 951770, 1383684, 1383685, 1383686, 1383687, 1383688, 1383689, 1383690, 1383713, 1383714 },
        Scourge_3  = { 542481, 542482, 542485, 542486, 951720, 951722, 951724, 951726, 951728, 951730 },
        Tauren_2   = { 542442, 542443, 542445, 542446, 951596, 951598, 951600, 951602, 951604, 951606, 1502100, 1502101, 1502102, 1502103, 1502104, 1502105 },
        Tauren_3   = { 542430, 542433, 542434, 542437, 951552, 951554, 951556, 951558, 951560, 951562 },
        Troll_2    = { 542466, 542467, 542468, 542471, 951686, 951688, 951690, 951692, 951694, 1512822, 1512823, 1512824, 1512825, 1512826 },
        Troll_3    = { 542453, 542454, 542460, 542462, 951642, 951644, 951646, 951648, 951650, 1502171, 1502172, 1502173, 1502174, 1502175, 1502176 },
    }
    local BOW_PULLBACK_IDS = { 567675, 567676, 567677, 567678, 567679, 567683 }
    local mutedSoundIDs = {}
    local staleMuteSwept = false

    windowPolish.ApplyCombatSoundMute = function()
        local muteFn, unmuteFn = _G.MuteSoundFile, _G.UnmuteSoundFile
        if type(muteFn) ~= "function" then return end
        local db = mod:GetDB()
        local want = {}
        if mod._active and db.muteAttackGrunts ~= false then
            local raceFile = nil
            if _G.UnitRace then
                local okR, _, rf = pcall(_G.UnitRace, "player")
                if okR and type(rf) == "string" and not F.IsSecret(rf) then raceFile = rf end
            end
            local sex = _G.UnitSex and F.PlainNumber(_G.UnitSex("player"), 0) or 0
            local list = raceFile and (sex == 2 or sex == 3) and ATTACK_GRUNT_IDS[raceFile .. "_" .. sex] or nil
            if list then
                for i = 1, #list do want[list[i]] = true end
            elseif raceFile then
                for _, s in ipairs({ 2, 3 }) do
                    local sub = ATTACK_GRUNT_IDS[raceFile .. "_" .. s]
                    if sub then
                        for i = 1, #sub do want[sub[i]] = true end
                    end
                end
            end
        end
        if mod._active and db.muteBowPullback == true then
            for i = 1, #BOW_PULLBACK_IDS do want[BOW_PULLBACK_IDS[i]] = true end
        end
        -- 静音会跨 /reload（以及换角色）保留，但本表每次重载都是空的：
        -- 本会话第一次执行时，若上次会话静音过，就把这次不需要的 ID 全部解除一遍（如换了不同种族的角色）
        if not staleMuteSwept and type(unmuteFn) == "function" then
            staleMuteSwept = true
            if db.soundMuteApplied then
                for _, list in pairs(ATTACK_GRUNT_IDS) do
                    for i = 1, #list do
                        if not want[list[i]] then pcall(unmuteFn, list[i]) end
                    end
                end
                for i = 1, #BOW_PULLBACK_IDS do
                    if not want[BOW_PULLBACK_IDS[i]] then pcall(unmuteFn, BOW_PULLBACK_IDS[i]) end
                end
            end
        end
        if type(unmuteFn) == "function" then
            for id in pairs(mutedSoundIDs) do
                if not want[id] then
                    pcall(unmuteFn, id)
                    mutedSoundIDs[id] = nil
                end
            end
        end
        for id in pairs(want) do
            if not mutedSoundIDs[id] then
                pcall(muteFn, id)
                mutedSoundIDs[id] = true
            end
        end
        db.soundMuteApplied = (next(mutedSoundIDs) ~= nil) or nil
    end
end

----------------------------------------------------------------------
--  8b-2) 鸿蒙字体全界面防顶部裁切与垂直居中修正
--        HarmonyOS Sans 的 usWinAscent 达 1056/1000（比暴雪默认字形高 ~20%），
--        凡是 ScrollFrame / ClipsChildren 顶边紧贴首行文字（如技能说明、声望说明、任务详情）
--        或定高单行框（如角色「等级30 猎人」）都会把第一行字顶切掉一截。
--        这里用弱表记录原始锚点与高度，统一补足顶部留白并支持无损还原。
----------------------------------------------------------------------
do
    local origAnchor = setmetatable({}, { __mode = "k" })
    local origHeight = setmetatable({}, { __mode = "k" })
    local origJustV  = setmetatable({}, { __mode = "k" })
    local unclippedNodes = setmetatable({}, { __mode = "k" })
    local hookedWin  = setmetatable({}, { __mode = "k" })
    local hookedSF   = setmetatable({}, { __mode = "k" })
    local skillsBoxHooked = false
    local gossipScrollHooked = false
    local questGreetingFnHooked = false
    local questDialogHooked = setmetatable({}, { __mode = "k" })

    local function IsSafeObj(o)
        if type(o) ~= "table" then return false end
        if o.IsForbidden then
            local ok, forb = pcall(o.IsForbidden, o)
            if not ok or forb then return false end
        end
        return true
    end

    local function IsTopPoint(pt)
        return pt == "TOP" or pt == "TOPLEFT" or pt == "TOPRIGHT"
    end

    -- 修复 NPC 对话窗（GossipFrame）与任务对话/邮件/书信窗在鸿蒙大字号下的文字与选项重叠问题：
    -- 12.x GossipFrame 使用 ScrollBox，GreetingText 换行高度在大字号下常超过预估行高，导致下方对话选项压在正文上。
    local function MeasureRowContentHeight(row, isGreeting)
        local maxH = 0
        local function CheckFS(fs)
            if not (IsSafeObj(fs) and fs.GetStringHeight) then return end
            if fs.IsShown and not fs:IsShown() then return end
            local txt = fs.GetText and F.PlainString(fs:GetText(), "") or ""
            if txt == "" then return end
            if fs.CanWordWrap and fs:CanWordWrap() and fs.SetHeight then
                -- 释放固定高度裁切，让 GetStringHeight 返回真实多行渲染高度
                local curFh = F.PlainNumber(fs:GetHeight(), 0) or 0
                local curSh = F.PlainNumber(fs:GetStringHeight(), 0) or 0
                if curFh > 0 and (curSh >= curFh - 2 or isGreeting) then
                    pcall(fs.SetHeight, fs, 0)
                end
            end
            local sh = F.PlainNumber(fs:GetStringHeight(), 0) or 0
            if sh > maxH then maxH = sh end
        end
        if row.GreetingText then CheckFS(row.GreetingText) end
        if row.GetFontString then CheckFS(row:GetFontString()) end
        if row.Title then CheckFS(row.Title) end
        if row.GetRegions then
            for _, reg in ipairs({ row:GetRegions() }) do
                if IsSafeObj(reg) and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                    CheckFS(reg)
                end
            end
        end
        if maxH <= 0 then return nil end
        return math_floor(maxH + (isGreeting and 14 or 8) + 0.5)
    end

    local gossipReflowBusy = false
    local gossipRowOrigH = setmetatable({}, { __mode = "k" })
    local function ReflowGossipScrollBox()
        if gossipReflowBusy then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        local gf = _G.GossipFrame
        local gp = gf and gf.GreetingPanel
        local sb = gp and gp.ScrollBox
        if not (IsSafeObj(gf) and gf:IsShown() and IsSafeObj(sb) and sb:IsShown()) then return end
        local target = sb.ScrollTarget
        if not IsSafeObj(target) then return end

        local rows = {}
        if sb.ForEachFrame then
            pcall(sb.ForEachFrame, sb, function(fr)
                if IsSafeObj(fr) and fr:IsShown() then
                    rows[#rows + 1] = fr
                end
            end)
        end
        if #rows == 0 and target.GetChildren then
            for _, ch in ipairs({ target:GetChildren() }) do
                if IsSafeObj(ch) and ch:IsShown() then
                    rows[#rows + 1] = ch
                end
            end
        end
        if #rows == 0 then return end

        -- 按元素索引优先、其次按当前屏幕 Y 坐标从上到下排序
        table.sort(rows, function(a, b)
            local ia = a.GetElementDataIndex and F.PlainNumber(a:GetElementDataIndex(), nil)
            local ib = b.GetElementDataIndex and F.PlainNumber(b:GetElementDataIndex(), nil)
            if ia and ib and ia ~= ib then return ia < ib end
            local ta = a.GetTop and F.PlainNumber(a:GetTop(), 0) or 0
            local tb = b.GetTop and F.PlainNumber(b:GetTop(), 0) or 0
            return ta > tb
        end)

        local tTop = target.GetTop and F.PlainNumber(target:GetTop(), nil)
        local cursorY = 0
        local needShift = false
        local plan = {}

        for i, row in ipairs(rows) do
            local isGreeting = (row.GreetingText ~= nil)
            local curH = F.PlainNumber(row.GetHeight and row:GetHeight(), 0) or 0
            if not gossipRowOrigH[row] and curH > 0 then
                gossipRowOrigH[row] = curH
            end
            local baseH = isGreeting and 20 or (gossipRowOrigH[row] or 20)
            if baseH > 36 then baseH = 24 end
            local needH = MeasureRowContentHeight(row, isGreeting) or baseH
            if needH < baseH then needH = baseH end

            -- 读取行当前相对 target 顶部的 y 偏移（负数表示向下）
            local okP, pt, rel, rpt, px, py = pcall(row.GetPoint, row, 1)
            local curTopY = (okP and rel == target and IsTopPoint(pt) and F.PlainNumber(py, nil)) or nil
            if not curTopY and tTop and row.GetTop then
                local rTop = F.PlainNumber(row:GetTop(), nil)
                if rTop then curTopY = rTop - tTop end
            end
            if i == 1 then
                cursorY = math_min(-4, curTopY or -4)
            else
                local expectedMaxTop = cursorY - 4
                if (curTopY and curTopY > expectedMaxTop) or needShift then
                    needShift = true
                else
                    cursorY = curTopY or expectedMaxTop
                end
            end

            if math_abs(needH - curH) > 1 then
                needShift = true
            end
            plan[i] = {
                row = row,
                x = (okP and F.PlainNumber(px, 0)) or 0,
                y = cursorY,
                h = needH,
                resized = math_abs(needH - curH) > 1,
            }
            cursorY = cursorY - needH - (isGreeting and 10 or 4)
        end

        if not needShift then return end
        gossipReflowBusy = true
        for _, item in ipairs(plan) do
            local row = item.row
            if item.resized and row.SetHeight then
                pcall(row.SetHeight, row, item.h)
            end
            if row.ClearAllPoints and row.SetPoint then
                pcall(row.ClearAllPoints, row)
                pcall(row.SetPoint, row, "TOPLEFT", target, "TOPLEFT", item.x, item.y)
                pcall(row.SetPoint, row, "TOPRIGHT", target, "TOPRIGHT", 0, item.y)
            end
        end
        local reqTargetH = math_abs(cursorY) + 16
        local curTargetH = F.PlainNumber(target.GetHeight and target:GetHeight(), 0) or 0
        if reqTargetH > curTargetH and target.SetHeight then
            pcall(target.SetHeight, target, reqTargetH)
        end
        gossipReflowBusy = false
    end

    -- 同类对话/任务/邮件/书信多行正文防固定高度裁切与重叠
    local MULTILINE_DIALOG_FS = {
        "GreetingText",
        "QuestInfoDescriptionText",
        "QuestInfoObjectivesText",
        "QuestInfoRewardText",
        "QuestProgressText",
        "OpenMailBodyText",
        "ItemTextPageText",
    }
    local MULTILINE_DIALOG_SET = {}
    for _, name in ipairs(MULTILINE_DIALOG_FS) do
        MULTILINE_DIALOG_SET[name] = true
    end

    local function FitGreetingTitleButton(btn)
        if not (IsSafeObj(btn) and btn.IsShown and btn:IsShown() and btn.SetHeight) then return end
        local fs = btn.GetFontString and btn:GetFontString()
        if IsSafeObj(fs) and fs.CanWordWrap and fs:CanWordWrap() and fs.SetHeight then
            local curFh = F.PlainNumber(fs.GetHeight and fs:GetHeight(), 0) or 0
            local curSh = F.PlainNumber(fs.GetStringHeight and fs:GetStringHeight(), 0) or 0
            if curFh > 0 and curSh >= curFh - 2 then
                pcall(fs.SetHeight, fs, 0)
            end
        end
        local sh = math_max(
            (IsSafeObj(fs) and fs.GetStringHeight and F.PlainNumber(fs:GetStringHeight(), 0)) or 0,
            (btn.GetTextHeight and F.PlainNumber(btn:GetTextHeight(), 0)) or 0
        )
        if sh <= 0 then return end
        local iconH = (IsSafeObj(btn.Icon) and btn.Icon.GetHeight and F.PlainNumber(btn.Icon:GetHeight(), 0)) or 0
        local wantH = math_max(math_floor(sh + 4 + 0.5), math_floor(iconH + 0.5))
        local curH = F.PlainNumber(btn.GetHeight and btn:GetHeight(), 0) or 0
        if wantH > curH + 0.5 then
            pcall(btn.SetHeight, btn, wantH)
        end
    end

    local function FixSimilarDialogOverlaps()
        for _, name in ipairs(MULTILINE_DIALOG_FS) do
            local fs = _G[name]
            if IsSafeObj(fs) and fs.SetHeight and fs.GetStringHeight
                and (not fs.GetObjectType or fs:GetObjectType() == "FontString") then
                pcall(fs.SetHeight, fs, 0)
            end
        end
        -- 任务问候页（QuestFrameGreetingPanel）：
        -- 注意：QuestGreetingFrameHorizontalBreak 是「现有任务」最后一个按钮与「可以取得的任务」之间的分隔线，
        -- AvailableQuestsText 锚在它下方（-12, -10），绝不可把它重锚到 GreetingText 下方，否则会把「可以取得的任务」拽上来压住现有任务列表。
        -- 只要保证 GreetingText 自动撑高（SetHeight(0)）且各任务标题按钮高度足够容纳鸿蒙字体/换行高度，暴雪原生锚点链即可自然顺排、绝不重叠。
        local qgp = _G.QuestFrameGreetingPanel
        if IsSafeObj(qgp) and qgp:IsShown() then
            local gt = _G.GreetingText
            if IsSafeObj(gt) and gt:IsShown() and gt.SetHeight then
                pcall(gt.SetHeight, gt, 0)
            end
            local pool = qgp.titleButtonPool
            if type(pool) == "table" and type(pool.EnumerateActive) == "function" then
                for btn in pool:EnumerateActive() do
                    FitGreetingTitleButton(btn)
                end
            else
                for i = 1, 32 do
                    local btn = _G["QuestTitleButton" .. i]
                    if not btn then break end
                    FitGreetingTitleButton(btn)
                end
            end
        end
    end

    local FONT_GUARD_WINDOWS = {
        "CharacterFrame", "PaperDollFrame", "SkillsFrame", "ReputationFrame",
        "PetPaperDollFrame", "TokenFrame", "HonorFrame", "PVPFrame", "InspectFrame",
        "QuestFrame", "QuestLogFrame", "GossipFrame",
        "MailFrame", "OpenMailFrame", "SendMailFrame",
        "MerchantFrame", "FriendsFrame", "GuildFrame",
        "ClassTrainerFrame", "TradeSkillFrame", "CraftFrame",
        "SpellBookFrame", "PlayerSpellsFrame", "MacroFrame",
        "AuctionHouseFrame", "DressUpFrame", "CommunitiesFrame", "EncounterJournal",
    }

    local function ReadAllPoints(region)
        local pts = {}
        local n = region.GetNumPoints and F.PlainNumber(region:GetNumPoints(), 1) or 1
        for i = 1, n do
            local okP, pt, rel, rpt, x, y = pcall(region.GetPoint, region, i)
            if okP and type(pt) == "string" then
                pts[#pts + 1] = { pt, rel, rpt, F.PlainNumber(x, 0), F.PlainNumber(y, 0) }
            end
        end
        return pts
    end

    local function SetAllPoints(region, pts)
        pcall(region.ClearAllPoints, region)
        for _, p in ipairs(pts) do
            pcall(region.SetPoint, region, p[1], p[2], p[3], p[4], p[5])
        end
    end

    -- 把顶边锚点下移 deltaY。暴雪会自己重排很多文字（如任务详情每次显示都会重新挂锚点、在任务窗口与任务日志之间换父框体），
    -- 所以每次都读当前锚点：仍是我们上次设的才算「已处理 / 可还原」；被暴雪改过就以新锚点为准重新判断，绝不套用旧锚点。
    -- minY：只有首个锚点是顶边且 y >= minY（文字贴着顶边）时才下移；nil 表示顶边锚点一律下移。
    local appliedAnchor = setmetatable({}, { __mode = "k" })
    local function ShiftAnchorY(region, deltaY, want, minY)
        if not (IsSafeObj(region) and region.GetPoint and region.SetPoint) then return end
        local cur = ReadAllPoints(region)
        local first = cur[1]
        if not first then return end
        local ap = appliedAnchor[region]
        local ours = ap ~= nil and ap[1] == first[1] and ap[2] == first[2] and ap[3] == first[3]
            and math_abs(ap[4] - first[4]) < 0.01 and math_abs(ap[5] - first[5]) < 0.01
        if ours then
            if not want and origAnchor[region] then
                SetAllPoints(region, origAnchor[region])
                origAnchor[region] = nil
                appliedAnchor[region] = nil
            end
            return
        end
        -- 当前锚点不是我们设的：之前记下的原锚点已过期
        origAnchor[region] = nil
        appliedAnchor[region] = nil
        if not want or not IsTopPoint(first[1]) or (minY and first[5] < minY) then return end
        origAnchor[region] = cur
        local shifted = {}
        for i, p in ipairs(cur) do
            shifted[i] = { p[1], p[2], p[3], p[4], IsTopPoint(p[1]) and (p[5] + deltaY) or p[5] }
        end
        SetAllPoints(region, shifted)
        appliedAnchor[region] = shifted[1]
    end

    local function GuardFontStringHeight(fs, want)
        if not (IsSafeObj(fs) and fs.GetFont and fs.GetHeight and fs.SetHeight) then return end
        local fname = fs.GetName and F.PlainString(fs:GetName(), nil) or nil
        if fname and MULTILINE_DIALOG_SET[fname] then
            if want then pcall(fs.SetHeight, fs, 0) end
            return
        end
        local okF, _, sz = pcall(fs.GetFont, fs)
        sz = okF and F.PlainNumber(sz, 0) or 0
        if sz < 9 then return end
        local h = F.PlainNumber(fs:GetHeight(), 0)
        if origHeight[fs] == nil then
            if h > 0 and h < sz * 1.40 then
                origHeight[fs] = h
            else
                return
            end
        end
        if want then
            local wrapped = fs.CanWordWrap and fs:CanWordWrap()
            local txt = fs.GetText and F.PlainString(fs:GetText(), "") or ""
            local strH = F.PlainNumber(fs.GetStringHeight and fs:GetStringHeight(), 0) or 0
            local isLong = wrapped and (#txt > 18 or strH > sz * 1.55)
            if isLong then
                pcall(fs.SetHeight, fs, 0)
            else
                local wantH = math_floor(sz * 1.48 + 0.5)
                if h == 0 or h < wantH then
                    pcall(fs.SetHeight, fs, wantH)
                end
                if fs.SetJustifyV then
                    if origJustV[fs] == nil and fs.GetJustifyV then
                        local okJ, jv = pcall(fs.GetJustifyV, fs)
                        origJustV[fs] = (okJ and type(jv) == "string") and jv or false
                    end
                    pcall(fs.SetJustifyV, fs, "MIDDLE")
                end
            end
        else
            pcall(fs.SetHeight, fs, origHeight[fs])
            if origJustV[fs] and fs.SetJustifyV then pcall(fs.SetJustifyV, fs, origJustV[fs]) end
            origJustV[fs] = nil
        end
    end

    local function IsFlushToParentTop(region, parent)
        if not (IsSafeObj(region) and region.GetPoint) then return false end
        local okP, pt, rel, rpt = pcall(region.GetPoint, region, 1)
        if not okP or not IsTopPoint(pt) then return false end
        if rel ~= nil and rel ~= parent then return false end
        return rpt == nil or IsTopPoint(rpt)
    end

    local function SyncScrollFrameTopGuard(sf, want)
        if not IsSafeObj(sf) then return end
        local sc = sf.GetScrollChild and sf:GetScrollChild()
        if not IsSafeObj(sc) then return end
        -- 首行文字若紧贴滚动区顶边（y >= -3），统一向下留出 6px 顶部安全区。
        -- 不关闭滚动区裁切：内容常在窗口开着时变长（任务日志切换任务等），关掉裁切后长文字会溢出到窗口按钮上。
        if sc.GetRegions then
            for _, reg in ipairs({ sc:GetRegions() }) do
                if IsSafeObj(reg) and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                    if not want or IsFlushToParentTop(reg, sc) then
                        ShiftAnchorY(reg, -6, want, -3)
                    end
                    GuardFontStringHeight(reg, want)
                end
            end
        end
        if sc.GetChildren then
            for _, ch in ipairs({ sc:GetChildren() }) do
                if IsSafeObj(ch) and (not want or IsFlushToParentTop(ch, sc)) then
                    ShiftAnchorY(ch, -6, want, -3)
                end
            end
        end
    end

    local function PolishSkillsDetailDescription(want)
        local sf = _G.SkillsFrame
        if not IsSafeObj(sf) then return end
        local sbox = sf.ScrollBox
        local function scan(node, depth)
            if not IsSafeObj(node) or node == sbox or depth > 5 then return end
            local otype = node.GetObjectType and node:GetObjectType()
            if otype == "ScrollFrame" then
                SyncScrollFrameTopGuard(node, want)
                return
            end
            local clips = node.DoesClipChildren and node:DoesClipChildren()
            if node.GetRegions then
                for _, reg in ipairs({ node:GetRegions() }) do
                    if IsSafeObj(reg) and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                        local txt = reg.GetText and F.PlainString(reg:GetText(), "") or ""
                        local isDesc = #txt >= 18 or (reg.CanWordWrap and reg:CanWordWrap() and #txt >= 8)
                        if isDesc or (not want and origAnchor[reg]) then
                            ShiftAnchorY(reg, -7, want, -6)
                            if want and reg.SetHeight then pcall(reg.SetHeight, reg, 0) end
                            -- 说明装得下才关裁切；换成更长的说明时（每次列表刷新都会重算）立即恢复裁切
                            if (clips or unclippedNodes[node]) and node.SetClipsChildren then
                                local nh = F.PlainNumber(node:GetHeight(), 0)
                                local rh = F.PlainNumber(reg:GetStringHeight(), 0)
                                local off = want and isDesc and nh > 0 and rh > 0 and rh + 12 <= nh
                                pcall(node.SetClipsChildren, node, not off)
                                unclippedNodes[node] = off or nil
                            end
                        else
                            GuardFontStringHeight(reg, want)
                        end
                    end
                end
            end
            if not want and unclippedNodes[node] and node.SetClipsChildren then
                pcall(node.SetClipsChildren, node, true)
                unclippedNodes[node] = nil
            end
            if node.GetChildren then
                for _, ch in ipairs({ node:GetChildren() }) do
                    scan(ch, depth + 1)
                end
            end
        end
        scan(sf, 0)
    end

    local function GuardWindowTree(root, want, depth)
        if not IsSafeObj(root) or depth > 5 or root == _G.kkowoUI_CharHeroCard then return end
        local rname = root.GetName and F.PlainString(root:GetName(), nil) or nil
        if rname and rname:sub(1, 8) == "kkowoUI_" then return end
        local otype = root.GetObjectType and F.PlainString(root:GetObjectType(), nil) or nil
        -- 跳过 EditBox 输入框/搜索框（如法术书/天赋/拍卖行/收藏/地下城手册搜索栏），
        -- 绝不对其内部提示文字（Instructions）执行 ShiftAnchorY 导致打开后延迟下移错位
        if otype == "EditBox" then
            if not want and root.GetRegions then
                for _, reg in ipairs({ root:GetRegions() }) do
                    if IsSafeObj(reg) and reg.GetObjectType and F.PlainString(reg:GetObjectType(), nil) == "FontString" then
                        if origAnchor[reg] then ShiftAnchorY(reg, -5, false, -2) end
                        if origHeight[reg] ~= nil then GuardFontStringHeight(reg, false) end
                    end
                end
            end
            return
        end
        -- 跳过 ScrollBox 虚拟化行池本身（避免破坏暴雪滚动布局），但处理常规 ScrollFrame
        if root.ScrollTarget then return end
        if otype == "ScrollFrame" then
            SyncScrollFrameTopGuard(root, want)
            if not hookedSF[root] and root.HookScript then
                hookedSF[root] = true
                root:HookScript("OnShow", function(self)
                    local on = mod._active and mod:GetDB().harmonyFontGuard ~= false
                    SyncScrollFrameTopGuard(self, on)
                end)
            end
            return
        end
        if root.GetRegions then
            local clips = root.DoesClipChildren and root:DoesClipChildren()
            for _, reg in ipairs({ root:GetRegions() }) do
                if IsSafeObj(reg) and reg.GetObjectType and F.PlainString(reg:GetObjectType(), nil) == "FontString" then
                    GuardFontStringHeight(reg, want)
                    if clips or origAnchor[reg] then
                        ShiftAnchorY(reg, -5, want, -2)
                    end
                end
            end
        end
        if root.GetChildren then
            for _, ch in ipairs({ root:GetChildren() }) do
                GuardWindowTree(ch, want, depth + 1)
            end
        end
    end

    -- 法术书（PlayerSpellsFrame.SpellBookFrame）右侧搜索框防跳动与筛选下拉对齐守卫：
    -- 1) 打开第 0 帧即预留 DungeonsForeverSpell 双标签（∞ / 锤）的精确宽度，
    --    并与 NativeSpellBook.lua:1686 的公式（right - left - 10，上限 300）完全对齐，
    --    彻底消除 0~200ms 延迟显形造成的「先宽后窄」跳动；
    -- 2) 挂接 box:SetWidth 与双标签 OnShow 防外部拉宽与微校准；
    -- 3) 基于原始锚点将 SearchBox 与右侧筛选下拉钮 [▼] 一起垂直居中对齐标签行，无漂移、停用无损还原。
    local spellBookGuardHooked = setmetatable({}, { __mode = "k" })
    local spellBoxWidthHooked = setmetatable({}, { __mode = "k" })
    local dfTabShowHooked = setmetatable({}, { __mode = "k" })
    local spellSearchOrigW = setmetatable({}, { __mode = "k" })
    local spellSearchOrigPts = setmetatable({}, { __mode = "k" })
    local spellSearchAppliedDy = setmetatable({}, { __mode = "k" })
    local spellFilterOrigPts = setmetatable({}, { __mode = "k" })
    local spellFilterAppliedDy = setmetatable({}, { __mode = "k" })
    local spellSearchBusy = false
    local StabilizeSpellBookSearchBox -- 前向声明

    local function IsDungeonsForeverSpellLoaded()
        if _G.DungeonsForeverSpellBookTab or _G.DungeonsForeverWeaponBookTab then
            return true
        end
        if _G.C_AddOns and type(_G.C_AddOns.IsAddOnLoaded) == "function" then
            local okL, loaded = pcall(_G.C_AddOns.IsAddOnLoaded, "DungeonsForeverSpell")
            if okL and not F.IsSecret(loaded) and loaded == true then
                return true
            end
        end
        return false
    end

    local function IsWidgetShownPlain(w)
        if not IsSafeObj(w) then return false end
        if w.IsShown then
            local okS, s = pcall(w.IsShown, w)
            if not okS or F.IsSecret(s) or not s then return false end
        end
        return true
    end

    local function HookDFTabOnShow(btn)
        if not (IsSafeObj(btn) and btn.HookScript and not dfTabShowHooked[btn]) then return end
        dfTabShowHooked[btn] = true
        btn:HookScript("OnShow", function()
            local on = mod._active and mod:GetDB().harmonyFontGuard ~= false
            StabilizeSpellBookSearchBox(on)
        end)
    end

    local function ReadScaledWidth(btn, fallbackW, refEffScale)
        local w = nil
        if IsSafeObj(btn) and btn.GetWidth then
            w = F.PlainNumber(btn:GetWidth(), nil)
        end
        if not (w and w > 4) then
            return fallbackW
        end
        if IsSafeObj(btn) and btn.GetEffectiveScale and refEffScale and refEffScale > 0 then
            local bScale = F.PlainNumber(btn:GetEffectiveScale(), nil)
            if bScale and bScale > 0 and math_abs(bScale - refEffScale) > 0.001 then
                w = w * (bScale / refEffScale)
            end
        end
        return w
    end

    local function FindRightmostSpellTab(sb, box)
        local rightmost = nil
        local blizzRightmost = nil
        local maxBlizzR = -1e9
        local sampleTabW = nil
        local boxEffScale = (IsSafeObj(box) and box.GetEffectiveScale and F.PlainNumber(box:GetEffectiveScale(), nil)) or 1
        if not (boxEffScale and boxEffScale > 0) then boxEffScale = 1 end

        local tabSys = sb and sb.CategoryTabSystem
        if IsSafeObj(tabSys) then
            local sysR = tabSys.GetRight and F.PlainNumber(tabSys:GetRight(), nil) or nil
            if sysR and sysR > maxBlizzR then
                maxBlizzR = sysR
                blizzRightmost = tabSys
            end
            if tabSys.GetChildren then
                local okC, kids = pcall(function() return { tabSys:GetChildren() } end)
                if okC and type(kids) == "table" then
                    for _, ch in ipairs(kids) do
                        if IsWidgetShownPlain(ch) then
                            local r = ch.GetRight and F.PlainNumber(ch:GetRight(), nil) or nil
                            if r and r > maxBlizzR then
                                maxBlizzR = r
                                blizzRightmost = ch
                            end
                            if not sampleTabW and ch.GetWidth then
                                local cw = F.PlainNumber(ch:GetWidth(), nil)
                                if cw and cw >= 18 and cw <= 120 then
                                    sampleTabW = ReadScaledWidth(ch, cw, boxEffScale)
                                end
                            end
                        end
                    end
                end
            end
        end
        sampleTabW = sampleTabW or 42
        rightmost = blizzRightmost
        local effectiveRight = (maxBlizzR > -1e8) and maxBlizzR or nil

        local dfSpellTab = _G.DungeonsForeverSpellBookTab
        local dfWeaponTab = _G.DungeonsForeverWeaponBookTab
        HookDFTabOnShow(dfSpellTab)
        HookDFTabOnShow(dfWeaponTab)

        if IsDungeonsForeverSpellLoaded() then
            local spellShown = IsWidgetShownPlain(dfSpellTab)
            local weaponShown = IsWidgetShownPlain(dfWeaponTab)
            local spellR = spellShown and dfSpellTab.GetRight and F.PlainNumber(dfSpellTab:GetRight(), nil) or nil
            local weaponR = weaponShown and dfWeaponTab.GetRight and F.PlainNumber(dfWeaponTab:GetRight(), nil) or nil

            if weaponR then
                if (not effectiveRight) or weaponR > effectiveRight then
                    effectiveRight = weaponR
                    rightmost = dfWeaponTab
                end
            elseif spellR then
                if (not effectiveRight) or spellR > effectiveRight then
                    effectiveRight = spellR
                    rightmost = dfSpellTab
                end
                -- 若第 2 枚标签（武器/训练师）尚未 Show，提前预留其宽度（+1px 间距）
                local w2 = ReadScaledWidth(dfWeaponTab, sampleTabW, boxEffScale)
                effectiveRight = effectiveRight + w2 + 1
            elseif effectiveRight then
                -- 打开第 0~200ms 延迟窗：双标签均尚未 Show，按原生 AnchorTabs 规则一次预留两枚完整宽度
                local w1 = ReadScaledWidth(dfSpellTab, sampleTabW, boxEffScale)
                local w2 = ReadScaledWidth(dfWeaponTab, sampleTabW, boxEffScale)
                effectiveRight = effectiveRight + (w1 + 1) + (w2 + 1)
            end
        end

        return rightmost, effectiveRight
    end

    local function FindSpellBookFilterButton(sb, box, origBoxPts)
        for _, field in ipairs({ "FilterDropdown", "SearchOptionsDropdown", "FilterButton", "FilterDropDownButton" }) do
            local cand = sb[field]
            if IsWidgetShownPlain(cand) and cand ~= box then
                return cand
            end
        end
        if type(origBoxPts) == "table" then
            for _, p in ipairs(origBoxPts) do
                local rel = p[2]
                if IsWidgetShownPlain(rel) and rel ~= sb and rel ~= box and rel ~= _G.PlayerSpellsFrame then
                    local par = rel.GetParent and rel:GetParent() or nil
                    if par == sb then
                        return rel
                    end
                end
            end
        end
        local boxR = box.GetRight and F.PlainNumber(box:GetRight(), nil) or nil
        local boxT = box.GetTop and F.PlainNumber(box:GetTop(), nil) or nil
        local boxB = box.GetBottom and F.PlainNumber(box:GetBottom(), nil) or nil
        if not (boxR and boxT and boxB and sb.GetChildren) then return nil end
        local boxCy = (boxT + boxB) * 0.5
        local okC, kids = pcall(function() return { sb:GetChildren() } end)
        if not (okC and type(kids) == "table") then return nil end
        local best, bestDist = nil, 1e9
        for _, ch in ipairs(kids) do
            if ch ~= box and ch ~= sb.CategoryTabSystem and ch ~= sb.CloseButton
                and ch ~= sb.MaximizeMinimizeButton and ch ~= _G.DungeonsForeverSpellBookTab
                and ch ~= _G.DungeonsForeverWeaponBookTab and IsWidgetShownPlain(ch) then
                local l = ch.GetLeft and F.PlainNumber(ch:GetLeft(), nil) or nil
                local t = ch.GetTop and F.PlainNumber(ch:GetTop(), nil) or nil
                local b = ch.GetBottom and F.PlainNumber(ch:GetBottom(), nil) or nil
                local w = ch.GetWidth and F.PlainNumber(ch:GetWidth(), nil) or nil
                local h = ch.GetHeight and F.PlainNumber(ch:GetHeight(), nil) or nil
                if l and t and b and w and h and w >= 12 and w <= 76 and h >= 12 and h <= 38 then
                    local dx = l - boxR
                    local cy = (t + b) * 0.5
                    if dx >= -6 and dx <= 48 and math_abs(cy - boxCy) <= 22 and math_abs(dx) < bestDist then
                        best = ch
                        bestDist = math_abs(dx)
                    end
                end
            end
        end
        return best
    end

    local function IsAnchoredTo(pts, target)
        if not (type(pts) == "table" and target) then return false end
        for _, p in ipairs(pts) do
            if p[2] == target then return true end
        end
        return false
    end

    local function ReadWidgetCenterY(widget)
        if not IsSafeObj(widget) then return nil end
        local top = widget.GetTop and F.PlainNumber(widget:GetTop(), nil) or nil
        local bot = widget.GetBottom and F.PlainNumber(widget:GetBottom(), nil) or nil
        if top and bot then return (top + bot) * 0.5 end
        return nil
    end

    local function AlignWidgetCenterY(widget, targetCy, origPtsMap, appliedDyMap, preCy, parentShift)
        if not (IsSafeObj(widget) and targetCy) then return 0 end
        if origPtsMap[widget] == nil then
            local pts = ReadAllPoints(widget)
            if #pts > 0 then origPtsMap[widget] = pts end
        end
        local origPts = origPtsMap[widget]
        if not (origPts and #origPts > 0) then return 0 end
        local curCy = preCy or ReadWidgetCenterY(widget)
        if not curCy then return 0 end
        local effCy = curCy + (parentShift or 0)
        local diff = targetCy - effCy
        if math_abs(diff) < 0.5 then return 0 end
        local curApplied = appliedDyMap[widget] or 0
        local newDy = curApplied + diff
        if math_abs(newDy) > 36 then return 0 end
        local adj = {}
        for i, p in ipairs(origPts) do
            adj[i] = { p[1], p[2], p[3], p[4], (p[5] or 0) + newDy }
        end
        SetAllPoints(widget, adj)
        appliedDyMap[widget] = newDy
        return diff
    end

    StabilizeSpellBookSearchBox = function(want)
        if spellSearchBusy then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        local psf = _G.PlayerSpellsFrame
        local sb = psf and psf.SpellBookFrame
        local box = sb and sb.SearchBox
        if not IsSafeObj(box) then return end

        spellSearchBusy = true
        if not want then
            local ow = spellSearchOrigW[box]
            if ow and box.SetWidth then pcall(box.SetWidth, box, ow) end
            spellSearchOrigW[box] = nil
            local op = spellSearchOrigPts[box]
            if op then
                SetAllPoints(box, op)
                spellSearchOrigPts[box] = nil
            end
            spellSearchAppliedDy[box] = nil
            local toRestore = {}
            for btn, pts in pairs(spellFilterOrigPts) do
                toRestore[#toRestore + 1] = { btn = btn, pts = pts }
            end
            for _, item in ipairs(toRestore) do
                if IsSafeObj(item.btn) then
                    SetAllPoints(item.btn, item.pts)
                end
                spellFilterOrigPts[item.btn] = nil
                spellFilterAppliedDy[item.btn] = nil
            end
            spellSearchBusy = false
            return
        end

        if not IsWidgetShownPlain(sb) then
            spellSearchBusy = false
            return
        end

        if not spellBoxWidthHooked[box] and type(box.SetWidth) == "function" then
            spellBoxWidthHooked[box] = true
            _G.hooksecurefunc(box, "SetWidth", function()
                if spellSearchBusy then return end
                local on = mod._active and mod:GetDB().harmonyFontGuard ~= false
                if on then
                    StabilizeSpellBookSearchBox(true)
                end
            end)
        end

        if spellSearchOrigW[box] == nil and box.GetWidth then
            spellSearchOrigW[box] = F.PlainNumber(box:GetWidth(), nil)
        end
        if spellSearchOrigPts[box] == nil then
            local pts = ReadAllPoints(box)
            if #pts > 0 then spellSearchOrigPts[box] = pts end
        end

        local rightmost, tabRight = FindRightmostSpellTab(sb, box)
        local boxRight = box.GetRight and F.PlainNumber(box:GetRight(), nil) or nil
        if tabRight and boxRight then
            -- 与 DungeonsForeverSpell NativeSpellBook.lua:1686 公式统一（right - left - 10，上限 300）
            local avail = math_floor(boxRight - tabRight - 10 + 0.5)
            local wantW = math_max(76, math_min(300, avail))
            local curW = F.PlainNumber(box.GetWidth and box:GetWidth(), 0) or 0
            if math_abs(curW - wantW) >= 1 and box.SetWidth then
                pcall(box.SetWidth, box, wantW)
            end
        end

        -- 基于原始锚点将搜索框与右侧筛选下拉按钮 [▼] 同步垂直居中对齐标签行中心
        local refTab = rightmost or (sb.CategoryTabSystem and sb.CategoryTabSystem)
        local tabCy = nil
        if IsSafeObj(refTab) then
            local tTop = refTab.GetTop and F.PlainNumber(refTab:GetTop(), nil) or nil
            local tBot = refTab.GetBottom and F.PlainNumber(refTab:GetBottom(), nil) or nil
            if tTop and tBot then tabCy = (tTop + tBot) * 0.5 end
        end
        if tabCy then
            local filterBtn = FindSpellBookFilterButton(sb, box, spellSearchOrigPts[box])
            local boxCy0 = ReadWidgetCenterY(box)
            local filterCy0 = filterBtn and ReadWidgetCenterY(filterBtn) or nil
            if filterBtn and spellFilterOrigPts[filterBtn] == nil then
                local fPts = ReadAllPoints(filterBtn)
                if #fPts > 0 then spellFilterOrigPts[filterBtn] = fPts end
            end
            if filterBtn and IsAnchoredTo(spellSearchOrigPts[box], filterBtn) then
                -- 搜索框锚定在筛选按钮上：先移动筛选按钮，再用预采中心+父级位移消除同帧双移
                local dFilt = AlignWidgetCenterY(filterBtn, tabCy, spellFilterOrigPts, spellFilterAppliedDy, filterCy0, 0)
                AlignWidgetCenterY(box, tabCy, spellSearchOrigPts, spellSearchAppliedDy, boxCy0, dFilt)
            else
                local dBox = AlignWidgetCenterY(box, tabCy, spellSearchOrigPts, spellSearchAppliedDy, boxCy0, 0)
                if filterBtn then
                    local fOnBox = IsAnchoredTo(spellFilterOrigPts[filterBtn], box)
                    AlignWidgetCenterY(filterBtn, tabCy, spellFilterOrigPts, spellFilterAppliedDy, filterCy0, fOnBox and dBox or 0)
                end
            end
        end
        spellSearchBusy = false
    end

    local function EnsureSpellBookSearchBoxGuard()
        local psf = _G.PlayerSpellsFrame
        local sb = psf and psf.SpellBookFrame
        if not IsSafeObj(sb) or spellBookGuardHooked[sb] then return end
        spellBookGuardHooked[sb] = true
        local function Sync()
            local on = mod._active and mod:GetDB().harmonyFontGuard ~= false
            StabilizeSpellBookSearchBox(on)
        end
        local function SyncDeferred()
            Sync()
            if C_Timer and C_Timer.After then
                C_Timer.After(0, Sync)
            end
        end
        if sb.HookScript then sb:HookScript("OnShow", SyncDeferred) end
        if type(sb.ResizeSearchBox) == "function" then
            _G.hooksecurefunc(sb, "ResizeSearchBox", Sync)
        end
        if type(sb.SetTab) == "function" then
            _G.hooksecurefunc(sb, "SetTab", SyncDeferred)
        end
        if IsSafeObj(psf) and psf.HookScript then
            psf:HookScript("OnSizeChanged", SyncDeferred)
        end
        HookDFTabOnShow(_G.DungeonsForeverSpellBookTab)
        HookDFTabOnShow(_G.DungeonsForeverWeaponBookTab)
    end

    local function PolishNamedHeaders(want)
        -- 角色面板「等级30 猎人」与宠物等级行：补足顶部留白并垂直居中
        for _, name in ipairs({ "CharacterLevelText", "PetCharacterLevelText" }) do
            local fs = _G[name]
            if IsSafeObj(fs) then
                local okF, _, sz = pcall(fs.GetFont, fs)
                sz = okF and F.PlainNumber(sz, 13) or 13
                if want then
                    if origHeight[fs] == nil and fs.GetHeight then
                        origHeight[fs] = F.PlainNumber(fs:GetHeight(), 0)
                    end
                    if origJustV[fs] == nil and fs.GetJustifyV then
                        local okJ, jv = pcall(fs.GetJustifyV, fs)
                        origJustV[fs] = (okJ and type(jv) == "string") and jv or false
                    end
                    if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "MIDDLE") end
                    if fs.SetHeight then pcall(fs.SetHeight, fs, math_max(22, math_floor(sz + 10))) end
                else
                    if origHeight[fs] ~= nil and fs.SetHeight then
                        pcall(fs.SetHeight, fs, origHeight[fs])
                    end
                    if origJustV[fs] and fs.SetJustifyV then pcall(fs.SetJustifyV, fs, origJustV[fs]) end
                    origJustV[fs] = nil
                end
                ShiftAnchorY(fs, -3, want)
            end
        end
        local title = _G.CharacterFrameTitleText
        if IsSafeObj(title) and title.SetJustifyV then
            pcall(title.SetJustifyV, title, "MIDDLE")
        end
    end

    windowPolish.ApplyFontClipGuard = function()
        local want = mod._active and mod:GetDB().harmonyFontGuard ~= false
        PolishNamedHeaders(want)
        PolishSkillsDetailDescription(want)
        EnsureSpellBookSearchBoxGuard()
        StabilizeSpellBookSearchBox(want)
        local sf = _G.SkillsFrame
        if IsSafeObj(sf) and type(sf.ScrollBox) == "table" and not skillsBoxHooked and type(sf.ScrollBox.Update) == "function" then
            skillsBoxHooked = true
            _G.hooksecurefunc(sf.ScrollBox, "Update", function()
                C_Timer.After(0, function()
                    PolishSkillsDetailDescription(mod._active and mod:GetDB().harmonyFontGuard ~= false)
                end)
            end)
        end

        -- GossipFrame ScrollBox 实时防重叠重排钩子（NPC 问候语与下方对话/商店选项绝不重叠）
        local gf = _G.GossipFrame
        local gsb = gf and gf.GreetingPanel and gf.GreetingPanel.ScrollBox
        if IsSafeObj(gsb) and not gossipScrollHooked and type(gsb.Update) == "function" then
            gossipScrollHooked = true
            local QueueGossipReflow = function()
                if not (mod._active and mod:GetDB().harmonyFontGuard ~= false) then return end
                ReflowGossipScrollBox()
                C_Timer.After(0, function()
                    if mod._active and mod:GetDB().harmonyFontGuard ~= false then
                        ReflowGossipScrollBox()
                    end
                end)
            end
            _G.hooksecurefunc(gsb, "Update", QueueGossipReflow)
            if gf.HookScript then
                gf:HookScript("OnShow", QueueGossipReflow)
            end
        end
        if want then
            ReflowGossipScrollBox()
            FixSimilarDialogOverlaps()
        end

        -- 任务对话页/邮件/书信页防多行文字重叠钩子（逐框体 weak 表记录，支持晚加载的邮件/书信窗）
        for _, qName in ipairs({ "QuestFrameGreetingPanel", "QuestFrameDetailPanel", "QuestFrameProgressPanel", "QuestFrameRewardPanel", "OpenMailFrame", "ItemTextFrame" }) do
            local qf = _G[qName]
            if IsSafeObj(qf) and not questDialogHooked[qf] and qf.HookScript then
                questDialogHooked[qf] = true
                qf:HookScript("OnShow", function()
                    if mod._active and mod:GetDB().harmonyFontGuard ~= false then
                        C_Timer.After(0, FixSimilarDialogOverlaps)
                    end
                end)
            end
        end
        if not questGreetingFnHooked and type(_G.QuestFrameGreetingPanel_OnShow) == "function" then
            questGreetingFnHooked = true
            _G.hooksecurefunc("QuestFrameGreetingPanel_OnShow", function()
                if mod._active and mod:GetDB().harmonyFontGuard ~= false then
                    C_Timer.After(0, FixSimilarDialogOverlaps)
                end
            end)
        end
        for _, winName in ipairs(FONT_GUARD_WINDOWS) do
            local w = _G[winName]
            if IsSafeObj(w) then
                if not hookedWin[w] and w.HookScript then
                    hookedWin[w] = true
                    w:HookScript("OnShow", function(self)
                        local on = mod._active and mod:GetDB().harmonyFontGuard ~= false
                        C_Timer.After(0, function()
                            if not IsSafeObj(self) or not self:IsShown() then return end
                            if self == _G.CharacterFrame or self == _G.PaperDollFrame then
                                PolishNamedHeaders(on)
                            elseif self == _G.SkillsFrame then
                                PolishSkillsDetailDescription(on)
                            end
                            GuardWindowTree(self, on, 0)
                        end)
                    end)
                end
                if w.IsShown and w:IsShown() then
                    GuardWindowTree(w, want, 0)
                end
            end
        end
    end
end

----------------------------------------------------------------------
--  8b-3) 角色界面现代化重设计 + 3D 模型控制钮防闪烁 + 13px 清晰属性栏
--        • 修复图 3：鼠标划过左右装备格时模型缩放/旋转按钮反复闪现（仅鼠标落入中间人物区域才显示）
--        • 修复图 1：默认关闭挡住人物模型的装备长绿字堆叠、装等归位图标底角、耐久移出人物头顶
--        • 修复图 1/4：重设计右侧人物属性栏（顶部玻璃装等+耐久卡片、13px 清晰大字、柔和高级配色与悬停高亮）
----------------------------------------------------------------------
do
    local STAT_BOX_NAMES = { "CharacterStatsPaneScrollBox", "CharacterStatsPanePetScrollBox" }
    local EQUIP_SLOT_NAMES = {
        "CharacterHeadSlot", "CharacterNeckSlot", "CharacterShoulderSlot", "CharacterBackSlot",
        "CharacterChestSlot", "CharacterShirtSlot", "CharacterTabardSlot", "CharacterWristSlot",
        "CharacterHandsSlot", "CharacterWaistSlot", "CharacterLegsSlot", "CharacterFeetSlot",
        "CharacterFinger0Slot", "CharacterFinger1Slot", "CharacterTrinket0Slot", "CharacterTrinket1Slot",
        "CharacterMainHandSlot", "CharacterSecondaryHandSlot", "CharacterRangedSlot", "CharacterAmmoSlot",
    }

    local REFINED_CAT_COLORS = {
        general   = { 0.42, 0.82, 0.95 }, -- 冰川青（概况）
        primary   = { 0.36, 0.84, 0.66 }, -- 柔玉绿（主要属性）
        attack    = { 0.95, 0.63, 0.41 }, -- 暖琥珀（武器/攻击）
        secondary = { 0.73, 0.59, 0.98 }, -- 薰衣草紫（副属性）
        defense   = { 0.45, 0.73, 0.98 }, -- 晴空蓝（防御）
    }

    local hookedStatBoxes = setmetatable({}, { __mode = "k" })
    local styledStatFrames = setmetatable({}, { __mode = "k" })
    local euiColorHooked = false
    local modelCtrlDriver = nil
    local modelCtrlHooked = false
    local heroCard = nil
    local sidebarDivider = nil
    local scrollBoxOrigPoints = setmetatable({}, { __mode = "k" })

    local function IsSafe(o)
        if type(o) ~= "table" then return false end
        if o.IsForbidden then
            local ok, forb = pcall(o.IsForbidden, o)
            if not ok or forb then return false end
        end
        return true
    end

    -- 1) 角色 3D 模型控制按钮：仅在鼠标悬停于中间人物身体区域（避开左右装备栏与下方武器栏）时显示
    local function IsCursorOverAnyEquipSlot()
        for i = 1, #EQUIP_SLOT_NAMES do
            local sl = _G[EQUIP_SLOT_NAMES[i]]
            if IsSafe(sl) and sl.IsVisible and sl:IsVisible() and sl.IsMouseOver and sl:IsMouseOver() then
                return true
            end
        end
        return false
    end

    local function IsCursorInModelCenter(scene, ctrl, ctrlShownNow)
        if not (IsSafe(scene) and _G.GetCursorPosition) then return false end
        local scale = F.PlainNumber(scene.GetEffectiveScale and scene:GetEffectiveScale(), 0)
        if scale <= 0 then
            scale = F.PlainNumber(_G.UIParent and _G.UIParent:GetEffectiveScale(), 1)
        end
        if scale <= 0 then scale = 1 end
        local rawX, rawY = _G.GetCursorPosition()
        local cx, cy = F.PlainNumber(rawX, nil), F.PlainNumber(rawY, nil)
        if not (cx and cy) then return false end
        cx, cy = cx / scale, cy / scale

        -- 若按钮当前已显示且光标正停在按钮条上，保持显示以便点击
        if ctrlShownNow and IsSafe(ctrl) and ctrl.IsMouseOver and ctrl:IsMouseOver() then
            return true
        end
        if IsCursorOverAnyEquipSlot() then return false end

        local sL = F.PlainNumber(scene.GetLeft and scene:GetLeft(), nil)
        local sR = F.PlainNumber(scene.GetRight and scene:GetRight(), nil)
        local sB = F.PlainNumber(scene.GetBottom and scene:GetBottom(), nil)
        local sT = F.PlainNumber(scene.GetTop and scene:GetTop(), nil)
        if not (sL and sR and sB and sT) then return false end

        local function slotCoordInSceneSpace(slot, fn)
            if not (IsSafe(slot) and slot[fn]) then return nil end
            local v = F.PlainNumber(slot[fn](slot), nil)
            if not v then return nil end
            local ss = F.PlainNumber(slot.GetEffectiveScale and slot:GetEffectiveScale(), scale)
            if ss > 0 and ss ~= scale then
                v = v * ss / scale
            end
            return v
        end

        local headR  = slotCoordInSceneSpace(_G.CharacterHeadSlot, "GetRight")
        local handsL = slotCoordInSceneSpace(_G.CharacterHandsSlot, "GetLeft")
        local mhT    = slotCoordInSceneSpace(_G.CharacterMainHandSlot, "GetTop")

        local leftBound   = math_max(sL + 48, headR and (headR + 14) or (sL + 48))
        local rightBound  = math_min(sR - 48, handsL and (handsL - 14) or (sR - 48))
        local bottomBound = math_max(sB + 46, mhT and (mhT + 10) or (sB + 46))
        local topBound    = sT - 2
        if rightBound <= leftBound + 20 then
            local mid = (sL + sR) * 0.5
            leftBound, rightBound = mid - 55, mid + 55
        end
        return cx >= leftBound and cx <= rightBound and cy >= bottomBound and cy <= topBound
    end

    local function SetTreeMouse(frame, enabled, depth)
        if not IsSafe(frame) or (depth or 0) > 2 then return end
        if frame.EnableMouse then pcall(frame.EnableMouse, frame, enabled) end
        if frame.GetChildren then
            local okC, kids = pcall(function() return { frame:GetChildren() } end)
            if okC and type(kids) == "table" then
                for _, ch in ipairs(kids) do
                    SetTreeMouse(ch, enabled, (depth or 0) + 1)
                end
            end
        end
    end

    local function SetModelCtrlVisible(ctrl, visible)
        if not IsSafe(ctrl) then return end
        local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()
        if visible then
            if not inCombat and ctrl.Show then pcall(ctrl.Show, ctrl) end
            pcall(ctrl.SetAlpha, ctrl, 1)
            if not inCombat then SetTreeMouse(ctrl, true, 0) end
        else
            pcall(ctrl.SetAlpha, ctrl, 0)
            if not inCombat then
                SetTreeMouse(ctrl, false, 0)
                if ctrl.Hide then pcall(ctrl.Hide, ctrl) end
            end
        end
    end

    local function SetupModelControlGuard()
        local scene = _G.CharacterModelScene
        local doll = _G.PaperDollFrame
        local ctrl = IsSafe(scene) and scene.ControlFrame or nil
        if not (IsSafe(scene) and IsSafe(doll) and IsSafe(ctrl)) then return end
        local want = mod._active and mod:GetDB().centerModelControls ~= false

        if not modelCtrlHooked then
            modelCtrlHooked = true
            if ctrl.HookScript then
                ctrl:HookScript("OnShow", function(self)
                    if not (mod._active and mod:GetDB().centerModelControls ~= false) then return end
                    if not IsCursorInModelCenter(scene, self, false) then
                        SetModelCtrlVisible(self, false)
                    end
                end)
            end
        end

        if not modelCtrlDriver then
            local drv = CreateFrame("Frame", nil, doll)
            drv._acc = 0
            drv._shown = false
            drv._leaveGrace = 0
            drv:SetScript("OnUpdate", function(self, elapsed)
                self._acc = self._acc + (elapsed or 0)
                if self._acc < 0.05 then return end
                local dt = self._acc
                self._acc = 0
                local active = mod._active and mod:GetDB().centerModelControls ~= false
                if not active then
                    if not self._restored then
                        self._restored = true
                        SetModelCtrlVisible(ctrl, true)
                    end
                    return
                end
                self._restored = false
                local inside = IsCursorInModelCenter(scene, ctrl, self._shown)
                if inside then
                    self._leaveGrace = 0.14
                    if not self._shown then
                        self._shown = true
                        SetModelCtrlVisible(ctrl, true)
                    elseif F.PlainNumber(ctrl:GetAlpha(), 1) < 0.9 then
                        SetModelCtrlVisible(ctrl, true)
                    end
                else
                    if self._shown then
                        self._leaveGrace = self._leaveGrace - dt
                        if self._leaveGrace <= 0 then
                            self._shown = false
                            SetModelCtrlVisible(ctrl, false)
                        end
                    elseif F.PlainNumber(ctrl:GetAlpha(), 0) > 0.01 then
                        SetModelCtrlVisible(ctrl, false)
                    end
                end
            end)
            drv:HookScript("OnShow", function(self)
                self._shown = false
                self._leaveGrace = 0
                if mod._active and mod:GetDB().centerModelControls ~= false then
                    SetModelCtrlVisible(ctrl, false)
                end
            end)
            modelCtrlDriver = drv
        end

        if want then
            modelCtrlDriver._shown = false
            modelCtrlDriver:Show()
            SetModelCtrlVisible(ctrl, false)
        else
            modelCtrlDriver._shown = false
            modelCtrlDriver:Hide()
            SetModelCtrlVisible(ctrl, true)
            if not (_G.InCombatLockdown and _G.InCombatLockdown())
                and ctrl.IsShown and ctrl:IsShown() and not (ctrl.IsMouseOver and ctrl:IsMouseOver()) then
                pcall(ctrl.Hide, ctrl)
            end
        end
    end

    -- 2) 简洁装备格设置：默认隐藏遮挡人物的绿字堆叠、装等收入图标底角、隐藏头顶漂浮耐久（移入右侧英雄卡）
    local function SyncCleanSlotPreferences()
        local euiDB = _G.EllesmereUIDB
        if type(euiDB) ~= "table" then return end
        local db = mod:GetDB()
        local want = mod._active and db.cleanCharSheet ~= false
        -- 原值存进 kkowoUI 存档（EUI 的这几项会随 EllesmereUIDB 落盘，只放内存的话重载后就成了改过的值）
        local saved = type(db.euiSheetBackup) == "table" and db.euiSheetBackup or nil
        if want then
            if not saved then
                db.euiSheetBackup = {
                    showStats = euiDB.charSheetShowItemStats,
                    ilvlPos   = euiDB.charSheetItemLevelPos,
                    outline   = euiDB.charSheetItemLevelOutline,
                    showDur   = euiDB.showCharSheetDurability,
                }
            end
            euiDB.charSheetShowItemStats = false
            euiDB.charSheetItemLevelPos = "iconbottom"
            euiDB.charSheetItemLevelOutline = true
            euiDB.showCharSheetDurability = false
        elseif saved then
            euiDB.charSheetShowItemStats = saved.showStats
            euiDB.charSheetItemLevelPos = saved.ilvlPos
            euiDB.charSheetItemLevelOutline = saved.outline
            euiDB.showCharSheetDurability = saved.showDur
            db.euiSheetBackup = nil
        end
        local EUI = _G.EllesmereUI
        if EUI then
            if type(EUI._refreshCharSheetSlotLabels) == "function" then
                pcall(EUI._refreshCharSheetSlotLabels)
            end
            if type(EUI._updateCharSheetDurability) == "function" then
                pcall(EUI._updateCharSheetDurability)
            end
        end
    end

    -- 3) 顶部现代玻璃装等 + 耐久英雄卡片（取代右侧单调的紫色浮字与压在人物头顶的绿字耐久）
    local function ComputeLowestDurability()
        local lowest = 100
        if not _G.GetInventoryItemDurability then return 100 end
        for slotId = 1, 18 do
            local ok, cur, mx = pcall(_G.GetInventoryItemDurability, slotId)
            cur = ok and F.PlainNumber(cur, nil) or nil
            mx = ok and F.PlainNumber(mx, nil) or nil
            if cur and mx and mx > 0 then
                local pct = cur / mx * 100
                if pct < lowest then lowest = pct end
            end
        end
        return math_floor(lowest)
    end

    local function HideEUIFloatingAverage(box, hide)
        if not (IsSafe(box) and box.GetChildren) then return end
        local inCombat = _G.InCombatLockdown and _G.InCombatLockdown()
        for _, ch in ipairs({ box:GetChildren() }) do
            if IsSafe(ch) and ch ~= heroCard and ch ~= box.ScrollBox and ch ~= box.ScrollBar then
                local h = F.PlainNumber(ch.GetHeight and ch:GetHeight(), 0)
                if h >= 20 and h <= 28 and not (ch.GetName and ch:GetName()) then
                    if ch.SetAlpha then pcall(ch.SetAlpha, ch, hide and 0 or 1) end
                    if not inCombat then
                        SetTreeMouse(ch, not hide, 0)
                    end
                end
            end
        end
    end

    local function UpdateHeroCardData()
        if not (heroCard and heroCard:IsShown()) then return end
        local eq = 0
        if _G.GetAverageItemLevel then
            local ok, ov, equipped = pcall(_G.GetAverageItemLevel)
            if ok then
                eq = F.PlainNumber(equipped, 0)
                if eq <= 0 then eq = F.PlainNumber(ov, 0) end
            end
        end
        if eq > 0 then
            heroCard._ilvlVal:SetText(string_format("%.2f", eq))
        else
            heroCard._ilvlVal:SetText("--")
        end
        local dur = ComputeLowestDurability()
        heroCard._durVal:SetText(dur .. "%")
        if dur >= 80 then
            heroCard._durVal:SetTextColor(0.38, 0.92, 0.78, 1)
        elseif dur >= 40 then
            heroCard._durVal:SetTextColor(0.99, 0.80, 0.34, 1)
        else
            heroCard._durVal:SetTextColor(0.98, 0.44, 0.52, 1)
        end
    end

    local function EnsureHeroCardAndSidebar()
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        local cf = _G.CharacterFrame
        local box = _G.CharacterStatsPaneScrollBox
        local want = mod._active and mod:GetDB().cleanCharSheet ~= false

        -- 左侧人物展示区与右侧属性栏之间增加一条精致玻璃竖线
        local rph = IsSafe(cf) and cf.RightPaneHost or nil
        if IsSafe(rph) then
            if not sidebarDivider then
                local ln = rph:CreateTexture(nil, "OVERLAY", nil, 2)
                if F.StyleTokens then F.StyleTokens.Hairline(ln, true) else ln:SetWidth(1) end
                ln:SetPoint("TOPLEFT", rph, "TOPLEFT", 0, -28)
                ln:SetPoint("BOTTOMLEFT", rph, "BOTTOMLEFT", 0, 10)
                ln:SetColorTexture(1, 1, 1, 0.08)
                sidebarDivider = ln
            end
            sidebarDivider:SetShown(want)
        end

        if not (IsSafe(box) and IsSafe(box.ScrollBox)) then return end
        HideEUIFloatingAverage(box, want)

        local sb = box.ScrollBox
        if not want then
            if heroCard then heroCard:Hide() end
            -- 只还原我们挪过的列表，并且还原成 EUI 当初的锚点（没挪过就不碰）
            local orig = scrollBoxOrigPoints[sb]
            if orig then
                pcall(sb.ClearAllPoints, sb)
                for _, p in ipairs(orig) do
                    pcall(sb.SetPoint, sb, p[1], p[2], p[3], p[4], p[5])
                end
                scrollBoxOrigPoints[sb] = nil
            end
            return
        end
        if not scrollBoxOrigPoints[sb] and sb.GetNumPoints then
            local pts = {}
            for i = 1, F.PlainNumber(sb:GetNumPoints(), 0) do
                local okP, pt, rel, rpt, x, y = pcall(sb.GetPoint, sb, i)
                if okP and type(pt) == "string" then
                    pts[#pts + 1] = { pt, rel, rpt, F.PlainNumber(x, 0), F.PlainNumber(y, 0) }
                end
            end
            if #pts > 0 then scrollBoxOrigPoints[sb] = pts end
        end

        if not heroCard then
            local card = CreateFrame("Frame", "kkowoUI_CharHeroCard", box)
            card:SetHeight(52)
            card:SetPoint("TOPLEFT", box, "TOPLEFT", 8, -4)
            card:SetPoint("TOPRIGHT", box, "TOPRIGHT", -24, -4)
            card:SetFrameLevel((box:GetFrameLevel() or 5) + 4)

            F.Theme.PaintPrettyCardOverlay(card, 0.44, 0.90, 0.92, 22, {
                rounded = true,
                radius = 6,
                alpha = 0.78,
                haloAlpha = 0.14,
                haloSpread = 10,
                headerTopAlpha = 0.22,
                headerBottomAlpha = 0.00,
            })

            local midLine = card:CreateTexture(nil, "OVERLAY", nil, 2)
            if F.StyleTokens then F.StyleTokens.Hairline(midLine, true) else midLine:SetWidth(1) end
            midLine:SetPoint("TOP", card, "TOP", 0, -9)
            midLine:SetPoint("BOTTOM", card, "BOTTOM", 0, 9)
            midLine:SetColorTexture(1, 1, 1, 0.10)

            local ilvlCap = card:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(ilvlCap, 10, "", 0.68, 0.75, 0.84, 0.92)
            ilvlCap:SetJustifyH("CENTER")
            ilvlCap:SetJustifyV("MIDDLE")
            ilvlCap:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -7)
            ilvlCap:SetPoint("TOPRIGHT", card, "TOP", -2, -7)
            ilvlCap:SetText("平均装等")

            local ilvlVal = card:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(ilvlVal, 16, "", 0.76, 0.99, 0.97, 1)
            ilvlVal:SetJustifyH("CENTER")
            ilvlVal:SetJustifyV("MIDDLE")
            ilvlVal:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 6, 7)
            ilvlVal:SetPoint("BOTTOMRIGHT", card, "BOTTOM", -2, 7)
            card._ilvlVal = ilvlVal

            local durCap = card:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(durCap, 10, "", 0.68, 0.75, 0.84, 0.92)
            durCap:SetJustifyH("CENTER")
            durCap:SetJustifyV("MIDDLE")
            durCap:SetPoint("TOPLEFT", card, "TOP", 2, -7)
            durCap:SetPoint("TOPRIGHT", card, "TOPRIGHT", -6, -7)
            durCap:SetText("装备耐久")

            local durVal = card:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(durVal, 16, "", 0.38, 0.92, 0.78, 1)
            durVal:SetJustifyH("CENTER")
            durVal:SetJustifyV("MIDDLE")
            durVal:SetPoint("BOTTOMLEFT", card, "BOTTOM", 2, 7)
            durVal:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -6, 7)
            card._durVal = durVal

            card:SetScript("OnEvent", UpdateHeroCardData)
            local function RegisterCardEvents(self)
                self:RegisterEvent("PLAYER_AVG_ITEM_LEVEL_UPDATE")
                self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
                self:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
                self:RegisterEvent("UPDATE_INVENTORY_ALERTS")
            end
            card:SetScript("OnShow", function(self)
                RegisterCardEvents(self)
                UpdateHeroCardData()
            end)
            card:SetScript("OnHide", function(self)
                self:UnregisterAllEvents()
            end)
            -- 新建框体默认就是显示状态，首次不会触发 OnShow：这里先注册一次，首次打开人物面板也能实时刷新
            RegisterCardEvents(card)
            heroCard = card
        end

        heroCard:Show()
        UpdateHeroCardData()
        -- 为顶部英雄卡片留出整洁间距，避免与「概况」标题重叠
        pcall(box.ScrollBox.ClearAllPoints, box.ScrollBox)
        pcall(box.ScrollBox.SetPoint, box.ScrollBox, "TOPLEFT", box, "TOPLEFT", 8, -62)
        pcall(box.ScrollBox.SetPoint, box.ScrollBox, "BOTTOMRIGHT", box, "BOTTOMRIGHT", -24, 6)
    end

    -- 4) 右侧属性列表全面放大与精修（修复原 PolishCharacterStatsFontSize 找错 ScrollFrame 导致 10px 极小字的 Bug）
    local function ClassifyStatCategory(name)
        if type(name) ~= "string" then return "general" end
        if name:find("主要", 1, true) or name:find("属性", 1, true) or name:find("Attr", 1, true) then return "primary" end
        if name:find("武器", 1, true) or name:find("攻击", 1, true) or name:find("战斗", 1, true)
            or name:find("Weapon", 1, true) or name:find("Attack", 1, true) or name:find("Combat", 1, true) then
            return "attack"
        end
        if name:find("防御", 1, true) or name:find("抗性", 1, true) or name:find("Defense", 1, true) then return "defense" end
        if name:find("强化", 1, true) or name:find("修正", 1, true) or name:find("法术", 1, true)
            or name:find("Mod", 1, true) or name:find("Spell", 1, true) then
            return "secondary"
        end
        return "general"
    end

    local function CategoryKeyOfElement(box, elementData)
        local list = box and box.elementData
        if type(list) ~= "table" then return "general" end
        local curName = nil
        for i = 1, #list do
            local d = list[i]
            if d and d.isHeader then curName = d.name end
            if d == elementData then return ClassifyStatCategory(curName) end
        end
        return ClassifyStatCategory(curName)
    end

    local function StyleForeverStatFrame(box, frame, elementData)
        if not IsSafe(frame) then return end
        local db = mod:GetDB()
        local active = mod._active == true
        local statSz = math_max(11, math_min(16, F.PlainNumber(db.charStatFontSize, 13)))
        local redesign = active and db.cleanCharSheet ~= false
        local fontPath = F.Theme.GetFont()
        local isHeader = (type(elementData) == "table" and elementData.isHeader == true)
            or (frame.Title ~= nil and frame.Label == nil)

        if isHeader then
            if frame.Title and frame.Title.SetFont then
                local sz = active and statSz or 11
                pcall(frame.Title.SetFont, frame.Title, fontPath, sz, "")
                if frame.Title.SetShadowColor then pcall(frame.Title.SetShadowColor, frame.Title, 0, 0, 0, 0.90) end
                if frame.Title.SetShadowOffset then pcall(frame.Title.SetShadowOffset, frame.Title, 1, -1) end
                if frame.Title.SetJustifyV then pcall(frame.Title.SetJustifyV, frame.Title, "MIDDLE") end
                if frame.Title.SetHeight then pcall(frame.Title.SetHeight, frame.Title, math_max(18, sz + 6)) end
                if redesign then
                    local key = ClassifyStatCategory(type(elementData) == "table" and elementData.name or (frame.Title.GetText and F.PlainString(frame.Title:GetText(), nil)))
                    local c = REFINED_CAT_COLORS[key] or REFINED_CAT_COLORS.general
                    pcall(frame.Title.SetTextColor, frame.Title, c[1], c[2], c[3], 1)
                    -- 柔和化 EUI 过亮的两侧色线（0.80 -> 0.42）
                    if frame.GetRegions then
                        for _, reg in ipairs({ frame:GetRegions() }) do
                            if IsSafe(reg) and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg ~= frame.Background then
                                local rh = F.PlainNumber(reg.GetHeight and reg:GetHeight(), 0)
                                if rh > 0 and rh <= 2.5 then
                                    pcall(reg.SetColorTexture, reg, c[1], c[2], c[3], 0.42)
                                end
                            end
                        end
                    end
                end
            end
            return
        end

        -- 属性行：放大至 13px（可调 11~16），高对比柔和银白标签 + 柔和亮色数值 + 轻悬停底色
        local rowSz = active and statSz or 10
        local catKey = CategoryKeyOfElement(box, elementData)
        local c = REFINED_CAT_COLORS[catKey] or REFINED_CAT_COLORS.general

        if frame.Label and frame.Label.SetFont then
            pcall(frame.Label.SetFont, frame.Label, fontPath, rowSz, "")
            if frame.Label.SetShadowColor then pcall(frame.Label.SetShadowColor, frame.Label, 0, 0, 0, 0.90) end
            if frame.Label.SetShadowOffset then pcall(frame.Label.SetShadowOffset, frame.Label, 1, -1) end
            if frame.Label.SetJustifyV then pcall(frame.Label.SetJustifyV, frame.Label, "MIDDLE") end
            if frame.Label.SetHeight then pcall(frame.Label.SetHeight, frame.Label, 0) end
            if redesign then
                pcall(frame.Label.SetTextColor, frame.Label, 0.84, 0.88, 0.94, 0.96)
            end
        end
        if frame.Value and frame.Value.SetFont then
            pcall(frame.Value.SetFont, frame.Value, fontPath, rowSz, "")
            if frame.Value.SetShadowColor then pcall(frame.Value.SetShadowColor, frame.Value, 0, 0, 0, 0.90) end
            if frame.Value.SetShadowOffset then pcall(frame.Value.SetShadowOffset, frame.Value, 1, -1) end
            if frame.Value.SetJustifyV then pcall(frame.Value.SetJustifyV, frame.Value, "MIDDLE") end
            if frame.Value.SetHeight then pcall(frame.Value.SetHeight, frame.Value, 0) end
            if redesign then
                -- 与白柔和混合（0.45 分类色 + 0.55 纯白），既保留分区辨识度又高级不刺眼
                pcall(frame.Value.SetTextColor, frame.Value,
                    c[1] * 0.45 + 0.55, c[2] * 0.45 + 0.55, c[3] * 0.45 + 0.55, 1)
            end
        end

        local hl = styledStatFrames[frame]
        if not hl and frame.CreateTexture then
            hl = frame:CreateTexture(nil, "HIGHLIGHT")
            hl:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, 0)
            hl:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 0)
            hl:SetColorTexture(1, 1, 1, 0.055)
            styledStatFrames[frame] = hl
        end
        if hl then
            hl:SetAlpha(redesign and 1 or 0)
        end
    end

    local function RefreshStatBoxesNow()
        for _, boxName in ipairs(STAT_BOX_NAMES) do
            local box = _G[boxName]
            local sb = IsSafe(box) and box.ScrollBox or nil
            if IsSafe(sb) then
                if not hookedStatBoxes[sb] then
                    hookedStatBoxes[sb] = true
                    local SU = _G.ScrollUtil
                    if SU and SU.AddInitializedFrameCallback then
                        pcall(SU.AddInitializedFrameCallback, sb, function(_, fr, ed)
                            StyleForeverStatFrame(box, fr, ed)
                        end, nil, false)
                    end
                    if sb.Update then
                        _G.hooksecurefunc(sb, "Update", function(self)
                            if self.ForEachFrame then
                                pcall(self.ForEachFrame, self, function(fr, ed) StyleForeverStatFrame(box, fr, ed) end)
                            end
                        end)
                    end
                end
                if sb.ForEachFrame then
                    pcall(sb.ForEachFrame, sb, function(fr, ed) StyleForeverStatFrame(box, fr, ed) end)
                end
            end
        end
    end

    local cfRedesignHooked = false
    local ammoOrigFont = setmetatable({}, { __mode = "k" })
    local ammoOrigAnchor = setmetatable({}, { __mode = "k" })
    local ammoCountHooked = setmetatable({}, { __mode = "k" })
    local ammoArrowFaded = setmetatable({}, { __mode = "k" })
    local ammoConnector = nil

    -- 5) 弹药格（CharacterAmmoSlot）与远程堆叠数防遮挡精修：
    --    暴雪原版木头箭头子框体横向盖在 27px 弹药格左侧，直接吃掉「394」首位数字且箭头也压到枪械图标上；
    --    这里淡出重叠木箭头并改为槽隙间极简细连线，同时按位数自适应 11/10/9px 描边数字右对齐，确保 3~4 位数完整显示。
    local function StyleStackCountFont(slot, fs, want)
        if not (IsSafe(slot) and IsSafe(fs) and fs.SetFont) then return end
        if not ammoOrigFont[fs] and fs.GetFont then
            local okF, face, sz, flags = pcall(fs.GetFont, fs)
            if okF and face and sz then
                ammoOrigFont[fs] = { face, F.PlainNumber(sz, 12), F.PlainString(flags, "") }
            end
        end
        if not ammoOrigAnchor[fs] and fs.GetPoint then
            local okP, pt, rel, rpt, x, y = pcall(fs.GetPoint, fs, 1)
            if okP and type(pt) == "string" then
                ammoOrigAnchor[fs] = { pt, rel, rpt, F.PlainNumber(x, 0), F.PlainNumber(y, 0) }
            end
        end
        if not want then
            local of = ammoOrigFont[fs]
            if of then pcall(fs.SetFont, fs, of[1], of[2], of[3]) end
            local oa = ammoOrigAnchor[fs]
            if oa and fs.ClearAllPoints and fs.SetPoint then
                pcall(fs.ClearAllPoints, fs)
                pcall(fs.SetPoint, fs, oa[1], oa[2], oa[3], oa[4], oa[5])
            end
            return
        end
        local txt = fs.GetText and F.PlainString(fs:GetText(), "") or ""
        local n = #txt
        local sz = (n >= 4) and 9 or ((n == 3) and 10 or 11)
        pcall(fs.SetFont, fs, F.Theme.GetFont(), sz, "OUTLINE")
        if fs.SetShadowColor then pcall(fs.SetShadowColor, fs, 0, 0, 0, 0.95) end
        if fs.SetShadowOffset then pcall(fs.SetShadowOffset, fs, 1, -1) end
        if fs.SetJustifyH then pcall(fs.SetJustifyH, fs, "RIGHT") end
        if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "BOTTOM") end
        if fs.SetWordWrap then pcall(fs.SetWordWrap, fs, false) end
        if fs.SetWidth then pcall(fs.SetWidth, fs, 0) end
        if fs.SetHeight then pcall(fs.SetHeight, fs, 0) end
        if fs.ClearAllPoints and fs.SetPoint then
            pcall(fs.ClearAllPoints, fs)
            pcall(fs.SetPoint, fs, "BOTTOMRIGHT", slot, "BOTTOMRIGHT", -2, 2)
        end
    end

    local function PolishAmmoAndStackSlots()
        local db = mod:GetDB()
        local want = mod._active and (db.cleanCharSheet ~= false or db.harmonyFontGuard ~= false)
        for _, slotName in ipairs({ "CharacterAmmoSlot", "CharacterRangedSlot" }) do
            local slot = _G[slotName]
            if IsSafe(slot) then
                local fs = slot.Count or _G[slotName .. "Count"] or slot.Stock or _G[slotName .. "Stock"]
                if not IsSafe(fs) and slot.GetRegions then
                    for _, reg in ipairs({ slot:GetRegions() }) do
                        if IsSafe(reg) and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                            fs = reg
                            break
                        end
                    end
                end
                if IsSafe(fs) then
                    StyleStackCountFont(slot, fs, want)
                    if not ammoCountHooked[fs] and type(fs.SetText) == "function" then
                        ammoCountHooked[fs] = true
                        _G.hooksecurefunc(fs, "SetText", function(self)
                            local d = mod:GetDB()
                            local on = mod._active and (d.cleanCharSheet ~= false or d.harmonyFontGuard ~= false)
                            if on then StyleStackCountFont(slot, self, true) end
                        end)
                    end
                end
            end
        end

        local ammo = _G.CharacterAmmoSlot
        if not IsSafe(ammo) then return end
        local EUI = _G.EllesmereUI
        local euiBrd = EUI and EUI.PanelPP and EUI.PanelPP.GetBorders and EUI.PanelPP.GetBorders(ammo) or nil
        if ammo.GetChildren then
            for _, ch in ipairs({ ammo:GetChildren() }) do
                if IsSafe(ch) and ch ~= euiBrd and ch ~= ammoConnector and ch ~= ammo.BorderFrame then
                    if ammoArrowFaded[ch] then
                        if ch.SetAlpha then pcall(ch.SetAlpha, ch, want and 0 or 1) end
                    elseif ch.GetRegions then
                        local regs = { ch:GetRegions() }
                        local texCnt, artCnt = 0, 0
                        for _, r in ipairs(regs) do
                            if IsSafe(r) and r.GetObjectType and r:GetObjectType() == "Texture" then
                                texCnt = texCnt + 1
                                local tex = r.GetTexture and r:GetTexture()
                                local atl = r.GetAtlas and r:GetAtlas()
                                if (tex ~= nil and tex ~= "") or (atl ~= nil and atl ~= "") then
                                    artCnt = artCnt + 1
                                end
                            end
                        end
                        -- 跳过 4 条边框子框体，精准命中暴雪木头箭头子框体（1~2 张贴图）
                        if texCnt > 0 and texCnt <= 2 and artCnt > 0 then
                            ammoArrowFaded[ch] = true
                            if ch.SetAlpha then pcall(ch.SetAlpha, ch, want and 0 or 1) end
                        end
                    end
                end
            end
        end

        -- 槽隙间绘制 1 条极简水平细连线（严格落在远程槽与弹药槽的空隙内，绝不触碰图标与数字）
        local ranged = _G.CharacterRangedSlot
        if want and IsSafe(ranged) and ranged:IsShown() and ammo:IsShown() then
            if not ammoConnector then
                local conn = CreateFrame("Frame", nil, ammo)
                conn:SetHeight(5)
                conn:SetPoint("LEFT", ranged, "RIGHT", 3, 0)
                conn:SetPoint("RIGHT", ammo, "LEFT", -3, 0)
                local ln = conn:CreateTexture(nil, "OVERLAY")
                ln:SetHeight(1)
                ln:SetPoint("LEFT", conn, "LEFT", 0, 0)
                ln:SetPoint("RIGHT", conn, "RIGHT", 0, 0)
                ln:SetColorTexture(0.78, 0.84, 0.92, 0.32)
                ammoConnector = conn
            end
            ammoConnector:Show()
        elseif ammoConnector then
            ammoConnector:Hide()
        end
    end

    local restoringEUIColors = false

    windowPolish.ApplyCharacterSheetRedesign = function()
        SyncCleanSlotPreferences()
        SetupModelControlGuard()
        EnsureHeroCardAndSidebar()
        local EUI = _G.EllesmereUI
        local redesign = mod._active and mod:GetDB().cleanCharSheet ~= false
        if not redesign and not restoringEUIColors and type(EUI) == "table" and type(EUI._refreshCharacterSheetColors) == "function" then
            restoringEUIColors = true
            pcall(EUI._refreshCharacterSheetColors)
            restoringEUIColors = false
        end
        RefreshStatBoxesNow()
        PolishAmmoAndStackSlots()
        local cf = _G.CharacterFrame
        if IsSafe(cf) and not cfRedesignHooked and cf.HookScript then
            cfRedesignHooked = true
            cf:HookScript("OnShow", function()
                C_Timer.After(0, function()
                    SetupModelControlGuard()
                    EnsureHeroCardAndSidebar()
                    RefreshStatBoxesNow()
                    PolishAmmoAndStackSlots()
                end)
                C_Timer.After(0.15, function()
                    EnsureHeroCardAndSidebar()
                    RefreshStatBoxesNow()
                    PolishAmmoAndStackSlots()
                end)
            end)
        end
        if not euiColorHooked and type(EUI) == "table" and type(EUI._refreshCharacterSheetColors) == "function" then
            euiColorHooked = true
            _G.hooksecurefunc(EUI, "_refreshCharacterSheetColors", function()
                if restoringEUIColors then return end
                C_Timer.After(0, RefreshStatBoxesNow)
            end)
        end
    end
end

----------------------------------------------------------------------
--  8c) 施法条英文技能名汉化
--      无限服中文客户端有少数技能名没汉化（如开箱子、点任务物件时的「Opening」）。
--      EUI 的施法条都先经 EllesmereUI.CleanCastName 清理名字，在它后面接一层整串对照；
--      保密值（12.x 战斗中他人的施法名）原样放行，不做任何读取。
----------------------------------------------------------------------
local HookEUICastNames, RestoreEUICastNames
do
local CAST_NAME_ZH = {
    ["Opening"] = "开启",
    ["Herb Gathering"] = "采集草药",
    ["Mining"] = "采矿",
    ["Skinning"] = "剥皮",
    ["Fishing"] = "钓鱼",
    ["Disenchant"] = "分解",
    ["Pick Lock"] = "开锁",
    ["Disarm Trap"] = "解除陷阱",
    ["Hearthstone"] = "炉石",
    ["Summoning"] = "召唤",
}
local origCleanCastName = nil
local wrappedCleanCastName = nil

HookEUICastNames = function()
    local EUI = _G.EllesmereUI
    if not (mod._active and EUI and type(EUI.CleanCastName) == "function") then return end
    if origCleanCastName and EUI.CleanCastName == wrappedCleanCastName then return end
    if origCleanCastName then
        -- 外层若已有第三方包装指向 wrappedCleanCastName，只需保持激活态即可自动恢复翻译，不再重复包裹
        return
    end
    origCleanCastName = EUI.CleanCastName
    wrappedCleanCastName = function(name)
        local orig = origCleanCastName
        if type(orig) ~= "function" then return name end
        local clean = orig(name)
        if F.IsSecret(clean) or type(clean) ~= "string" or not mod._active then
            return clean
        end
        return CAST_NAME_ZH[clean] or clean
    end
    EUI.CleanCastName = wrappedCleanCastName
end

RestoreEUICastNames = function()
    local EUI = _G.EllesmereUI
    if not origCleanCastName then return end
    if EUI and EUI.CleanCastName == wrappedCleanCastName then
        EUI.CleanCastName = origCleanCastName
        origCleanCastName = nil
        wrappedCleanCastName = nil
    end
    -- 若其他插件在 wrappedCleanCastName 之上又包裹了一层，保留 origCleanCastName 供 mod._active==false 时透明直通
end
end

local function RefreshAllModernHUD()
    pcall(SkinVehicleLeaveButton)
    pcall(SkinGhostFrame)
    pcall(StripZoneAbilityStyle)
    pcall(ApplyBlizzDurabilityVisibility)
    pcall(ApplyEUIBuiltinHUDSkinsOnce)
    pcall(ApplyFlightTimerDedup)
    pcall(ApplyQuestieTownsfolkDedup, false)
    pcall(RefreshHDPetHappiness)
    pcall(HookTrainerFrameIfReady)
    pcall(windowPolish.HookAuctionHouse)
    pcall(windowPolish.HookMail)
    pcall(windowPolish.HookMerchant)
    pcall(windowPolish.ApplyWorldMapCoordsDedup)
    pcall(windowPolish.ApplyCombatSoundMute)
    pcall(windowPolish.ApplyFontClipGuard)
    pcall(windowPolish.ApplyCharacterSheetRedesign)
    pcall(HookEUICastNames)
    pcall(HookCombatTextSizing)
    pcall(RefreshWorldRefreshBanner)
end

-- 登录/重载时 OnEnable（PLAYER_LOGIN）与紧随其后的 PLAYER_ENTERING_WORLD 曾各排一套 0.5/1.5/3 秒补刷，
-- 3 秒内整套 HUD 重绘 8 次。现用代次号合并：后排的一套作废前一套，且每次回调都检查模块是否仍启用。
local bootRefreshGen = 0
local QueueCharacterBarsRefresh = F.Debounce(0.3, function()
    if mod._active then RefreshAllCharacterBars() end
end)

local function ScheduleBootRefresh(fromPEW)
    bootRefreshGen = bootRefreshGen + 1
    local gen = bootRefreshGen
    local function step(extra)
        if gen ~= bootRefreshGen or not mod._active then return end
        pcall(ApplyUnifiedResourceBars, false)
        pcall(swingGuard.Install)
        pcall(swingGuard.Heal, nil)
        pcall(cdmPosGuard.Install)
        pcall(cdmPosGuard.VerifyAll)
        RefreshAllModernHUD()
        if extra then extra() end
    end
    C_Timer.After(0.5, function() step() end)
    C_Timer.After(1.5, function()
        step(fromPEW and function() pcall(SkinSkillsScrollBar) end or nil)
    end)
    C_Timer.After(3.0, function()
        step(fromPEW and function() pcall(SkinBugSackIfReady) end or nil)
    end)
end


MC.windowPolish = windowPolish
MC.RestoreEUICastNames = RestoreEUICastNames
MC.QueueCharacterBarsRefresh = QueueCharacterBarsRefresh
MC.RefreshAllModernHUD = RefreshAllModernHUD
MC.ScheduleBootRefresh = ScheduleBootRefresh
MC.CancelBootRefresh = function()
    bootRefreshGen = bootRefreshGen + 1
end
