----------------------------------------------------------------------
--  kkowoUI — Modules/ModernChrome.lua
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
    desc = "统一职业主题色、角色面板声望/技能/PvP 精致美化、高清宠物快乐度图标、施法条风格统一。",
    group = "theme",
    order = 10,
    defaults = {
        enabled = true,
        flatCharBars = true,
        charFramePolish = true,
        charStatFontSize = 13,          -- 角色面板右侧属性栏字号（EUI 默认硬编码 10px 偏小，默认提至 13px，支持 11-16 调节）
        v4CharStatSizeMigrated = false,
        cleanCharSheet = true,          -- 重设计角色属性面板（去除遮挡人物的绿字堆叠、装等归位槽内、右侧升级装等/耐久卡片与清爽大号属性列表）
        centerModelControls = true,     -- 角色 3D 模型控制按钮仅在鼠标移入中间人物区域时显示，滑过装备栏绝不闪烁
        harmonyFontGuard = true,        -- 鸿蒙字体全界面防顶部裁切与垂直居中修正（角色/技能/声望/任务/邮件/商人等）
        hdPetHappy = true,
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
        dedupWorldMapCoords = true,   -- 与 Polestar 共存时自动隐藏 Leatrix_Maps / 暴雪重复的世界地图底部坐标，保留 Polestar 单套清晰坐标栏
        muteAttackGrunts = true,      -- 静音角色射箭/攻击时的「啊/哈」发声（仅静音角色战斗发声，不影响拉弓/技能音效与 NPC 语音）
        muteBowPullback = false,      -- 可选：同时静音拉弓吱嘎声
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
        local statSz = math_max(11, math_min(16, F.PlainNumber(db.charStatFontSize, 13)))
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
                if not (mod._active and mod:GetDB().expandFriends) and friendsOrigH and ff then
                    ff:SetHeight(friendsOrigH)
                    friendsOrigH = nil
                end
            end)
        end
        return
    end
    F.RunOutOfCombat("FUI_ExpandFriends", function()
        if not (mod._active and mod:GetDB().expandFriends) then return end
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
--  4) EUI 冲突一键「停用并重载」弹窗（DataBars 重叠 / 冷却管理器冲突）+ 调试插件提醒
----------------------------------------------------------------------
local RunConflictDiagnostics
do
    local CDM_ADDON = "EllesmereUICooldownManager"
    local DATABARS_ADDON = "EllesmereUIDataBars"
    local pendingDisableList = {}

    local function DisableAddonSafely(addonName)
        local ca = _G.C_AddOns
        local disable = (ca and ca.DisableAddOn) or _G.DisableAddOn
        if not disable then return end
        local getState = ca and ca.GetAddOnEnableState
        local guid = _G.UnitGUID and _G.UnitGUID("player") or nil
        -- 无限服角色名带姓氏，UnitName("player") 会丢失姓氏导致 DisableAddOn(name, player) 静默失效；
        -- 优先用 UnitGUID("player") 按当前角色停用，若未生效则回退为全局停用（与 EUI 面板一致）
        if guid then
            pcall(disable, addonName, guid)
        end
        local stillOn = true
        if getState then
            local ok, st = pcall(getState, addonName)
            if ok and type(st) == "number" and st == 0 then
                stillOn = false
            end
        end
        if stillOn then
            pcall(disable, addonName)
        end
    end

    if _G.StaticPopupDialogs then
        _G.StaticPopupDialogs["KKOWOUI_EUI_CONFLICT"] = {
            text = "%s",
            button1 = "停用并重载",
            button2 = "保留",
            OnAccept = function()
                local saveFn = _G.C_AddOns and _G.C_AddOns.SaveAddOns
                for _, addonName in ipairs(pendingDisableList) do
                    DisableAddonSafely(addonName)
                end
                if saveFn then pcall(saveFn) end
                if _G.ReloadUI then _G.ReloadUI() end
            end,
            OnCancel = function(_, _, reason)
                if reason == "clicked" then
                    local db = mod:GetDB()
                    local ck = F.GetCharKey()
                    db.euiConflictKeep = type(db.euiConflictKeep) == "table" and db.euiConflictKeep or {}
                    db.euiConflictKeep[ck] = type(db.euiConflictKeep[ck]) == "table" and db.euiConflictKeep[ck] or {}
                    for _, addonName in ipairs(pendingDisableList) do
                        db.euiConflictKeep[ck][addonName] = true
                    end
                end
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end

    RunConflictDiagnostics = function()
        local db = mod:GetDB()
        if not db.conflictCheck then
            return
        end
        local ck = F.GetCharKey()
        local charKeep = type(db.euiConflictKeep) == "table" and type(db.euiConflictKeep[ck]) == "table" and db.euiConflictKeep[ck] or nil

        for i = #pendingDisableList, 1, -1 do pendingDisableList[i] = nil end
        local reasons = {}

        local sysMod = F.Modules and F.Modules.Get and F.Modules.Get("systemBar")
        if F.IsAddOnLoaded(DATABARS_ADDON) and sysMod and sysMod._active then
            if not (charKeep and charKeep[DATABARS_ADDON]) then
                pendingDisableList[#pendingDisableList + 1] = DATABARS_ADDON
                reasons[#reasons + 1] = "• EUI 数据条（EllesmereUIDataBars）与底部系统栏重叠（时钟/FPS/延迟重影）"
            end
        end

        -- EUI 冷却管理器与 ArcAuras 都接管暴雪冷却显示，同时开启会冲突：
        --   • 选择了「ArcAuras 换成 EUI 冷却管理器」（/kk deadguard arc on）：守卫开着时登录就会处理，否则建议停用 ArcAuras；
        --   • 默认（例如朋友装了整合包、自己本来在用 ArcAuras）：以对方的 ArcAuras 为准，建议停用 EUI 冷却管理器。
        if F.IsAddOnLoaded(CDM_ADDON) and F.IsAddOnLoaded("ArcAuras") then
            local guardOn = F.db and F.db.autoDisableDeadAddons ~= false
            local preferCDM = F.db and F.db.cdmReplacesArc == true
            if preferCDM then
                if not guardOn and not (charKeep and charKeep.ArcAuras) then
                    pendingDisableList[#pendingDisableList + 1] = "ArcAuras"
                    reasons[#reasons + 1] = "• ArcAuras 与 EUI 冷却管理器冲突（都接管暴雪冷却显示），已改用 EUI 冷却管理器"
                end
            elseif not (charKeep and charKeep[CDM_ADDON]) then
                pendingDisableList[#pendingDisableList + 1] = CDM_ADDON
                reasons[#reasons + 1] = "• EUI 冷却管理器与你的 ArcAuras 冲突（都接管暴雪冷却显示），保留 ArcAuras、停用 EUI 冷却管理器"
            end
        end

        if #pendingDisableList > 0 then
            local msg = "|cffdca77fkkowoUI|r\n\n检测到更新 EUI 后以下重叠/冲突子插件被重新启用：\n\n"
                .. table.concat(reasons, "\n")
                .. "\n\n要停用上述插件并重载界面吗？（其他角色若也启用了它们，会一并停用）"
            F.RunOutOfCombat("FUI_EUIConflictPopup", function()
                if _G.StaticPopup_Show then
                    _G.StaticPopup_Show("KKOWOUI_EUI_CONFLICT", msg)
                end
            end)
        end

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

    F.RunOutOfCombat("FUI_ResourceBarsStyle", function()
        if not (mod._active and db.unifyResourceBars ~= false) then return end
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
    F.RunOutOfCombat("FUI_ResourceBarsStyle", function()
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

-- EUI 解锁模式取消/放弃改动时，若挥砍计时器开启了「闲置时按类型隐藏」，
-- EUI 会把进解锁前的单行快照高度（12）按解锁预览展开后的 2~3 行均分，触发 setHeight 下限 4（约 5px 细线）。
-- 这里零侵入监听解锁模式退出并自愈，并在登录时修复已受损的 <=4.5 高度。
local swingGuard = {}
do
    local preUnlockSwingH = nil
    local swingGuardRegistered = false

    function swingGuard.Heal(expectedH)
        local prof, applyFn = GetERBProfileAndApply()
        local st = type(prof) == "table" and prof.swingTimer
        if type(st) ~= "table" or not st.enabled then return end
        local curH = F.PlainNumber(st.height, nil)
        if not curH then return end
        local textSz = F.PlainNumber(st.textSize, 11) or 11
        local targetH
        if expectedH and expectedH >= 8 and curH <= 5.5 and curH <= expectedH * 0.55 then
            targetH = expectedH
        elseif not expectedH and curH <= 4.5 and textSz >= 9
            -- 登录时的启发式修复只在用户仍使用统一资源条样式时进行；
            -- /kk restorebars 还原为自己的样式后，细线挥砍条可能就是用户本意
            and mod:GetDB().unifyResourceBars ~= false then
            targetH = (ERB_UNIFY_PLAN.swingTimer and ERB_UNIFY_PLAN.swingTimer.height) or 12
        end
        if not targetH then return end
        F.RunOutOfCombat("FUI_HealSwingHeight", function()
            local p2, fn2 = GetERBProfileAndApply()
            local st2 = type(p2) == "table" and p2.swingTimer
            if type(st2) == "table" then
                st2.height = targetH
                if fn2 then pcall(fn2) end
            end
        end)
    end

    function swingGuard.Install()
        if swingGuardRegistered then return end
        local EUI = _G.EllesmereUI
        if not (EUI and EUI.RegisterUnlockModeListener) then return end
        swingGuardRegistered = true
        pcall(EUI.RegisterUnlockModeListener, EUI, "kkowoUI_SwingHeightGuard", function(active, closeAction)
            if not mod._active then return end
            if active then
                local prof = GetERBProfileAndApply()
                local st = type(prof) == "table" and prof.swingTimer
                local h = type(st) == "table" and F.PlainNumber(st.height, 12) or nil
                preUnlockSwingH = (h and h >= 8) and h or nil
            else
                local savedH = preUnlockSwingH
                preUnlockSwingH = nil
                -- 「保存」退出时的高度是用户在解锁模式里亲手调的，不能回滚；
                -- EUI 的均分 bug 只出现在取消 / 放弃改动时
                if savedH and closeAction ~= "save" then
                    C_Timer.After(0, function()
                        if mod._active then swingGuard.Heal(savedH) end
                    end)
                end
            end
        end)
    end

    function swingGuard.Remove()
        if not swingGuardRegistered then return end
        swingGuardRegistered = false
        preUnlockSwingH = nil
        local EUI = _G.EllesmereUI
        if EUI and EUI.UnregisterUnlockModeListener then
            pcall(EUI.UnregisterUnlockModeListener, EUI, "kkowoUI_SwingHeightGuard")
        end
    end
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
    -- EUI 飞行条在本次登录第一次飞行时才懒创建：未找到前，战斗中不扫，同一帧内的连发调用只扫一次整个 UIParent。
    -- 只按「同一帧」去重（GetTime 在一帧内不变）：起飞时下一帧的补扫正是消除重复退出按钮的关键，不能被跳过
    if _G.InCombatLockdown and _G.InCombatLockdown() then return nil end
    local now = _G.GetTime and _G.GetTime() or 0
    if now == flightBarLastScan then return nil end
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
    local db = mod:GetDB()
    local mode = mod._active and (db.flightTimerMode or "keep_eui") or "both"
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
--     完整保留 EUI 点击喂食菜单与提示）
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
        "kkowoUI", "Ellesmere", "Polestar", "Questie", "BigWigs",
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

    -- 系统对话框（StaticPopup 确认框、组队邀请、副本就位、团队确认等）绝不当作刷新横幅：
    -- 游戏的「立即刷新世界」确认框就是 StaticPopup，一旦被当成横幅，它会被改样式、挪位置、
    -- 文字被拉到同一行叠字、按钮底图被抹掉；而 StaticPopup1 之后还会被组队邀请等对话框复用，
    -- 于是这些对话框也跟着坏掉，甚至在与真横幅同时出现时被当作「重复横幅」静音成点不到。
    local DIALOG_PREFIXES = {
        "StaticPopup", "LFGDungeonReady", "LFGInvitePopup", "LFGListInviteDialog", "LFDRoleCheckPopup",
        "ReadyCheckFrame", "PVPReadyDialog", "GroupInvite", "PartyInvite", "RolePollPopup",
        "PetBattleQueueReadyFrame", "ElvUI_StaticPopup",
    }
    local function IsDialogFrame(f)
        if not IsSafeReadableFrame(f) then return false end
        local okD, isDlg = pcall(function() return f.which ~= nil and f.button1 ~= nil end)
        if okD and isDlg then return true end
        if f.GetName then
            local okN, raw = pcall(f.GetName, f)
            local nm = okN and F.PlainString(raw, nil) or nil
            if nm then
                for _, p in ipairs(DIALOG_PREFIXES) do
                    if nm:sub(1, #p) == p then return true end
                end
            end
        end
        return false
    end

    local function ShouldSkipFrame(f)
        if not IsSafeReadableFrame(f) then return true end
        if IsDialogFrame(f) then return true end
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
        if IsDialogFrame(cur) then return nil end
        for _ = 1, 3 do
            local okP, p = pcall(function() return cur and cur.GetParent and cur:GetParent() end)
            if not okP or not p or p == _G.UIParent or p == _G.WorldFrame or not IsSafeReadableFrame(p) then
                break
            end
            -- 文字落在对话框里：整段都不是横幅
            if IsDialogFrame(p) then return nil end
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

    -- 横幅里带文字的普通按钮（如「立即刷新」）：不是左侧小图标钮，自身有底图和文字标签
    local function IsTextButton(ch)
        if not IsSafeReadableFrame(ch) or IsSmallActionButton(ch) then return false end
        local okT, ot = pcall(ch.GetObjectType, ch)
        return okT and (ot == "Button" or ot == "CheckButton")
    end

    -- 文字按钮交给 EUI 官方皮肤（扁平暗底 + 细边框 + 白字），保留可点击外观；没有 EUI 皮肤接口时保持原版
    local wrTextBtnSkinned = setmetatable({}, { __mode = "k" })
    local function SkinBannerTextButton(btn)
        if wrTextBtnSkinned[btn] then return end
        local S = F.Theme.GetSkinAPI and F.Theme.GetSkinAPI()
        if not (S and S.Button) then return end
        wrTextBtnSkinned[btn] = true
        pcall(S.Button, btn)
        if S.StateButtonLabel then pcall(S.StateButtonLabel, btn) end
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
            if type(part) == "table" and part.SetAlpha then pcall(part.SetAlpha, part, alpha) end
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
                if ch and ch ~= wrSkin[box] and ch ~= wrBtnSkin[box]
                    and not IsSmallActionButton(ch) and not IsTextButton(ch) then
                    MuteNativeBannerArt(ch, alpha, (depth or 0) + 1)
                end
            end
        end
    end

    local function StyleBannerFontsAndButtons(box, want)
        local hasLeftBtn, hasTextBtn = false, false
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
                        elseif IsTextButton(ch) then
                            -- 不进入按钮内部：它的文字标签属于按钮，绝不能被拉到横幅正中（会与正文叠字）
                            hasTextBtn = true
                            if want then SkinBannerTextButton(ch) end
                        else
                            walk(ch, depth + 1)
                        end
                    end
                end
            end
        end
        walk(box, 0)

        -- 真正居中排版只用于「单行倒计时 + 左侧小刷新钮」的简单横幅；
        -- 带文字按钮或多段文字的状态（如「立即刷新世界。」）保持暴雪原排版，避免几段文字挤到同一行重叠
        local simpleLayout = (not hasTextBtn) and #mainFS == 1
        if want and #mainFS > 0 and not simpleLayout then
            for _, fs in ipairs(mainFS) do
                local o = wrOrigFS[fs]
                if o then
                    pcall(fs.ClearAllPoints, fs)
                    pcall(fs.SetPoint, fs, o[1], o[2], o[3], o[4], o[5])
                    if fs.SetJustifyH and o[6] then pcall(fs.SetJustifyH, fs, o[6]) end
                end
            end
        end
        if want and simpleLayout then
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
        -- 旧版本登记过的系统对话框：还原成原样并从横幅列表剔除
        for i = #wrList, 1, -1 do
            local b = wrList[i]
            if IsDialogFrame(b) then
                SilenceDuplicateBanner(b, false)
                local ov = wrSkin[b]
                if ov then ov:Hide() end
                MuteNativeBannerArt(b, 1, 0)
                StyleBannerFontsAndButtons(b, false)
                if wrPrimary == b then wrPrimary = nil end
                table.remove(wrList, i)
            end
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
                for _, cv in ipairs({ "worldMapShowPlayerCoords", "worldMapShowCursorCoords" }) do
                    local okV, v = pcall(getCV, cv)
                    if okV and v == "1" then
                        pcall(setCV, cv, "0")
                        db.wmDisabledCVars = type(db.wmDisabledCVars) == "table" and db.wmDisabledCVars or {}
                        db.wmDisabledCVars[cv] = true
                    end
                end
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
                if setCV then
                    for cv in pairs(db.wmDisabledCVars) do pcall(setCV, cv, "1") end
                end
                db.wmDisabledCVars = nil
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
    local function ReflowGossipScrollBox()
        if gossipReflowBusy then return end
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
            local needH = MeasureRowContentHeight(row, isGreeting) or curH
            if needH < curH then needH = curH end

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

            if needH > curH + 1 then
                needShift = true
            end
            plan[i] = {
                row = row,
                x = (okP and F.PlainNumber(px, 0)) or 0,
                y = cursorY,
                h = needH,
                grew = needH > curH + 1,
            }
            cursorY = cursorY - needH - (isGreeting and 10 or 4)
        end

        if not needShift then return end
        gossipReflowBusy = true
        for _, item in ipairs(plan) do
            local row = item.row
            if item.grew and row.SetHeight then
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

    local function FixSimilarDialogOverlaps()
        for _, name in ipairs(MULTILINE_DIALOG_FS) do
            local fs = _G[name]
            if IsSafeObj(fs) and fs.SetHeight and fs.GetStringHeight then
                local curH = F.PlainNumber(fs.GetHeight and fs:GetHeight(), 0) or 0
                local strH = F.PlainNumber(fs:GetStringHeight(), 0) or 0
                if curH > 0 and strH >= curH - 2 then
                    pcall(fs.SetHeight, fs, 0)
                end
            end
        end
        -- 任务问候页（QuestFrameGreetingPanel）：确保水平分隔线与第一个任务按钮严禁压在 GreetingText 上
        local qgp = _G.QuestFrameGreetingPanel
        local gt = _G.GreetingText
        if IsSafeObj(qgp) and qgp:IsShown() and IsSafeObj(gt) and gt:IsShown() then
            pcall(gt.SetHeight, gt, 0)
            local hBreak = _G.QuestGreetingFrameHorizontalBreak
            if IsSafeObj(hBreak) and hBreak:IsShown() and hBreak.ClearAllPoints then
                pcall(hBreak.ClearAllPoints, hBreak)
                pcall(hBreak.SetPoint, hBreak, "TOPLEFT", gt, "BOTTOMLEFT", 0, -10)
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

    local function SyncScrollFrameTopGuard(sf, want)
        if not IsSafeObj(sf) then return end
        local sc = sf.GetScrollChild and sf:GetScrollChild()
        if not IsSafeObj(sc) then return end
        -- 首行文字若紧贴滚动区顶边（y >= -3），统一向下留出 6px 顶部安全区。
        -- 不关闭滚动区裁切：内容常在窗口开着时变长（任务日志切换任务等），关掉裁切后长文字会溢出到窗口按钮上。
        if sc.GetRegions then
            for _, reg in ipairs({ sc:GetRegions() }) do
                if IsSafeObj(reg) and reg.GetObjectType and reg:GetObjectType() == "FontString" then
                    ShiftAnchorY(reg, -6, want, -3)
                    GuardFontStringHeight(reg, want)
                end
            end
        end
        if sc.GetChildren then
            for _, ch in ipairs({ sc:GetChildren() }) do
                if IsSafeObj(ch) then
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
        local otype = root.GetObjectType and root:GetObjectType()
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
                if IsSafeObj(reg) and reg.GetObjectType and reg:GetObjectType() == "FontString" then
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
                        pcall(self.SetAlpha, self, 0)
                        pcall(self.EnableMouse, self, false)
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
                        pcall(ctrl.SetAlpha, ctrl, 1)
                        pcall(ctrl.EnableMouse, ctrl, true)
                    end
                    return
                end
                self._restored = false
                local inside = IsCursorInModelCenter(scene, ctrl, self._shown)
                if inside then
                    self._leaveGrace = 0.14
                    if not self._shown then
                        self._shown = true
                        pcall(ctrl.Show, ctrl)
                        pcall(ctrl.SetAlpha, ctrl, 1)
                        pcall(ctrl.EnableMouse, ctrl, true)
                    elseif F.PlainNumber(ctrl:GetAlpha(), 1) < 0.9 then
                        pcall(ctrl.SetAlpha, ctrl, 1)
                        pcall(ctrl.EnableMouse, ctrl, true)
                    end
                else
                    if self._shown then
                        self._leaveGrace = self._leaveGrace - dt
                        if self._leaveGrace <= 0 then
                            self._shown = false
                            pcall(ctrl.SetAlpha, ctrl, 0)
                            pcall(ctrl.EnableMouse, ctrl, false)
                        end
                    elseif F.PlainNumber(ctrl:GetAlpha(), 0) > 0.01 then
                        pcall(ctrl.SetAlpha, ctrl, 0)
                        pcall(ctrl.EnableMouse, ctrl, false)
                    end
                end
            end)
            drv:HookScript("OnShow", function(self)
                self._shown = false
                self._leaveGrace = 0
                if mod._active and mod:GetDB().centerModelControls ~= false then
                    pcall(ctrl.SetAlpha, ctrl, 0)
                    pcall(ctrl.EnableMouse, ctrl, false)
                end
            end)
            modelCtrlDriver = drv
        end

        if want then
            modelCtrlDriver._shown = false
            modelCtrlDriver:Show()
            pcall(ctrl.SetAlpha, ctrl, 0)
            pcall(ctrl.EnableMouse, ctrl, false)
        else
            modelCtrlDriver._shown = false
            modelCtrlDriver:Hide()
            pcall(ctrl.SetAlpha, ctrl, 1)
            pcall(ctrl.EnableMouse, ctrl, true)
            if ctrl.IsShown and ctrl:IsShown() and not (ctrl.IsMouseOver and ctrl:IsMouseOver()) then
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
        for _, ch in ipairs({ box:GetChildren() }) do
            if IsSafe(ch) and ch ~= heroCard and ch ~= box.ScrollBox and ch ~= box.ScrollBar then
                local h = F.PlainNumber(ch.GetHeight and ch:GetHeight(), 0)
                if h >= 20 and h <= 28 and not (ch.GetName and ch:GetName()) then
                    if ch.SetAlpha then pcall(ch.SetAlpha, ch, hide and 0 or 1) end
                    if ch.EnableMouse then pcall(ch.EnableMouse, ch, not hide) end
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
local HookEUICastNames
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
local castNameHooked = false

HookEUICastNames = function()
    local EUI = _G.EllesmereUI
    if castNameHooked or not (EUI and type(EUI.CleanCastName) == "function") then return end
    castNameHooked = true
    local orig = EUI.CleanCastName
    EUI.CleanCastName = function(name)
        local clean = orig(name)
        if F.IsSecret(clean) or type(clean) ~= "string" or not mod._active then
            return clean
        end
        return CAST_NAME_ZH[clean] or clean
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
    swingGuard.Remove()
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
    pcall(ApplyUnifiedResourceBars, false)
    pcall(swingGuard.Heal, nil)
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
        F.Print("友方玩家 ID 策略已切换为：|cff5fd3a6" .. (MODE_LABELS[target] or target) .. "|r")
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
            text = "友方玩家 ID 隐藏策略",
            tooltip = "压制 EUI 强制重开友方玩家名，显著缓解主城卡顿。\n聊天框输入 /kk friendly 可一键切换模式。",
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
            text = "同步隐藏友方公会与头衔",
            tooltip = "隐藏友方玩家 ID 时一并关闭公会与头衔渲染，主城帧数提升更明显。",
            getValue = function() return db.hideGuildTitle ~= false end,
            setValue = function(v) db.hideGuildTitle = v == true; ClearManualOverrides(); ApplyAll() end,
        }, {
            type = "toggle",
            text = "主城同时隐藏友方 NPC 姓名板",
            tooltip = "在主城/休整区临时隐藏卫兵、商人等友方 NPC 姓名板以换取最高帧数（离开主城自动恢复）。",
            getValue = function() return db.hideCityNpcPlates == true end,
            setValue = function(v) db.hideCityNpcPlates = v == true; ClearManualOverrides(); ApplyAll() end,
        })
        y = y - h

        _, h = W:DualRow(parent, y, {
            type = "toggle",
            text = "公会与头衔在所有地方都隐藏（含自己）",
            tooltip = "默认只在主城/休整区隐藏公会与头衔，离开后恢复；开启后在野外和副本也一直隐藏，包括你自己名字下方的公会。\n需同时开启「同步隐藏友方公会与头衔」；关闭后恢复为开启前的游戏设置。",
            getValue = function() return db.guildTitleAlways == true end,
            setValue = function(v) db.guildTitleAlways = v == true; ClearManualOverrides(); ApplyAll() end,
        }, blank)
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
