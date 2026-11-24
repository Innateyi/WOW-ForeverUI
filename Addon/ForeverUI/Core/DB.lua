----------------------------------------------------------------------
--  ForeverUI — Core/DB.lua
--  账号级 / 角色级存档管理 + 首次启动自动继承旧哈兰德关键偏好
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local type, pairs = type, pairs

local DB = {}
F.DB = DB

local ACCOUNT_DEFAULTS = {
    version = 1,
    migratedFromHaaland = false,
    modules = {},
    positions = {},
    theme = {
        accentMode = "class",      -- "class" = 职业主题色（默认）, "eui" = 跟随 EllesmereUI 主色
        combatFadeAlpha = 0.18,
    },
}

local CHAR_DEFAULTS = {
    xpSession = {
        gainedXP = 0,
        startTime = 0,
        lastXP = 0,
        maxXP = 0,
    },
}

local moduleDefaults = {}

function DB.RegisterDefaults(key, defaults)
    moduleDefaults[key] = defaults or {}
    if F.db then
        F.db.modules[key] = F.MergeDefaults(F.db.modules[key], moduleDefaults[key])
    end
end

function DB.GetModule(key)
    if not F.db then
        DB.Init()
    end
    if not F.db.modules[key] then
        F.db.modules[key] = F.DeepCopy(moduleDefaults[key] or {})
    end
    return F.db.modules[key]
end

function DB.GetPosition(key)
    if not F.db then
        DB.Init()
    end
    return F.db.positions[key]
end

local VALID_ANCHOR_POINTS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function IsFiniteNum(v)
    return type(v) == "number" and v == v and v > -1e6 and v < 1e6
end

function DB.SavePosition(key, point, relPoint, x, y)
    if not F.db then
        DB.Init()
    end
    local pt = F.PlainString(point, nil)
    local rpt = F.PlainString(relPoint, nil)
    local nx = F.PlainNumber(x, nil)
    local ny = F.PlainNumber(y, nil)
    if not (pt and VALID_ANCHOR_POINTS[pt]) then return end
    if not (IsFiniteNum(nx) and IsFiniteNum(ny)) then return end
    local finalRel = (rpt and VALID_ANCHOR_POINTS[rpt]) and rpt or pt
    F.db.positions[key] = {
        point = pt,
        relPoint = finalRel,
        x = nx,
        y = ny,
    }
end

local function SanitizePositions()
    if type(F.db) ~= "table" or type(F.db.positions) ~= "table" then return end
    for k, pos in pairs(F.db.positions) do
        local pt = type(pos) == "table" and F.PlainString(pos.point, nil) or nil
        local rpt = type(pos) == "table" and pos.relPoint ~= nil and F.PlainString(pos.relPoint, nil) or nil
        local nx = type(pos) == "table" and F.PlainNumber(pos.x, nil) or nil
        local ny = type(pos) == "table" and F.PlainNumber(pos.y, nil) or nil
        local bad = type(pos) ~= "table"
            or not (pt and VALID_ANCHOR_POINTS[pt])
            or not (IsFiniteNum(nx) and IsFiniteNum(ny))
            or (pos.relPoint ~= nil and not (rpt and VALID_ANCHOR_POINTS[rpt]))
        if bad then
            F.db.positions[k] = nil
        end
    end
end

function DB.ClearPosition(key)
    if F.db and F.db.positions then
        F.db.positions[key] = nil
    end
end

-- 首次登录如果存在旧哈兰德存档，安全导入关键设置（不改写旧存档）
local function ImportLegacyIfPresent()
    if F.db.migratedFromHaaland then
        return
    end
    local old = _G.EllesmereUIPlusAccountDB
    if type(old) ~= "table" then
        F.db.migratedFromHaaland = true
        return
    end

    local gp = type(old.gameplay) == "table" and old.gameplay or {}

    -- 1. 自动任务
    if type(gp.automation) == "table" then
        local q = DB.GetModule("questAuto")
        if gp.automation.autoAcceptQuestEnabled ~= nil then
            q.autoAccept = gp.automation.autoAcceptQuestEnabled == true
        end
        if gp.automation.autoTurnInQuestEnabled ~= nil then
            q.autoTurnIn = gp.automation.autoTurnInQuestEnabled == true
        end
        if gp.automation.autoQuestSkipTrivial ~= nil then
            q.skipTrivial = gp.automation.autoQuestSkipTrivial ~= false
        end
        if gp.automation.autoQuestPickBestReward ~= nil then
            q.pickBestReward = gp.automation.autoQuestPickBestReward == true
        end
    end

    -- 2. 技能音效
    if type(gp.spellSounds) == "table" then
        local ss = DB.GetModule("spellSounds")
        if gp.spellSounds.enabled ~= nil then
            ss.enabled = gp.spellSounds.enabled ~= false
        end
        if type(gp.spellSounds.channel) == "string" then
            ss.channel = gp.spellSounds.channel
        end
        if type(gp.spellSounds.off) == "table" then
            ss.off = F.DeepCopy(gp.spellSounds.off)
        end
    end

    -- 3. 进/脱战警报文字与音效偏好
    if type(gp.combatAlert) == "table" then
        local ca = DB.GetModule("combatAlert")
        if type(gp.combatAlert.enterText) == "string" then ca.enterText = gp.combatAlert.enterText end
        if type(gp.combatAlert.leaveText) == "string" then ca.leaveText = gp.combatAlert.leaveText end
        if gp.combatAlert.sound ~= nil then ca.sound = gp.combatAlert.sound == true end
        if type(gp.combatAlert.soundEnter) == "string" then ca.soundEnter = gp.combatAlert.soundEnter end
        if type(gp.combatAlert.soundLeave) == "string" then ca.soundLeave = gp.combatAlert.soundLeave end
    end

    -- 4. 邮件常用联系人与小号列表
    if type(old.social) == "table" and type(old.social.contacts) == "table" then
        local sc = DB.GetModule("socialTools")
        if type(old.social.contacts.favorites) == "table" then
            sc.favorites = F.DeepCopy(old.social.contacts.favorites)
        end
    end

    F.db.migratedFromHaaland = true
end

function DB.Init()
    _G.ForeverUIDB = F.MergeDefaults(_G.ForeverUIDB, ACCOUNT_DEFAULTS)
    _G.ForeverUICharDB = F.MergeDefaults(_G.ForeverUICharDB, CHAR_DEFAULTS)
    F.db = _G.ForeverUIDB
    F.charDB = _G.ForeverUICharDB
    -- 清理旧测试主题残留并确保主题色回归职业色/跟随 EUI
    if type(F.db.theme) == "table" then
        F.db.theme.style = nil
        F.db.theme.polestarSkinApplied = nil
        F.db.theme.polestarStyleV2 = nil
        if F.db.theme.accentMode ~= "class" and F.db.theme.accentMode ~= "eui" then
            F.db.theme.accentMode = "class"
        end
    end
    for k, defs in pairs(moduleDefaults) do
        F.db.modules[k] = F.MergeDefaults(F.db.modules[k], defs)
    end
    SanitizePositions()
    ImportLegacyIfPresent()
end
