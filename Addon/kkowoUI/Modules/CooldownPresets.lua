----------------------------------------------------------------------
--  kkowoUI — Modules/CooldownPresets.lua
--  职业预设冷却条（写入 EllesmereUI 冷却管理器的「追踪条」）：
--    • 每个职业一组常用冷却（输出循环 → 爆发 → 保命 → 控制/打断），数据见 Data/CooldownPresets.lua。
--    • 样式：左侧技能图标、条内左侧技能名、右侧倒计时，填充职业色；技能就绪时整条隐藏，
--      只在冷却中出现，所以列得多也不会占屏。
--    • 只添加角色已学会的技能；以后学会新技能 / 新等级时自动补上或升级到最高等级。
--    • 你在 EUI 里删掉的预设条不会被加回来（「重新添加预设」按钮可恢复）；
--      位置、尺寸、配色都在 EUI 设置 → 冷却管理器 → 追踪条里改，kkowoUI 不再覆盖。
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type
local C_Timer = C_Timer

local mod = F.RegisterModule("cdPresets", {
    title = "职业预设冷却条",
    desc = "为当前职业在 EUI 冷却管理器里添加一组常用技能冷却条（图标 + 技能名 + 右侧倒计时，冷却中才显示）。只添加已学会的技能，学会新技能或新等级时自动补上。需要启用 EllesmereUI 冷却管理器。",
    group = "combat",
    order = 12,
    defaults = {
        enabled = true,
        v1SmoothCooldownsSeeded = false,
    },
})

local CDM_ADDON = "EllesmereUICooldownManager"
local syncQueued = false
local QueueSync   -- forward：Sync 在存档未就绪时要自我重排

local function CDM()
    local E = _G.EllesmereUI
    local ns = E and E._ModuleNS and E._ModuleNS[CDM_ADDON]
    if type(ns) ~= "table" then return nil end
    if type(ns.GetTrackedBuffBars) ~= "function" or type(ns.BuildTrackedBuffBars) ~= "function"
        or type(ns.GetActiveSpecKey) ~= "function" or type(ns.TBB_DEFAULT_BAR) ~= "table" then
        return nil
    end
    return ns
end

local function Known(id)
    if _G.IsPlayerSpell then
        local ok, v = pcall(_G.IsPlayerSpell, id)
        if ok and v == true then return true end
    end
    if _G.IsSpellKnown then
        local ok, v = pcall(_G.IsSpellKnown, id)
        if ok and v == true then return true end
    end
    return false
end

-- 预设里的等级是高 → 低排列，第一个已学会的就是最高等级
local function BestKnownID(entry)
    for _, id in ipairs(entry.ids) do
        if Known(id) then return id end
    end
    return nil
end

local function SpellName(id)
    local api = _G.C_Spell
    if api and api.GetSpellName then
        local ok, n = pcall(api.GetSpellName, id)
        if ok and type(n) == "string" and not F.IsSecret(n) and n ~= "" then return n end
    end
    return nil
end

local function SpecState(specKey)
    local cdb = F.charDB
    if type(cdb) ~= "table" then return nil end
    if type(cdb.cdPresets) ~= "table" then cdb.cdPresets = {} end
    local st = cdb.cdPresets[specKey]
    if type(st) ~= "table" then
        st = { added = {} }
        cdb.cdPresets[specKey] = st
    end
    if type(st.added) ~= "table" then st.added = {} end
    return st
end

local function GroupOf(ns, cfg)
    if type(ns.TBBBarGroupID) == "function" then
        local ok, g = pcall(ns.TBBBarGroupID, cfg)
        if ok and type(g) == "number" then return g end
    end
    if type(cfg.groupId) == "number" then return cfg.groupId end
    return (cfg.grouped ~= false) and 1 or 0
end

-- 预设条单独成一组：玩家自己已有的追踪条用着 1 号组时，预设放到下一个空组，互不打乱
local function PickGroup(ns, bars, st)
    if type(st.gid) == "number" then return st.gid end
    local maxG, usedByOthers = 0, false
    for _, cfg in ipairs(bars) do
        local g = GroupOf(ns, cfg)
        if g > maxG then maxG = g end
        if not cfg.kkPreset then usedByOthers = true end
    end
    st.gid = (usedByOthers and maxG >= 1) and (maxG + 1) or 1
    return st.gid
end

local function NewBar(ns, entry, spellID, gid)
    local bar = F.DeepCopy(ns.TBB_DEFAULT_BAR)
    bar.spellID = spellID
    bar.name = SpellName(spellID) or entry.key
    bar.customName = entry.label
    bar.trackType = "cooldown"
    bar.enabled = true
    bar.hideWhenInactive = true      -- 就绪时隐藏，只在冷却中出现
    bar.iconDisplay = "left"
    bar.width = 230                  -- 含图标的总宽
    bar.height = 20
    bar.showName = true
    bar.namePosition = "left"
    bar.nameSize = 11
    bar.showTimer = true
    bar.timerPosition = "right"
    bar.timerSize = 12
    bar.bgA = 0.45
    bar.showSpark = true
    bar.kkPreset = entry.key         -- 认领标记：只升级 / 去重自己加的条，绝不碰玩家自己的条
    if type(ns.TBBSetBarGroup) == "function" then
        pcall(ns.TBBSetBarGroup, bar, gid)
    else
        bar.groupId = gid
        bar.grouped = gid ~= 0
    end
    return bar
end

local function Sync()
    syncQueued = false
    if not mod._active then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.RunOutOfCombat("cdPresetsSync", Sync)
        return
    end
    local ns = CDM()
    if not ns then return end
    local presets = F.CooldownPresets and F.CooldownPresets[F.GetPlayerClass()]
    if type(presets) ~= "table" then return end
    local okK, specKey = pcall(ns.GetActiveSpecKey)
    if not okK or not specKey then return end
    local st = SpecState(specKey)
    if not st then return end
    local okT, tbb = pcall(ns.GetTrackedBuffBars)
    if not (okT and type(tbb) == "table" and type(tbb.bars) == "table") then return end
    -- 存档还没就绪时 EUI 每次都返回一张临时空表：写进去等于丢失，还会被记成「已添加」。
    -- 两次取到同一张表才说明是真正落盘的那张，否则稍后重试。
    local okT2, tbb2 = pcall(ns.GetTrackedBuffBars)
    if not (okT2 and tbb2 == tbb) then
        QueueSync(3)
        return
    end
    local bars = tbb.bars

    local mine = {}
    for _, cfg in ipairs(bars) do
        if type(cfg) == "table" and type(cfg.kkPreset) == "string" then mine[cfg.kkPreset] = cfg end
    end

    local changed, added = false, {}
    for _, entry in ipairs(presets) do
        local best = BestKnownID(entry)
        local cfg = mine[entry.key]
        if cfg then
            -- 学会了更高等级：升到最高等级（低等级的冷却查询在部分客户端上读不到）
            if best and cfg.spellID ~= best then
                cfg.spellID = best
                cfg.name = SpellName(best) or cfg.name
                changed = true
            end
            st.added[entry.key] = true
        elseif best and not st.added[entry.key] then
            local gid = PickGroup(ns, bars, st)
            local bar = NewBar(ns, entry, best, gid)
            local newIdx = #bars + 1
            bars[newIdx] = bar
            -- 新加入已有分组时，把组锚点的存档坐标同步镜像给新成员，
            -- 防止玩家日后禁用/删掉第 1 条导致新晋锚点缺坐标跳回默认 (0, 200)
            if gid ~= 0 and type(ns.GetTBBPositions) == "function" and type(ns.TBBGroupAnchorIndex) == "function" then
                local okA, anchorIdx = pcall(ns.TBBGroupAnchorIndex, gid)
                local okP, tbbPos = pcall(ns.GetTBBPositions)
                if okA and anchorIdx and anchorIdx ~= newIdx and okP and type(tbbPos) == "table" then
                    local src = tbbPos[tostring(anchorIdx)]
                    local dstKey = tostring(newIdx)
                    if type(src) == "table" and not tbbPos[dstKey] then
                        tbbPos[dstKey] = F.DeepCopy(src)
                    end
                end
            end
            st.added[entry.key] = true
            changed = true
            added[#added + 1] = bar.customName or bar.name
        end
    end

    -- EUI 追踪条默认只对 Buff 开启平滑插值，冷却条默认关闭（tbbSmooth.cooldowns == nil）：
    -- 首次同步时仅在玩家从未改动过该项时设为 true，让预设冷却条获得 C 端平滑过渡（玩家之后在 EUI 里手动关掉绝不覆写）
    local db = mod:GetDB()
    if not db.v1SmoothCooldownsSeeded and type(ns.GetTBBSmoothSettings) == "function" then
        local okS, sm = pcall(ns.GetTBBSmoothSettings)
        if okS and type(sm) == "table" then
            if sm.cooldowns == nil then
                sm.cooldowns = true
            end
            db.v1SmoothCooldownsSeeded = true
        end
    end

    if changed then
        pcall(ns.BuildTrackedBuffBars)
    end
    if #added > 0 then
        if st.seeded then
            -- 练级途中学会新技能：一句话带过
            F.Print("新增冷却条：" .. table.concat(added, "、"))
        else
            F.Print("已在 EUI 冷却管理器添加 " .. #added .. " 条预设冷却条（冷却中才显示；位置与样式在 EUI 设置 → 冷却管理器 → 追踪条 调整）。")
        end
    end
    st.seeded = true
end

QueueSync = function(delay)
    if syncQueued then return end
    syncQueued = true
    C_Timer.After(delay or 1, Sync)
end

-- 「重新添加预设」：只忘掉「已添加过」的记录，让被你删掉的预设条在下次同步时回来
local function ResetRemoved()
    if not mod._active then
        F.Print("请先启用「职业预设冷却条」模块。")
        return
    end
    local ns = CDM()
    if not ns then
        F.Print("EUI 冷却管理器未启用，无法添加预设冷却条。")
        return
    end
    local okK, specKey = pcall(ns.GetActiveSpecKey)
    if not okK or not specKey then return end
    local st = SpecState(specKey)
    if st then st.added = {} end
    syncQueued = false
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        F.Print("当前处于战斗中，已排队将在脱战后自动重新添加预设冷却条。")
    end
    Sync()
end
mod.ResetRemoved = ResetRemoved

function mod:OnEnable()
    -- EUI 冷却管理器在 PLAYER_LOGIN 之后才建好存档与专精表：进世界后稍等再同步
    self:RegisterEvent("PLAYER_ENTERING_WORLD", function() QueueSync(4) end)
    self:RegisterEvent("SPELLS_CHANGED", function() QueueSync(1.5) end)
    QueueSync(4)
end

function mod:OnDisable()
    -- 已添加的条属于 EUI 的设置，停用本模块不删除，只是不再自动补条
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local _, h = W:DualRow(parent, y, enableSlot, {
        type = "labeledButton",
        text = "恢复被删除的预设冷却条",
        buttonText = "重新添加",
        width = 120,
        tooltip = "把你在 EUI 里删掉的预设冷却条加回来（已存在的不会重复添加）。",
        onClick = ResetRemoved,
    })
    y = y - h
    return y
end
