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
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, pairs, math_abs, math_floor, math_max, math_min, pcall, tonumber, tostring, type =
    ipairs, pairs, math.abs, math.floor, math.max, math.min, pcall, tonumber, tostring, type
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local setmetatable = setmetatable

local MC = {}
F._MC = MC

local mod = F.RegisterModule("modernChrome", {
    title = "外观与界面统一",
    desc = "统一主题色、战斗伤害字体、人物面板、地图去重与弓箭静音。",
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
    local ST = F.StyleTokens
    local barTex = (ST and ST.GetBarFillTexture) and ST.GetBarFillTexture(false) or F.Theme.FLAT_TEX
    f.bar:SetStatusBarTexture(barTex)
    f.bar:SetMinMaxValues(0, maxVal > 0 and maxVal or 1)
    f.bar:SetValue(maxVal > 0 and math_min(val, maxVal) or 1)
    local ft = f.bar.GetStatusBarTexture and f.bar:GetStatusBarTexture() or nil
    if ST and ST.IsFXEnabled and ST.IsFXEnabled("fx_barTexture") and ft and ST.ApplySoftFlatGradient then
        f.bar:SetStatusBarColor(1, 1, 1, 1)
        if not ST.ApplySoftFlatGradient(ft, r, g, b, 0.92, false) then
            f.bar:SetStatusBarColor(r, g, b, 0.90)
        end
    else
        f.bar:SetStatusBarColor(r, g, b, 0.90)
    end
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
    if not btn or (btn.IsForbidden and btn:IsForbidden()) then return end
    local fs = btn.Duration
    if not (fs and not (fs.IsForbidden and fs:IsForbidden()) and fs.GetFont and fs.SetFont) then
        return
    end
    local okW, rawW = pcall(btn.GetWidth, btn)
    local w = okW and F.PlainNumber(rawW, nil) or nil
    local iw = nil
    if btn.Icon and not (btn.Icon.IsForbidden and btn.Icon:IsForbidden()) and btn.Icon.GetWidth then
        local okIW, rawIW = pcall(btn.Icon.GetWidth, btn.Icon)
        iw = okIW and F.PlainNumber(rawIW, nil) or nil
    end
    if iw and iw > 0 and (not w or iw < w) then
        w = iw
    end
    if not w or w <= 0 then
        return
    end
    local okF, rawFace, rawSize, rawFlags = pcall(fs.GetFont, fs)
    if not okF then return end
    local face = F.PlainString(rawFace, nil)
    local size = F.PlainNumber(rawSize, nil)
    local flags = F.PlainString(rawFlags, "") or ""
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
    if not pcall(measureFS.SetFont, measureFS, face, base, flags) then return end
    pcall(measureFS.SetText, measureFS, "88 m")
    local okTW, rawTW = pcall(measureFS.GetStringWidth, measureFS)
    local tw = okTW and F.PlainNumber(rawTW, nil) or nil
    local newSize = base
    if tw and tw > w then
        newSize = math_max(7, math_floor(base * w / tw * 10) / 10)
    end
    if math_abs(newSize - size) >= 0.05 then
        pcall(fs.SetFont, fs, face, newSize, flags)
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
        if fs and not (fs.IsForbidden and fs:IsForbidden()) and fs.GetFont and fs.SetFont and done[3] then
            local okF, rawFace, rawSize, rawFlags = pcall(fs.GetFont, fs)
            local face = okF and F.PlainString(rawFace, nil) or nil
            local size = okF and F.PlainNumber(rawSize, nil) or nil
            local flags = okF and F.PlainString(rawFlags, "") or ""
            if face and size and math_abs(size - done[3]) >= 0.05 then
                pcall(fs.SetFont, fs, face, done[3], flags)
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
        local guid = _G.UnitGUID and F.PlainString(_G.UnitGUID("player"), nil) or nil
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

MC.mod = mod
MC.SetupCharacterBars = SetupCharacterBars
MC.RefreshAllCharacterBars = RefreshAllCharacterBars
MC.PolishCharacterStatsFontSize = PolishCharacterStatsFontSize
MC.SkinSkillsScrollBar = SkinSkillsScrollBar
MC.QueueAuraFit = QueueAuraFit
MC.RestoreFittedAuraTimers = RestoreFittedAuraTimers
MC.SetupFriendsHook = SetupFriendsHook
MC.ExpandFriendsIfEnabled = ExpandFriendsIfEnabled
MC.SkinBugSackIfReady = SkinBugSackIfReady
MC.RunConflictDiagnostics = RunConflictDiagnostics
