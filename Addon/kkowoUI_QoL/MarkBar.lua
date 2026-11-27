----------------------------------------------------------------------
--  kkowoUI — Modules/MarkBar.lua
--  现代扁平矢量团队标记条（重绘 128px 高清矢量图标 + 烟熏玻璃胶囊 + 目标同步高亮）
--    • 8 枚现代扁平矢量团队标记（骷髅/红叉/方块/月亮/三角/菱形/大饼/星星）
--    • 3 枚同比例矢量功能钮（清除标记 / 就位确认 / 开怪倒数），全行光学居中零偏移
--    • 实时监听目标当前标记（RAID_TARGET_UPDATE / PLAYER_TARGET_CHANGED），
--      自动点亮目标已有标记对应格与 1px 底部高亮线，再次点击即可取消
--    • 视觉语言与 EUI 聊天标签及 PrettyTooltip 保持一致，纯 AnimationGroup 淡隐零污染
----------------------------------------------------------------------
local _G = _G
local F = _G.kkowoUI
if not F then return end
local ipairs, math_floor, math_max, math_min, pairs, pcall, tostring, type =
    ipairs, math.floor, math.max, math.min, pairs, pcall, tostring, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GameTooltip = _G.GameTooltip

local mod = F.RegisterModule("markBar", {
    title = "快捷标记条",
    desc = "提供快捷标记条、高清重绘标记与姓名板标记大小统一调节。",
    group = "combat",
    order = 40,
    defaults = {
        enabled = true,
        iconPack = "modern",      -- "modern" = 现代扁平矢量重绘（推荐）| "blizzard" = 暴雪原版标记
        showBackdrop = true,      -- 烟熏暗色玻璃胶囊托底 + 1px 职业色顶线（与 EUI 统一）
        v3ModernRedesign = false,
        hideWithoutPermission = true,
        hoverReveal = true,
        idleAlpha = 0.78,
        combatFade = false,
        v4NoCombatFadeMigrated = false,
        iconSize = 20,
        overheadSize = 36,        -- 头顶 / 姓名板团队标记尺寸（默认 36px，接近角色自身头顶暴雪默认 3D 标记）
        targetMarkerScalePct = 0, -- 当前目标标记额外放大百分比（默认 0%，范围 0~100%）
        savedEUIRaidMarker = nil, -- 备份 EUI 姓名板原标记尺寸，关闭模块时无损还原
        pullSeconds = 10,
    },
})

local MARK_DIR = F.MEDIA .. "MarkBar\\"
local RAID_ATLAS = MARK_DIR .. "UI-RaidTargetingIcons.blp"
local globalIconHooked = false
local euiRefreshHooked = false
local restoringMarkers = false
local pendingCombatTargetScale = false
-- 记录被换成现代图集的贴图：GetTexture() 返回值会被引擎规范化（且 12.x 可能是机密值），不能拿路径字符串比较
local replacedRaidTex = setmetatable({}, { __mode = "k" })
local origBlizzRaidSize = setmetatable({}, { __mode = "k" })
local scaledTargetMarkers = setmetatable({}, { __mode = "k" })

-- 关闭像素网格吸附与 texel 偏置：放大后的团队标记（尤其在移动的 3D 姓名板上）按子像素平滑采样，消除锯齿抖动
local function DisablePixelSnap(tex)
    if not tex then return end
    if tex.SetSnapToPixelGrid then pcall(tex.SetSnapToPixelGrid, tex, false) end
    if tex.SetTexelSnappingBias then pcall(tex.SetTexelSnappingBias, tex, 0) end
end

local function InstallGlobalRaidIconHook()
    if globalIconHooked or type(_G.hooksecurefunc) ~= "function" then return end
    if type(_G.SetRaidTargetIconTexture) ~= "function" then return end
    globalIconHooked = true
    _G.hooksecurefunc("SetRaidTargetIconTexture", function(tex, idx)
        if not tex or type(tex.SetTexture) ~= "function" then return end
        if tex.IsForbidden and tex:IsForbidden() then return end
        -- 12.x 机密值兼容：type() 零污染安全；严禁把 idx 直接做数值比较否则机密标记会提前返回
        if type(idx) == "nil" then return end
        local wantModern = mod._active and (mod:GetDB().iconPack or "modern") ~= "blizzard"
        if wantModern then
            pcall(tex.SetTexture, tex, RAID_ATLAS, nil, nil, "TRILINEAR")
            DisablePixelSnap(tex)
            replacedRaidTex[tex] = true
        elseif replacedRaidTex[tex] then
            pcall(tex.SetTexture, tex, "Interface\\TargetingFrame\\UI-RaidTargetingIcons")
            replacedRaidTex[tex] = nil
        else
            return
        end
        -- 若 idx 为明文整数则显式校准 TexCoord；若为 12.x 机密值则保留暴雪刚算好的 TexCoord（SetTexture 不清 TexCoord）
        local n = F.PlainNumber(idx, nil)
        if n and n >= 1 and n <= 8 and tex.SetTexCoord then
            local zero = n - 1
            local left = (zero % 4) * 0.25
            local top = math_floor(zero / 4) * 0.25
            pcall(tex.SetTexCoord, tex, left, left + 0.25, top, top + 0.25)
        end
    end)
end

-- EUI 姓名板在文件加载时就把 SetRaidTargetIconTexture 存成了本地变量（早于本插件挂钩），
-- 上面的全局钩子对姓名板标记无效：直接给 EUI 姓名板的标记贴图换上同为 4x4 布局的超高清图集并关闭像素吸附，
-- 之后 EUI 只改 TexCoord，图标就会一直是抗锯齿高清样式。
-- （人物自身头顶与无姓名板单位的 3D 世界标记由游戏引擎绘制，大小不可调，图集可通过 Tools/deploy_raid_markers.py 覆盖。）
local function RetextureRaidTex(tex, wantModern)
    if not tex or type(tex.SetTexture) ~= "function" then return end
    if tex.IsForbidden and tex:IsForbidden() then return end
    if wantModern then
        pcall(tex.SetTexture, tex, RAID_ATLAS, nil, nil, "TRILINEAR")
        DisablePixelSnap(tex)
        replacedRaidTex[tex] = true
    elseif replacedRaidTex[tex] then
        pcall(tex.SetTexture, tex, "Interface\\TargetingFrame\\UI-RaidTargetingIcons")
        replacedRaidTex[tex] = nil
    end
end

local function GetEUINameplateNS()
    local EUI = _G.EllesmereUI
    local ns = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUINameplates
    return type(ns) == "table" and ns or nil
end

local function GetEUINameplateProfile()
    local npNS = GetEUINameplateNS()
    if npNS then
        local enp = npNS.ENP or (npNS._npInternals and npNS._npInternals.ENP)
        if enp and enp.db and type(enp.db.profile) == "table" then
            return enp.db.profile
        end
    end
    local EUI = _G.EllesmereUI
    if EUI and EUI.GetModule then
        local ok, m = pcall(EUI.GetModule, EUI, "EllesmereUINameplates", true)
        if ok and m and m.db and type(m.db.profile) == "table" then
            return m.db.profile
        end
    end
    return nil
end

local function RetexturePlate(plate, wantModern)
    if type(plate) ~= "table" then return end
    RetextureRaidTex(plate.raid, wantModern)
    RetextureRaidTex(plate.nameRaid, wantModern)
end

local function GetConfiguredOverheadSize()
    local raw = F.PlainNumber(mod:GetDB().overheadSize, 36) or 36
    return math_max(16, math_min(64, math_floor(raw + 0.5)))
end

local function GetTargetMarkerScalePct()
    local raw = F.PlainNumber(mod:GetDB().targetMarkerScalePct, 0) or 0
    return math_max(0, math_min(100, math_floor(raw + 0.5)))
end

local function IsSafeObj(obj)
    if not obj then return false end
    if obj.IsForbidden then
        local ok, forb = pcall(obj.IsForbidden, obj)
        if not ok or forb then return false end
    end
    return true
end

-- 判断某个暴雪原生姓名板 UnitFrame 当前是否真正可见（例如友方玩家「仅名字」板，或未装 EUI 时的全部姓名板）
local function IsBlizzUFVisiblyActive(uf)
    if not IsSafeObj(uf) then return false end
    if uf.IsShown and not uf:IsShown() then return false end
    if uf.GetAlpha then
        local ok, a = pcall(uf.GetAlpha, uf)
        local pa = ok and F.PlainNumber(a, 1) or 1
        if pa <= 0.05 then return false end
    end
    return true
end

local function RefreshPlateArrows(plate, npNS)
    if not plate then return end
    if npNS and type(npNS.PositionArrowsOutsideAuras) == "function" then
        pcall(npNS.PositionArrowsOutsideAuras, plate)
    end
    if type(F._RefreshNameplateMotionArrows) == "function" then
        pcall(F._RefreshNameplateMotionArrows, plate)
    end
end

local function RestoreScaledTargetMarkers(exceptObj)
    local inCombatNow = _G.InCombatLockdown and _G.InCombatLockdown()
    local npNS = GetEUINameplateNS()
    local toClear = {}
    for obj, info in pairs(scaledTargetMarkers) do
        if obj ~= exceptObj then
            if info.kind == "blizz" then
                if inCombatNow then
                    pendingCombatTargetScale = true
                else
                    if IsSafeObj(obj) and obj.SetSize then
                        pcall(obj.SetSize, obj, info.baseW, info.baseH)
                    end
                    toClear[#toClear + 1] = obj
                end
            else
                if IsSafeObj(obj) and obj.SetSize then
                    pcall(obj.SetSize, obj, info.baseW, info.baseH)
                end
                if info.kind == "plate" and info.plate then
                    if info.obj == info.plate.raidFrame then
                        info.plate.raidFrame._npSz = info.baseW
                        info.plate.raidFrame._kkScaledExtra = nil
                    end
                    RefreshPlateArrows(info.plate, npNS)
                end
                toClear[#toClear + 1] = obj
            end
        end
    end
    for _, obj in ipairs(toClear) do
        scaledTargetMarkers[obj] = nil
    end
end

-- 当前目标标记额外放大：战斗中只改插件自建框体/贴图（plate.raidFrame / overlay.raid），绝不碰受保护的暴雪 RaidTargetFrame
local function ApplyTargetMarkerScale(restore)
    local pct = GetTargetMarkerScalePct()
    if restore or (not mod._active) or pct <= 0 then
        RestoreScaledTargetMarkers(nil)
        return
    end
    local okE, exists = false, false
    if _G.UnitExists then okE, exists = pcall(_G.UnitExists, "target") end
    if not (okE and not F.IsSecret(exists) and exists == true) then
        RestoreScaledTargetMarkers(nil)
        return
    end

    local baseSz = GetConfiguredOverheadSize()
    local targetSz = math_floor(baseSz * (1 + pct / 100) + 0.5)
    local npNS = GetEUINameplateNS()
    local inCombatNow = _G.InCombatLockdown and _G.InCombatLockdown()
    local activeObj = nil

    -- 1) 定位当前目标对应的姓名板 token
    local targetNP = nil
    if _G.C_NamePlate and _G.C_NamePlate.GetNamePlateForUnit then
        local okN, np = pcall(_G.C_NamePlate.GetNamePlateForUnit, "target")
        if okN and IsSafeObj(np) then targetNP = np end
    end
    local unitToken = targetNP and F.PlainString(targetNP.namePlateUnitToken or (targetNP.UnitFrame and targetNP.UnitFrame.unit), nil) or nil

    local function FindUnitInTable(tbl)
        if type(tbl) ~= "table" then return nil end
        if unitToken and tbl[unitToken] then return tbl[unitToken] end
        if _G.UnitIsUnit then
            for u, pl in pairs(tbl) do
                local okU, same = pcall(_G.UnitIsUnit, u, "target")
                if okU and not F.IsSecret(same) and same == true then
                    return pl
                end
            end
        end
        return nil
    end

    local ep = npNS and FindUnitInTable(npNS.plates) or nil
    local fp = npNS and FindUnitInTable(npNS.friendlyPlates) or nil

    -- 2) 优先改插件自建的 EUI 敌方板 / 友方板（战斗内外均可即时生效）
    local euiPlate = (ep and IsSafeObj(ep) and ep:IsShown() and ep)
        or (fp and IsSafeObj(fp) and fp:IsShown() and fp) or nil
    if euiPlate and euiPlate.raidFrame and IsSafeObj(euiPlate.raidFrame) and euiPlate.raidFrame.SetSize then
        activeObj = euiPlate.raidFrame
        local wasScaled = scaledTargetMarkers[activeObj] ~= nil
        RestoreScaledTargetMarkers(activeObj)
        scaledTargetMarkers[activeObj] = {
            obj = activeObj, kind = "plate", plate = euiPlate, baseW = baseSz, baseH = baseSz,
        }
        pcall(activeObj.SetSize, activeObj, targetSz, targetSz)
        activeObj._npSz = targetSz
        activeObj._kkScaledExtra = targetSz - baseSz
        RefreshPlateArrows(euiPlate, npNS)
        if not wasScaled and targetSz > baseSz and F.Motion and F.Motion.PlayScalePop then
            F.Motion.PlayScalePop(euiPlate.raid or activeObj, 1.12, 0.18)
        end
        return
    end

    -- 3) 友方 NPC 仅名字覆盖层（插件自建，战斗内外均安全）
    if targetNP and targetNP.GetChildren then
        local okC, children = pcall(function() return { targetNP:GetChildren() } end)
        if okC and type(children) == "table" then
            for _, ch in ipairs(children) do
                if ch and ch ~= ep and ch ~= fp and IsSafeObj(ch) and ch.raid and IsSafeObj(ch.raid)
                    and ch:IsShown() and ch.raid.SetSize then
                    activeObj = ch.raid
                    RestoreScaledTargetMarkers(activeObj)
                    scaledTargetMarkers[activeObj] = {
                        obj = activeObj, kind = "overlay", baseW = baseSz, baseH = baseSz,
                    }
                    pcall(activeObj.SetSize, activeObj, targetSz, targetSz)
                    return
                end
            end
        end
    end

    -- 4) 暴雪原生姓名板（含友方玩家「仅名字」板）：仅脱战时缩放
    if targetNP then
        local uf = targetNP.UnitFrame
        local rtf = uf and uf.RaidTargetFrame
        if IsBlizzUFVisiblyActive(uf) and IsSafeObj(rtf) and rtf.SetSize then
            if inCombatNow then
                pendingCombatTargetScale = true
                RestoreScaledTargetMarkers(nil)
            else
                activeObj = rtf
                RestoreScaledTargetMarkers(activeObj)
                scaledTargetMarkers[activeObj] = {
                    obj = activeObj, kind = "blizz", baseW = baseSz, baseH = baseSz,
                }
                pcall(rtf.SetSize, rtf, targetSz, targetSz)
            end
            return
        end
    end

    RestoreScaledTargetMarkers(nil)
end

-- 同步覆盖层（EUI 友方 NPC 仅名字覆盖层）与暴雪原生姓名板（含友方玩家「仅名字」板）的团队标记贴图及尺寸
local function SyncNameplateChildMarkers(wantModern, sz, restore)
    local CNP = _G.C_NamePlate
    if not (CNP and CNP.GetNamePlates) then return end
    local ok, list = pcall(CNP.GetNamePlates)
    if not (ok and type(list) == "table") then return end
    local npNS = GetEUINameplateNS()
    local inCombatNow = _G.InCombatLockdown and _G.InCombatLockdown()
    for _, np in ipairs(list) do
        if IsSafeObj(np) then
            local unitToken = F.PlainString(np.namePlateUnitToken or (np.UnitFrame and np.UnitFrame.unit), nil)
            local ep = npNS and unitToken and type(npNS.plates) == "table" and npNS.plates[unitToken] or nil
            local fp = npNS and unitToken and type(npNS.friendlyPlates) == "table" and npNS.friendlyPlates[unitToken] or nil
            -- 1) EUI 友方 NPC / 宠物仅名字覆盖层（挂在 nameplate 子框体上，带 .raid 贴图）
            if np.GetChildren then
                local okC, children = pcall(function() return { np:GetChildren() } end)
                if okC and type(children) == "table" then
                    for _, ch in ipairs(children) do
                        if ch and ch ~= ep and ch ~= fp and IsSafeObj(ch) and ch.raid then
                            RetextureRaidTex(ch.raid, wantModern)
                            if not restore and mod._active and ch.raid.SetSize then
                                pcall(ch.raid.SetSize, ch.raid, sz, sz)
                            end
                        end
                    end
                end
            end
            -- 2) 暴雪原生姓名板（含 EUI 开启时的友方玩家「仅名字」板以及无 EUI 时的全部姓名板）：仅脱战时调整尺寸
            local uf = np.UnitFrame
            local rtf = uf and uf.RaidTargetFrame
            if IsSafeObj(rtf) then
                local rti = rtf.RaidTargetIcon
                if IsSafeObj(rti) then
                    DisablePixelSnap(rti)
                    if not restore and wantModern then
                        RetextureRaidTex(rti, true)
                    elseif restore then
                        RetextureRaidTex(rti, false)
                    end
                end
                if not inCombatNow then
                    if restore then
                        local orig = origBlizzRaidSize[rtf]
                        if orig then
                            pcall(rtf.SetSize, rtf, orig[1], orig[2])
                            origBlizzRaidSize[rtf] = nil
                        end
                    elseif mod._active and IsBlizzUFVisiblyActive(uf) then
                        if not origBlizzRaidSize[rtf] and rtf.GetSize then
                            local okS, ow, oh = pcall(rtf.GetSize, rtf)
                            local pw, ph = okS and F.PlainNumber(ow, nil), okS and F.PlainNumber(oh, nil)
                            if pw and ph and pw > 0 and ph > 0 then
                                origBlizzRaidSize[rtf] = { pw, ph }
                            end
                        end
                        pcall(rtf.SetSize, rtf, sz, sz)
                    end
                elseif restore then
                    pendingCombatTargetScale = true
                end
            end
        end
    end
end

local function SyncEUIPlateRaidIcons(unit)
    local ns = GetEUINameplateNS()
    local wantModern = mod._active and (mod:GetDB().iconPack or "modern") ~= "blizzard"
    local sz = GetConfiguredOverheadSize()
    if ns then
        if unit then
            if type(ns.plates) == "table" then RetexturePlate(ns.plates[unit], wantModern) end
            if type(ns.friendlyPlates) == "table" then RetexturePlate(ns.friendlyPlates[unit], wantModern) end
        else
            if type(ns.plates) == "table" then
                for _, plate in pairs(ns.plates) do RetexturePlate(plate, wantModern) end
            end
            if type(ns.friendlyPlates) == "table" then
                for _, plate in pairs(ns.friendlyPlates) do RetexturePlate(plate, wantModern) end
            end
        end
    end
    SyncNameplateChildMarkers(wantModern, sz, not mod._active)
    ApplyTargetMarkerScale(not mod._active)
end

-- 将「标记大小」同步到 EUI 姓名板（敌方板 + 友方血条板 + 名字旁标记 + 友方 NPC 覆盖层）及暴雪原生/友方仅名字板
local function SyncOverheadMarkerSize(restore)
    local db = mod:GetDB()
    local sz = GetConfiguredOverheadSize()
    local wantModern = (not restore) and mod._active and (db.iconPack or "modern") ~= "blizzard"
    local npNS = GetEUINameplateNS()
    local p = GetEUINameplateProfile()

    restoringMarkers = restore == true
    if p then
        if restore then
            local saved = db.savedEUIRaidMarker
            if type(saved) == "table" then
                if saved.core == "__nil__" then p.raidMarkerCoreSize = nil else p.raidMarkerCoreSize = saved.core end
                if saved.base == "__nil__" then p.raidMarkerSize = nil else p.raidMarkerSize = saved.base end
                if saved.nameSz ~= nil then
                    if saved.nameSz == "__nil__" then p.nameRaidMarkerSize = nil else p.nameRaidMarkerSize = saved.nameSz end
                end
                if saved.nameEn ~= nil then
                    if saved.nameEn == "__nil__" then p.nameRaidMarkerEnabled = nil else p.nameRaidMarkerEnabled = saved.nameEn end
                end
                db.savedEUIRaidMarker = nil
            end
        elseif mod._active then
            if type(db.savedEUIRaidMarker) ~= "table" then
                db.savedEUIRaidMarker = {
                    core = p.raidMarkerCoreSize == nil and "__nil__" or p.raidMarkerCoreSize,
                    base = p.raidMarkerSize == nil and "__nil__" or p.raidMarkerSize,
                    nameSz = p.nameRaidMarkerSize == nil and "__nil__" or p.nameRaidMarkerSize,
                    nameEn = p.nameRaidMarkerEnabled == nil and "__nil__" or p.nameRaidMarkerEnabled,
                }
            else
                if db.savedEUIRaidMarker.nameSz == nil then
                    db.savedEUIRaidMarker.nameSz = p.nameRaidMarkerSize == nil and "__nil__" or p.nameRaidMarkerSize
                end
                if db.savedEUIRaidMarker.nameEn == nil then
                    db.savedEUIRaidMarker.nameEn = p.nameRaidMarkerEnabled == nil and "__nil__" or p.nameRaidMarkerEnabled
                end
            end
            p.raidMarkerCoreSize = sz
            p.raidMarkerSize = sz
            p.nameRaidMarkerSize = sz
            if p.raidMarkerPos == "none" then
                p.nameRaidMarkerEnabled = true
            end
        end
    end

    if npNS then
        if type(npNS.plates) == "table" then
            for _, plate in pairs(npNS.plates) do
                RetexturePlate(plate, wantModern)
                if plate and plate.unit and type(plate.UpdateRaidIcon) == "function" then
                    pcall(plate.UpdateRaidIcon, plate)
                end
                if plate and plate.unit and p and p.nameRaidMarkerEnabled == true
                    and type(plate.RefreshNamePosition) == "function" then
                    pcall(plate.RefreshNamePosition, plate, true)
                end
            end
        end
        if type(npNS.friendlyPlates) == "table" then
            for _, fp in pairs(npNS.friendlyPlates) do
                RetexturePlate(fp, wantModern)
                if fp and fp.unit and type(fp.UpdateRaidIcon) == "function" then
                    pcall(fp.UpdateRaidIcon, fp)
                end
            end
        end
        if type(npNS.RefreshAllNPCOverlays) == "function" then
            pcall(npNS.RefreshAllNPCOverlays)
        end
    end
    SyncNameplateChildMarkers(wantModern, sz, restore == true)
    ApplyTargetMarkerScale(restore == true)
    restoringMarkers = false
end

local function SyncAllRaidIcons()
    local wantModern = mod._active and (mod:GetDB().iconPack or "modern") ~= "blizzard"
    local list = {}
    for tex in pairs(replacedRaidTex) do
        list[#list + 1] = tex
    end
    for _, tex in ipairs(list) do
        RetextureRaidTex(tex, wantModern)
    end
    SyncEUIPlateRaidIcons()
end

local MARK_SPECS = {
    { index = 8, name = "骷髅", file = "Mark8.tga", color = { 0.96, 0.97, 1.00 } },
    { index = 7, name = "红叉", file = "Mark7.tga", color = { 0.96, 0.34, 0.38 } },
    { index = 6, name = "方块", file = "Mark6.tga", color = { 0.28, 0.76, 0.98 } },
    { index = 5, name = "月亮", file = "Mark5.tga", color = { 0.80, 0.86, 0.95 } },
    { index = 4, name = "三角", file = "Mark4.tga", color = { 0.24, 0.86, 0.48 } },
    { index = 3, name = "菱形", file = "Mark3.tga", color = { 0.78, 0.48, 0.98 } },
    { index = 2, name = "大饼", file = "Mark2.tga", color = { 0.99, 0.62, 0.24 } },
    { index = 1, name = "星星", file = "Mark1.tga", color = { 0.99, 0.84, 0.30 } },
}

local ACTION_SPECS = {
    {
        id = "clear",
        file = "Clear.tga",
        fallbackText = "清",
        label = "清除目标标记",
        color = { 0.94, 0.50, 0.54 },
        macro = "/tm 0",
    },
    {
        id = "ready",
        file = "Ready.tga",
        fallbackText = "备",
        label = "发起就位确认",
        color = { 0.40, 0.88, 0.62 },
        macro = "/readycheck",
    },
    {
        id = "pull",
        file = "Pull.tga",
        fallbackText = "倒",
        label = "发起开怪倒数",
        color = { 0.98, 0.78, 0.36 },
        macroFn = function()
            return "/countdown " .. tostring(mod:GetDB().pullSeconds or 10)
        end,
    },
}

local barFrame = nil
local topHairline = nil
local sepTex = nil
local markBtns = {}
local actionBtns = {}
local isHovered = false
local isDraggingBar = false
local inCombat = false
local currentTargetMark = 0

local function StartBarDrag()
    if not barFrame then return end
    if _G.IsShiftKeyDown and _G.IsShiftKeyDown() and not (inCombat or (_G.InCombatLockdown and _G.InCombatLockdown())) then
        isDraggingBar = true
        barFrame:StartMoving()
    end
end

local function StopBarDrag()
    if not isDraggingBar then return end
    isDraggingBar = false
    if not barFrame then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end
    barFrame:StopMovingOrSizing()
    local pt, _, rpt, x, y = barFrame:GetPoint(1)
    if pt and rpt then
        F.DB.SavePosition("MarkBar", pt, rpt, x, y)
    end
end

local function RefreshActionMacros()
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarMacros", RefreshActionMacros)
        return
    end
    for _, btn in ipairs(actionBtns) do
        local spec = btn._spec
        if spec and spec.macroFn then
            btn:SetAttribute("macrotext", spec.macroFn())
        end
    end
end

local function HasMarkPermission()
    if not (_G.IsInGroup and _G.IsInGroup()) then
        return true
    end
    if not (_G.IsInRaid and _G.IsInRaid()) then
        return true
    end
    return (_G.UnitIsGroupLeader and _G.UnitIsGroupLeader("player"))
        or (_G.UnitIsGroupAssistant and _G.UnitIsGroupAssistant("player"))
end

local function SyncAlpha(instant)
    if not (barFrame and barFrame:IsShown()) then return end
    local db = mod:GetDB()
    local over = isHovered or (barFrame.IsMouseOver and barFrame:IsMouseOver())
    local goal = 1.0
    if not over then
        if db.combatFade and (inCombat or (_G.InCombatLockdown and _G.InCombatLockdown())) then
            goal = (F.db and F.db.theme and F.db.theme.combatFadeAlpha) or 0.18
        elseif db.hoverReveal ~= false then
            goal = db.idleAlpha or 0.78
        end
    end
    if instant then
        F.Theme.FadeTo(barFrame, goal, 0)
        return
    end
    local cur = F.PlainNumber(barFrame:GetAlpha(), 1)
    if (cur - goal) < 0.015 and (goal - cur) < 0.015 then return end
    F.Theme.FadeTo(barFrame, goal, goal > cur and 0.14 or 0.22)
end

local function ScheduleLeaveCheck()
    local db = mod:GetDB()
    if db.hoverReveal == false and db.combatFade ~= true then
        isHovered = false
        return
    end
    C_Timer.After(0.10, function()
        if not (barFrame and barFrame:IsMouseOver()) then
            isHovered = false
            SyncAlpha(false)
        end
    end)
end

local function PaintCellState(btn, isActive)
    local hovered = btn._isHovered == true
    local col = btn._color or { 0.85, 0.88, 0.92 }
    if hovered then
        btn._cellBg:SetColorTexture(col[1], col[2], col[3], 0.22)
        btn._underline:SetColorTexture(col[1], col[2], col[3], 0.95)
        btn._underline:Show()
        if btn._icon then btn._icon:SetAlpha(1.0) end
        if btn._actionColor and btn._icon then
            btn._icon:SetVertexColor(
                math_max(col[1], col[1] * 0.85 + 0.15),
                math_max(col[2], col[2] * 0.85 + 0.15),
                math_max(col[3], col[3] * 0.85 + 0.15), 1)
        end
    elseif isActive then
        btn._cellBg:SetColorTexture(col[1], col[2], col[3], 0.16)
        btn._underline:SetColorTexture(col[1], col[2], col[3], 0.92)
        btn._underline:Show()
        if btn._icon then btn._icon:SetAlpha(1.0) end
    else
        local showBg = mod:GetDB().showBackdrop ~= false
        if showBg then
            btn._cellBg:SetColorTexture(1, 1, 1, 0.035)
        else
            btn._cellBg:SetColorTexture(0, 0, 0, 0)
        end
        btn._underline:Hide()
        if btn._icon then
            btn._icon:SetAlpha(0.92)
            if btn._actionColor then
                btn._icon:SetVertexColor(col[1], col[2], col[3], 0.92)
            end
        end
    end
end

local function RefreshTargetMarkHighlight()
    local prevIdx = currentTargetMark
    local idx = 0
    if _G.UnitExists and _G.GetRaidTargetIndex then
        local okE, exists = pcall(_G.UnitExists, "target")
        if okE and not F.IsSecret(exists) and exists == true then
            local okR, rIdx = pcall(_G.GetRaidTargetIndex, "target")
            if okR then idx = F.PlainNumber(rIdx, 0) or 0 end
        end
    end
    currentTargetMark = idx
    for _, btn in ipairs(markBtns) do
        local isAct = idx > 0 and btn._markIndex == idx
        PaintCellState(btn, isAct)
        if isAct and idx ~= prevIdx and F.Motion and F.Motion.PlayScalePop then
            F.Motion.PlayScalePop(btn._icon, 1.18, 0.18)
        end
    end
end

local function LayoutAndStyle()
    if not barFrame then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarLayout", LayoutAndStyle)
        return
    end
    local db = mod:GetDB()
    local ar, ag, ab = F.Theme.GetAccent()
    local showBg = db.showBackdrop ~= false
    local useModern = (db.iconPack or "modern") ~= "blizzard"

    local iconSz = math_max(14, math_floor(F.PlainNumber(db.iconSize, 20) + 0.5))
    local cellSz = iconSz + 6
    local gap = 2
    local padX = showBg and 6 or 2
    local padY = showBg and 4 or 2
    local sepSpace = 9

    local ST = F.StyleTokens
    if showBg then
        F.Theme.StyleLuminousCard(barFrame, {
            palette = "class",
            radius = 7,
            bgAlpha = 0.76,
            tintMix = 0.16,
            glowAlpha = 0.22,
            glowWidth = 136,
            borderAlpha = 0.76,
            leftBar = false,
        })
        if barFrame._fuiBg then barFrame._fuiBg:Hide() end
        if barFrame._fuiBorders then
            for _, ln in ipairs(barFrame._fuiBorders) do ln:Hide() end
        end
        if topHairline then
            if ST and ST.ApplyGradient and ST.GetClassGradient then
                topHairline:SetTexture(ST.TEX.FLAT)
                local r1, g1, b1, r2, g2, b2 = ST.GetClassGradient()
                ST.ApplyGradient(topHairline, "HORIZONTAL", r1, g1, b1, 0.88, r2, g2, b2, 0.98)
            else
                topHairline:SetColorTexture(ar, ag, ab, 0.80)
            end
            if ST then ST.MaskTexture(barFrame, topHairline, 7) end
            topHairline:Show()
        end
    else
        F.Theme.SetLuminousCardShown(barFrame, false)
        if barFrame._fuiBg then barFrame._fuiBg:Hide() end
        if barFrame._fuiBorders then
            for _, ln in ipairs(barFrame._fuiBorders) do ln:Hide() end
        end
        if topHairline then topHairline:Hide() end
    end

    local x = padX
    for _, btn in ipairs(markBtns) do
        btn:ClearAllPoints()
        btn:SetSize(cellSz, cellSz)
        btn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        btn._icon:SetSize(iconSz, iconSz)
        if useModern then
            btn._icon:SetTexCoord(0, 1, 0, 1)
            pcall(btn._icon.SetTexture, btn._icon, MARK_DIR .. btn._spec.file, nil, nil, "TRILINEAR")
            DisablePixelSnap(btn._icon)
            btn._icon:SetVertexColor(1, 1, 1, 1)
        else
            btn._icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
            if _G.SetRaidTargetIconTexture then
                _G.SetRaidTargetIconTexture(btn._icon, btn._markIndex)
            end
            btn._icon:SetVertexColor(1, 1, 1, 1)
        end
        PaintCellState(btn, currentTargetMark > 0 and btn._markIndex == currentTargetMark)
        x = x + cellSz + gap
    end

    -- 1px 垂直细分隔线（严格垂直居中于标记条）
    if sepTex then
        sepTex:ClearAllPoints()
        sepTex:SetSize(1, math_max(10, cellSz - 8))
        sepTex:SetPoint("LEFT", barFrame, "LEFT", x + math_floor((sepSpace - gap) / 2), 0)
        sepTex:SetColorTexture(1, 1, 1, showBg and 0.16 or 0.24)
    end
    x = x + (sepSpace - gap)

    local actIconSz = math_max(14, iconSz - 1)
    for _, btn in ipairs(actionBtns) do
        btn:ClearAllPoints()
        btn:SetSize(cellSz, cellSz)
        btn:SetPoint("LEFT", barFrame, "LEFT", x, 0)
        btn._icon:SetSize(actIconSz, actIconSz)
        pcall(btn._icon.SetTexture, btn._icon, MARK_DIR .. btn._spec.file, nil, nil, "TRILINEAR")
        DisablePixelSnap(btn._icon)
        PaintCellState(btn, false)
        x = x + cellSz + gap
    end

    local totalW = x - gap + padX
    local totalH = cellSz + padY * 2
    barFrame:SetSize(totalW, totalH)
    SyncAlpha(true)
end

local function UpdateVisibility()
    if not barFrame then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarVis", UpdateVisibility)
        return
    end
    local db = mod:GetDB()
    if not mod._active then
        barFrame:Hide()
        return
    end
    if db.hideWithoutPermission and not HasMarkPermission() then
        barFrame:Hide()
    else
        barFrame:Show()
        RefreshTargetMarkHighlight()
        SyncAlpha(true)
    end
end

local function CreateCellButton(parent, color, macroText)
    -- 使用暴雪安全动作按钮执行 /tm /readycheck /countdown：
    -- 彻底解决 16001/12.x 下 SetRaidTarget 受保护触发 ADDON_ACTION_BLOCKED 报错，战斗内外均可用
    local btn = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    btn._color = color
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetAttribute("useOnKeyDown", false)
    btn:SetAttribute("type1", "macro")
    btn:SetAttribute("shift-type1", "") -- Shift+左键专用于拖拽，不误触标记或倒数
    if macroText then
        btn:SetAttribute("macrotext", macroText)
    end

    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", StartBarDrag)
    btn:SetScript("OnDragStop", StopBarDrag)

    local cellBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
    cellBg:SetAllPoints()
    if F.StyleTokens and F.StyleTokens.MaskTexture then
        F.StyleTokens.MaskTexture(btn, cellBg, 4)
    end
    btn._cellBg = cellBg

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
    btn._icon = icon

    local underline = btn:CreateTexture(nil, "OVERLAY", nil, 6)
    underline:SetHeight(2)
    underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 3, 1)
    underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -3, 1)
    underline:Hide()
    btn._underline = underline

    return btn
end

local function CreateBar()
    if barFrame then return end
    barFrame = CreateFrame("Frame", "kkowoUI_MarkBar", _G.UIParent)
    barFrame:SetSize(310, 32)
    barFrame:SetFrameStrata("HIGH")
    barFrame:EnableMouse(true)

    topHairline = barFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    topHairline:SetHeight(1)
    topHairline:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
    topHairline:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, 0)

    sepTex = barFrame:CreateTexture(nil, "ARTWORK")

    barFrame:SetScript("OnEnter", function()
        isHovered = true
        SyncAlpha(false)
    end)
    barFrame:SetScript("OnLeave", ScheduleLeaveCheck)
    barFrame:SetMovable(true)
    barFrame:RegisterForDrag("LeftButton")
    barFrame:SetScript("OnDragStart", StartBarDrag)
    barFrame:SetScript("OnDragStop", StopBarDrag)
    barFrame:HookScript("OnHide", StopBarDrag)

    for i, spec in ipairs(MARK_SPECS) do
        local btn = CreateCellButton(barFrame, spec.color, "/tm " .. tostring(spec.index))
        btn._spec = spec
        btn._markIndex = spec.index

        btn:SetScript("OnEnter", function(self)
            isHovered = true
            self._isHovered = true
            SyncAlpha(false)
            PaintCellState(self, currentTargetMark == spec.index)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM", 0, -4)
            GameTooltip:AddLine("标记：" .. spec.name, spec.color[1], spec.color[2], spec.color[3])
            GameTooltip:AddLine("左键点击给当前目标上标记（再次点击清除）", 0.82, 0.85, 0.89)
            GameTooltip:AddLine("Shift + 左键拖动可移动标记条", 0.56, 0.60, 0.66)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self._isHovered = false
            PaintCellState(self, currentTargetMark == spec.index)
            GameTooltip:Hide()
            ScheduleLeaveCheck()
        end)
        markBtns[i] = btn
    end

    for i, spec in ipairs(ACTION_SPECS) do
        local macro = spec.macroFn and spec.macroFn() or spec.macro
        local btn = CreateCellButton(barFrame, spec.color, macro)
        btn._spec = spec
        btn._actionColor = true

        btn:SetScript("OnEnter", function(self)
            isHovered = true
            self._isHovered = true
            SyncAlpha(false)
            PaintCellState(self, false)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM", 0, -4)
            local title = spec.label
            if spec.id == "pull" then
                title = spec.label .. " (" .. tostring(mod:GetDB().pullSeconds or 10) .. "秒)"
            end
            GameTooltip:AddLine(title, spec.color[1], spec.color[2], spec.color[3])
            GameTooltip:AddLine("Shift + 左键拖动可移动标记条", 0.56, 0.60, 0.66)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self)
            self._isHovered = false
            PaintCellState(self, false)
            GameTooltip:Hide()
            ScheduleLeaveCheck()
        end)
        actionBtns[i] = btn
    end

    F.Mover.Register({
        key = "MarkBar",
        label = "快捷标记条",
        frame = barFrame,
        order = 40,
        defaultPoint = "TOP",
        defaultRelPoint = "TOP",
        defaultX = 0,
        defaultY = -44,
        allowShiftDrag = false,
        isHidden = function() return not mod._active end,
    })
end

function mod:OnEnable()
    local db = self:GetDB()
    inCombat = (_G.InCombatLockdown and _G.InCombatLockdown()) == true
    if not db.v3ModernRedesign then
        db.v3ModernRedesign = true
        db.iconPack = "modern"
        db.showBackdrop = true
        db.idleAlpha = 0.78
    end
    if not db.v4NoCombatFadeMigrated then
        db.v4NoCombatFadeMigrated = true
        db.combatFade = false
    end
    InstallGlobalRaidIconHook()
    if not barFrame and _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("FUI_MarkBarCreate", function()
            if not mod._active then return end
            CreateBar()
            LayoutAndStyle()
            UpdateVisibility()
        end)
    else
        CreateBar()
        LayoutAndStyle()
        UpdateVisibility()
    end
    self:RegisterEvent("GROUP_ROSTER_UPDATE", UpdateVisibility)
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        UpdateVisibility()
        SyncOverheadMarkerSize(false)
        SyncAllRaidIcons()
    end)
    self:RegisterEvent("PLAYER_TARGET_CHANGED", function()
        RefreshTargetMarkHighlight()
        ApplyTargetMarkerScale(false)
    end)
    self:RegisterEvent("RAID_TARGET_UPDATE", function()
        RefreshTargetMarkHighlight()
        -- 晚一帧，等 EUI 姓名板自己的标记刷新先跑完
        C_Timer.After(0, function() if mod._active then SyncEUIPlateRaidIcons() end end)
    end)
    self:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, _, unit)
        local u = F.PlainString(unit, nil)
        if not u then return end
        C_Timer.After(0, function() if mod._active then SyncEUIPlateRaidIcons(u) end end)
    end)
    self:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function()
        if mod._active then ApplyTargetMarkerScale(false) end
    end)
    -- 冲突优先权：本模块开启时以 kkowoUI 标记大小为准，避免在 EUI 面板里误调导致不同步
    local EUI = _G.EllesmereUI
    if (not euiRefreshHooked) and EUI and type(EUI.RegisterWidgetRefresh) == "function" then
        euiRefreshHooked = true
        pcall(EUI.RegisterWidgetRefresh, function()
            if restoringMarkers or not mod._active then return end
            local p = GetEUINameplateProfile()
            local sz = GetConfiguredOverheadSize()
            if p and (p.raidMarkerSize ~= sz or p.raidMarkerCoreSize ~= sz or p.nameRaidMarkerSize ~= sz) then
                F.PrintOnce("markBarEuiPriority", "标记大小当前由 kkowoUI 统一管理，请在 kkowoUI「标记与标记条」中调节。")
                SyncOverheadMarkerSize(false)
            end
        end)
    end
    SyncOverheadMarkerSize(false)
    SyncAllRaidIcons()
    C_Timer.After(0.5, function()
        if mod._active then
            SyncOverheadMarkerSize(false)
            SyncAllRaidIcons()
        end
    end)
    self:RegisterEvent("PLAYER_REGEN_DISABLED", function()
        inCombat = true
        -- 条上挂着安全按钮：拖动中进战必须在本事件内（受保护调用仍合法）结束移动，否则松手时 StopMovingOrSizing 会被拦截
        if isDraggingBar and barFrame then
            isDraggingBar = false
            barFrame:StopMovingOrSizing()
            local pt, _, rpt, x, y = barFrame:GetPoint(1)
            if pt and rpt then
                F.DB.SavePosition("MarkBar", pt, rpt, x, y)
            end
        end
        if mod:GetDB().combatFade == true then SyncAlpha(false) end
    end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        inCombat = false
        if mod:GetDB().combatFade == true then SyncAlpha(false) end
        pendingCombatTargetScale = false
        SyncEUIPlateRaidIcons()
    end)
end

function mod:OnDisable()
    inCombat = false
    StopBarDrag()
    -- 停用后把姓名板标记尺寸（含敌方/友方/仅名字板）与已换掉的全部团队标记还原成原状
    SyncOverheadMarkerSize(true)
    SyncAllRaidIcons()
    if pendingCombatTargetScale then
        F.RunOutOfCombat("FUI_MarkBarRestoreBlizz", function()
            if not mod._active then
                pendingCombatTargetScale = false
                RestoreScaledTargetMarkers(nil)
                SyncNameplateChildMarkers(false, GetConfiguredOverheadSize(), true)
            end
        end)
    end
    if barFrame then
        if _G.InCombatLockdown and _G.InCombatLockdown() then
            F.RunOutOfCombat("FUI_MarkBarVis", function()
                if barFrame and not mod._active then barFrame:Hide() end
            end)
        else
            barFrame:Hide()
        end
    end
end

function mod:ApplyOverheadSize(sz)
    local db = self:GetDB()
    db.overheadSize = math_max(16, math_min(64, math_floor((F.PlainNumber(sz, 36) or 36) + 0.5)))
    SyncOverheadMarkerSize(false)
    return db.overheadSize
end

function mod:ApplyTargetScalePct(pct)
    local db = self:GetDB()
    db.targetMarkerScalePct = math_max(0, math_min(100, math_floor((F.PlainNumber(pct, 0) or 0) + 0.5)))
    ApplyTargetMarkerScale(false)
    return db.targetMarkerScalePct
end

function mod:OnThemeChanged()
    LayoutAndStyle()
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "dropdown",
        text = "标记图标风格",
        tooltip = "可选现代矢量重绘标记，或切回暴雪原版团队标记图标。",
        values = {
            modern   = "现代扁平矢量重绘（推荐）",
            blizzard = "经典暴雪原版标记",
        },
        order = { "modern", "blizzard" },
        getValue = function() return db.iconPack or "modern" end,
        setValue = function(v) db.iconPack = v; LayoutAndStyle(); SyncAllRaidIcons() end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "slider",
        text = "标记大小 (px)",
        tooltip = "统一调节敌友与仅名字板标记，自己头顶由游戏绘制无法调整。",
        min = 16, max = 64, step = 1,
        getValue = function() return GetConfiguredOverheadSize() end,
        setValue = function(v)
            db.overheadSize = math_max(16, math_min(64, math_floor((v or 36) + 0.5)))
            SyncOverheadMarkerSize(false)
        end,
    }, {
        type = "slider",
        text = "当前目标放大 (%)",
        tooltip = "选中目标时额外放大其姓名板标记，切换目标自动还原。默认 0%。",
        min = 0, max = 100, step = 5,
        getValue = function() return GetTargetMarkerScalePct() end,
        setValue = function(v)
            mod:ApplyTargetScalePct(v)
        end,
    })
    y = y - h

    local function buildAdv(w, p, curY)
        local _, rh
        _, rh = w:DualRow(p, curY, {
            type = "slider",
            text = "按钮图标大小 (px)",
            min = 16, max = 28, step = 1,
            getValue = function() return db.iconSize or 20 end,
            setValue = function(v) db.iconSize = v; LayoutAndStyle() end,
        }, {
            type = "slider",
            text = "开怪倒数 (秒)",
            min = 3, max = 20, step = 1,
            getValue = function() return db.pullSeconds or 10 end,
            setValue = function(v) db.pullSeconds = v; RefreshActionMacros() end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "显示玻璃托底",
            tooltip = "开启后显示半透明暗色托底与职业色顶线，关闭则透明悬浮。",
            getValue = function() return db.showBackdrop ~= false end,
            setValue = function(v) db.showBackdrop = v == true; LayoutAndStyle() end,
        }, {
            type = "toggle",
            text = "悬停高亮显示",
            tooltip = "平时半透明淡化，鼠标移到标记条上立即完全清晰。",
            getValue = function() return db.hoverReveal ~= false end,
            setValue = function(v) db.hoverReveal = v == true; SyncAlpha(false) end,
        })
        curY = curY - rh

        _, rh = w:DualRow(p, curY, {
            type = "toggle",
            text = "无权限自动隐藏",
            tooltip = "单人和小队始终显示，团队中非团长或助理时自动隐藏。",
            getValue = function() return db.hideWithoutPermission ~= false end,
            setValue = function(v) db.hideWithoutPermission = v == true; UpdateVisibility() end,
        }, {
            type = "toggle",
            text = "战斗中自动淡出",
            getValue = function() return db.combatFade == true end,
            setValue = function(v) db.combatFade = v == true; SyncAlpha(false) end,
        })
        curY = curY - rh
        return curY
    end

    if type(F.BuildAdvancedSection) == "function" then
        y = F.BuildAdvancedSection("markBar", W, parent, y, buildAdv, blank)
    else
        y = buildAdv(W, parent, y)
    end
    return y
end
