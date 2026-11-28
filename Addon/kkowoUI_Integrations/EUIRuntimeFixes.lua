----------------------------------------------------------------------
--  kkowoUI — Modules/EUIRuntimeFixes.lua
--  EllesmereUI 零文件修改运行时修复（替代原 2 个 EUI 姓名板文件补丁）：
--    1) 拦截 EllesmereUINameplates 每次登录强制打开原生友方玩家名字 CVar
--       （替代 Patches/eui_friendly_player_names.py；仅首次安装放行）
--    2) 姓名板任务计数与怪物名字防重叠 + 上方槽位字号自动对齐
--       （替代 Patches/eui_np_questtext_name.py；零污染 hooksecurefunc）
--  所有状态均存放在弱表中，绝不向暴雪/EUI 框体写入自定义字段。
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_abs, math_max, pairs, pcall, setmetatable, type =
    ipairs, math.abs, math.max, pairs, pcall, setmetatable, type
local C_Timer = C_Timer

local mod = F.RegisterModule("euiRuntimeFixes", {
    title = "姓名板防重叠",
    desc = "防止登录强开友方玩家名字，并避免姓名板任务计数遮挡怪名。",
    group = "theme",
    order = 42,
    defaults = {
        enabled = true,
        guardFriendlyNameCVar = true,
        fixNameplateQuestOverlap = true,
        fixMenuOverlap = true,
    },
})

----------------------------------------------------------------------
--  1) 顶层尽早包装 EllesmereUI.SetCVar（在 PLAYER_LOGIN 前拦截），停用时无损还原
----------------------------------------------------------------------
local origEUISetCVar = nil
local wrappedEUISetCVar = nil

local function ShouldGuardFriendlyCVar()
    if mod._active == false then
        return false
    end
    local sv = _G.kkowoUIDB or _G.KkowoUIDB
    local cfg = type(sv) == "table" and type(sv.modules) == "table" and sv.modules.euiRuntimeFixes
    if type(cfg) == "table" then
        if cfg.enabled == false or cfg.guardFriendlyNameCVar == false then
            return false
        end
    end
    return true
end

local function InstallEUISetCVarHook()
    local EUI = _G.EllesmereUI
    if type(EUI) ~= "table" or type(EUI.SetCVar) ~= "function" then return end
    if origEUISetCVar then return end
    origEUISetCVar = EUI.SetCVar
    wrappedEUISetCVar = function(name, value, owner)
        local orig = origEUISetCVar
        if name == "UnitNameFriendlyPlayerName"
            and owner == "EllesmereUINameplates"
            and (value == 1 or value == "1" or value == true)
            and not EUI._firstInstallPending
            and ShouldGuardFriendlyCVar() then
            return false
        end
        if type(orig) == "function" then
            return orig(name, value, owner)
        end
        return false
    end
    EUI.SetCVar = wrappedEUISetCVar
end

local function RestoreEUISetCVarHook()
    local EUI = _G.EllesmereUI
    if not origEUISetCVar then return end
    if type(EUI) == "table" and EUI.SetCVar == wrappedEUISetCVar then
        EUI.SetCVar = origEUISetCVar
        origEUISetCVar = nil
        wrappedEUISetCVar = nil
    end
    -- 若已有第三方插件在 wrappedEUISetCVar 外层再次包装，保留 origEUISetCVar 让停用态安全直通不报错
end

InstallEUISetCVarHook()

----------------------------------------------------------------------
--  2) 姓名板任务计数与名字防重叠 + 上方任务计数字号同步
----------------------------------------------------------------------
local hookedPlates = setmetatable({}, { __mode = "k" })
local plateShiftState = setmetatable({}, { __mode = "k" })

local function GetEUIActiveNameplateProfile()
    local db = _G.EllesmereUINameplatesDB
    if type(db) ~= "table" or type(db.profiles) ~= "table" then
        return nil
    end
    local profName = db.activeProfile or "Default"
    local prof = db.profiles[profName]
    if type(prof) == "table" then
        return prof
    end
    for _, v in pairs(db.profiles) do
        if type(v) == "table" then
            return v
        end
    end
    return nil
end

local function IsSafeFrame(f)
    if not f then return false end
    if f.IsForbidden then
        local ok, forb = pcall(f.IsForbidden, f)
        if not ok or forb then return false end
    end
    return true
end

local function IsTopRowFrame(frame, health)
    if not (IsSafeFrame(frame) and IsSafeFrame(health) and frame.IsShown and frame:IsShown()) then
        return false, nil
    end
    local ok, p, rel, rp = pcall(frame.GetPoint, frame, 1)
    if not (ok and rel == health and type(rp) == "string") then
        return false, nil
    end
    if rp == "TOPLEFT" then
        return true, "left"
    elseif rp == "TOPRIGHT" then
        return true, "right"
    elseif rp == "TOP" then
        return true, "center"
    end
    return false, nil
end

local function FrameWidthSafe(frame)
    if not (IsSafeFrame(frame) and frame.GetWidth) then
        return 0
    end
    local w = F.PlainNumber(frame._npW, nil)
    if not w or w <= 0 then
        w = F.PlainNumber(frame._npSz, nil)
    end
    if not w or w <= 0 then
        local ok, raw = pcall(frame.GetWidth, frame)
        w = ok and F.PlainNumber(raw, 0) or 0
    end
    return w or 0
end

local function SyncQuestTextFontSize(plate)
    if not (mod._active and mod:GetDB().fixNameplateQuestOverlap ~= false) then
        return
    end
    if not IsSafeFrame(plate) then return end
    local qf = plate.questTextFrame
    local nameFS = plate.name
    local health = plate.health
    if not (IsSafeFrame(qf) and IsSafeFrame(nameFS) and IsSafeFrame(health) and qf.IsShown and qf:IsShown()) then
        return
    end
    local onTop = IsTopRowFrame(qf, health)
    if not onTop then
        return
    end
    local prof = GetEUIActiveNameplateProfile()
    if type(prof) == "table" and prof.questObjectiveTextSize ~= nil then
        return
    end
    local okN, nFont, nSize, nFlags = pcall(nameFS.GetFont, nameFS)
    nSize = okN and F.PlainNumber(nSize, nil) or nil
    if not (nFont and nSize and nSize >= 6) then
        return
    end
    -- EUI questTextFrame 内部 FontString 可能是 qf.text / qf.fs 或唯一子 FontString
    local qfs = qf.text or qf.fs
    if not qfs and qf.GetRegions then
        local okR, regs = pcall(function() return { qf:GetRegions() } end)
        if okR and type(regs) == "table" then
            for i = 1, #regs do
                local r = regs[i]
                if IsSafeFrame(r) and r.GetObjectType and r:GetObjectType() == "FontString" then
                    qfs = r
                    break
                end
            end
        end
    end
    if not (IsSafeFrame(qfs) and qfs.GetFont and qfs.SetFont) then
        return
    end
    local okQ, qFont, qSize, qFlags = pcall(qfs.GetFont, qfs)
    qSize = okQ and F.PlainNumber(qSize, nil) or nil
    if qSize and math_abs(qSize - nSize) < 0.25 then
        return
    end
    pcall(qfs.SetFont, qfs, qFont or nFont, nSize, qFlags or nFlags or "")
    if qfs.GetStringWidth and qf.SetWidth then
        local okW, sw = pcall(qfs.GetStringWidth, qfs)
        sw = okW and F.PlainNumber(sw, nil) or nil
        if sw and sw > 0 then
            pcall(qf.SetWidth, qf, sw + 2)
        end
    end
end

local function AdjustTopNameShift(plate)
    if not (mod._active and mod:GetDB().fixNameplateQuestOverlap ~= false) then
        return
    end
    if not IsSafeFrame(plate) then return end
    local nameFS = plate.name
    local health = plate.health
    if not (IsSafeFrame(nameFS) and IsSafeFrame(health) and nameFS.GetPoint) then
        return
    end
    local okP, pt, rel, rpt, xOff, yOff = pcall(nameFS.GetPoint, nameFS, 1)
    if not (okP and pt == "BOTTOM" and rel == health and rpt == "TOP") then
        return
    end
    xOff = F.PlainNumber(xOff, 0) or 0
    yOff = F.PlainNumber(yOff, 0) or 0

    -- 先还原上次我们施加的平移量，算出 EUI 原始基准 x
    local st = plateShiftState[plate]
    local prevShift = st and st.applied or 0
    local baseX = xOff - prevShift

    local leftRes, rightRes = 0, 0
    local candidates = {
        { frame = plate.raidFrame, pad = 2 },
        { frame = plate.classFrame, pad = 4 },
        { frame = plate.questFrame, pad = 4 },
        { frame = plate.questTextFrame, pad = 4 },
        { frame = plate.factionFrame, pad = 4 },
    }
    for i = 1, #candidates do
        local c = candidates[i]
        local onTop, side = IsTopRowFrame(c.frame, health)
        if onTop and (side == "left" or side == "right") then
            local w = FrameWidthSafe(c.frame)
            if w > 0 then
                if side == "left" then
                    leftRes = leftRes + w + c.pad
                else
                    rightRes = rightRes + w + c.pad
                end
            end
        end
    end

    local newShift = (leftRes - rightRes) * 0.5
    if math_abs(newShift - prevShift) < 0.25 and math_abs(newShift) < 0.25 then
        if st then st.applied = 0 end
        return
    end

    if not st then
        st = {}
        plateShiftState[plate] = st
    end
    st.applied = newShift

    pcall(nameFS.ClearAllPoints, nameFS)
    pcall(nameFS.SetPoint, nameFS, "BOTTOM", health, "TOP", baseX + newShift, yOff)

    -- 同步收紧名字最大宽度，确保不越界压入左侧/右侧任务计数
    if health.GetWidth and nameFS.GetWidth and nameFS.SetWidth then
        local okHB, hbW = pcall(health.GetWidth, health)
        local okNW, curNW = pcall(nameFS.GetWidth, nameFS)
        hbW = okHB and F.PlainNumber(hbW, nil) or nil
        curNW = okNW and F.PlainNumber(curNW, nil) or nil
        if hbW and curNW and (leftRes > 0 or rightRes > 0) then
            local avail = math_max(hbW - leftRes - rightRes, 24)
            if curNW > avail then
                pcall(nameFS.SetWidth, nameFS, avail)
            end
        end
    end
end

local function FindEUIPlateFromBlizzPlate(blizzPlate)
    if type(blizzPlate) ~= "table" or not IsSafeFrame(blizzPlate) then
        return nil
    end
    -- EUI 姓名板挂载为暴雪 nameplate 的子框体，具备 health + name + UpdateNameWidth 方法
    if blizzPlate.GetChildren then
        local okC, children = pcall(function() return { blizzPlate:GetChildren() } end)
        if not (okC and type(children) == "table") then return nil end
        for i = 1, #children do
            local ch = children[i]
            if type(ch) == "table" and IsSafeFrame(ch) and ch.health and ch.name and type(ch.UpdateNameWidth) == "function" then
                return ch
            end
        end
    end
    return nil
end

local function HookEUIPlate(plate)
    if not (plate and IsSafeFrame(plate) and not hookedPlates[plate] and _G.hooksecurefunc) then
        return
    end
    hookedPlates[plate] = true
    if type(plate.UpdateQuestText) == "function" then
        _G.hooksecurefunc(plate, "UpdateQuestText", function(self)
            SyncQuestTextFontSize(self)
            AdjustTopNameShift(self)
        end)
    end
    if type(plate.UpdateNameWidth) == "function" then
        _G.hooksecurefunc(plate, "UpdateNameWidth", function(self)
            AdjustTopNameShift(self)
        end)
    end
    if type(plate.RefreshNamePosition) == "function" then
        _G.hooksecurefunc(plate, "RefreshNamePosition", function(self)
            local st = plateShiftState[self]
            if st then st.applied = 0 end
            AdjustTopNameShift(self)
        end)
    end
    SyncQuestTextFontSize(plate)
    AdjustTopNameShift(plate)
end

local function ScanAllPlates()
    local NP = _G.C_NamePlate
    if not (NP and type(NP.GetNamePlates) == "function") then
        return
    end
    local ok, list = pcall(NP.GetNamePlates)
    if not (ok and type(list) == "table") then
        return
    end
    for i = 1, #list do
        local ep = FindEUIPlateFromBlizzPlate(list[i])
        if ep then
            HookEUIPlate(ep)
        end
    end
end

----------------------------------------------------------------------
--  3) 零污染下拉菜单防穿透与右侧边缘防重叠（修复小地图子菜单叠在父菜单上）
----------------------------------------------------------------------
local menuHooksInstalled = false
local menuPending = {}
local menuFlushArmed = false
local openMenus = {}

local function GetScaledRect(f)
    if not (f and f.GetLeft and f.GetRight and f.GetTop and f.GetBottom) then return nil end
    local okL, l = pcall(f.GetLeft, f)
    local okR, r = pcall(f.GetRight, f)
    local okT, t = pcall(f.GetTop, f)
    local okB, b = pcall(f.GetBottom, f)
    l = okL and F.PlainNumber(l, nil) or nil
    r = okR and F.PlainNumber(r, nil) or nil
    t = okT and F.PlainNumber(t, nil) or nil
    b = okB and F.PlainNumber(b, nil) or nil
    if not (l and r and t and b) then return nil end
    local s = (f.GetEffectiveScale and F.PlainNumber(f:GetEffectiveScale(), 1)) or 1
    if s <= 0 then s = 1 end
    return l * s, r * s, t * s, b * s, s
end

local function BoostMenuBackdropOpacity(menu)
    if not (menu and menu.GetRegions) then return end
    local okR, regs = pcall(function() return { menu:GetRegions() } end)
    if not (okR and type(regs) == "table") then return end
    for i = 1, #regs do
        local reg = regs[i]
        if reg and reg.GetObjectType and reg:GetObjectType() == "Texture" then
            local okL, layer = pcall(reg.GetDrawLayer, reg)
            if okL and layer == "BACKGROUND" then
                local okT, tex = pcall(reg.GetTexture, reg)
                local okA, a = pcall(reg.GetAlpha, reg)
                a = okA and F.PlainNumber(a, 1) or 1
                if a > 0.05 then
                    local plainTex = okT and F.PlainString(tex, nil) or nil
                    local isSolid = (tex == nil) or (plainTex and (plainTex:find("WHITE8", 1, true) or plainTex == "Color-00000000"))
                    if isSolid and reg.SetColorTexture then
                        pcall(reg.SetColorTexture, reg, 0.055, 0.062, 0.080, 0.96)
                    elseif a < 0.95 and reg.SetAlpha then
                        pcall(reg.SetAlpha, reg, 0.96)
                    end
                end
            end
        end
    end
end

local function TreatMenuFrame(menu)
    if not (mod._active and mod:GetDB().fixMenuOverlap ~= false) then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end
    if not (IsSafeFrame(menu) and menu.IsShown and menu:IsShown()) then return end

    BoostMenuBackdropOpacity(menu)

    -- 清理已关闭的旧菜单
    local kept = {}
    local already = false
    for i = 1, #openMenus do
        local m = openMenus[i]
        if IsSafeFrame(m) and m.IsShown and m:IsShown() then
            kept[#kept + 1] = m
            if m == menu then already = true end
        end
    end
    if not already then
        kept[#kept + 1] = menu
    end
    openMenus = kept

    -- 若刚弹出的子菜单在屏幕右侧被夹回并叠在上一级菜单上，则优雅左翻紧贴父菜单左缘
    if #openMenus < 2 then return end
    local ml, mr, mt, mb, ms = GetScaledRect(menu)
    if not ml then return end
    local mw = mr - ml

    local parentMenu = nil
    for i = #openMenus, 1, -1 do
        local cand = openMenus[i]
        if cand ~= menu then
            local pl, pr, pt, pb = GetScaledRect(cand)
            if pl and ml < pr - 2 and mr > pl + 2 and mb < pt - 2 and mt > pb + 2 then
                parentMenu = cand
                if (pl - mw) >= 6 and menu.ClearAllPoints and menu.SetPoint then
                    local yOff = (mt - pt) / ms
                    pcall(menu.ClearAllPoints, menu)
                    pcall(menu.SetPoint, menu, "TOPRIGHT", cand, "TOPLEFT", -2, yOff)
                end
                break
            end
        end
    end
    if parentMenu and menu.GetFrameLevel and menu.SetFrameLevel and parentMenu.GetFrameLevel then
        local plvl = F.PlainNumber(parentMenu:GetFrameLevel(), 100) or 100
        local mlvl = F.PlainNumber(menu:GetFrameLevel(), 100) or 100
        if mlvl <= plvl then
            pcall(menu.SetFrameLevel, menu, plvl + 10)
        end
    end
end

local function FlushMenus()
    menuFlushArmed = false
    local batch = {}
    for i = 1, #menuPending do
        batch[i] = menuPending[i]
        menuPending[i] = nil
    end
    for i = 1, #batch do
        TreatMenuFrame(batch[i])
    end
    -- EUI 皮肤在下一帧也会重绘底色，0.02s 后再补校一次透明度与位置
    if #batch > 0 and C_Timer and C_Timer.After then
        C_Timer.After(0.02, function()
            for i = 1, #batch do
                TreatMenuFrame(batch[i])
            end
        end)
    end
end

local function OnMenuStyleGenerate(menuFrame)
    if not (mod._active and mod:GetDB().fixMenuOverlap ~= false) then return end
    menuPending[#menuPending + 1] = menuFrame
    if not menuFlushArmed and C_Timer and C_Timer.After then
        menuFlushArmed = true
        C_Timer.After(0, FlushMenus)
    end
end

local function EnsureMenuOverlapHooks()
    if menuHooksInstalled or type(_G.hooksecurefunc) ~= "function" then return end
    local hookedAny = false
    if type(_G.MenuStyle1Mixin) == "table" and type(_G.MenuStyle1Mixin.Generate) == "function" then
        _G.hooksecurefunc(_G.MenuStyle1Mixin, "Generate", OnMenuStyleGenerate)
        hookedAny = true
    end
    if type(_G.MenuStyle2Mixin) == "table" and type(_G.MenuStyle2Mixin.Generate) == "function" then
        _G.hooksecurefunc(_G.MenuStyle2Mixin, "Generate", OnMenuStyleGenerate)
        hookedAny = true
    end
    if hookedAny then
        menuHooksInstalled = true
    end
end

function mod:OnEnable()
    InstallEUISetCVarHook()
    EnsureMenuOverlapHooks()
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, _, unit)
        local NP = _G.C_NamePlate
        if NP and NP.GetNamePlateForUnit and unit then
            local ok, bp = pcall(NP.GetNamePlateForUnit, unit)
            if ok and bp then
                local ep = FindEUIPlateFromBlizzPlate(bp)
                if ep then
                    HookEUIPlate(ep)
                    return
                end
            end
        end
        C_Timer.After(0, ScanAllPlates)
    end)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        EnsureMenuOverlapHooks()
        C_Timer.After(0.5, ScanAllPlates)
    end)
    C_Timer.After(0.5, ScanAllPlates)
end

function mod:OnDisable()
    RestoreEUISetCVarHook()
    for i = #openMenus, 1, -1 do openMenus[i] = nil end
    for i = #menuPending, 1, -1 do menuPending[i] = nil end
end

function mod:BuildOptions(W, parent, y, enableSlot)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "防强开友方名",
        tooltip = "阻止 EUI 登录时强开友方玩家名字，尊重游戏界面设置。",
        getValue = function() return db.guardFriendlyNameCVar ~= false end,
        setValue = function(v) db.guardFriendlyNameCVar = v == true end,
    })
    y = y - h
    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "任务计数防压字",
        tooltip = "按任务计数与稀有图标宽度平移怪物名字并同步字号。",
        getValue = function() return db.fixNameplateQuestOverlap ~= false end,
        setValue = function(v)
            db.fixNameplateQuestOverlap = v == true
            if db.fixNameplateQuestOverlap then ScanAllPlates() end
        end,
    }, {
        type = "toggle",
        text = "下拉菜单防重叠",
        tooltip = "提高小地图等下拉菜单底板不透明度，贴边子菜单自动左翻。",
        getValue = function() return db.fixMenuOverlap ~= false end,
        setValue = function(v) db.fixMenuOverlap = v == true end,
    })
    y = y - h
    return y
end
