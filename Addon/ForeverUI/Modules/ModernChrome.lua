----------------------------------------------------------------------
--  ForeverUI — Modules/ModernChrome.lua
--  现代 MMO 视觉统一核心模块：
--  1) 职业主题色（默认）/ 跟随 EUI 主色切换 + 全局战斗淡出透明度
--  2) 角色面板「声望 / 技能」ScrollBox 列表行 + 详情条 / 宠物经验条统一为 MerfinMain 现代扁平条
--     • 登录即挂钩，切页 0ms 瞬时生效、零卡顿零闪烁
--     • 声望行 & 声望详情条：完全同步派系原生配色（中立黄/友善绿/尊敬青等）
--     • 技能行（child.Content.SkillsBar）& 技能详情条：职业主题色（练满暖金）
--     • 同步美化 SkillsFrame.ScrollBar，与声望页签滚动条完全统一
--  3) 增益/减益计时文字防重叠（12.x 保密值安全）
--  4) 好友列表适度加高 + BugSack 轻量皮肤 + 冷却管理器冲突一键「停用并重载」弹窗
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, math_abs, math_floor, math_max, math_min, pcall, tonumber, tostring, type =
    ipairs, pairs, math.abs, math.floor, math.max, math.min, pcall, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local setmetatable = setmetatable

local mod = F.RegisterModule("modernChrome", {
    title = "现代视觉统一与修复",
    desc = "统一职业主题色、角色面板声望/技能/PvP 精致美化、高清宠物快乐度图标、施法条风格统一、伤害统计队伍总伤显示。",
    group = "theme",
    order = 10,
    defaults = {
        enabled = true,
        flatCharBars = true,
        charFramePolish = true,
        charStatFontSize = 12,          -- 角色面板右侧属性栏字号（EUI 默认硬编码 10px 偏小，默认提至 12px，支持 10-14 调节）
        hdPetHappy = true,
        partyDamageLabel = true,
        damageFont = "youshe",          -- "youshe" | "smiley" | "default"（仅修改战斗伤害/治疗浮动字体）
        smartCombatText = true,         -- 战斗飘字智能分级（受伤大字 / 2D 经验小字 + 3D 缩放）
        worldTextScale = 1.00,          -- 3D 头顶打怪伤害/世界飘字缩放（同步 WorldTextScale_v2，默认 1.00 不缩字）
        damageArcMode = "keep",         -- "keep" = 保持当前 | "classic" = 经典直出(0) | "compact" = 紧凑散射(1.0)
        v3WorldTextScaleMigrated = false,
        incomingDamageSize = 34,        -- 自身受伤飘字字号（20-48px）
        combatXPSize = 15,              -- 2D 经验/声望/荣誉飘字字号（12-24px）
        savedWorldTextScale = nil,
        skinWorldRefresh = true,        -- 美化并下移无限服「世界刷新」提示框，避免遮挡经验条
        trainerHideUsed = true,         -- 打开训练师/野兽训练自动隐藏「已学会」技能
        trainerHideUnavailable = true,  -- 打开训练师/野兽训练自动隐藏「暂不可学」技能（只看最新可学）
        unifyResourceBars = true,
        erbUnifiedApplied = false,
        erbUnifiedVersion = 0,
        modernBlizzHUD = true,
        hideBlizzDurability = true,
        flightTimerMode = "keep_eui", -- "keep_eui" | "keep_polestar" | "both"
        dedupMinimapNPC = true,       -- 与 Polestar 共存时自动关闭 Questie 城镇 NPC 标记，统一由 Polestar 显示小地图 NPC（保留 Questie 任务感叹号/问号）
        hudSkinSeeded = false,
        fitBuffTimers = true,
        expandFriends = true,
        skinBugSack = true,
        conflictCheck = true,
        cdmConflictKeep = {},
    },
})

----------------------------------------------------------------------
--  1) 角色面板现代扁平进度条（零延迟同步渲染 + 全弱表防污染）
----------------------------------------------------------------------
local barOverlay    = setmetatable({}, { __mode = "k" })
local hookedHost    = setmetatable({}, { __mode = "k" })
local hookedSkillFS = setmetatable({}, { __mode = "k" })
local hiddenOnce    = setmetatable({}, { __mode = "k" })
local hookedBoxes   = setmetatable({}, { __mode = "k" })
local scannedPanels = setmetatable({}, { __mode = "k" })
local origNamePoint = setmetatable({}, { __mode = "k" })
local cbOverlay     = setmetatable({}, { __mode = "k" })
local cbHooked      = setmetatable({}, { __mode = "k" })
local pvpOverlay    = setmetatable({}, { __mode = "k" })
local hookedPanels  = setmetatable({}, { __mode = "k" })
local looseBarList  = {}
local charHooked    = false

local GOLD_MAX_COLOR = { 0.86, 0.72, 0.36 }
local PET_XP_COLOR   = { 0.58, 0.44, 0.90 }

local function FormatNum(n)
    if _G.BreakUpLargeNumbers then
        local ok, s = pcall(_G.BreakUpLargeNumbers, n)
        if ok and type(s) == "string" then return s end
    end
    return tostring(n)
end

local function HideNativeArt(host)
    if hiddenOnce[host] then
        return
    end
    hiddenOnce[host] = true
    for _, reg in ipairs({ host:GetRegions() }) do
        if reg.SetAlpha then reg:SetAlpha(0) end
    end
    if host.Text and host.Text.SetAlpha then host.Text:SetAlpha(0) end
    if host.Fill and host.Fill.SetAlpha then host.Fill:SetAlpha(0) end
    local ov = barOverlay[host]
    for _, ch in ipairs({ host:GetChildren() }) do
        if ch ~= ov and ch.TopEdge and ch.SetAlpha then
            ch:SetAlpha(0)
        end
    end
end

local function ShowNativeArt(host)
    if not hiddenOnce[host] then
        return
    end
    hiddenOnce[host] = nil
    for _, reg in ipairs({ host:GetRegions() }) do
        if reg.SetAlpha then reg:SetAlpha(1) end
    end
    if host.Text and host.Text.SetAlpha then host.Text:SetAlpha(1) end
    if host.Fill and host.Fill.SetAlpha then host.Fill:SetAlpha(1) end
    local ov = barOverlay[host]
    for _, ch in ipairs({ host:GetChildren() }) do
        if ch ~= ov and ch.TopEdge and ch.SetAlpha then
            ch:SetAlpha(1)
        end
    end
end

local function EnsureFlatOverlay(host, rowChild)
    local f = barOverlay[host]
    if not f then
        f = CreateFrame("Frame", nil, host)
        f:SetFrameLevel(host:GetFrameLevel() + 2)
        F.Theme.StylePanel(f, 0.86, 0.76)

        local sb = CreateFrame("StatusBar", nil, f)
        sb:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        sb:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        sb:SetStatusBarTexture(F.Theme.FLAT_TEX)
        sb:SetMinMaxValues(0, 1)
        sb:SetValue(0)

        local sheen = sb:CreateTexture(nil, "OVERLAY")
        sheen:SetHeight(1)
        sheen:SetPoint("TOPLEFT", sb, "TOPLEFT", 0, 0)
        sheen:SetPoint("TOPRIGHT", sb, "TOPRIGHT", 0, 0)
        sheen:SetColorTexture(1, 1, 1, 0.14)

        local shade = sb:CreateTexture(nil, "OVERLAY")
        shade:SetHeight(2)
        shade:SetPoint("BOTTOMLEFT", sb, "BOTTOMLEFT", 0, 0)
        shade:SetPoint("BOTTOMRIGHT", sb, "BOTTOMRIGHT", 0, 0)
        shade:SetColorTexture(0, 0, 0, 0.22)

        local textHost = CreateFrame("Frame", nil, f)
        textHost:SetAllPoints()
        textHost:SetFrameLevel(sb:GetFrameLevel() + 2)

        local centerFS = textHost:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(centerFS, 11, "", 0.96, 0.96, 0.98, 1)
        centerFS:SetPoint("CENTER", 0, 0)

        local leftFS = textHost:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(leftFS, 11, "", 0.96, 0.96, 0.98, 1)
        leftFS:SetPoint("LEFT", textHost, "LEFT", 7, 0)
        leftFS:SetJustifyH("LEFT")

        local rightFS = textHost:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(rightFS, 11, "", 0.94, 0.95, 0.97, 1)
        rightFS:SetPoint("RIGHT", textHost, "RIGHT", -7, 0)
        rightFS:SetJustifyH("RIGHT")

        f.bar = sb
        f.center = centerFS
        f.left = leftFS
        f.right = rightFS
        barOverlay[host] = f
    end

    f:ClearAllPoints()
    if rowChild then
        -- 声望行与技能行统一为 174×16 像素右对齐进度条，两页视觉列宽完全一致
        f:SetSize(174, 16)
        f:SetPoint("RIGHT", rowChild, "RIGHT", -10, 0)
    else
        -- 右侧详情条统一为 16px 高度并向内缩进 6px，防止紧贴分隔线
        f:SetHeight(16)
        f:SetPoint("LEFT", host, "LEFT", 6, 0)
        f:SetPoint("RIGHT", host, "RIGHT", -6, 0)
    end
    return f
end

local function SetFlatBar(host, val, maxVal, text, r, g, b, rightText, rowChild)
    local f = EnsureFlatOverlay(host, rowChild)
    HideNativeArt(host)
    f.bar:SetStatusBarTexture(F.Theme.FLAT_TEX)
    f.bar:SetMinMaxValues(0, maxVal > 0 and maxVal or 1)
    f.bar:SetValue(maxVal > 0 and math_min(val, maxVal) or 1)
    f.bar:SetStatusBarColor(r, g, b, 0.90)
    if rightText then
        f.center:SetText("")
        f.left:SetText(text or "")
        f.right:SetText(rightText)
    else
        f.center:SetText(text or "")
        f.left:SetText("")
        f.right:SetText("")
    end
    f:Show()
end

local function ClearFlatBar(host)
    local f = barOverlay[host]
    if f then f:Hide() end
    ShowNativeArt(host)
end

-- 声望行派系查找（安全过滤 secret string）
local function ResolveRowFaction(child)
    local CR = _G.C_Reputation
    if not CR then return nil end
    if child.GetElementData then
        local ok, data = pcall(child.GetElementData, child)
        if ok and type(data) == "table" then
            if data.factionIndex and CR.GetFactionDataByIndex then
                local d = CR.GetFactionDataByIndex(data.factionIndex)
                if d then return d end
            end
            if data.factionID and CR.GetFactionDataByID then
                local d = CR.GetFactionDataByID(data.factionID)
                if d then return d end
            end
        end
    end
    local nameFS = child.Content and child.Content.Name
    local name = nameFS and F.PlainString(nameFS:GetText(), nil)
    if not (name and CR.GetNumFactions and CR.GetFactionDataByIndex) then
        return nil
    end
    for i = 1, CR.GetNumFactions() or 0 do
        local d = CR.GetFactionDataByIndex(i)
        if d and d.name == name then
            return d
        end
    end
    return nil
end

-- 声望右侧详情框派系色查找（与左侧列表同色）
local function ResolveDetailFactionColor(root)
    local CR = _G.C_Reputation
    if not (root and CR and CR.GetNumFactions and CR.GetFactionDataByIndex) then
        return nil
    end
    local names = {}
    local function collect(f, depth)
        for _, reg in ipairs({ f:GetRegions() }) do
            if reg.GetObjectType and reg:GetObjectType() == "FontString" then
                local t = F.PlainString(reg:GetText(), nil)
                if t and t ~= "" then
                    for line in t:gmatch("[^\n]+") do
                        names[line] = true
                    end
                end
            end
        end
        if depth < 2 then
            for _, c in ipairs({ f:GetChildren() }) do
                collect(c, depth + 1)
            end
        end
    end
    collect(root, 0)
    for i = 1, CR.GetNumFactions() or 0 do
        local d = CR.GetFactionDataByIndex(i)
        if d and d.name and d.reaction and names[d.name] then
            local fc = _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[d.reaction]
            if fc then
                return fc.r, fc.g, fc.b
            end
        end
    end
    return nil
end

local function FindRowLabelFS(child, excludeHost)
    if not child or (child.IsForbidden and child:IsForbidden()) then return nil end
    local c = child.Content
    local fs = (c and (c.Name or c.SkillName or c.Title or c.Label))
        or child.Name or child.SkillName or child.Title or child.Label
    if fs and fs.GetObjectType and fs:GetObjectType() == "FontString" then
        return fs
    end
    local searchRoot = c or child
    if searchRoot.GetRegions then
        for _, reg in ipairs({ searchRoot:GetRegions() }) do
            if reg ~= excludeHost and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                local t = F.PlainString(reg:GetText(), nil)
                if t and t ~= "" and not t:find("^%s*%d+%s*/%s*%d+%s*$") then
                    return reg
                end
            end
        end
    end
    return nil
end

local function ApplyRowIndent(child, excludeHost)
    local fs = FindRowLabelFS(child, excludeHost)
    if not (fs and fs.GetPoint and fs.SetPoint) then return end
    local orig = origNamePoint[fs]
    if not orig then
        local okP, pt, rel, rpt, x, y = pcall(fs.GetPoint, fs, 1)
        if not (okP and pt) then return end
        orig = { pt, rel, rpt, F.PlainNumber(x, 0), F.PlainNumber(y, 0) }
        origNamePoint[fs] = orig
    end
    if mod._active and mod:GetDB().charFramePolish ~= false then
        -- 声望与技能子项统一绝对左缩进 22px（分类标题位于 ~10px），彻底消除两页缩进不一致
        pcall(fs.ClearAllPoints, fs)
        pcall(fs.SetPoint, fs, "LEFT", child, "LEFT", 22, 0)
        if fs.SetJustifyH then pcall(fs.SetJustifyH, fs, "LEFT") end
    else
        pcall(fs.ClearAllPoints, fs)
        pcall(fs.SetPoint, fs, orig[1], orig[2], orig[3], orig[4], orig[5])
    end
end

local function StyleRepRow(child)
    if not child or (child.IsForbidden and child:IsForbidden()) then return end
    local host = child.Content and child.Content.ReputationBar
    if not host then return end
    ApplyRowIndent(child, host)
    if not (mod._active and mod:GetDB().flatCharBars) then
        ClearFlatBar(host)
        return
    end
    local d = ResolveRowFaction(child)
    local lo = d and F.PlainNumber(d.currentReactionThreshold, nil)
    local hi = d and F.PlainNumber(d.nextReactionThreshold, nil)
    local cur = d and F.PlainNumber(d.currentStanding, nil)
    if not (d and lo and hi and cur) then
        ClearFlatBar(host)
        return
    end
    local reaction = d.reaction or 4
    local label = (_G.GetText and _G.GetText("FACTION_STANDING_LABEL" .. reaction, _G.UnitSex("player")))
        or _G["FACTION_STANDING_LABEL" .. reaction] or ""
    local fc = _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[reaction]
    local cr, cg, cb = fc and fc.r or 0.55, fc and fc.g or 0.55, fc and fc.b or 0.58
    local range = hi - lo
    if range > 0 then
        SetFlatBar(host, cur - lo, range, label, cr, cg, cb, FormatNum(cur - lo) .. " / " .. FormatNum(range), child)
    else
        SetFlatBar(host, 1, 0, label, cr, cg, cb, nil, child)
    end
end

local function StyleSkillHost(host, rowChild)
    if not host or (host.IsForbidden and host:IsForbidden()) then return end
    if not (mod._active and mod:GetDB().flatCharBars) then
        ClearFlatBar(host)
        return
    end
    local txt = host.Text and F.PlainString(host.Text:GetText(), nil)
    local rank = txt and tonumber(txt:match("^%s*(%d+)"))
    local maxV = txt and tonumber(txt:match("(%d+)%s*$"))
    if not (rank and maxV and maxV > 0) then
        ClearFlatBar(host)
        return
    end
    local rightStr = FormatNum(rank) .. " / " .. FormatNum(maxV)
    if rank >= maxV then
        SetFlatBar(host, rank, maxV, "已满", GOLD_MAX_COLOR[1], GOLD_MAX_COLOR[2], GOLD_MAX_COLOR[3], rightStr, rowChild)
    else
        local ar, ag, ab = F.Theme.GetAccent()
        local pctStr = tostring(math_floor(rank / maxV * 100 + 0.5)) .. "%"
        -- 适度加深职业色饱和度，让白色进度数字与声望条一样高对比锐利
        SetFlatBar(host, rank, maxV, pctStr, ar * 0.72, ag * 0.78, ab * 0.72, rightStr, rowChild)
    end
end

local function StyleSkillRow(child)
    if not child or (child.IsForbidden and child:IsForbidden()) then return end
    -- 无限服 16001 技能行进度条字段名为 child.Content.SkillsBar
    local host = (child.Content and (child.Content.SkillsBar or child.Content.SkillBar or child.Content.StatusBar))
        or child.SkillsBar or child.SkillBar or child.StatusBar
    if not host then return end
    ApplyRowIndent(child, host)
    if host.Text and not hookedSkillFS[host.Text] then
        hookedSkillFS[host.Text] = true
        _G.hooksecurefunc(host.Text, "SetText", function() StyleSkillHost(host, child) end)
    end
    StyleSkillHost(host, child)
end

local function ForEachScrollRow(box, fn)
    if not box then return end
    if box.ForEachFrame then
        pcall(box.ForEachFrame, box, fn)
    elseif box.ScrollTarget then
        for _, ch in ipairs({ box.ScrollTarget:GetChildren() }) do
            fn(ch)
        end
    end
end

local function SkinSkillsScrollBar()
    if not (mod._active and mod:GetDB().flatCharBars) then return end
    local S = F.Theme.GetSkinAPI()
    local sf = _G.SkillsFrame
    if S and S.ScrollBar and sf and sf.ScrollBar then
        pcall(S.ScrollBar, sf.ScrollBar)
    end
end

local function HookScrollBoxesNow()
    local repBox = _G.ReputationFrame and _G.ReputationFrame.ScrollBox
    if repBox then
        if not hookedBoxes[repBox] then
            hookedBoxes[repBox] = true
            _G.hooksecurefunc(repBox, "Update", function(self) ForEachScrollRow(self, StyleRepRow) end)
        end
        ForEachScrollRow(repBox, StyleRepRow)
    end

    local skillBox = _G.SkillsFrame and _G.SkillsFrame.ScrollBox
    if skillBox then
        if not hookedBoxes[skillBox] then
            hookedBoxes[skillBox] = true
            _G.hooksecurefunc(skillBox, "Update", function(self) ForEachScrollRow(self, StyleSkillRow) end)
        end
        ForEachScrollRow(skillBox, StyleSkillRow)
    end
    SkinSkillsScrollBar()
end

-- 散条（声望右侧详情条、技能右侧详情条、宠物经验条）
local function ReadBarText(host)
    local fs = host.Text or host.text
    if fs and fs.GetText then
        return fs, F.PlainString(fs:GetText(), nil)
    end
    for _, reg in ipairs({ host:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "FontString" then
            local t = F.PlainString(reg:GetText(), nil)
            if t and t ~= "" then
                return reg, t
            end
        end
    end
    return nil, nil
end

local function ParseRatio(host, txt)
    if host.GetMinMaxValues and host.GetValue then
        local lo, hi = host:GetMinMaxValues()
        local v = host:GetValue()
        lo, hi, v = F.PlainNumber(lo, nil), F.PlainNumber(hi, nil), F.PlainNumber(v, nil)
        if lo and hi and v and hi > lo then
            return math_max(0, v - lo), hi - lo
        end
    end
    if type(txt) == "string" then
        local clean = txt:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("(%d)[,%.](%d)", "%1%2")
        local a, b = clean:match("(%d+)%s*/%s*(%d+)")
        if not a then
            a, b = clean:match("(%d+)"), clean:match("(%d+)%D*$")
        end
        a, b = tonumber(a), tonumber(b)
        if a and b and b > 0 then
            return a, b
        end
    end
    if host.Fill and host.Fill.GetWidth and host.GetWidth then
        local w = F.PlainNumber(host:GetWidth(), nil)
        local fw = F.PlainNumber(host.Fill:GetWidth(), nil)
        if w and fw and w > 0 then
            return math_min(fw, w), w
        end
    end
    return nil, nil
end

local function IsUnder(frame, root)
    if not root then return false end
    local p = frame
    while p do
        if p == root then return true end
        p = p:GetParent()
    end
    return false
end

local function PaintLooseBar(host)
    if not (mod._active and mod:GetDB().flatCharBars) then
        ClearFlatBar(host)
        return
    end
    local _, txt = ReadBarText(host)
    local cur, max = ParseRatio(host, txt)
    if not (cur and max and max > 0) then
        ClearFlatBar(host)
        return
    end

    local r, g, b
    if IsUnder(host, _G.ReputationFrame) then
        r, g, b = ResolveDetailFactionColor(host:GetParent())
        if not r then
            local detail = _G.ReputationFrame and _G.ReputationFrame.ReputationDetailFrame
            r, g, b = ResolveDetailFactionColor(detail)
        end
        if not r then
            -- 兜底取原生条贴图色
            local fill = host.Fill
            if fill and fill.GetVertexColor then
                local vr, vg, vb = fill:GetVertexColor()
                if vr and not (vr > 0.95 and vg > 0.95 and vb > 0.95) then
                    r, g, b = vr, vg, vb
                end
            end
        end
        if not r then r, g, b = 0.0, 0.6, 0.1 end
    elseif IsUnder(host, _G.PetPaperDollFrame) or (type(txt) == "string" and (txt:find("XP") or txt:find("经验"))) then
        r, g, b = PET_XP_COLOR[1], PET_XP_COLOR[2], PET_XP_COLOR[3]
    elseif cur >= max then
        r, g, b = GOLD_MAX_COLOR[1], GOLD_MAX_COLOR[2], GOLD_MAX_COLOR[3]
    else
        local ar, ag, ab = F.Theme.GetAccent()
        r, g, b = ar * 0.72, ag * 0.78, ab * 0.72
    end

    local pctLabel = (cur >= max) and "已满" or (tostring(math_floor(cur / max * 100 + 0.5)) .. "%")
    local rightStr = FormatNum(cur) .. " / " .. FormatNum(max)
    SetFlatBar(host, cur, max, pctLabel, r, g, b, rightStr, nil)
end

local function IsCandidateBar(f)
    if f.Fill and f.Text and f.Fill.GetObjectType and f.Fill:GetObjectType() == "Texture" then
        return true
    end
    if f.GetObjectType and f:GetObjectType() == "StatusBar" then
        local _, txt = ReadBarText(f)
        return type(txt) == "string" and txt:find("%d%s*/%s*%d") ~= nil
    end
    return false
end

-- 每个子面板只扫描一次并缓存找到的散条，切页零递归卡顿
local function ScanSubPanelOnce(panel)
    if not panel or scannedPanels[panel] then
        return
    end
    scannedPanels[panel] = true
    local skip = {}
    if _G.ReputationFrame and _G.ReputationFrame.ScrollBox then skip[_G.ReputationFrame.ScrollBox] = true end
    if _G.SkillsFrame and _G.SkillsFrame.ScrollBox then skip[_G.SkillsFrame.ScrollBox] = true end
    if _G.CharacterStatsPane then skip[_G.CharacterStatsPane] = true end

    local function visit(f, depth)
        if not f or (f.IsForbidden and f:IsForbidden()) or skip[f] or depth > 6 then
            return
        end
        if IsCandidateBar(f) then
            if not hookedHost[f] then
                hookedHost[f] = true
                looseBarList[#looseBarList + 1] = f
                local function refreshNow()
                    if f.IsForbidden and f:IsForbidden() then return end
                    PaintLooseBar(f)
                    C_Timer.After(0, function()
                        if f and not (f.IsForbidden and f:IsForbidden()) and f:IsVisible() then PaintLooseBar(f) end
                    end)
                end
                local fs = ReadBarText(f)
                if fs then
                    _G.hooksecurefunc(fs, "SetText", refreshNow)
                    _G.hooksecurefunc(fs, "SetFormattedText", refreshNow)
                end
                if f:GetObjectType() == "StatusBar" then
                    _G.hooksecurefunc(f, "SetValue", refreshNow)
                    _G.hooksecurefunc(f, "SetMinMaxValues", refreshNow)
                end
                f:HookScript("OnShow", refreshNow)
            end
            PaintLooseBar(f)
            return
        end
        for _, ch in ipairs({ f:GetChildren() }) do
            visit(ch, depth + 1)
        end
    end
    visit(panel, 0)
end

-- 现代扁平复选框美化（用于声望详情「交战状态 / 隐藏 / 显示为经验条」及角色面板其它复选框，零污染弱表）
local function SyncCheckBoxVisual(cb, hovered)
    local ov = cbOverlay[cb]
    if not ov then return end
    local checked = cb.GetChecked and cb:GetChecked() and true or false
    local enabled = not (cb.IsEnabled and not cb:IsEnabled())
    local ar, ag, ab = F.Theme.GetAccent()
    ov._check:SetShown(checked)
    if checked then
        ov._check:SetVertexColor(ar, ag, ab, enabled and 1 or 0.45)
    end
    if ov._fuiBg then
        if hovered and enabled then
            ov._fuiBg:SetColorTexture(0.14, 0.16, 0.20, 0.96)
        elseif checked then
            ov._fuiBg:SetColorTexture(ar * 0.18 + 0.05, ag * 0.18 + 0.055, ab * 0.18 + 0.07, 0.94)
        else
            ov._fuiBg:SetColorTexture(0.07, 0.078, 0.095, 0.94)
        end
    end
    if ov._fuiBorders then
        local br, bg, bb, ba
        if hovered and enabled then
            br, bg, bb, ba = ar, ag, ab, 0.95
        elseif checked then
            br, bg, bb, ba = ar, ag, ab, 0.78
        else
            br, bg, bb, ba = 0.30, 0.33, 0.38, 0.88
        end
        for _, ln in ipairs(ov._fuiBorders) do
            ln:SetColorTexture(br, bg, bb, enabled and ba or 0.35)
        end
    end
end

local CHECKBOX_TEX_GETTERS = {
    "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture",
    "GetCheckedTexture", "GetDisabledCheckedTexture", "GetDisabledTexture",
}

local function MuteCheckBoxStockArt(cb, alpha)
    for _, getter in ipairs(CHECKBOX_TEX_GETTERS) do
        local fn = cb[getter]
        local t = fn and fn(cb)
        if t and t.SetAlpha then t:SetAlpha(alpha) end
    end
    for _, reg in ipairs({ cb:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" and reg.SetAlpha then
            reg:SetAlpha(alpha)
        end
    end
end

local function SkinModernCheckBox(cb)
    if not cb or (cb.IsForbidden and cb:IsForbidden()) then return end
    if not (cb.GetObjectType and cb:GetObjectType() == "CheckButton") then return end
    if not (mod._active and mod:GetDB().charFramePolish ~= false) then
        local ov = cbOverlay[cb]
        if ov then ov:Hide() end
        MuteCheckBoxStockArt(cb, 1)
        return
    end

    MuteCheckBoxStockArt(cb, 0)
    local ov = cbOverlay[cb]
    if not ov then
        ov = CreateFrame("Frame", nil, cb)
        ov:SetSize(16, 16)
        ov:SetPoint("CENTER", cb, "CENTER", 0, 0)
        ov:SetFrameLevel((cb:GetFrameLevel() or 2) + 2)
        ov:EnableMouse(false)
        F.Theme.StylePanel(ov, 0.94, 0.88)

        local chk = ov:CreateTexture(nil, "OVERLAY")
        chk:SetSize(12, 12)
        chk:SetPoint("CENTER", ov, "CENTER", 0, 0)
        chk:SetTexture(F.Theme.ICONS .. "Check.tga")
        chk:SetTexCoord(0, 1, 0, 1)
        ov._check = chk
        cbOverlay[cb] = ov
    end
    ov:Show()
    SyncCheckBoxVisual(cb, false)

    if not cbHooked[cb] then
        cbHooked[cb] = true
        cb:HookScript("OnShow", function(self)
            -- 走完整入口：停用模块/关闭选项后会还原原生勾选框，而不是把原生贴图静音却不显示覆盖层（勾选框整个消失）
            SkinModernCheckBox(self)
        end)
        cb:HookScript("OnClick", function(self)
            SyncCheckBoxVisual(self, self.IsMouseOver and self:IsMouseOver())
        end)
        cb:HookScript("OnEnter", function(self) SyncCheckBoxVisual(self, true) end)
        cb:HookScript("OnLeave", function(self) SyncCheckBoxVisual(self, false) end)
        if cb.SetChecked then
            _G.hooksecurefunc(cb, "SetChecked", function(self)
                SyncCheckBoxVisual(self, self.IsMouseOver and self:IsMouseOver())
            end)
        end
    end
end

local function SkinCheckBoxesIn(root, depth)
    if not root or (root.IsForbidden and root:IsForbidden()) or (depth or 0) > 5 then return end
    if root.GetObjectType and root:GetObjectType() == "CheckButton" then
        -- 排除大尺寸标签页按钮（只处理标准 14-36px 复选框）
        local w = F.PlainNumber(root:GetWidth(), 0)
        local h = F.PlainNumber(root:GetHeight(), 0)
        if w >= 12 and w <= 38 and h >= 12 and h <= 38 then
            SkinModernCheckBox(root)
        end
        return
    end
    if root.GetChildren then
        for _, ch in ipairs({ root:GetChildren() }) do
            if ch and ch ~= barOverlay[root] and ch ~= cbOverlay[root] and ch ~= pvpOverlay[root] then
                SkinCheckBoxesIn(ch, (depth or 0) + 1)
            end
        end
    end
end

-- 美化角色面板 PvP 页签中遗留的老旧棕色浮雕框（「下一批奖励将在等级1解锁」与奖励图标铜框）
local function IsOrnamentalBorderTex(tex)
    local layer = tex.GetDrawLayer and tex:GetDrawLayer()
    local atlas = tex.GetAtlas and F.PlainString(tex:GetAtlas(), "") or ""
    local path = tex.GetTexture and F.PlainString(tex:GetTexture(), "") or ""
    local hay = (atlas .. " " .. tostring(path)):lower()
    if hay:find("border", 1, true) or hay:find("frame", 1, true) or hay:find("slot", 1, true)
        or hay:find("bronze", 1, true) or hay:find("metal", 1, true) or hay:find("bevel", 1, true)
        or hay:find("overlay", 1, true) or hay:find("highlight", 1, true) or hay:find("button", 1, true) then
        return true
    end
    return layer == "OVERLAY" or layer == "BORDER"
end

local function SkinPvPSubElements(root, depth)
    if not root or (root.IsForbidden and root:IsForbidden()) or (depth or 0) > 6 then return end
    local want = mod._active and mod:GetDB().charFramePolish ~= false
    local ar, ag, ab = F.Theme.GetAccent()

    -- 1) 识别「下一批奖励将在等级X解锁」老旧棕色圆角浮雕标签框
    local hasUnlockBanner = false
    local bannerFS = nil
    if root.GetRegions then
        for _, reg in ipairs({ root:GetRegions() }) do
            if reg.GetObjectType and reg:GetObjectType() == "FontString" then
                local t = F.PlainString(reg:GetText(), nil)
                if t and (t:find("下一批奖励", 1, true) or t:find("将在等级", 1, true) or t:find("Next Reward", 1, true) or t:find("Unlocked at", 1, true)) then
                    hasUnlockBanner = true
                    bannerFS = reg
                    break
                end
            end
        end
    end

    if hasUnlockBanner then
        if want then
            if root.NineSlice and root.NineSlice.SetAlpha then root.NineSlice:SetAlpha(0) end
            for _, reg in ipairs({ root:GetRegions() }) do
                if reg.GetObjectType and reg:GetObjectType() == "Texture" then
                    reg:SetAlpha(0)
                end
            end
            local ov = pvpOverlay[root]
            if not ov then
                ov = CreateFrame("Frame", nil, root)
                ov:SetPoint("TOPLEFT", root, "TOPLEFT", 1, -1)
                ov:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -1, 1)
                ov:SetFrameLevel(math_max(0, (root:GetFrameLevel() or 2) - 1))
                ov:EnableMouse(false)
                local bar = ov:CreateTexture(nil, "OVERLAY")
                bar:SetWidth(2)
                bar:SetPoint("TOPLEFT", ov, "TOPLEFT", 0, 0)
                bar:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 0, 0)
                ov._accentBar = bar
                pvpOverlay[root] = ov
            end
            F.Theme.StylePanel(ov, 0.72, 0.65)
            ov._accentBar:SetColorTexture(ar, ag, ab, 0.90)
            ov:Show()
            if bannerFS then
                F.Theme.ApplyFont(bannerFS, 12, "", 0.94, 0.95, 0.97, 1)
            end
        else
            local ov = pvpOverlay[root]
            if ov then ov:Hide() end
            if root.NineSlice and root.NineSlice.SetAlpha then root.NineSlice:SetAlpha(1) end
            for _, reg in ipairs({ root:GetRegions() }) do
                if reg.GetObjectType and reg:GetObjectType() == "Texture" then reg:SetAlpha(1) end
            end
        end
        return
    end

    -- 2) 识别奖励图标铜框（30-56px 方框，内部包含物品图标 + 棕色浮雕边框）
    local w = F.PlainNumber(root:GetWidth(), 0)
    local h = F.PlainNumber(root:GetHeight(), 0)
    if w >= 28 and w <= 56 and h >= 28 and h <= 56 and math_abs(w - h) <= 4 then
        local iconTex = root.Icon or root.icon or root.IconTexture
        local hasBorder = false
        local borderTexList = {}
        if root.GetRegions then
            for _, reg in ipairs({ root:GetRegions() }) do
                if reg.GetObjectType and reg:GetObjectType() == "Texture" then
                    local layer = reg.GetDrawLayer and reg:GetDrawLayer()
                    if not iconTex and (layer == "ARTWORK" or layer == "BACKGROUND") and not IsOrnamentalBorderTex(reg) then
                        local texVal = reg.GetTexture and reg:GetTexture()
                        if texVal then iconTex = reg end
                    elseif reg ~= iconTex and IsOrnamentalBorderTex(reg) then
                        hasBorder = true
                        borderTexList[#borderTexList + 1] = reg
                    end
                end
            end
        end
        if iconTex and (hasBorder or root.Border or root.IconBorder or root.NineSlice) then
            if want then
                if root.NineSlice and root.NineSlice.SetAlpha then root.NineSlice:SetAlpha(0) end
                if root.Border and root.Border.SetAlpha then root.Border:SetAlpha(0) end
                if root.IconBorder and root.IconBorder.SetAlpha then root.IconBorder:SetAlpha(0) end
                for _, bt in ipairs(borderTexList) do bt:SetAlpha(0) end
                if iconTex.SetTexCoord then iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
                local ov = pvpOverlay[root]
                if not ov then
                    ov = CreateFrame("Frame", nil, root)
                    ov:SetPoint("TOPLEFT", iconTex, "TOPLEFT", -1, 1)
                    ov:SetPoint("BOTTOMRIGHT", iconTex, "BOTTOMRIGHT", 1, -1)
                    ov:SetFrameLevel((root:GetFrameLevel() or 2) + 2)
                    ov:EnableMouse(false)
                    F.Theme.StylePanel(ov, 0, 0.85)
                    if ov._fuiBg then ov._fuiBg:Hide() end
                    pvpOverlay[root] = ov
                end
                if ov._fuiBorders then
                    for _, ln in ipairs(ov._fuiBorders) do
                        ln:SetColorTexture(ar, ag, ab, 0.82)
                    end
                end
                ov:Show()
            else
                local ov = pvpOverlay[root]
                if ov then
                    -- 只还原本模块改过的图标（有覆盖层即说明曾被美化），恢复原生铜框与完整图标裁切
                    ov:Hide()
                    if root.NineSlice and root.NineSlice.SetAlpha then root.NineSlice:SetAlpha(1) end
                    if root.Border and root.Border.SetAlpha then root.Border:SetAlpha(1) end
                    if root.IconBorder and root.IconBorder.SetAlpha then root.IconBorder:SetAlpha(1) end
                    for _, bt in ipairs(borderTexList) do bt:SetAlpha(1) end
                    if iconTex.SetTexCoord then iconTex:SetTexCoord(0, 1, 0, 1) end
                end
            end
            return
        end
    end

    if root.GetChildren then
        for _, ch in ipairs({ root:GetChildren() }) do
            if ch and ch ~= pvpOverlay[root] and ch ~= cbOverlay[root] and ch ~= barOverlay[root] then
                SkinPvPSubElements(ch, (depth or 0) + 1)
            end
        end
    end
end

local function PolishCharacterSubPanels()
    local rep = _G.ReputationFrame
    if rep then
        SkinCheckBoxesIn(rep, 0)
        if rep.ReputationDetailFrame then
            SkinCheckBoxesIn(rep.ReputationDetailFrame, 0)
        end
    end
    for _, cbName in ipairs({
        "ReputationDetailAtWarCheckBox",
        "ReputationDetailInactiveCheckBox",
        "ReputationDetailMainScreenCheckBox",
    }) do
        if _G[cbName] then SkinModernCheckBox(_G[cbName]) end
    end
    if _G.SkillsFrame then SkinCheckBoxesIn(_G.SkillsFrame, 0) end
    if _G.TokenFrame then SkinCheckBoxesIn(_G.TokenFrame, 0) end
    if _G.PetPaperDollFrame then SkinCheckBoxesIn(_G.PetPaperDollFrame, 0) end

    for _, pvpName in ipairs({ "HonorFrame", "PVPFrame", "PVPCharacterFrame", "PVPHonorFrame", "CharacterHonorFrame" }) do
        local pf = _G[pvpName]
        if pf then
            SkinPvPSubElements(pf, 0)
            SkinCheckBoxesIn(pf, 0)
            if not hookedPanels[pf] and pf.HookScript then
                hookedPanels[pf] = true
                pf:HookScript("OnShow", function(self)
                    SkinPvPSubElements(self, 0)
                    SkinCheckBoxesIn(self, 0)
                    C_Timer.After(0, function()
                        if self:IsVisible() then SkinPvPSubElements(self, 0) end
                    end)
                end)
            end
        end
    end
    -- 兜底扫描 CharacterFrame 当前可见 PvP 子页签（绝不误伤装备方案/称号侧边栏标签页）
    local cf = _G.CharacterFrame
    local paperDollOpen = _G.PaperDollFrame and _G.PaperDollFrame:IsVisible()
    if cf and cf:IsVisible() and not paperDollOpen and cf.GetChildren then
        for _, ch in ipairs({ cf:GetChildren() }) do
            if ch and not (ch.IsForbidden and ch:IsForbidden()) and ch:IsVisible()
                and ch ~= _G.PaperDollFrame and ch ~= _G.ReputationFrame and ch ~= _G.SkillsFrame and ch ~= _G.TokenFrame then
                local chName = ch.GetName and F.PlainString(ch:GetName(), "") or ""
                local chW = F.PlainNumber(ch:GetWidth(), 0)
                local chH = F.PlainNumber(ch:GetHeight(), 0)
                -- 仅处理大型内容面板（排除 CharacterFrameModeTab / 侧边标签小按钮）
                if not chName:find("Tab", 1, true) and chW >= 260 and chH >= 200 then
                    SkinPvPSubElements(ch, 0)
                    SkinCheckBoxesIn(ch, 0)
                end
            end
        end
    end
end

local PolishCharacterStatsFontSize
do
    local origStatFS = setmetatable({}, { __mode = "k" })
    local cachedStatsChild = nil

    local function HasStatSectionHeader(root, depth)
        if not root or (root.IsForbidden and root:IsForbidden()) or depth > 2 then return false end
        if root.GetRegions then
            for _, reg in ipairs({ root:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                    local t = F.PlainString(reg:GetText(), nil)
                    if t and (t == "防御" or t == "抗性" or t == "主要属性" or t == "概览"
                        or t == "Defense" or t == "Attributes" or t == "Resistances") then
                        return true
                    end
                end
            end
        end
        if depth < 2 and root.GetChildren then
            for _, ch in ipairs({ root:GetChildren() }) do
                if HasStatSectionHeader(ch, depth + 1) then return true end
            end
        end
        return false
    end

    local function FindStatsScrollChild(root, depth)
        if not root or (root.IsForbidden and root:IsForbidden()) or depth > 3 then return nil end
        if root == _G.ReputationFrame or root == _G.SkillsFrame or root == _G.TokenFrame then return nil end
        if root.GetObjectType and root:GetObjectType() == "ScrollFrame" and root.GetScrollChild then
            local okS, sc = pcall(root.GetScrollChild, root)
            if okS and sc and HasStatSectionHeader(sc, 0) then
                return sc
            end
        end
        if depth < 3 and root.GetChildren then
            for _, ch in ipairs({ root:GetChildren() }) do
                local found = FindStatsScrollChild(ch, depth + 1)
                if found then return found end
            end
        end
        return nil
    end

    local function ApplyStatFontsIn(root, statSz, active, depth)
        if not root or (root.IsForbidden and root:IsForbidden()) or depth > 3 then return end
        if root.GetRegions then
            for _, reg in ipairs({ root:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" and reg.GetFont and reg.SetFont then
                    local okF, face, sz, flags = pcall(reg.GetFont, reg)
                    sz = okF and F.PlainNumber(sz, nil) or nil
                    if face and sz and sz > 0 then
                        local orig = origStatFS[reg]
                        if not orig then
                            orig = sz
                            origStatFS[reg] = orig
                        end
                        if orig <= 12.2 then
                            local target = orig
                            if active then
                                target = (orig <= 10.6) and statSz or (statSz + 1)
                            end
                            if math_abs(sz - target) >= 0.2 then
                                pcall(reg.SetFont, reg, face, target, flags or "")
                            end
                        end
                    end
                end
            end
        end
        if depth < 3 and root.GetChildren then
            for _, ch in ipairs({ root:GetChildren() }) do
                ApplyStatFontsIn(ch, statSz, active, depth + 1)
            end
        end
    end

    PolishCharacterStatsFontSize = function()
        local cf = _G.CharacterFrame
        if not cf then return end
        if not cachedStatsChild or (cachedStatsChild.IsForbidden and cachedStatsChild:IsForbidden()) then
            cachedStatsChild = FindStatsScrollChild(cf, 0)
        end
        if not cachedStatsChild then return end
        local db = mod:GetDB()
        local statSz = math_max(10, math_min(14, F.PlainNumber(db.charStatFontSize, 12)))
        ApplyStatFontsIn(cachedStatsChild, statSz, mod._active == true, 0)
    end
end

-- 用名字表 + _G[name] 遍历：ipairs 遇到第一个 nil 就停，{ _G.A, _G.B } 里任一框体尚未加载都会漏掉后面的面板
local SCAN_PANEL_NAMES = { "ReputationFrame", "SkillsFrame", "PetPaperDollFrame" }
local HOOK_PANEL_NAMES = { "ReputationFrame", "SkillsFrame", "PetPaperDollFrame", "TokenFrame", "HonorFrame", "PVPFrame" }

local function RefreshAllCharacterBars()
    HookScrollBoxesNow()
    for _, name in ipairs(SCAN_PANEL_NAMES) do
        local panel = _G[name]
        if panel then
            ScanSubPanelOnce(panel)
        end
    end
    for _, host in ipairs(looseBarList) do
        if host and not (host.IsForbidden and host:IsForbidden()) and host:IsVisible() then
            PaintLooseBar(host)
        end
    end
    PolishCharacterSubPanels()
    PolishCharacterStatsFontSize()
end

local function SetupCharacterBars()
    HookScrollBoxesNow()
    for _, panelName in ipairs(HOOK_PANEL_NAMES) do
        local panel = _G[panelName]
        if panel then
            if panel == _G.ReputationFrame or panel == _G.SkillsFrame or panel == _G.PetPaperDollFrame then
                ScanSubPanelOnce(panel)
            end
            if not hookedPanels[panel] and panel.HasScript and panel:HasScript("OnShow") then
                hookedPanels[panel] = true
                panel:HookScript("OnShow", function()
                    HookScrollBoxesNow()
                    if panel == _G.ReputationFrame or panel == _G.SkillsFrame or panel == _G.PetPaperDollFrame then
                        ScanSubPanelOnce(panel)
                    end
                    for _, host in ipairs(looseBarList) do
                        if host and not (host.IsForbidden and host:IsForbidden()) and host:IsVisible() then
                            PaintLooseBar(host)
                        end
                    end
                    PolishCharacterSubPanels()
                    C_Timer.After(0, PolishCharacterSubPanels)
                end)
            end
        end
    end
    local cf = _G.CharacterFrame
    if cf and not hookedPanels[cf] and cf.HookScript then
        hookedPanels[cf] = true
        cf:HookScript("OnShow", function()
            C_Timer.After(0, function()
                PolishCharacterSubPanels()
                PolishCharacterStatsFontSize()
            end)
            C_Timer.After(0.2, PolishCharacterStatsFontSize)
        end)
        if _G.CharacterFrameTab_OnClick then
            _G.hooksecurefunc("CharacterFrameTab_OnClick", function()
                C_Timer.After(0, function()
                    PolishCharacterSubPanels()
                    PolishCharacterStatsFontSize()
                end)
            end)
        end
    end
    charHooked = true
    PolishCharacterSubPanels()
    PolishCharacterStatsFontSize()
end

----------------------------------------------------------------------
--  2) 增益/减益计时文字防重叠（12.x 保密值安全）
----------------------------------------------------------------------
local fittedTimers = setmetatable({}, { __mode = "k" })
local measureFS = nil

local function FitAuraButton(btn)
    local fs = btn and btn.Duration
    if not (fs and fs.GetFont and fs.SetFont) then
        return
    end
    local w = F.PlainNumber(btn:GetWidth(), nil)
    local iw = btn.Icon and btn.Icon.GetWidth and F.PlainNumber(btn.Icon:GetWidth(), nil)
    if iw and iw > 0 and (not w or iw < w) then
        w = iw
    end
    if not w or w <= 0 then
        return
    end
    local face, size, flags = fs:GetFont()
    size = F.PlainNumber(size, nil)
    if not (face and size and size > 0) then
        return
    end
    local done = fittedTimers[fs]
    if done and done[1] == w and math_abs(size - done[2]) < 0.05 then
        return
    end
    local base = (done and math_abs(size - done[2]) < 0.05) and done[3] or size
    if not measureFS then
        measureFS = _G.UIParent:CreateFontString(nil, "BACKGROUND")
        measureFS:Hide()
    end
    measureFS:SetFont(face, base, flags or "")
    measureFS:SetText("88 m")
    local tw = F.PlainNumber(measureFS:GetStringWidth(), nil)
    local newSize = base
    if tw and tw > w then
        newSize = math_max(7, math_floor(base * w / tw * 10) / 10)
    end
    if math_abs(newSize - size) >= 0.05 then
        fs:SetFont(face, newSize, flags or "")
    end
    fittedTimers[fs] = { w, newSize, base }
end

local AURA_ROOT_NAMES = { "BuffFrame", "DebuffFrame" }

local function FitAuraChildren(c)
    if c and not (c.IsForbidden and c:IsForbidden()) and c.GetChildren then
        for _, ch in ipairs({ c:GetChildren() }) do
            if ch and not (ch.IsForbidden and ch:IsForbidden()) and ch.Duration then FitAuraButton(ch) end
        end
    end
end

-- 关闭「计时文字防重叠」或停用模块时把缩小过的计时字号还原
local function RestoreFittedAuraTimers()
    for fs, done in pairs(fittedTimers) do
        if fs and fs.GetFont and fs.SetFont and done[3] then
            local face, size, flags = fs:GetFont()
            size = F.PlainNumber(size, nil)
            if face and size and math_abs(size - done[3]) >= 0.05 then
                pcall(fs.SetFont, fs, face, done[3], flags or "")
            end
        end
        fittedTimers[fs] = nil
    end
end

local function FitAllAuras()
    if not (mod._active and mod:GetDB().fitBuffTimers) then
        if next(fittedTimers) ~= nil then RestoreFittedAuraTimers() end
        return
    end
    for _, rootName in ipairs(AURA_ROOT_NAMES) do
        local root = _G[rootName]
        if root and not (root.IsForbidden and root:IsForbidden()) then
            if type(root.auraFrames) == "table" then
                -- 有 auraFrames 列表时直接遍历（零分配），不再重复扫描 AuraContainer 子框
                for _, btn in ipairs(root.auraFrames) do
                    if btn and not (btn.IsForbidden and btn:IsForbidden()) then FitAuraButton(btn) end
                end
            else
                -- 旧式：分别检查 AuraContainer 与根框体（原写法 { nil, root } 会让 ipairs 一次都不执行）
                FitAuraChildren(root.AuraContainer)
                FitAuraChildren(root)
            end
        end
    end
end

local QueueAuraFit = F.Debounce(0.12, FitAllAuras)

----------------------------------------------------------------------
--  3) 好友列表适度加高 + BugSack 轻量皮肤
----------------------------------------------------------------------
local friendsHooked = false
local friendsOrigH = nil
local function ExpandFriendsIfEnabled()
    local ff = _G.FriendsFrame
    if not ff then return end
    if not (mod._active and mod:GetDB().expandFriends) then
        -- 关闭「好友列表加高」或停用模块时还原原始高度
        if friendsOrigH then
            F.RunOutOfCombat("FUI_ExpandFriends", function()
                if friendsOrigH and ff then
                    ff:SetHeight(friendsOrigH)
                    friendsOrigH = nil
                end
            end)
        end
        return
    end
    F.RunOutOfCombat("FUI_ExpandFriends", function()
        local h = ff and F.PlainNumber(ff:GetHeight(), 560)
        if h and h < 520 then
            friendsOrigH = friendsOrigH or h
            ff:SetHeight(560)
        end
    end)
end

local function SetupFriendsHook()
    local ff = _G.FriendsFrame
    if ff and not friendsHooked then
        friendsHooked = true
        ff:HookScript("OnShow", ExpandFriendsIfEnabled)
    end
end

local bugSackHooked = false

local function SkinBugSackIfReady()
    if not (mod._active and mod:GetDB().skinBugSack) then
        return
    end
    -- BugSackFrame 在第一次 BugSack:OpenSack() 时才懒创建：挂钩打开函数，首次打开即可上皮肤
    local bs = _G.BugSack
    if not bugSackHooked and type(bs) == "table" and type(bs.OpenSack) == "function" then
        bugSackHooked = true
        _G.hooksecurefunc(bs, "OpenSack", function()
            if mod._active and mod:GetDB().skinBugSack then
                C_Timer.After(0, SkinBugSackIfReady)
            end
        end)
    end
    local frame = _G.BugSackFrame
    local S = F.Theme.GetSkinAPI()
    if frame and S and S.Shell then
        pcall(S.Shell, frame)
    end
end

----------------------------------------------------------------------
--  4) 冷却管理器冲突一键「停用并重载」弹窗 + 调试插件提醒
----------------------------------------------------------------------
local CDM_ADDON = "EllesmereUICooldownManager"

if _G.StaticPopupDialogs then
    _G.StaticPopupDialogs["FOREVERUI_CDM_CONFLICT"] = {
        text = "|cffdca77fForeverUI|r\n\n检测到 EUI 冷却管理器 与 Arc Auras 同时启用，冷却图标会重复或错乱。\n\n要为当前角色停用 EUI 冷却管理器并重载界面吗？",
        button1 = "停用并重载",
        button2 = "保留",
        OnAccept = function()
            local disable = (_G.C_AddOns and _G.C_AddOns.DisableAddOn) or _G.DisableAddOn
            if disable then pcall(disable, CDM_ADDON, _G.UnitName("player")) end
            if _G.ReloadUI then _G.ReloadUI() end
        end,
        OnCancel = function(_, _, reason)
            if reason == "clicked" then
                local db = mod:GetDB()
                db.cdmConflictKeep = type(db.cdmConflictKeep) == "table" and db.cdmConflictKeep or {}
                db.cdmConflictKeep[F.GetCharKey()] = true
            end
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local function RunConflictDiagnostics()
    local db = mod:GetDB()
    if not db.conflictCheck then
        return
    end
    if F.IsAddOnLoaded(CDM_ADDON) and F.IsAddOnLoaded("ArcAuras") then
        local keep = type(db.cdmConflictKeep) == "table" and db.cdmConflictKeep[F.GetCharKey()] == true
        if not keep then
            F.RunOutOfCombat("FUI_CDMConflictPopup", function()
                if _G.StaticPopup_Show then
                    _G.StaticPopup_Show("FOREVERUI_CDM_CONFLICT")
                end
            end)
        end
    end
    if F.IsAddOnLoaded("QuestieTrace") or F.IsAddOnLoaded("BlizzMove_Debug") then
        F.PrintOnce("debug_addons", "|cffffcc00性能提示：|r检测到调试插件 QuestieTrace 或 BlizzMove_Debug 仍在启用，建议停用以降低内存开销。")
    end
    if F.IsAddOnLoaded("ArcUI") then
        F.PrintOnce("arcui_stub", "|cffffcc00精简提示：|rArcUI 是一次性迁移存根，数据已迁至 ArcAuras 后可直接停用。")
    end
end

----------------------------------------------------------------------
--  5) 统一 EllesmereUI 资源条 / 挥砍计时器 / 施法条 现代极简职业色风格
--     • 绝不改动任何 unlockPos 位置坐标与可见性（visibility）
--     • 首次修改前自动完整快照备份到 db.erbStyleBackup，随时可一键还原
----------------------------------------------------------------------
local function CopyStyleFields(src, keys)
    local out = {}
    if type(src) ~= "table" then return out end
    for _, k in ipairs(keys) do
        out[k] = src[k]
    end
    return out
end

local ERB_UNIFY_VERSION = 3

local function GetERBProfileAndApply()
    -- EUI ResourceBars 直接导出 _G._ERB_AceDB 与 _G._ERB_Apply（EUI_ResourceBars_Events.lua）
    local aceDB = _G._ERB_AceDB
    local applyFn = _G._ERB_Apply
    if aceDB and type(aceDB.profile) == "table" then
        return aceDB.profile, applyFn
    end
    local EUI = _G.EllesmereUI
    local nsMap = EUI and EUI._ModuleNS
    local rbNS = nsMap and nsMap.EllesmereUIResourceBars
    local ERB = rbNS and rbNS.ERB
    if ERB and ERB.db and type(ERB.db.profile) == "table" then
        return ERB.db.profile, function() if ERB.ApplyAll then ERB:ApplyAll() end end
    end
    return nil, nil
end

local ERB_UNIFY_PLAN = {
    general = {
        barTexture = "sm:MerfinMain",
    },
    health = {
        width = 249, height = 14, textSize = 12,
        customColored = false, gradientEnabled = false,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    primary = {
        width = 249, height = 14, textSize = 12,
        customColored = false, gradientEnabled = false,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    secondary = {
        pipWidth = 249, pipHeight = 14, textSize = 12,
        classColored = true, darkTheme = false,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.72,
        barBgR = 0.055, barBgG = 0.060, barBgB = 0.072, barBgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    swingTimer = {
        width = 249, height = 12, rowSpacing = 2,
        texture = "sm:MerfinMain",
        classColored = true,
        textSize = 11,
        hideWhenIdle = true,
        idleHidePerType = true,
        showSpark = true,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.86,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    castBar = {
        width = 229, height = 20, -- 229 + 20 图标 = 249px 与上方资源条像素级等宽
        texture = "sm:MerfinMain",
        classColored = true,
        gradientEnabled = false,
        useBlizzardStyle = false,
        useClassicStyle = false,
        showIconDivider = true,
        showSpark = true,
        spellTextSize = 12, timerSize = 12,
        showTotalDuration = false,
        latencyShowText = false,
        latencyR = 0.90, latencyG = 0.34, latencyB = 0.40, latencyA = 0.55,
        channelOverride = true, channelR = 0.37, channelG = 0.83, channelB = 0.65,
        uninterruptibleOverride = true, uninterruptibleR = 0.52, uninterruptibleG = 0.55, uninterruptibleB = 0.60,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.86,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
    gcdBar = {
        width = 249, height = 4,
        texture = "sm:MerfinMain",
        classColored = true,
        bgR = 0.055, bgG = 0.060, bgB = 0.072, bgA = 0.84,
        borderSize = 1, borderTexture = "solid",
        borderR = 0.14, borderG = 0.15, borderB = 0.18, borderA = 0.90,
    },
}

local function ApplyUnifiedResourceBars(forceApply)
    local db = mod:GetDB()
    if not (mod._active and db.unifyResourceBars ~= false) then return false end
    -- 版本号门控：首次升级至 v2 自动统一一次（修复此前 GetERB 取值为 nil 导致施法条未生效的问题）
    if not forceApply and db.erbUnifiedVersion == ERB_UNIFY_VERSION then return false end
    local prof, applyFn = GetERBProfileAndApply()
    if type(prof) ~= "table" then return false end

    F.RunOutOfCombat("FUI_UnifyResourceBars", function()
        if type(db.erbStyleBackup) ~= "table" then
            local snap = {}
            for sec, spec in pairs(ERB_UNIFY_PLAN) do
                if type(prof[sec]) == "table" then
                    local keys = {}
                    for k in pairs(spec) do keys[#keys + 1] = k end
                    snap[sec] = CopyStyleFields(prof[sec], keys)
                end
            end
            db.erbStyleBackup = snap
        end

        for sec, spec in pairs(ERB_UNIFY_PLAN) do
            prof[sec] = type(prof[sec]) == "table" and prof[sec] or {}
            for k, v in pairs(spec) do
                prof[sec][k] = v
            end
        end
        db.erbUnifiedApplied = true
        db.erbUnifiedVersion = ERB_UNIFY_VERSION

        if applyFn then
            pcall(applyFn)
        end
        if forceApply then
            F.Print("已统一资源条、挥砍计时器与施法条风格（249px 等宽 + 职业主题色 + 纤细 1px 暗灰边框，位置完全保留）。")
        end
    end)
    return true
end

local function RestoreResourceBarsStyle(notify)
    local db = mod:GetDB()
    local snap = db.erbStyleBackup
    local prof, applyFn = GetERBProfileAndApply()
    if type(snap) ~= "table" or type(prof) ~= "table" then
        if notify then F.Print("当前没有可还原的资源条样式备份。") end
        return
    end
    F.RunOutOfCombat("FUI_RestoreResourceBars", function()
        -- 按统一方案逐键还原：备份里原本为 nil 的键（pairs 遍历不到）也要写回 nil，
        -- 否则 249px 宽度 / solid 边框等会永久留在 EUI 配置里；备份时不存在的整段同理清回默认
        for sec, spec in pairs(ERB_UNIFY_PLAN) do
            local dst = prof[sec]
            if type(dst) == "table" then
                local fields = type(snap[sec]) == "table" and snap[sec] or {}
                for k in pairs(spec) do
                    dst[k] = fields[k]
                end
            end
        end
        db.erbStyleBackup = nil
        db.erbUnifiedApplied = false
        db.erbUnifiedVersion = 0
        if applyFn then
            pcall(applyFn)
        end
        if notify then
            F.Print("已还原你之前的资源条 / 挥砍计时器 / 施法条外观设置。")
        end
    end)
end

function mod:UnifyResourceBarsNow()
    self:GetDB().unifyResourceBars = true
    ApplyUnifiedResourceBars(true)
end

function mod:RestoreResourceBarsNow()
    self:GetDB().unifyResourceBars = false
    RestoreResourceBarsStyle(true)
end

----------------------------------------------------------------------
--  6) 补齐遗漏暴雪 HUD 现代化（退出载具 / 返回墓地 / 额外技能 / 呼吸条 / 耐久小人）
--     + 飞行计时器去重（EUI 极简细线 vs Polestar 黑影卡片）
----------------------------------------------------------------------
local hudSkins = setmetatable({}, { __mode = "k" })
local hudHooked = setmetatable({}, { __mode = "k" })
local euiFlightBarRef = nil
local vehFlightSuppressed = false

local function SetTextureAlpha(tex, alpha)
    if tex and tex.SetAlpha then
        tex:SetAlpha(alpha)
    end
end

local function SetVehicleStockAlpha(btn, alpha)
    if btn.GetNormalTexture then SetTextureAlpha(btn:GetNormalTexture(), alpha) end
    if btn.GetPushedTexture then SetTextureAlpha(btn:GetPushedTexture(), alpha) end
    if btn.GetHighlightTexture then SetTextureAlpha(btn:GetHighlightTexture(), alpha) end
    if btn.GetDisabledTexture then SetTextureAlpha(btn:GetDisabledTexture(), alpha) end
    for _, reg in ipairs({ btn:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" then
            SetTextureAlpha(reg, alpha)
        end
    end
end

local flightBarLastScan = 0

local function FindAndHookEUIFlightBar(onChange)
    if euiFlightBarRef and euiFlightBarRef.exit then
        return euiFlightBarRef
    end
    if not F.IsAddOnLoaded("EllesmereUIForeverEssentials") then return nil end
    -- EUI 飞行条在本次登录第一次飞行时才懒创建：未找到前，战斗中不扫，同一帧内的连发调用只扫一次整个 UIParent
    -- （起飞时 PLAYER_CONTROL_LOST 会在 0/0.15/0.55 秒补扫，节流必须短于这些间隔）
    if _G.InCombatLockdown and _G.InCombatLockdown() then return nil end
    local now = _G.GetTime and _G.GetTime() or 0
    if now - flightBarLastScan < 0.1 then return nil end
    flightBarLastScan = now
    local ui = _G.UIParent
    if not (ui and ui.GetChildren) then return nil end
    for _, ch in ipairs({ ui:GetChildren() }) do
        if ch and not (ch.IsForbidden and ch:IsForbidden())
            and ch.exit and ch.track and ch.clip and ch.you and ch.ends then
            euiFlightBarRef = ch
            if not hudHooked[ch] and ch.HookScript then
                hudHooked[ch] = true
                ch:HookScript("OnShow", onChange)
                ch:HookScript("OnHide", onChange)
            end
            if ch.exit and not hudHooked[ch.exit] and ch.exit.HookScript then
                hudHooked[ch.exit] = true
                ch.exit:HookScript("OnShow", onChange)
                ch.exit:HookScript("OnHide", onChange)
            end
            return ch
        end
    end
    return nil
end

local function ShouldHideVehicleLeaveForFlight(onChange)
    local euiDB = _G.EllesmereUIDB
    local ft = euiDB and euiDB.flightTimer
    if ft and (ft.enabled == false or ft.earlyExit == false) then
        return false
    end
    -- EUI 实时飞行条是 UIParent 直接子框体（设置页预览条不是），且仅在飞行路线中显示；
    -- 起飞瞬间 UnitOnTaxi 尚未变 true 时飞行条已出现，直接以其 .exit 可见为准避免起飞闪现重复按钮
    local fb = FindAndHookEUIFlightBar(onChange)
    return (fb and fb:IsShown() and fb.exit and fb.exit:IsShown()) == true
end

local function RestoreVehicleLeaveVisibility(btn)
    if not (btn and vehFlightSuppressed) then return end
    vehFlightSuppressed = false
    pcall(btn.SetAlpha, btn, 1)
    if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
        pcall(btn.EnableMouse, btn, true)
    else
        F.RunOutOfCombat("FUI_VehLeaveMouse", function()
            local b = _G.MainMenuBarVehicleLeaveButton
            if b and not vehFlightSuppressed then
                pcall(b.EnableMouse, b, true)
            end
        end)
    end
end

local function SkinVehicleLeaveButton()
    local db = mod:GetDB()
    local btn = _G.MainMenuBarVehicleLeaveButton
    if not btn then return end
    if not (mod._active and db.modernBlizzHUD ~= false) then
        RestoreVehicleLeaveVisibility(btn)
        local sk = hudSkins[btn]
        if sk then sk:Hide() end
        SetVehicleStockAlpha(btn, 1)
        return
    end

    -- 按钮未显示（绝大多数时间：变形/潜行/姿态切换、被控）时无需重绘玻璃皮肤，也无需扫描飞行条；
    -- 按钮的 OnShow 钩子会在真正出现时再走完整流程
    if hudHooked[btn] and hudSkins[btn] and not vehFlightSuppressed and not btn:IsShown() then
        return
    end

    local cr, cg, cb = 0.93, 0.36, 0.43 -- 现代珊瑚红退出语义

    -- 静音原版木纹方框与红色掉头箭头材质，绝不触碰点击安全链
    local function StripStockArt()
        if not (mod._active and mod:GetDB().modernBlizzHUD ~= false) then return end
        SetVehicleStockAlpha(btn, 0)
    end
    StripStockArt()

    local function SyncIconSize(sk)
        if not (sk and sk._icon) then return end
        local w = F.PlainNumber(btn:GetWidth(), 32)
        local h = F.PlainNumber(btn:GetHeight(), 32)
        local sz = math_max(14, math_min(28, math_floor(math_min(w, h) * 0.60 + 0.5)))
        sk._icon:SetSize(sz, sz)
    end

    local sk = hudSkins[btn]
    if not sk then
        sk = CreateFrame("Frame", nil, btn)
        sk:SetAllPoints(btn)
        sk:SetFrameLevel(math_max(0, (btn:GetFrameLevel() or 1) + 1))
        sk:EnableMouse(false)

        local icon = sk:CreateTexture(nil, "OVERLAY", nil, 4)
        icon:SetPoint("CENTER", sk, "CENTER", 0, 0)
        icon:SetTexture(F.Theme.ICONS .. "VehicleLeave.tga")
        icon:SetTexCoord(0, 1, 0, 1)
        sk._icon = icon

        hudSkins[btn] = sk
    end

    F.Theme.StyleGlassSurface(sk, {
        accent = { cr, cg, cb },
        bgAlpha = 0.93,
        borderAlpha = 0.92,
        restAura = 0.14,
        hoverAura = 0.34,
        borderTintMix = 0.24,
        hovered = btn.IsMouseOver and btn:IsMouseOver() or false,
    })
    SyncIconSize(sk)
    if btn.IsMouseOver and btn:IsMouseOver() then
        sk._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0)
    else
        sk._icon:SetVertexColor(0.97, 0.56, 0.61, 0.96)
    end

    -- 飞行坐骑期间若 EUI 飞行计时条已显示羽毛提前降落按钮，则无污染隐藏重复的暴雪退出载具按钮
    -- （真实载具/攻城车或飞行途中重载导致飞行条未显示时，仍自动保留本按钮）
    if ShouldHideVehicleLeaveForFlight(SkinVehicleLeaveButton) then
        vehFlightSuppressed = true
        pcall(btn.SetAlpha, btn, 0)
        sk:Hide()
        if not (_G.InCombatLockdown and _G.InCombatLockdown()) then
            pcall(btn.EnableMouse, btn, false)
        end
    else
        RestoreVehicleLeaveVisibility(btn)
        sk:Show()
    end

    if not hudHooked[btn] then
        hudHooked[btn] = true
        if btn.SetNormalTexture then
            _G.hooksecurefunc(btn, "SetNormalTexture", StripStockArt)
        end
        if btn.SetPushedTexture then
            _G.hooksecurefunc(btn, "SetPushedTexture", StripStockArt)
        end
        btn:HookScript("OnShow", function()
            SkinVehicleLeaveButton()
            C_Timer.After(0, SkinVehicleLeaveButton)
        end)
        btn:HookScript("OnSizeChanged", function()
            SyncIconSize(hudSkins[btn])
        end)
        btn:HookScript("OnEnter", function()
            if not (mod._active and mod:GetDB().modernBlizzHUD ~= false) then return end
            local s = hudSkins[btn]
            if not s then return end
            F.Theme.SetGlassState(s, true, false)
            if s._icon then s._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0) end
        end)
        btn:HookScript("OnLeave", function()
            local s = hudSkins[btn]
            if not s then return end
            F.Theme.SetGlassState(s, false, false)
            if s._icon then
                s._icon:ClearAllPoints()
                s._icon:SetPoint("CENTER", s, "CENTER", 0, 0)
                s._icon:SetVertexColor(0.97, 0.56, 0.61, 0.96)
            end
        end)
        btn:HookScript("OnMouseDown", function()
            local s = hudSkins[btn]
            if s and s._icon then
                s._icon:ClearAllPoints()
                s._icon:SetPoint("CENTER", s, "CENTER", 0, -1)
                s._icon:SetVertexColor(0.92, 0.72, 0.75, 0.95)
            end
        end)
        btn:HookScript("OnMouseUp", function()
            local s = hudSkins[btn]
            if s and s._icon then
                s._icon:ClearAllPoints()
                s._icon:SetPoint("CENTER", s, "CENTER", 0, 0)
                if btn.IsMouseOver and btn:IsMouseOver() then
                    s._icon:SetVertexColor(1.0, 0.84, 0.86, 1.0)
                else
                    s._icon:SetVertexColor(0.97, 0.56, 0.61, 0.96)
                end
            end
        end)
    end
end

local function SetGhostStockAlpha(gf, alpha)
    for _, name in ipairs({ "GhostFrameLeft", "GhostFrameMiddle", "GhostFrameRight" }) do
        SetTextureAlpha(_G[name], alpha)
    end
    for _, reg in ipairs({ gf:GetRegions() }) do
        if reg.GetObjectType and reg:GetObjectType() == "Texture" then
            SetTextureAlpha(reg, alpha)
        end
    end
end

local function SkinGhostFrame()
    local db = mod:GetDB()
    local gf = _G.GhostFrame
    if not gf then return end
    local stockIcon = _G.GhostFrameContentsFrameIcon
    if not (mod._active and db.modernBlizzHUD ~= false) then
        local sk = hudSkins[gf]
        if sk then sk:Hide() end
        SetGhostStockAlpha(gf, 1)
        SetTextureAlpha(stockIcon, 1)
        return
    end

    SetGhostStockAlpha(gf, 0)
    SetTextureAlpha(stockIcon, 0)
    local text = _G.GhostFrameContentsFrameText
    if text then
        F.Theme.ApplyFont(text, 12, "", 0.92, 0.96, 0.99, 1)
    end

    local sk = hudSkins[gf]
    if not sk then
        sk = CreateFrame("Frame", nil, gf)
        sk:SetAllPoints(gf)
        sk:SetFrameLevel(math_max(0, (gf:GetFrameLevel() or 1) - 1))
        sk:EnableMouse(false)

        local vecIcon = sk:CreateTexture(nil, "OVERLAY", nil, 4)
        vecIcon:SetSize(18, 18)
        if stockIcon then
            vecIcon:SetPoint("CENTER", stockIcon, "CENTER", 0, 0)
        else
            vecIcon:SetPoint("LEFT", sk, "LEFT", 10, 0)
        end
        vecIcon:SetTexture(F.Theme.ICONS .. "GhostReturn.tga")
        vecIcon:SetTexCoord(0, 1, 0, 1)
        sk._vecIcon = vecIcon

        hudSkins[gf] = sk
    end

    F.Theme.StyleGlassSurface(sk, {
        accent = { 0.46, 0.84, 0.98 },
        bgAlpha = 0.92,
        borderAlpha = 0.90,
        restAura = 0.14,
        hoverAura = 0.32,
        borderTintMix = 0.24,
        hovered = gf.IsMouseOver and gf:IsMouseOver() or false,
    })
    if sk._vecIcon then
        sk._vecIcon:SetVertexColor(0.58, 0.88, 1.0, 0.96)
    end
    sk:Show()

    if not hudHooked[gf] then
        hudHooked[gf] = true
        gf:HookScript("OnShow", function()
            if mod._active and mod:GetDB().modernBlizzHUD ~= false then
                SetGhostStockAlpha(gf, 0)
                SetTextureAlpha(_G.GhostFrameContentsFrameIcon, 0)
            end
        end)
        gf:HookScript("OnEnter", function()
            if not (mod._active and mod:GetDB().modernBlizzHUD ~= false) then return end
            local s = hudSkins[gf]
            if not s then return end
            F.Theme.SetGlassState(s, true, false)
            if s._vecIcon then s._vecIcon:SetVertexColor(0.88, 0.97, 1.0, 1.0) end
            local t = _G.GhostFrameContentsFrameText
            if t then t:SetTextColor(1, 1, 1, 1) end
        end)
        gf:HookScript("OnLeave", function()
            local s = hudSkins[gf]
            if not s then return end
            F.Theme.SetGlassState(s, false, false)
            if s._vecIcon then s._vecIcon:SetVertexColor(0.58, 0.88, 1.0, 0.96) end
            local t = _G.GhostFrameContentsFrameText
            if t then t:SetTextColor(0.92, 0.96, 0.99, 1) end
        end)
    end
end

local function StripZoneAbilityStyle()
    local db = mod:GetDB()
    local alpha = (mod._active and db.modernBlizzHUD ~= false) and 0 or 1
    local zf = _G.ZoneAbilityFrame
    if zf and zf.Style then
        SetTextureAlpha(zf.Style, alpha)
    end
    local eab = _G.ExtraActionButton1
    if eab and eab.style then
        SetTextureAlpha(eab.style, alpha)
    end
end

local function ApplyBlizzDurabilityVisibility()
    local df = _G.DurabilityFrame
    if not df then return end
    local wantHide = mod._active and (mod:GetDB().hideBlizzDurability ~= false)
    if not hudHooked[df] then
        hudHooked[df] = true
        df:HookScript("OnShow", function(self)
            if mod._active and mod:GetDB().hideBlizzDurability ~= false then
                self:SetAlpha(0)
            end
        end)
    end
    df:SetAlpha(wantHide and 0 or 1)
end

local function ApplyEUIBuiltinHUDSkinsOnce()
    local db = mod:GetDB()
    if not (mod._active and db.modernBlizzHUD ~= false) then return end
    if db.hudSkinSeeded then return end
    local euiDB = _G.EllesmereUIDB
    if type(euiDB) ~= "table" then return end
    db.hudSkinSeeded = true
    -- 补齐 EUI 内置但默认关闭的两项现代 HUD 皮肤：额外技能钮 + 呼吸/疲劳/假死条
    if euiDB.reskinExtraActionButton == nil then
        euiDB.reskinExtraActionButton = true
    end
    if euiDB.reskinTimerBars == nil then
        euiDB.reskinTimerBars = true
    end
    if euiDB.timerBarsBorderTexture == "pixels-textured" then
        euiDB.timerBarsBorderTexture = "solid"
    end
end

local function ApplyFlightTimerDedup()
    if not mod._active then return end
    local mode = mod:GetDB().flightTimerMode or "keep_eui"
    local pFrame = _G.PolestarFlightTimer
    local pDB = _G.PolestarDB
    local euiDB = _G.EllesmereUIDB

    if pFrame and not hudHooked[pFrame] then
        hudHooked[pFrame] = true
        pFrame:HookScript("OnShow", function(self)
            if mod._active and (mod:GetDB().flightTimerMode or "keep_eui") == "keep_eui" then
                self:Hide()
            end
        end)
    end

    local db = mod:GetDB()
    if mode == "keep_eui" then
        -- 关闭 Polestar 重复的黑影飞行卡片，保留下方极简细线 EUI 飞行条并同步职业色
        if type(pDB) == "table" and type(pDB.settings) == "table" then
            pDB.settings.maps = type(pDB.settings.maps) == "table" and pDB.settings.maps or {}
            if pDB.settings.maps.flightTimer ~= false then
                db.ftDisabledPolestar = true
            end
            pDB.settings.maps.flightTimer = false
        end
        if pFrame and pFrame:IsShown() then
            pFrame:Hide()
        end
        if type(euiDB) == "table" then
            euiDB.flightTimer = type(euiDB.flightTimer) == "table" and euiDB.flightTimer or {}
            euiDB.flightTimer.enabled = true
            db.ftDisabledEUI = nil
            -- 外观只预设一次，之后用户在 EUI 里改的材质/边框不再被每次刷新覆盖
            if not db.euiFlightStyleSeeded then
                db.euiFlightStyleSeeded = true
                euiDB.flightTimer.classColored = true
                euiDB.flightTimer.texture = "sm:MerfinMain"
                euiDB.flightTimer.borderSize = 1
                euiDB.flightTimer.borderTexture = "solid"
            end
        end
    elseif mode == "keep_polestar" then
        if type(pDB) == "table" and type(pDB.settings) == "table" then
            pDB.settings.maps = type(pDB.settings.maps) == "table" and pDB.settings.maps or {}
            pDB.settings.maps.flightTimer = true
            db.ftDisabledPolestar = nil
        end
        if type(euiDB) == "table" then
            euiDB.flightTimer = type(euiDB.flightTimer) == "table" and euiDB.flightTimer or {}
            if euiDB.flightTimer.enabled ~= false then
                db.ftDisabledEUI = true
            end
            euiDB.flightTimer.enabled = false
        end
    else
        -- 「不干预」：把此前由本模块关掉的那一方重新打开，其余保持用户自己的设置
        if db.ftDisabledPolestar and type(pDB) == "table" and type(pDB.settings) == "table"
            and type(pDB.settings.maps) == "table" then
            pDB.settings.maps.flightTimer = true
        end
        if db.ftDisabledEUI and type(euiDB) == "table" and type(euiDB.flightTimer) == "table" then
            euiDB.flightTimer.enabled = true
        end
        db.ftDisabledPolestar = nil
        db.ftDisabledEUI = nil
    end

    local ft = _G.EllesmereUI and _G.EllesmereUI._FlightTimer
    if type(ft) == "table" then
        if type(ft.Apply) == "function" then pcall(ft.Apply) end
        if type(ft.ApplyStyle) == "function" then pcall(ft.ApplyStyle) end
    end
end

-- 小地图/世界地图服务 NPC 去重：统一交由 Polestar 显示，自动关闭 Questie 重复城镇 NPC（完整保留 Questie 任务感叹号/问号）
local QUESTIE_TOWNSFOLK_KEYS = {
    "Flight Master", "Innkeeper", "Mailbox", "Meeting Stones", "Repair",
    "Class Trainer", "Banker", "Spirit Healer", "Battlemaster", "Weapon Master",
    "Auctioneer", "Stable Master", "Reagents", "Poisons", "Transmogrifier",
    "Arcane Reforger", "Barber", "Trade Goods", "Ammo", "Vendor",
}
local questieDedupSwept = false

local function ApplyQuestieTownsfolkDedup(forceFlush)
    if not (mod._active and mod:GetDB().dedupMinimapNPC ~= false) then return end
    if not (F.IsAddOnLoaded("Polestar") and F.IsAddOnLoaded("Questie")) then return end

    local pDB = _G.PolestarDB
    if type(pDB) == "table" and type(pDB.settings) == "table" then
        pDB.settings.maps = type(pDB.settings.maps) == "table" and pDB.settings.maps or {}
        if pDB.settings.maps.servicePins ~= true then
            pDB.settings.maps.servicePins = true
        end
        if pDB.settings.maps.serviceMinimap ~= true then
            pDB.settings.maps.serviceMinimap = true
        end
    end

    local q = _G.Questie
    local qProf = q and q.db and q.db.profile
    if type(qProf) ~= "table" then return end

    local changed = false
    if qProf.townsfolkKnownProfessions == true then
        qProf.townsfolkKnownProfessions = false
        changed = true
    end
    if type(qProf.townsfolkConfig) ~= "table" then
        qProf.townsfolkConfig = {}
        changed = true
    end
    local cfg = qProf.townsfolkConfig
    for k, v in pairs(cfg) do
        if v == true then
            cfg[k] = false
            changed = true
        end
    end
    for _, k in ipairs(QUESTIE_TOWNSFOLK_KEYS) do
        if cfg[k] ~= false then
            cfg[k] = false
            changed = true
        end
    end

    if (changed or forceFlush or not questieDedupSwept) and _G.QuestieLoader and _G.QuestieLoader.ImportModule then
        local okM, qMenu = pcall(_G.QuestieLoader.ImportModule, _G.QuestieLoader, "QuestieMenu")
        if okM and type(qMenu) == "table" then
            if type(qMenu.OnLogin) == "function" then
                -- Questie 登录后才异步初始化 townsfolk 表：早调用会报错，失败时不标记，留给下一次刷新重试
                local okSweep = pcall(qMenu.OnLogin, qMenu, true)
                if okSweep then questieDedupSwept = true end
            end
            if type(qMenu.RefreshKnownProfessionTrainers) == "function" then
                pcall(qMenu.RefreshKnownProfessionTrainers)
            end
        end
    end
end

----------------------------------------------------------------------
--  7) 高清矢量宠物快乐度图标（替换模糊 2004 低分辨率 UI-PetHappiness 图集，
--     完整保留 EUI 点击喂食菜单与提示） + 伤害统计「队伍总伤」清晰文案
----------------------------------------------------------------------
local PET_HAPPY_ICONS = {
    ["UI-PetHappiness"] = F.MEDIA .. "Icons\\PetHappy.tga",
    ["UI-PetNeutral"]   = F.MEDIA .. "Icons\\PetNeutral.tga",
    ["UI-PetMad"]       = F.MEDIA .. "Icons\\PetMad.tga",
}
local petHappyHooked = false
local petHappyFrameHooked = setmetatable({}, { __mode = "k" })

local function ApplyHDPetHappyTo(h)
    if not (h and h._tex) then return end
    if not (mod._active and mod:GetDB().hdPetHappy ~= false) then
        if h._atlas and h._tex.SetAtlas then
            pcall(h._tex.SetAtlas, h._tex, h._atlas)
        end
        return
    end
    local texPath = h._atlas and PET_HAPPY_ICONS[h._atlas]
    if not texPath and _G.C_PetInfo and _G.C_PetInfo.GetPetHappiness then
        local lv = F.PlainNumber(_G.C_PetInfo.GetPetHappiness(), nil)
        texPath = (lv == 3 and PET_HAPPY_ICONS["UI-PetHappiness"])
            or (lv == 2 and PET_HAPPY_ICONS["UI-PetNeutral"])
            or (lv == 1 and PET_HAPPY_ICONS["UI-PetMad"])
            or nil
    end
    if texPath then
        h._tex:SetTexCoord(0, 1, 0, 1)
        h._tex:SetTexture(texPath)
    end
end

local function RefreshHDPetHappiness()
    local EUI = _G.EllesmereUI
    local ufNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIUnitFrames
    if not ufNS then return end
    if not petHappyHooked then
        petHappyHooked = true
        if type(ufNS.UF_RefreshPetHappiness) == "function" then
            _G.hooksecurefunc(ufNS, "UF_RefreshPetHappiness", ApplyHDPetHappyTo)
        end
        if type(ufNS.UF_ApplyPetHappiness) == "function" then
            _G.hooksecurefunc(ufNS, "UF_ApplyPetHappiness", function()
                local pf = ufNS._internals and ufNS._internals.frames and ufNS._internals.frames.pet
                local h = pf and pf._petHappy
                if h then
                    if not petHappyFrameHooked[h] and h.HookScript then
                        petHappyFrameHooked[h] = true
                        h:HookScript("OnEvent", ApplyHDPetHappyTo)
                        h:HookScript("OnShow", ApplyHDPetHappyTo)
                    end
                    ApplyHDPetHappyTo(h)
                end
            end)
        end
    end
    local pf = ufNS._internals and ufNS._internals.frames and ufNS._internals.frames.pet
    local h = pf and pf._petHappy
    if h then
        if not petHappyFrameHooked[h] and h.HookScript then
            petHappyFrameHooked[h] = true
            h:HookScript("OnEvent", ApplyHDPetHappyTo)
            h:HookScript("OnShow", ApplyHDPetHappyTo)
        end
        ApplyHDPetHappyTo(h)
    end
end

local HookDamageMeterTotal, RestoreDMTotalLabels
do
    local dmHookedFS = setmetatable({}, { __mode = "k" })
    local rewritingDM = false

    local dmRewritten = setmetatable({}, { __mode = "k" })
    local dmHeaderOf = setmetatable({}, { __mode = "k" })

    local function DMLabelWanted()
        return mod._active and mod:GetDB().partyDamageLabel ~= false
    end

    -- 仅当该窗口标题是「造成伤害 / 每秒伤害」时才改名；治疗、吸收、受到伤害等保持 EUI 原样「总计」
    local function IsDamageDoneHeader(header, skipFS)
        if not (header and header.GetRegions) then return false end
        for _, reg in ipairs({ header:GetRegions() }) do
            if reg ~= skipFS and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                local t = F.PlainString(reg:GetText(), nil)
                if t and (t:find("造成伤害", 1, true) or t:find("每秒伤害", 1, true)) then
                    return true
                end
            end
        end
        return false
    end

    local function FormatDMTotalText(raw, header, fs)
        if type(raw) ~= "string" then return nil end
        local num = raw:match("^总计%s+(.+)$")
        if not num then return nil end
        if not IsDamageDoneHeader(header, fs) then return nil end
        if _G.IsInGroup and _G.IsInGroup() then
            return "队伍总伤 " .. num
        end
        return "总伤害 " .. num
    end

    local function RewriteDMTotal(fs, text)
        local clean = F.PlainString(text, nil)
        local repl = clean and FormatDMTotalText(clean, dmHeaderOf[fs], fs)
        if repl and repl ~= clean then
            rewritingDM = true
            pcall(fs.SetText, fs, repl)
            rewritingDM = false
            dmRewritten[fs] = true
        end
    end

    -- 关闭选项/停用模块时把已改写的文字还原成 EUI 原文「总计」
    RestoreDMTotalLabels = function()
        for fs in pairs(dmRewritten) do
            local t = F.PlainString(fs:GetText(), nil)
            local num = t and (t:match("^队伍总伤%s+(.+)$") or t:match("^总伤害%s+(.+)$"))
            if num then
                rewritingDM = true
                pcall(fs.SetText, fs, "总计 " .. num)
                rewritingDM = false
            end
            dmRewritten[fs] = nil
        end
    end

    -- EUI 伤害统计窗口全局名为 EllesmereUIDMFrame1..N（EDM_Win 只是解锁模式的键名，并非全局框体）。
    -- 标题栏子框带 _hdrBg 字段；登录时合计文字往往还是空串，所以对标题栏全部 FontString 预先挂钩，
    -- 在 SetText 时再判断是否为「总计 xxx」。
    HookDamageMeterTotal = function()
        if not DMLabelWanted() then
            RestoreDMTotalLabels()
            return
        end
        for idx = 1, 3 do
            local win = _G["EllesmereUIDMFrame" .. idx] or _G["EDM_Win" .. idx]
            if win and not (win.IsForbidden and win:IsForbidden()) and win.GetChildren then
                for _, header in ipairs({ win:GetChildren() }) do
                    if header and not (header.IsForbidden and header:IsForbidden()) and header._hdrBg ~= nil and header.GetRegions then
                        for _, reg in ipairs({ header:GetRegions() }) do
                            if reg.GetObjectType and reg:GetObjectType() == "FontString" then
                                dmHeaderOf[reg] = header
                                if not dmHookedFS[reg] then
                                    dmHookedFS[reg] = true
                                    _G.hooksecurefunc(reg, "SetText", function(self, newText)
                                        if rewritingDM or not DMLabelWanted() then return end
                                        RewriteDMTotal(self, newText)
                                    end)
                                end
                                RewriteDMTotal(reg, reg:GetText())
                            end
                        end
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
--  8) 训练师 / 猎人野兽训练智能过滤 + 行内文字防重叠排版修复
--     • 使用暴雪官方 SetTrainerServiceTypeFilter，零污染、绝不破坏点击训练索引
--     • 彻底移除登录/打开前抢先预置过滤（避免造成 C++ 过滤标记与野兽训练首开列表脱节）
--     • 同一次打开合并多事件（TRAINER_SHOW / ADDON_LOADED / OnShow）防定时回调互杀，
--       并结合 TRAINER_UPDATE + 多拍复核确认列表中真正清除「已学会/暂不可学」后才结束；
--       严格限制单次打开最多写入 3 次 + 重入锁，玩家手动点「过滤器」立刻放手
--     • 排版修复在 0s + 0.08s 双拍生效，确保在 EUI 首次皮肤防抖后仍保持行内不重叠
----------------------------------------------------------------------
local trainerHooked = false
local trainerScrollHooked = false
local trainerDropdownHooked = false
local trainerOpenGen = 0
local trainerDoneGen = 0
local trainerUserTouchedGen = 0
local trainerAttemptsForGen = 0
local trainerCyclingGen = 0
local trainerSessionActive = false
local applyingTrainerFilter = false
local polishTrainerQueued = false

local function FixTrainerRowLayout(row)
    if not (row and mod._active) then return end
    if row.IsForbidden and row:IsForbidden() then return end

    local nameFS = row.name
    local subFS = row.subText
    local icon = row.icon
    local money = row.money
    local rightBadge = nil
    if money and money.IsShown and money:IsShown() then
        rightBadge = money
    elseif row.cost and row.cost.IsShown and row.cost:IsShown() then
        rightBadge = row.cost
    end

    -- 统一技能名、等级后缀（「（等级 X）」）与训练点数的字体与字号（避免 EUI 仅换 row.name 字体导致大小不齐）
    local fontFace = F.Theme.GetFont()
    local topSize, topFlags = 13, ""
    if nameFS and nameFS.GetFont then
        local okF, fPath, fSize, fFlags = pcall(nameFS.GetFont, nameFS)
        if okF then
            if type(fPath) == "string" and fPath ~= "" and (not fontFace or fontFace == "") then
                fontFace = fPath
            end
            local parsed = F.PlainNumber(fSize, nil)
            if parsed and parsed >= 10 and parsed <= 18 then
                topSize = math_floor(parsed + 0.5)
            end
            if type(fFlags) == "string" then
                topFlags = fFlags
            end
        end
    end
    if fontFace and fontFace ~= "" then
        if nameFS and nameFS.SetFont then
            pcall(nameFS.SetFont, nameFS, fontFace, topSize, topFlags)
        end
        if row.GetRegions then
            for _, reg in ipairs({ row:GetRegions() }) do
                if reg and reg ~= subFS and reg ~= nameFS
                    and reg.GetObjectType and reg:GetObjectType() == "FontString"
                    and reg.SetFont then
                    pcall(reg.SetFont, reg, fontFace, topSize, topFlags)
                end
            end
        end
    end

    -- 价格框 / 训练点数对齐至行右上角，给下方需求文字腾出整行宽度
    if rightBadge and rightBadge.ClearAllPoints then
        pcall(rightBadge.ClearAllPoints, rightBadge)
        pcall(rightBadge.SetPoint, rightBadge, "TOPRIGHT", row, "TOPRIGHT", -6, -5)
    end

    if subFS and subFS.ClearAllPoints then
        local face = (fontFace and fontFace ~= "") and fontFace or (subFS.GetFont and subFS:GetFont())
        if face and face ~= "" then
            pcall(subFS.SetFont, subFS, face, 11, "")
        end
        if subFS.SetJustifyH then pcall(subFS.SetJustifyH, subFS, "LEFT") end
        if subFS.SetJustifyV then pcall(subFS.SetJustifyV, subFS, "TOP") end
        if subFS.SetWordWrap then pcall(subFS.SetWordWrap, subFS, false) end
        if subFS.SetMaxLines then pcall(subFS.SetMaxLines, subFS, 1) end
        pcall(subFS.ClearAllPoints, subFS)
        if icon then
            pcall(subFS.SetPoint, subFS, "TOPLEFT", icon, "TOPRIGHT", 8, -22)
        elseif nameFS then
            pcall(subFS.SetPoint, subFS, "TOPLEFT", nameFS, "BOTTOMLEFT", 0, -4)
        else
            pcall(subFS.SetPoint, subFS, "TOPLEFT", row, "TOPLEFT", 46, -22)
        end
        -- 需求行横跨整行右侧（位于价格下方），彻底告别折行压字与裁切
        pcall(subFS.SetPoint, subFS, "RIGHT", row, "RIGHT", -6, 0)
    end
end

local function PolishTrainerRows()
    local ctf = _G.ClassTrainerFrame
    if not (ctf and ctf:IsShown() and ctf.ScrollBox and ctf.ScrollBox.ForEachFrame) then return end
    pcall(ctf.ScrollBox.ForEachFrame, ctf.ScrollBox, FixTrainerRowLayout)
end

local function QueuePolishTrainerRows()
    if polishTrainerQueued or not mod._active then return end
    polishTrainerQueued = true
    C_Timer.After(0, function()
        polishTrainerQueued = false
        PolishTrainerRows()
        -- 兜底复刷一拍：避免首次加载 Blizzard_TrainerUI 时 EUI WSkin.Debounce 晚一帧覆盖行内字体
        C_Timer.After(0.08, PolishTrainerRows)
    end)
end

local function IsFilterFlagOn(v)
    return v == true or v == 1
end

local function ExtractServiceCategory(i)
    if not _G.GetTrainerServiceInfo then return nil end
    local ok, _, r2, r3, r4 = pcall(_G.GetTrainerServiceInfo, i)
    if not ok then return nil end
    if r2 == "available" or r2 == "unavailable" or r2 == "used" then
        return r2
    end
    if r3 == "available" or r3 == "unavailable" or r3 == "used" then
        return r3
    end
    if r4 == "available" or r4 == "unavailable" or r4 == "used" then
        return r4
    end
    return nil
end

local function ScanTrainerServices(wantHideUsed, wantHideUnavail)
    local numSvc = _G.GetNumTrainerServices and F.PlainNumber(_G.GetNumTrainerServices(), 0) or 0
    local hasUsed, hasUnavail = false, false
    if numSvc > 0 then
        for i = 1, numSvc do
            local cat = ExtractServiceCategory(i)
            if wantHideUsed and cat == "used" then
                hasUsed = true
            elseif wantHideUnavail and cat == "unavailable" then
                hasUnavail = true
            end
            if (not wantHideUsed or hasUsed) and (not wantHideUnavail or hasUnavail) then
                break
            end
        end
    end
    return numSvc, hasUsed, hasUnavail
end

local function ApplyFilterFinal(ctf, wantHideUsed, wantHideUnavail)
    applyingTrainerFilter = true
    pcall(function()
        _G.SetTrainerServiceTypeFilter("available", true)
        if wantHideUsed then _G.SetTrainerServiceTypeFilter("used", false) end
        if wantHideUnavail then _G.SetTrainerServiceTypeFilter("unavailable", false) end
        if _G.ClassTrainerFrame_Update then
            _G.ClassTrainerFrame_Update()
        elseif ctf and ctf.Update then
            ctf:Update()
        end
        if ctf and ctf.FilterDropdown and ctf.FilterDropdown.Update then
            ctf.FilterDropdown:Update()
        end
        if ctf and ctf.ScrollBox and ctf.ScrollBox.ScrollToBegin then
            ctf.ScrollBox:ScrollToBegin()
        end
    end)
    applyingTrainerFilter = false
    QueuePolishTrainerRows()
end

local function ResetTrainerSession()
    -- 递增代次号，让关闭窗口前排下的 0.08~0.55 秒补刷定时器全部作废
    trainerOpenGen = trainerOpenGen + 1
    trainerSessionActive = false
    trainerDoneGen = 0
    trainerAttemptsForGen = 0
    trainerUserTouchedGen = 0
    trainerCyclingGen = 0
end

local function ApplyTrainerFilterForOpen(gen, reason)
    if applyingTrainerFilter or not mod._active then return end
    if gen ~= trainerOpenGen then return end
    if trainerDoneGen == gen or trainerUserTouchedGen == gen or trainerCyclingGen == gen then return end
    if trainerAttemptsForGen >= 3 then
        trainerDoneGen = gen
        return
    end

    local db = mod:GetDB()
    local wantHideUsed = db.trainerHideUsed ~= false
    local wantHideUnavail = db.trainerHideUnavailable ~= false
    if not wantHideUsed and not wantHideUnavail then
        trainerDoneGen = gen
        return
    end
    if not _G.SetTrainerServiceTypeFilter then return end

    local ctf = _G.ClassTrainerFrame
    if not (ctf and ctf:IsShown()) then return end

    local getFilter = _G.GetTrainerServiceTypeFilter
    local curAvail = getFilter and IsFilterFlagOn(getFilter("available"))
    local curUsed = getFilter and IsFilterFlagOn(getFilter("used"))
    local curUnavail = getFilter and IsFilterFlagOn(getFilter("unavailable"))

    local numSvc, hasUsed, hasUnavail = ScanTrainerServices(wantHideUsed, wantHideUnavail)

    local flagNeedsFix = (getFilter == nil)
        or (not curAvail)
        or (wantHideUsed and curUsed)
        or (wantHideUnavail and curUnavail)
    local staleRows = (hasUsed or hasUnavail)

    -- 尚未收到服务列表且过滤标志已就位：等待 TRAINER_UPDATE 或后续拍次，不提前锁死 trainerDoneGen
    if (not flagNeedsFix) and (not staleRows) then
        if reason == "verify" or reason == "late" or (numSvc > 0 and reason == "delay") then
            trainerDoneGen = gen
        end
        QueuePolishTrainerRows()
        return
    end

    -- 关键防卡死保护：严格递增尝试计数并置重入锁
    trainerAttemptsForGen = trainerAttemptsForGen + 1

    if flagNeedsFix then
        ApplyFilterFinal(ctf, wantHideUsed, wantHideUnavail)
        -- 延迟 0.10s 真正复核列表（等待 C++ 引擎/服务器重建列表），而非当帧盲目锁死 done
        C_Timer.After(0.10, function()
            if trainerOpenGen == gen and trainerDoneGen ~= gen and trainerUserTouchedGen ~= gen then
                ApplyTrainerFilterForOpen(gen, "verify")
            end
        end)
        return
    end

    -- C++ 过滤标记已是 false，但列表里仍存在「已学会 / 暂不可学」残留行（野兽训练首次打开常见现象）：
    -- 跨帧先置 true 并刷新，0.08s 后再置 false 并刷新，随后 0.12s 复核确保彻底清空
    trainerCyclingGen = gen
    applyingTrainerFilter = true
    pcall(function()
        if wantHideUsed then _G.SetTrainerServiceTypeFilter("used", true) end
        if wantHideUnavail then _G.SetTrainerServiceTypeFilter("unavailable", true) end
        if _G.ClassTrainerFrame_Update then
            _G.ClassTrainerFrame_Update()
        end
    end)
    applyingTrainerFilter = false

    C_Timer.After(0.08, function()
        if trainerCyclingGen == gen then
            trainerCyclingGen = 0
        end
        if not mod._active or gen ~= trainerOpenGen or trainerUserTouchedGen == gen then return end
        local curCtf = _G.ClassTrainerFrame
        if not (curCtf and curCtf:IsShown()) then return end
        ApplyFilterFinal(curCtf, wantHideUsed, wantHideUnavail)
        C_Timer.After(0.12, function()
            if trainerOpenGen == gen and trainerDoneGen ~= gen and trainerUserTouchedGen ~= gen then
                ApplyTrainerFilterForOpen(gen, "verify")
            end
        end)
    end)
end

F.DumpTrainerDebug = function()
    local ctf = _G.ClassTrainerFrame
    local gf = _G.GetTrainerServiceTypeFilter
    local tt = _G.C_Trainer and _G.C_Trainer.GetTrainerType and _G.C_Trainer.GetTrainerType()
    local n, hu, hun = ScanTrainerServices(true, true)
    F.Print(string_format("TrainerDebug: shown=%s active=%s gen=%d/%d att=%d type=%s n=%d usedRow=%s unavailRow=%s | fAvail=%s fUsed=%s fUnavail=%s",
        tostring(ctf and ctf:IsShown() or false), tostring(trainerSessionActive),
        trainerOpenGen, trainerDoneGen, trainerAttemptsForGen,
        tostring(tt), n, tostring(hu), tostring(hun),
        tostring(gf and gf("available")), tostring(gf and gf("used")), tostring(gf and gf("unavailable"))))
    if _G.GetTrainerServiceInfo and n > 0 then
        for i = 1, math_min(n, 6) do
            local r1, r2, r3, r4 = _G.GetTrainerServiceInfo(i)
            F.Print(string_format("  [%d] r1=%s r2=%s r3=%s r4=%s", i, tostring(r1), tostring(r2), tostring(r3), tostring(r4)))
        end
    end
end

local function BeginTrainerOpenSession()
    if applyingTrainerFilter or not mod._active then return end
    -- 同一次打开内合并 TRAINER_SHOW / ADDON_LOADED / OnShow 多事件，避免递增 gen 误杀正在执行的跨帧翻转定时器
    if trainerSessionActive then
        QueuePolishTrainerRows()
        return
    end
    trainerSessionActive = true
    trainerOpenGen = trainerOpenGen + 1
    trainerDoneGen = 0
    trainerUserTouchedGen = 0
    trainerAttemptsForGen = 0
    trainerCyclingGen = 0
    local gen = trainerOpenGen
    -- 多拍覆盖首开 LoD 加载与网络包延迟：0s / 0.12s / 0.30s / 0.55s（任一拍确认干净即锁 done 跳过后续）
    C_Timer.After(0, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "open")
        end
    end)
    C_Timer.After(0.12, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "open2")
        end
    end)
    C_Timer.After(0.30, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "delay")
        end
    end)
    C_Timer.After(0.55, function()
        if trainerOpenGen == gen and trainerDoneGen ~= gen then
            ApplyTrainerFilterForOpen(gen, "late")
        end
    end)
end

local function HookTrainerFrameIfReady()
    local ctf = _G.ClassTrainerFrame
    if not ctf then return false end
    local newlyHooked = false
    if not trainerHooked and ctf.HookScript then
        trainerHooked = true
        newlyHooked = true
        ctf:HookScript("OnShow", BeginTrainerOpenSession)
        ctf:HookScript("OnHide", ResetTrainerSession)
        if _G.ClassTrainerFrame_Update then
            _G.hooksecurefunc("ClassTrainerFrame_Update", QueuePolishTrainerRows)
        end
    end
    if ctf.FilterDropdown and not trainerDropdownHooked and ctf.FilterDropdown.HookScript then
        trainerDropdownHooked = true
        ctf.FilterDropdown:HookScript("OnMouseDown", function()
            -- 玩家手动点击「过滤器」时立即停止本次自动干预，绝不抢回选项
            trainerUserTouchedGen = trainerOpenGen
            trainerDoneGen = trainerOpenGen
        end)
    end
    if ctf.ScrollBox and not trainerScrollHooked and type(ctf.ScrollBox.Update) == "function" then
        trainerScrollHooked = true
        _G.hooksecurefunc(ctf.ScrollBox, "Update", QueuePolishTrainerRows)
    end
    return newlyHooked
end

----------------------------------------------------------------------
--  9) 战斗飘字智能分级与自由调节（仅影响战斗数字/飘字，绝不改其他 UI 字体）
--     • 3D 头顶打怪伤害/击杀经验：同步 WorldTextScale_v2 / WorldTextScale（默认 0.85 收敛近景过大）
--     • 2D 滚动战斗文字（Blizzard_CombatText）：纯 hooksecurefunc 零污染分级
--         - 自身受伤数字（物理红 / 法术紫红）：自动放大至 incomingDamageSize（默认 34px）
--         - 2D 经验 / 声望 / 荣誉提示：自动缩至 combatXPSize（默认 15px）
--         - 治疗 / 触发等其余提示：保持清晰适中 22px
----------------------------------------------------------------------
local ApplyWorldTextScale, RestoreWorldTextScale, HookCombatTextSizing
do
    local combatTextHooked = false

    local function GetCVarSafe(name)
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

    local function SetCVarSafe(name, val)
        if GetCVarSafe(name) == nil then return false end
        local want = tostring(val)
        if GetCVarSafe(name) == want then return true end
        local CV = _G.C_CVar
        if CV and CV.SetCVar then
            return (pcall(CV.SetCVar, name, want)) == true
        elseif _G.SetCVar then
            return (pcall(_G.SetCVar, name, want)) == true
        end
        return false
    end

    ApplyWorldTextScale = function()
        local db = mod:GetDB()
        if not (mod._active and db.smartCombatText ~= false) then return end
        local scale = F.PlainNumber(db.worldTextScale, 1.00)
        scale = math_max(0.50, math_min(2.00, math_floor(scale * 100 + 0.5) / 100))
        F.RunOutOfCombat("FUI_WorldTextScale", function()
            if not (mod._active and mod:GetDB().smartCombatText ~= false) then return end
            local curDB = mod:GetDB()
            if type(curDB.savedWorldTextScale) ~= "table" then
                local snap = {}
                for _, cv in ipairs({ "WorldTextScale_v2", "WorldTextScale", "floatingCombatTextCombatDamageDirectionalScale_v2" }) do
                    local orig = GetCVarSafe(cv)
                    if orig ~= nil then snap[cv] = orig end
                end
                curDB.savedWorldTextScale = snap
            elseif curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2 == nil then
                local origArc = GetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2")
                if origArc ~= nil then
                    curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2 = origArc
                end
            end
            SetCVarSafe("WorldTextScale_v2", scale)
            SetCVarSafe("WorldTextScale", scale)
            local arcMode = curDB.damageArcMode or "keep"
            if arcMode == "classic" then
                SetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2", 0)
            elseif arcMode == "compact" then
                SetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2", 1)
            elseif arcMode == "keep" and curDB.savedWorldTextScale
                and curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2 ~= nil then
                SetCVarSafe("floatingCombatTextCombatDamageDirectionalScale_v2", curDB.savedWorldTextScale.floatingCombatTextCombatDamageDirectionalScale_v2)
            end
        end)
    end

    RestoreWorldTextScale = function()
        F.RunOutOfCombat("FUI_WorldTextScale", function()
            local db = mod:GetDB()
            if type(db.savedWorldTextScale) == "table" then
                for cv, orig in pairs(db.savedWorldTextScale) do
                    if orig ~= nil then SetCVarSafe(cv, orig) end
                end
                db.savedWorldTextScale = nil
            end
        end)
    end

    local function FindLatestCombatTextFS(plain)
        local animList = _G.COMBAT_TEXT_TO_ANIMATE
        if type(animList) == "table" and #animList > 0 then
            local last = animList[#animList]
            if last and not (last.IsForbidden and last:IsForbidden()) and last.SetTextHeight then
                return last
            end
        end
        local maxLines = F.PlainNumber(_G.NUM_COMBAT_TEXT_LINES, 20)
        -- 优先精确匹配同帧刚写入的文本，避免同帧多条飘字误改前一条的字号
        if plain and plain ~= "" then
            for i = maxLines, 1, -1 do
                local cand = _G["CombatText" .. i]
                if cand and not (cand.IsForbidden and cand:IsForbidden()) and cand:IsShown() and cand.SetTextHeight then
                    local st = F.PlainNumber(cand.scrollTime, 999)
                    if st <= 0.05 and cand.GetText then
                        local okT, txt = pcall(cand.GetText, cand)
                        if okT and F.PlainString(txt, nil) == plain then
                            return cand
                        end
                    end
                end
            end
        end
        local bestFS, bestTime = nil, 999
        for i = 1, maxLines do
            local cand = _G["CombatText" .. i]
            if cand and not (cand.IsForbidden and cand:IsForbidden()) and cand:IsShown() and cand.SetTextHeight then
                local st = F.PlainNumber(cand.scrollTime, 999)
                if st < bestTime then
                    bestTime = st
                    bestFS = cand
                end
            end
        end
        return bestFS
    end

    local function OnCombatTextAddMessage(message, _, r, g, b, displayType)
        if not (mod._active and mod:GetDB().smartCombatText ~= false) then return end
        local plain = F.PlainString(message, nil)
        local fs = FindLatestCombatTextFS(plain)
        if not fs then return end

        -- 暴雪对 crit 会在 CombatText_OnUpdate 每帧动态插值 SetTextHeight，
        -- 强行写入一次高度会导致首帧尺寸闪跳，此处交由暴雪原生暴击弹跳动画处理
        if F.PlainString(displayType, nil) == "crit" then
            return
        end

        local db = mod:GetDB()
        local rn = F.PlainNumber(r, nil)
        local gn = F.PlainNumber(g, nil)
        local bn = F.PlainNumber(b, nil)

        -- 1) 识别 2D 经验 / 声望 / 荣誉提示（优先识别，避免被紫色法伤误判）
        local isXPOrMisc = false
        if plain then
            local low = plain:lower()
            if plain:find("经验", 1, true) or plain:find("声望", 1, true) or plain:find("荣誉", 1, true)
                or low:find("xp", 1, true) or low:find("reputation", 1, true) or low:find("honor", 1, true) then
                isXPOrMisc = true
            end
        end
        if not isXPOrMisc and rn and gn and bn and rn <= 0.22 and gn <= 0.22 and bn >= 0.88 then
            isXPOrMisc = true
        end

        -- 2) 识别角色自身受到的伤害（物理红 1/0.1/0.1、法术紫红 0.79/0.3/0.85、负伤害数字）
        --    当文本可读（非 12.x 保密值）时必须包含数字，防止把红字「<进入战斗> / 生命值过低」误放大成 34px
        local isIncomingDmg = false
        if not isXPOrMisc then
            local hasDigits = (plain == nil) or (plain:find("%d") ~= nil)
            local isPhysRed = hasDigits and rn and gn and bn and rn >= 0.88 and gn <= 0.28 and bn <= 0.28
            local isSpellMag = hasDigits and rn and gn and bn
                and math_abs(rn - 0.79) <= 0.08 and math_abs(gn - 0.30) <= 0.08 and math_abs(bn - 0.85) <= 0.08
            local isNegNum = plain and plain:find("^%-?%d") and rn and rn >= 0.68 and gn and gn <= 0.45
            if isPhysRed or isSpellMag or isNegNum then
                isIncomingDmg = true
            end
        end

        local targetSize
        if isXPOrMisc then
            targetSize = math_max(10, math_min(26, F.PlainNumber(db.combatXPSize, 15)))
        elseif isIncomingDmg then
            targetSize = math_max(20, math_min(48, F.PlainNumber(db.incomingDamageSize, 34)))
        else
            targetSize = 22
        end
        pcall(fs.SetTextHeight, fs, targetSize)
    end

    local function OnCombatTextAddMessageSafe(message, scrollFunction, r, g, b, displayType)
        pcall(OnCombatTextAddMessage, message, scrollFunction, r, g, b, displayType)
    end

    HookCombatTextSizing = function()
        if combatTextHooked then return end
        if type(_G.CombatText_AddMessage) == "function" then
            combatTextHooked = true
            _G.hooksecurefunc("CombatText_AddMessage", OnCombatTextAddMessageSafe)
        end
    end
end

----------------------------------------------------------------------
--  10) 无限服「世界刷新」倒计时提示框美化、去重、居中与无拖影淡入
--      • 同时探测紧凑版（「世界会在X分钟后刷新」）与完整版（「你周围的世界会在…」）
--      • 若暴雪同时在聊框上方再弹第二个重复原版横幅，自动静音去重只保留主卡片
--      • 停用暴雪原版平移动画 + 合并定位防抖，彻底消除出现时的拖影，改用纯 Alpha 丝滑淡入
--      • 左侧原生红框黄箭头按钮美化为内嵌现代琥珀刷新钮（完整保留原生点击功能）
--      • 正文严格水平/垂直居中，Shift+左键拖动自动记忆位置，全弱表零污染
----------------------------------------------------------------------
local RefreshWorldRefreshBanner, StopWorldRefreshTicker, EnsureWorldRefreshTicker
do
    local wrSkin = setmetatable({}, { __mode = "k" })
    local wrHooked = setmetatable({}, { __mode = "k" })
    local wrBtnSkin = setmetatable({}, { __mode = "k" })
    local wrBtnHooked = setmetatable({}, { __mode = "k" })
    local wrBtnOrigPt = setmetatable({}, { __mode = "k" })
    local wrOrigFS = setmetatable({}, { __mode = "k" })
    local wrPosQueued = setmetatable({}, { __mode = "k" })
    local wrKnown = setmetatable({}, { __mode = "k" })
    local wrSuppressed = setmetatable({}, { __mode = "k" })
    local wrList = {}
    local wrPrimary = nil
    local wrMoving = false
    local wrDragging = false
    local wrTicker = nil

    local SKIP_PREFIXES = {
        "ForeverUI", "Ellesmere", "Polestar", "Questie", "BigWigs",
        "ChatFrame", "ActionBar", "MultiBar", "GameTooltip", "WorldMap",
        "CharacterFrame", "SpellBook", "FriendsFrame", "BugSack", "WorldFrame",
        "ContainerFrame", "PlayerFrame", "TargetFrame", "Minimap", "BuffFrame", "DebuffFrame",
    }

    local function IsSafeReadableFrame(f)
        if not f then return false end
        if f.IsForbidden then
            local okF, forb = pcall(f.IsForbidden, f)
            if not okF or forb then return false end
        end
        if f.GetWidth then
            local okW, w = pcall(f.GetWidth, f)
            if not okW or F.IsSecret(w) then return false end
        end
        return true
    end

    local function IsFrameShownSafe(f)
        if not IsSafeReadableFrame(f) or not f.IsShown then return false end
        local ok, shown = pcall(f.IsShown, f)
        return ok and shown == true
    end

    local function ShouldSkipFrame(f)
        if not IsSafeReadableFrame(f) then return true end
        if f.GetFrameStrata then
            local okS, strata = pcall(f.GetFrameStrata, f)
            if okS and F.PlainString(strata, nil) == "TOOLTIP" then
                return true
            end
        end
        if f._brd and f.bg and f.text then
            return true
        end
        if f.GetName then
            local okN, raw = pcall(f.GetName, f)
            local nm = okN and F.PlainString(raw, nil) or nil
            if nm then
                for _, p in ipairs(SKIP_PREFIXES) do
                    if nm:sub(1, #p) == p then return true end
                end
            end
        end
        return false
    end

    local function IsWorldRefreshText(txt)
        if type(txt) ~= "string" or txt == "" then return false end
        if txt:find("默认灰框", 1, true) or txt:find("将无限服", 1, true)
            or txt:find("提示框统一", 1, true) or txt:find("Shift+左键", 1, true) then
            return false
        end
        if txt:find("世界会在", 1, true)
            and (txt:find("刷新", 1, true) or txt:find("分钟", 1, true) or txt:find("秒", 1, true)) then
            return true
        end
        if txt:find("周围的世界", 1, true) and txt:find("刷新", 1, true) then
            return true
        end
        local low = txt:lower()
        return low:find("world around you will refresh", 1, true) ~= nil
            or (low:find("world will refresh", 1, true) ~= nil)
    end

    local function SearchRefreshInFrame(f, depth)
        if not IsSafeReadableFrame(f) or depth > 3 then return nil, nil end
        if f.GetRegions then
            local okR, regions = pcall(function() return { f:GetRegions() } end)
            if okR and type(regions) == "table" then
                for _, reg in ipairs(regions) do
                    if reg and not (reg.IsForbidden and reg:IsForbidden()) and reg.GetObjectType then
                        local okT, ot = pcall(reg.GetObjectType, reg)
                        if okT and ot == "FontString" and reg.GetText then
                            local okS, rawTxt = pcall(reg.GetText, reg)
                            local t = okS and F.PlainString(rawTxt, nil) or nil
                            if IsWorldRefreshText(t) then
                                return f, reg
                            end
                        end
                    end
                end
            end
        end
        if depth < 3 and f.GetChildren then
            local okC, children = pcall(function() return { f:GetChildren() } end)
            if okC and type(children) == "table" then
                for _, ch in ipairs(children) do
                    if IsFrameShownSafe(ch) then
                        local hitF, hitFS = SearchRefreshInFrame(ch, depth + 1)
                        if hitF then return hitF, hitFS end
                    end
                end
            end
        end
        return nil, nil
    end

    local function ResolveOuterBanner(hitF)
        local cur = hitF
        for _ = 1, 3 do
            local okP, p = pcall(function() return cur and cur.GetParent and cur:GetParent() end)
            if not okP or not p or p == _G.UIParent or p == _G.WorldFrame or not IsSafeReadableFrame(p) then
                break
            end
            local okW, rawW = pcall(p.GetWidth, p)
            local okH, rawH = pcall(p.GetHeight, p)
            local pw = okW and F.PlainNumber(rawW, 9999) or 9999
            local ph = okH and F.PlainNumber(rawH, 9999) or 9999
            if pw > 600 or ph > 220 or pw < 80 or ph < 24 then
                break
            end
            cur = p
        end
        return cur
    end

    -- 停掉暴雪自带的滑入/缩放/闪光 AnimationGroup，彻底消除出现时的残影与拖影
    local function StopBannerNativeAnims(f, depth)
        if not IsSafeReadableFrame(f) or (depth or 0) > 2 then return end
        if f.GetAnimationGroups then
            local okA, groups = pcall(function() return { f:GetAnimationGroups() } end)
            if okA and type(groups) == "table" then
                for _, ag in ipairs(groups) do
                    if ag and not ag._fuiFade and ag.IsPlaying and ag:IsPlaying() and ag.Stop then
                        pcall(ag.Stop, ag)
                    end
                end
            end
        end
        if (depth or 0) < 2 and f.GetChildren then
            local okC, children = pcall(function() return { f:GetChildren() } end)
            if okC and type(children) == "table" then
                for _, ch in ipairs(children) do
                    if ch and ch ~= wrSkin[f] and ch ~= wrBtnSkin[f] then
                        StopBannerNativeAnims(ch, (depth or 0) + 1)
                    end
                end
            end
        end
    end

    local function IsSmallActionButton(ch)
        if not IsSafeReadableFrame(ch) then return false end
        local okT, ot = pcall(ch.GetObjectType, ch)
        if not (okT and ot == "Button") then return false end
        local w = F.PlainNumber(ch.GetWidth and ch:GetWidth(), 0)
        local h = F.PlainNumber(ch.GetHeight and ch:GetHeight(), 0)
        return w >= 16 and w <= 48 and h >= 16 and h <= 48 and math_abs(w - h) <= 10
    end

    local function MuteButtonStockTextures(btn, alpha)
        for _, getter in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetHighlightTexture", "GetDisabledTexture" }) do
            local fn = btn[getter]
            local t = fn and fn(btn)
            if t and t.SetAlpha then pcall(t.SetAlpha, t, alpha) end
        end
        if btn.GetRegions then
            for _, reg in ipairs({ btn:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg.SetAlpha then
                    pcall(reg.SetAlpha, reg, alpha)
                end
            end
        end
    end

    local function SkinBannerLeftButton(btn, box, want)
        if not IsSafeReadableFrame(btn) then return end
        local canMoveBtn = not (btn.IsProtected and btn:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown())
        if not want then
            local sk = wrBtnSkin[btn]
            if sk then sk:Hide() end
            MuteButtonStockTextures(btn, 1)
            -- 还原被内收到卡片左内侧的原生按钮锚点
            local o = wrBtnOrigPt[btn]
            if o and canMoveBtn then
                pcall(btn.ClearAllPoints, btn)
                pcall(btn.SetPoint, btn, o[1], o[2], o[3], o[4], o[5])
                wrBtnOrigPt[btn] = nil
            end
            return
        end
        MuteButtonStockTextures(btn, 0)
        local sk = wrBtnSkin[btn]
        if not sk then
            sk = CreateFrame("Frame", nil, btn)
            sk:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
            sk:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
            sk:SetFrameLevel((btn:GetFrameLevel() or 2) + 2)
            sk:EnableMouse(false)

            local ic = sk:CreateTexture(nil, "OVERLAY", nil, 4)
            ic:SetSize(14, 14)
            ic:SetPoint("CENTER", sk, "CENTER", 0, 0)
            ic:SetTexture(F.Theme.ICONS .. "Refresh.tga")
            ic:SetTexCoord(0, 1, 0, 1)
            sk._icon = ic
            wrBtnSkin[btn] = sk
        end
        F.Theme.StyleGlassSurface(sk, {
            accent = { 0.96, 0.76, 0.30 },
            bgAlpha = 0.88,
            borderAlpha = 0.85,
            restAura = 0.14,
            hoverAura = 0.34,
            borderTintMix = 0.30,
            hovered = btn.IsMouseOver and btn:IsMouseOver() or false,
        })
        if sk._icon then
            sk._icon:SetVertexColor(0.98, 0.82, 0.38, 0.96)
        end
        -- 将原本突出在左框外的红底按钮齐整内收至卡片左内侧
        if box and canMoveBtn then
            if not wrBtnOrigPt[btn] then
                local okP, p1, rel, p2, ox, oy = pcall(btn.GetPoint, btn, 1)
                p1, p2 = okP and F.PlainString(p1, nil), okP and F.PlainString(p2, nil)
                ox, oy = okP and F.PlainNumber(ox, nil), okP and F.PlainNumber(oy, nil)
                if p1 and ox and oy then
                    wrBtnOrigPt[btn] = { p1, rel, p2 or p1, ox, oy }
                end
            end
            pcall(btn.ClearAllPoints, btn)
            pcall(btn.SetPoint, btn, "LEFT", box, "LEFT", 10, 0)
        end
        sk:Show()
        if not wrBtnHooked[btn] then
            wrBtnHooked[btn] = true
            if btn.HookScript then
                btn:HookScript("OnShow", function(self)
                    if mod._active and mod:GetDB().skinWorldRefresh ~= false then
                        MuteButtonStockTextures(self, 0)
                    end
                end)
                btn:HookScript("OnEnter", function(self)
                    local s = wrBtnSkin[self]
                    if s and mod._active and mod:GetDB().skinWorldRefresh ~= false then
                        F.Theme.SetGlassState(s, true, false)
                        if s._icon then s._icon:SetVertexColor(1, 0.92, 0.65, 1) end
                    end
                end)
                btn:HookScript("OnLeave", function(self)
                    local s = wrBtnSkin[self]
                    if s then
                        F.Theme.SetGlassState(s, false, false)
                        if s._icon then s._icon:SetVertexColor(0.98, 0.82, 0.38, 0.96) end
                    end
                end)
            end
        end
    end

    local function MuteNativeBannerArt(box, alpha, depth)
        if not IsSafeReadableFrame(box) or (depth or 0) > 2 then return end
        if box.NineSlice and box.NineSlice.SetAlpha then
            pcall(box.NineSlice.SetAlpha, box.NineSlice, alpha)
        end
        if box.SetBackdropColor then
            pcall(box.SetBackdropColor, box, 0, 0, 0, alpha == 0 and 0 or 0.85)
        end
        if box.SetBackdropBorderColor then
            pcall(box.SetBackdropBorderColor, box, 0.5, 0.5, 0.5, alpha == 0 and 0 or 1)
        end
        for _, field in ipairs({ "Border", "Bg", "Background", "Center", "TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Glow", "Shine" }) do
            local part = box[field]
            if part and part.SetAlpha then pcall(part.SetAlpha, part, alpha) end
        end
        if box.GetRegions then
            for _, reg in ipairs({ box:GetRegions() }) do
                if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" and reg.SetAlpha then
                    pcall(reg.SetAlpha, reg, alpha)
                end
            end
        end
        if (depth or 0) < 2 and box.GetChildren then
            for _, ch in ipairs({ box:GetChildren() }) do
                if ch and ch ~= wrSkin[box] and ch ~= wrBtnSkin[box] and not IsSmallActionButton(ch) then
                    MuteNativeBannerArt(ch, alpha, (depth or 0) + 1)
                end
            end
        end
    end

    local function StyleBannerFontsAndButtons(box, want)
        local hasLeftBtn = false
        local mainFS = {}

        local function walk(f, depth)
            if not IsSafeReadableFrame(f) or depth > 2 then return end
            if f.GetRegions then
                for _, reg in ipairs({ f:GetRegions() }) do
                    if reg and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                        if want then
                            F.Theme.ApplyFont(reg, 13, "", 0.88, 0.94, 1.0, 1)
                            if reg.SetSpacing then pcall(reg.SetSpacing, reg, 3) end
                            if reg.SetJustifyH then pcall(reg.SetJustifyH, reg, "CENTER") end
                            if reg.SetJustifyV then pcall(reg.SetJustifyV, reg, "MIDDLE") end
                            mainFS[#mainFS + 1] = reg
                        elseif wrOrigFS[reg] then
                            local o = wrOrigFS[reg]
                            pcall(reg.ClearAllPoints, reg)
                            pcall(reg.SetPoint, reg, o[1], o[2], o[3], o[4], o[5])
                            if reg.SetJustifyH and o[6] then pcall(reg.SetJustifyH, reg, o[6]) end
                        end
                    end
                end
            end
            if depth < 2 and f.GetChildren then
                for _, ch in ipairs({ f:GetChildren() }) do
                    if ch and ch ~= wrSkin[box] and ch ~= wrBtnSkin[f] then
                        if IsSmallActionButton(ch) then
                            hasLeftBtn = true
                            SkinBannerLeftButton(ch, box, want)
                        else
                            walk(ch, depth + 1)
                        end
                    end
                end
            end
        end
        walk(box, 0)

        -- 真正居中排版：清除原版左偏锚点，左右对称留白使标题在玻璃卡片正中显示
        if want and #mainFS > 0 then
            local sidePad = hasLeftBtn and 42 or 16
            for _, fs in ipairs(mainFS) do
                if not wrOrigFS[fs] and fs.GetPoint then
                    local okP, pt, rel, rpt, x, y = pcall(fs.GetPoint, fs, 1)
                    local jh = fs.GetJustifyH and F.PlainString(fs:GetJustifyH(), "LEFT") or "LEFT"
                    if okP and pt then
                        wrOrigFS[fs] = { pt, rel, rpt, F.PlainNumber(x, 0), F.PlainNumber(y, 0), jh }
                    end
                end
                pcall(fs.ClearAllPoints, fs)
                pcall(fs.SetPoint, fs, "LEFT", box, "LEFT", sidePad, 0)
                pcall(fs.SetPoint, fs, "RIGHT", box, "RIGHT", -sidePad, 0)
                if fs.SetJustifyH then pcall(fs.SetJustifyH, fs, "CENTER") end
                if fs.SetJustifyV then pcall(fs.SetJustifyV, fs, "MIDDLE") end
            end
        end
    end

    local function PositionWorldRefresh(box)
        if not IsSafeReadableFrame(box) then return end
        if not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then return end
        if wrSuppressed[box] then return end
        F.RunOutOfCombat("FUI_MoveWorldRefresh", function()
            if not IsSafeReadableFrame(box) or wrSuppressed[box] then return end
            if not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then return end
            local saved = F.DB and F.DB.GetPosition and F.DB.GetPosition("WorldRefresh")
            local pt = (saved and saved.point) or "TOP"
            local rpt = (saved and saved.relPoint) or pt
            local x = (saved and saved.x) or 0
            local y = (saved and saved.y) or -96
            -- 已在目标坐标 ±1.5px 内则不再重复 ClearAllPoints/SetPoint，杜绝布局抖动与拖影
            if box.GetPoint then
                local okP, cpt, crel, crpt, cx, cy = pcall(box.GetPoint, box, 1)
                cx = okP and F.PlainNumber(cx, nil) or nil
                cy = okP and F.PlainNumber(cy, nil) or nil
                if okP and cpt == pt and crel == _G.UIParent and crpt == rpt
                    and cx and cy and math_abs(cx - x) <= 1.5 and math_abs(cy - y) <= 1.5 then
                    return
                end
            end
            wrMoving = true
            pcall(box.ClearAllPoints, box)
            pcall(box.SetPoint, box, pt, _G.UIParent, rpt, x, y)
            wrMoving = false
        end)
    end

    -- EnableMouse 在受保护框体上战斗中会触发 ADDON_ACTION_BLOCKED（pcall 也挡不住报告），一律延后到脱战
    local function SetBannerMouse(dup, enabled)
        if not dup.EnableMouse then return end
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            F.RunOutOfCombat("FUI_WRMouse_" .. tostring(dup), function()
                if IsSafeReadableFrame(dup) and (wrSuppressed[dup] == true) ~= enabled then
                    pcall(dup.EnableMouse, dup, enabled)
                end
            end)
        else
            pcall(dup.EnableMouse, dup, enabled)
        end
    end

    local function SilenceDuplicateBanner(dup, silent)
        if not IsSafeReadableFrame(dup) then return end
        wrSuppressed[dup] = silent and true or nil
        if silent then
            StopBannerNativeAnims(dup, 0)
            pcall(dup.SetAlpha, dup, 0)
            SetBannerMouse(dup, false)
            local ov = wrSkin[dup]
            if ov then ov:Hide() end
        else
            pcall(dup.SetAlpha, dup, 1)
            SetBannerMouse(dup, true)
        end
    end

    local function ApplySkinToBanner(box, playFadeIn)
        if not IsSafeReadableFrame(box) then return end
        local want = mod._active and (mod:GetDB().skinWorldRefresh ~= false)
        if not want then
            SilenceDuplicateBanner(box, false)
            local ov = wrSkin[box]
            if ov then ov:Hide() end
            MuteNativeBannerArt(box, 1, 0)
            StyleBannerFontsAndButtons(box, false)
            return
        end

        StopBannerNativeAnims(box, 0)
        MuteNativeBannerArt(box, 0, 0)
        StyleBannerFontsAndButtons(box, true)

        local ov = wrSkin[box]
        if not ov then
            ov = CreateFrame("Frame", nil, box)
            ov:SetAllPoints(box)
            local lvl = F.PlainNumber(box:GetFrameLevel(), 2)
            ov:SetFrameLevel(math_max(0, lvl - 1))
            ov:EnableMouse(false)

            local tipTag = ov:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(tipTag, 9, "OUTLINE", 0.76, 0.80, 0.88, 0.88)
            tipTag:SetPoint("TOP", ov, "BOTTOM", 7, -3)
            tipTag:SetText("Shift+左键拖动位置 · 左键点击立即刷新")
            ov._tipTag = tipTag

            local refIcon = ov:CreateTexture(nil, "OVERLAY", nil, 4)
            refIcon:SetSize(11, 11)
            refIcon:SetPoint("RIGHT", tipTag, "LEFT", -3, 0)
            refIcon:SetTexture(F.Theme.ICONS .. "Refresh.tga")
            refIcon:SetTexCoord(0, 1, 0, 1)
            ov._refIcon = refIcon

            wrSkin[box] = ov
        end

        F.Theme.StyleGlassSurface(ov, {
            accent = { 0.95, 0.74, 0.28 },
            bgAlpha = 0.92,
            borderAlpha = 0.90,
            restAura = 0.11,
            hoverAura = 0.26,
            borderTintMix = 0.24,
            hovered = box.IsMouseOver and box:IsMouseOver() or false,
        })
        if ov._refIcon then
            ov._refIcon:SetVertexColor(0.95, 0.76, 0.34, 0.90)
        end
        ov:Show()

        if not wrHooked[box] then
            wrHooked[box] = true
            if box.HookScript then
                box:HookScript("OnShow", function(self)
                    if wrSuppressed[self] then
                        SilenceDuplicateBanner(self, true)
                        return
                    end
                    ApplySkinToBanner(self, true)
                end)
                box:HookScript("OnEnter", function(self)
                    local s = wrSkin[self]
                    if s and mod._active and mod:GetDB().skinWorldRefresh ~= false then
                        F.Theme.SetGlassState(s, true, false)
                        if s._refIcon then s._refIcon:SetVertexColor(1.0, 0.88, 0.56, 1.0) end
                    end
                end)
                box:HookScript("OnLeave", function(self)
                    local s = wrSkin[self]
                    if s then
                        F.Theme.SetGlassState(s, false, false)
                        if s._refIcon then s._refIcon:SetVertexColor(0.95, 0.76, 0.34, 0.90) end
                    end
                end)
            end
            if box.SetPoint then
                _G.hooksecurefunc(box, "SetPoint", function(self)
                    if wrMoving or wrDragging or wrSuppressed[self] or wrPosQueued[self]
                        or not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then
                        return
                    end
                    wrPosQueued[self] = true
                    C_Timer.After(0, function()
                        wrPosQueued[self] = nil
                        if not wrDragging and not wrSuppressed[self] and IsFrameShownSafe(self) then
                            StopBannerNativeAnims(self, 0)
                            PositionWorldRefresh(self)
                        end
                    end)
                end)
            end
            F.RunOutOfCombat("FUI_DragWorldRefresh", function()
                if not IsSafeReadableFrame(box) then return end
                pcall(box.SetMovable, box, true)
                pcall(box.SetClampedToScreen, box, true)
                pcall(box.RegisterForDrag, box, "LeftButton")
                if box.HookScript then
                    box:HookScript("OnDragStart", function(self)
                        if not (mod._active and mod:GetDB().skinWorldRefresh ~= false) then return end
                        if _G.IsShiftKeyDown() and not (_G.InCombatLockdown and _G.InCombatLockdown()) then
                            wrDragging = true
                            pcall(self.StartMoving, self)
                        end
                    end)
                    box:HookScript("OnDragStop", function(self)
                        -- 未按 Shift 的普通拖动也会触发 OnDragStop：只处理本模块发起的拖动，否则会误存坐标
                        if not wrDragging then return end
                        wrDragging = false
                        pcall(self.StopMovingOrSizing, self)
                        local pt, _, rpt, x, y = self:GetPoint(1)
                        -- SavePosition 内部过滤 12.x 机密值与非法锚点
                        if F.DB and F.DB.SavePosition then
                            F.DB.SavePosition("WorldRefresh", pt, rpt, x, y)
                        end
                    end)
                end
            end)
        end

        PositionWorldRefresh(box)
        if playFadeIn then
            pcall(box.SetAlpha, box, 0)
            F.Theme.FadeTo(box, 1.0, 0.22)
        end
    end

    local function ReconcileBanners()
        local want = mod._active and (mod:GetDB().skinWorldRefresh ~= false)
        if not want then
            for _, b in ipairs(wrList) do
                ApplySkinToBanner(b, false)
            end
            wrPrimary = nil
            return
        end
        local shownList = {}
        for _, b in ipairs(wrList) do
            if IsFrameShownSafe(b) then
                shownList[#shownList + 1] = b
            end
        end
        if #shownList == 0 then
            wrPrimary = nil
            return
        end
        -- 多个刷新框同时出现时（例如顶部主条 + 聊框上方暴雪原版横幅），只保留一个主卡片，静音重复原版框
        local chosen = (wrPrimary and IsFrameShownSafe(wrPrimary)) and wrPrimary or shownList[1]
        wrPrimary = chosen
        for _, b in ipairs(shownList) do
            if b == chosen then
                if wrSuppressed[b] then SilenceDuplicateBanner(b, false) end
                ApplySkinToBanner(b, false)
            else
                SilenceDuplicateBanner(b, true)
            end
        end
    end

    local function RefreshWorldRefreshBannerInner()
        local want = mod._active and (mod:GetDB().skinWorldRefresh ~= false)
        if not want then
            ReconcileBanners()
            return
        end
        -- 战斗中或副本/战场内不遍历 UIParent 子框体，零团本 CPU 抖动
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        if _G.IsInInstance then
            local inInst, iType = _G.IsInInstance()
            if inInst and (iType == "raid" or iType == "party" or iType == "pvp" or iType == "arena") then
                return
            end
        end
        local ui = _G.UIParent
        if ui and ui.GetChildren then
            local okC, children = pcall(function() return { ui:GetChildren() } end)
            if okC and type(children) == "table" then
                for _, ch in ipairs(children) do
                    if not wrKnown[ch] and not ShouldSkipFrame(ch) and IsFrameShownSafe(ch) then
                        local okW, rw = pcall(ch.GetWidth, ch)
                        local okH, rh = pcall(ch.GetHeight, ch)
                        local cw = okW and F.PlainNumber(rw, 0) or 0
                        local chH = okH and F.PlainNumber(rh, 0) or 0
                        -- 仅对尺寸接近横幅/容器的框体向下扫描，跳过大面积全屏/微距装饰框以杜绝每几秒的 Lua 表垃圾分配
                        if cw >= 120 and cw <= 720 and chH >= 24 and chH <= 260 then
                            local hitF = SearchRefreshInFrame(ch, 0)
                            if hitF then
                                local outer = ResolveOuterBanner(hitF)
                                if outer and not wrKnown[outer] then
                                    wrKnown[outer] = true
                                    wrList[#wrList + 1] = outer
                                end
                            end
                        end
                    end
                end
            end
        end
        ReconcileBanners()
    end

    RefreshWorldRefreshBanner = function()
        pcall(RefreshWorldRefreshBannerInner)
    end

    EnsureWorldRefreshTicker = function()
        if wrTicker then return end
        if C_Timer and C_Timer.NewTicker then
            -- 平时已靠 CHAT_MSG_SYSTEM / UI_INFO_MESSAGE 毫秒级触发，后台兜底改为 15 秒极轻量巡检（零卡顿）
            wrTicker = C_Timer.NewTicker(15.0, RefreshWorldRefreshBanner)
        end
    end

    StopWorldRefreshTicker = function()
        if wrTicker then
            wrTicker:Cancel()
            wrTicker = nil
        end
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
    pcall(HookDamageMeterTotal)
    pcall(HookTrainerFrameIfReady)
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

function mod:OnDisable()
    bootRefreshGen = bootRefreshGen + 1
    StopWorldRefreshTicker()
    RestoreWorldTextScale()
    if F.ApplyDamageFont then
        F.ApplyDamageFont("default", true)
    end
    RestoreDMTotalLabels()
    RestoreFittedAuraTimers()
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
    self:RegisterEvent("TRAINER_UPDATE", function()
        if applyingTrainerFilter then return end
        HookTrainerFrameIfReady()
        local ctf = _G.ClassTrainerFrame
        if ctf and ctf:IsShown() and not trainerSessionActive then
            BeginTrainerOpenSession()
        elseif trainerOpenGen > 0 and trainerDoneGen ~= trainerOpenGen and trainerUserTouchedGen ~= trainerOpenGen then
            local gen = trainerOpenGen
            C_Timer.After(0, function()
                if trainerOpenGen == gen and trainerDoneGen ~= gen then
                    ApplyTrainerFilterForOpen(gen, "update")
                end
            end)
        end
        QueuePolishTrainerRows()
    end)
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
        end
    end)
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
    self:RegisterEvent("GROUP_ROSTER_UPDATE", HookDamageMeterTotal)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, _, isInitialLogin, isReloadingUi)
        pcall(SetupCharacterBars)
        pcall(ApplyWorldTextScale)
        pcall(QueueAuraFit)
        pcall(ApplyUnifiedResourceBars, false)
        RefreshAllModernHUD()
        ScheduleBootRefresh(true)
        -- 冲突诊断弹窗与 Questie 城镇 NPC 全量去重只在登录/重载时跑一次，过传送门、副本读条不再重复
        if isInitialLogin or isReloadingUi then
            C_Timer.After(4, function()
                if mod._active then RunConflictDiagnostics() end
            end)
            C_Timer.After(5.5, function()
                if mod._active then pcall(ApplyQuestieTownsfolkDedup, true) end
            end)
        end
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
    pcall(ApplyUnifiedResourceBars, false)
    ScheduleBootRefresh(false)
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

    _, h = W:DualRow(parent, y, {
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
    }, {
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
    })
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
        text = "伤害统计显示「队伍总伤」标签",
        tooltip = "EUI 伤害统计总计本身即汇总全队/全团伤害；开启后组队时清晰标为「队伍总伤」。",
        getValue = function() return db.partyDamageLabel ~= false end,
        setValue = function(v) db.partyDamageLabel = v == true; HookDamageMeterTotal() end,
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
        tooltip = "同步美化 BugSack，并在检测到冷却管理器与 ArcAuras 同时开启时弹窗询问停用。",
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
    }, {
        type = "slider",
        text = "角色属性栏字号（右侧防御/抗性等）",
        tooltip = "EUI 角色面板右侧属性栏原版硬编码 10px 偏小，默认优化为清晰 12px，可实时在 10–14px 间微调。",
        min = 10, max = 14, step = 1,
        getValue = function() return db.charStatFontSize or 12 end,
        setValue = function(v)
            db.charStatFontSize = math_floor(v + 0.5)
            PolishCharacterStatsFontSize()
        end,
    })
    y = y - h
    return y
end

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
        title = "姓名板与主城减卡优化",
        desc = "压制 EUI 强制开启友方玩家名，支持主城自动隐藏或全局隐藏友方玩家 ID（大幅缓解主城卡顿），并可选统一远处 NPC 原生文字。",
        group = "visual",
        order = 15,
        defaults = {
            enabled = true,
            friendlyMode = "city_hide",     -- "city_hide" | "instance_only" | "always_hide" | "keep"
            hideGuildTitle = true,          -- 隐藏友方玩家 ID 时同步隐藏公会/头衔
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

    local function SafeSetCVar(name, value)
        local cur = SafeGetCVar(name)
        if cur == nil then return false end
        local want = tostring(value)
        if cur == want then return true end
        local CV = _G.C_CVar
        if CV and CV.SetCVar then
            return pcall(CV.SetCVar, name, want)
        elseif _G.SetCVar then
            return pcall(_G.SetCVar, name, want)
        end
        return false
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

        if shouldHide then
            db.savedFriendly = SnapshotCVars(db.savedFriendly, FRIENDLY_NAME_CVARS)
            if db.hideGuildTitle ~= false then
                db.savedFriendly = SnapshotCVars(db.savedFriendly, FRIENDLY_EXTRA_CVARS)
            end
            for _, name in ipairs(FRIENDLY_NAME_CVARS) do
                SafeSetCVar(name, "0")
            end
            if db.hideGuildTitle ~= false then
                for _, name in ipairs(FRIENDLY_EXTRA_CVARS) do
                    SafeSetCVar(name, "0")
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
                SafeSetCVar(name, "0")
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
        ApplyAll()
        F.Print("友方玩家 ID 策略已切换为：|cff5fd3a6" .. (MODE_LABELS[target] or target) .. "|r")
    end

    function npMod:OnEnable()
        local QueueApply = F.Debounce(0.25, ApplyAll)
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
            ApplyAll()
            C_Timer.After(0.6, ApplyAll)
            C_Timer.After(2.0, ApplyAll)
            C_Timer.After(3.5, ApplyAll)
            C_Timer.After(1.0, HookEUIHideOnce)
        end)
        self:RegisterEvent("PLAYER_UPDATE_RESTING", ApplyAll)
        self:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
            ApplyAll()
            C_Timer.After(1.0, ApplyAll)
        end)
        -- 战斗中被推迟的 ApplyAll 已由 F.RunOutOfCombat 在 PLAYER_REGEN_ENABLED 统一补跑，无需每次脱战再查一遍 CVar
        self:RegisterEvent("CVAR_UPDATE", function(_, _, cvar)
            -- EUI 友方姓名板模块也会改写 nameplateShowFriends / 友方 NPC 姓名板；本模块自身写回不会再改值，防抖后至多空跑一次
            if WATCHED_NP_CVARS[cvar] then
                QueueApply()
            end
        end)

        ApplyAll()
        C_Timer.After(0.6, ApplyAll)
        C_Timer.After(1.0, HookEUIHideOnce)
        C_Timer.After(2.0, ApplyAll)
    end

    function npMod:OnDisable()
        RestoreAll()
    end

    function npMod:BuildOptions(W, parent, y, enableSlot, blank)
        local db = self:GetDB()
        local _, h
        _, h = W:DualRow(parent, y, enableSlot, {
            type = "dropdown",
            text = "友方玩家 ID 隐藏策略",
            tooltip = "压制 EUI 强制重开友方玩家名，显著缓解主城卡顿。\n聊天框输入 /fui friendly 可一键切换模式。",
            values = {
                city_hide     = "主城/休整区自动隐藏（推荐）",
                instance_only = "仅副本内显示（主城+野外隐藏）",
                always_hide   = "全局彻底隐藏友方 ID",
                keep          = "不干预（交由游戏与 EUI）",
            },
            order = { "city_hide", "instance_only", "always_hide", "keep" },
            getValue = function() return db.friendlyMode or "city_hide" end,
            setValue = function(v) db.friendlyMode = v; ApplyAll() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "同步隐藏友方公会与头衔",
            tooltip = "隐藏友方玩家 ID 时一并关闭公会与头衔渲染，主城帧数提升更明显。",
            getValue = function() return db.hideGuildTitle ~= false end,
            setValue = function(v) db.hideGuildTitle = v == true; ApplyAll() end,
        }, {
            type = "toggle",
            text = "主城同时隐藏友方 NPC 姓名板",
            tooltip = "在主城/休整区临时隐藏卫兵、商人等友方 NPC 姓名板以换取最高帧数（离开主城自动恢复）。",
            getValue = function() return db.hideCityNpcPlates == true end,
            setValue = function(v) db.hideCityNpcPlates = v == true; ApplyAll() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "dropdown",
            text = "45 码外原生 NPC 名称",
            tooltip = "无限服引擎将姓名板最远距离硬锁在 45 码。\n关闭远处原生 NPC 名称可彻底统一视觉（全部由 45 码内 EUI 姓名板呈现）。",
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
