----------------------------------------------------------------------
--  KkowoUI — Modules/SocialTools.lua
--  安全右键菜单增强（复制名字/快捷密语/公会邀请）+ 邮件小号/常用联系人抽屉
--  • 仅使用暴雪官方 Menu.ModifyMenu（不篡改 UnitPopupMenus）
--  • 绝不自动代发密语
----------------------------------------------------------------------
local _, F = ...

local _G = _G
local ipairs, pairs, pcall, type = ipairs, pairs, pcall, type
local table_sort = table.sort
local CreateFrame = CreateFrame

local mod = F.RegisterModule("socialTools", {
    title = "右键菜单与邮件联系人",
    desc = "右键玩家菜单新增「复制名字-服务器」与公会邀请；寄信时在右侧展示本服小号与收藏联系人一键填入。",
    group = "social",
    order = 20,
    defaults = {
        enabled = true,
        contextMenu = true,
        mailContacts = true,
        alts = {},
        favorites = {},
    },
})

local copyBoxFrame = nil
local mailDrawer = nil
local mailRows = {}
local menuHooked = false

local function ShowCopyDialog(text)
    if not copyBoxFrame then
        copyBoxFrame = CreateFrame("Frame", "KkowoUI_CopyBox", _G.UIParent)
        copyBoxFrame:SetSize(280, 74)
        copyBoxFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
        copyBoxFrame:SetFrameStrata("DIALOG")
        F.Theme.StylePanel(copyBoxFrame, 0.94, 0.9)
        F.Theme.SetBorderAccent(copyBoxFrame, true)

        local title = copyBoxFrame:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(title, 12, "", 0.95, 0.95, 0.96, 1)
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText("按 Ctrl+C 复制（Esc 关闭）")

        local eb = CreateFrame("EditBox", nil, copyBoxFrame)
        eb:SetSize(256, 26)
        eb:SetPoint("BOTTOM", 0, 12)
        eb:SetAutoFocus(true)
        F.Theme.StylePanel(eb, 0.98, 0.6)
        F.Theme.ApplyFont(eb, 13, "", 1, 1, 1, 1)
        eb:SetTextInsets(6, 6, 0, 0)
        eb:SetScript("OnEscapePressed", function() copyBoxFrame:Hide() end)
        eb:SetScript("OnEnterPressed", function() copyBoxFrame:Hide() end)
        copyBoxFrame.editBox = eb
    end
    copyBoxFrame:Show()
    copyBoxFrame.editBox:SetText(text or "")
    copyBoxFrame.editBox:HighlightText()
    copyBoxFrame.editBox:SetFocus()
end

local function HookContextMenus()
    if menuHooked or not (_G.Menu and _G.Menu.ModifyMenu) then
        return
    end
    menuHooked = true
    local tags = {
        "MENU_UNIT_PLAYER",
        "MENU_UNIT_FRIEND",
        "MENU_UNIT_PARTY",
        "MENU_UNIT_RAID_PLAYER",
        "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
        "MENU_UNIT_TARGET",
    }
    for _, tag in ipairs(tags) do
        pcall(_G.Menu.ModifyMenu, tag, function(_, rootDescription, contextData)
            if not (mod._active and mod:GetDB().contextMenu) then
                return
            end
            if type(contextData) ~= "table" then
                return
            end
            local name = F.PlainString(contextData.name, nil)
            if not name or name == "" then
                return
            end
            local realm = F.PlainString(contextData.server, nil)
            local full = (realm and realm ~= "") and (name .. "-" .. realm) or name
            rootDescription:CreateDivider()
            rootDescription:CreateButton("复制名字：" .. name, function()
                ShowCopyDialog(full)
            end)
            -- 公会邀请：12.x 起 GuildInvite 迁到 C_GuildInfo.Invite；自己、已是公会成员、NPC/怪物目标不显示
            local inviteFn = (_G.C_GuildInfo and _G.C_GuildInfo.Invite) or _G.GuildInvite
            local showInvite = inviteFn and _G.CanGuildInvite and _G.CanGuildInvite()
                and tag ~= "MENU_UNIT_PLAYER" and tag ~= "MENU_UNIT_COMMUNITIES_GUILD_MEMBER"
            if showInvite then
                local unit = F.PlainString(contextData.unit, nil)
                if unit and _G.UnitExists and _G.UnitExists(unit) then
                    local okP, isPlayer = pcall(_G.UnitIsPlayer, unit)
                    local okS, isSelf = pcall(_G.UnitIsUnit, unit, "player")
                    if not okP or F.IsSecret(isPlayer) or not isPlayer then showInvite = false end
                    if okS and not F.IsSecret(isSelf) and isSelf then showInvite = false end
                end
            end
            if showInvite then
                rootDescription:CreateButton("邀请加入公会", function()
                    pcall(inviteFn, full)
                end)
            end
        end)
    end
end

local function RecordCurrentAlt()
    local db = mod:GetDB()
    local name = _G.UnitName("player")
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    if not realm or realm == "" then
        return
    end
    -- 清理早期在登录瞬间 GetRealmName 为空时写入的脏键
    if db.alts[""] then
        db.alts[""] = nil
    end
    local faction = _G.UnitFactionGroup and _G.UnitFactionGroup("player") or "Neutral"
    local class = F.GetPlayerClass()
    if name and name ~= "" then
        db.alts[realm] = db.alts[realm] or {}
        db.alts[realm][faction] = db.alts[realm][faction] or {}
        db.alts[realm][faction][name] = class
    end
end

local function RefreshMailDrawer()
    if not mailDrawer then
        return
    end
    local db = mod:GetDB()
    if not (mod._active and db.mailContacts and _G.SendMailFrame and _G.SendMailFrame:IsShown()) then
        mailDrawer:Hide()
        return
    end

    local realm = (_G.GetRealmName and _G.GetRealmName()) or "Default"
    local faction = _G.UnitFactionGroup and _G.UnitFactionGroup("player") or "Neutral"
    local selfName = _G.UnitName("player")

    local list = {}
    local seen = {}
    local alts = db.alts[realm] and db.alts[realm][faction]
    if type(alts) == "table" then
        for n, cls in pairs(alts) do
            if n ~= selfName then
                list[#list + 1] = { name = n, class = cls, tag = "小号" }
                seen[n] = true
            end
        end
    end
    for n, cls in pairs(db.favorites or {}) do
        if not seen[n] then
            list[#list + 1] = { name = n, class = cls, tag = "常用" }
        end
    end
    table_sort(list, function(a, b) return a.name < b.name end)

    for _, r in ipairs(mailRows) do r:Hide() end
    if #list == 0 then
        -- 没有小号/常用收件人时不显示空框
        mailDrawer:Hide()
        return
    end

    -- EUI BlizzardSkin 自带的「小号/好友/公会」收件人列表（EllesmereUIMailAltList）同样贴在邮箱右侧：
    -- 它显示时本抽屉改为接在它下方，避免两块面板完全重叠
    mailDrawer:ClearAllPoints()
    local euiList = _G.EllesmereUIMailAltList
    if euiList and euiList.IsShown and euiList:IsShown() and not (euiList.IsForbidden and euiList:IsForbidden()) then
        mailDrawer:SetPoint("TOPLEFT", euiList, "BOTTOMLEFT", 0, -6)
    else
        mailDrawer:SetPoint("TOPLEFT", _G.MailFrame, "TOPRIGHT", 6, 0)
    end

    local y = -30
    for i, item in ipairs(list) do
        if i > 12 then break end
        local row = mailRows[i]
        if not row then
            row = CreateFrame("Button", nil, mailDrawer)
            row:SetSize(148, 20)
            F.Theme.StyleButton(row, 11)
            local lbl = row:CreateFontString(nil, "OVERLAY")
            F.Theme.ApplyFont(lbl, 11, "", 0.92, 0.93, 0.95, 1)
            lbl:SetPoint("LEFT", 6, 0)
            lbl:SetPoint("RIGHT", -6, 0)
            lbl:SetJustifyH("LEFT")
            lbl:SetWordWrap(false)
            row.lbl = lbl
            mailRows[i] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", mailDrawer, "TOPLEFT", 8, y)
        local c = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[item.class]
        if c then
            row.lbl:SetTextColor(c.r, c.g, c.b, 1)
        else
            row.lbl:SetTextColor(0.92, 0.93, 0.95, 1)
        end
        row.lbl:SetText(item.name)
        row._recipient = item.name
        if not row._clickSet then
            row._clickSet = true
            row:SetScript("OnClick", function(self)
                if _G.SendMailNameEditBox and self._recipient then
                    _G.SendMailNameEditBox:SetText(self._recipient)
                end
            end)
        end
        row:Show()
        y = y - 22
    end

    mailDrawer:SetHeight(math.max(66, math.abs(y) + 12))
    mailDrawer:Show()
end

local function EnsureMailDrawer()
    if mailDrawer or not _G.MailFrame then
        return
    end
    mailDrawer = CreateFrame("Frame", "KkowoUI_MailContacts", _G.MailFrame)
    mailDrawer:SetSize(164, 180)
    mailDrawer:SetPoint("TOPLEFT", _G.MailFrame, "TOPRIGHT", 6, 0)
    F.Theme.StylePanel(mailDrawer, 0.9, 0.8)

    local hdr = mailDrawer:CreateFontString(nil, "OVERLAY")
    F.Theme.ApplyFont(hdr, 12, "", 0.95, 0.95, 0.96, 1)
    hdr:SetPoint("TOPLEFT", 10, -8)
    hdr:SetText("快捷收件人")

    if _G.SendMailFrame then
        -- EUI 的收件人列表也在 SendMailFrame:OnShow 里显示：本抽屉晚一帧定位，才能读到它的可见状态
        _G.SendMailFrame:HookScript("OnShow", function()
            RefreshMailDrawer()
            _G.C_Timer.After(0, RefreshMailDrawer)
        end)
        _G.SendMailFrame:HookScript("OnHide", function() if mailDrawer then mailDrawer:Hide() end end)
    end
    mailDrawer:Hide()
end

function mod:OnEnable()
    RecordCurrentAlt()
    HookContextMenus()
    EnsureMailDrawer()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", RecordCurrentAlt)
    self:RegisterEvent("MAIL_SHOW", function()
        EnsureMailDrawer()
        RefreshMailDrawer()
    end)
end

function mod:OnDisable()
    if mailDrawer then mailDrawer:Hide() end
    if copyBoxFrame then copyBoxFrame:Hide() end
end

function mod:BuildOptions(W, parent, y, enableSlot, blank)
    local db = self:GetDB()
    local _, h
    _, h = W:DualRow(parent, y, enableSlot, {
        type = "toggle",
        text = "右键菜单复制名字 / 公会邀请",
        tooltip = "使用官方 Menu.ModifyMenu 安全扩展玩家右键菜单。",
        getValue = function() return db.contextMenu ~= false end,
        setValue = function(v) db.contextMenu = v == true end,
    })
    y = y - h

    _, h = W:DualRow(parent, y, {
        type = "toggle",
        text = "寄信界面显示小号/联系人抽屉",
        tooltip = "打开寄信标签页时，在邮箱右侧列出同服同阵营小号与常用收件人。",
        getValue = function() return db.mailContacts ~= false end,
        setValue = function(v) db.mailContacts = v == true; RefreshMailDrawer() end,
    }, blank)
    y = y - h
    return y
end
