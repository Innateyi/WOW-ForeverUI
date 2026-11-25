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
        v2CleanedLegacyFavs = false,
    },
})


local function GetPlayerMailName()
    local first, second = _G.UnitName("player")
    first = F.PlainString(first, nil)
    second = F.PlainString(second, nil)
    if not first or first == "" then return nil end
    -- 无限服（16001）角色带姓氏：UnitName("player") 第 2 返回值为姓氏，寄信必须填「名 姓」
    if second and second ~= "" and _G.EllesmereUI and _G.EllesmereUI.IS_FOREVER then
        return first .. " " .. second
    end
    return first
end

local copyBoxFrame = nil
local mailDrawer = nil
local mailRows = {}
local menuHooked = false

local function ShowCopyDialog(text)
    if not copyBoxFrame then
        copyBoxFrame = CreateFrame("Frame", "KkowoUI_CopyBox", _G.UIParent)
        copyBoxFrame:SetSize(296, 78)
        copyBoxFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 120)
        copyBoxFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        copyBoxFrame:SetFrameLevel(260)
        copyBoxFrame:SetToplevel(true)
        copyBoxFrame:SetClampedToScreen(true)
        copyBoxFrame:EnableMouse(true)
        copyBoxFrame:SetMovable(true)
        copyBoxFrame:RegisterForDrag("LeftButton")
        copyBoxFrame:SetScript("OnDragStart", copyBoxFrame.StartMoving)
        copyBoxFrame:SetScript("OnDragStop", copyBoxFrame.StopMovingOrSizing)
        copyBoxFrame:Hide()
        F.Theme.StylePanel(copyBoxFrame, 0.94, 0.9)
        F.Theme.SetBorderAccent(copyBoxFrame, true)

        local title = copyBoxFrame:CreateFontString(nil, "OVERLAY")
        F.Theme.ApplyFont(title, 12, "", 0.95, 0.95, 0.96, 1)
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText("按 Ctrl+C 复制（Esc 关闭）")

        local closeBtn = CreateFrame("Button", nil, copyBoxFrame)
        closeBtn:SetSize(20, 20)
        closeBtn:SetPoint("TOPRIGHT", -8, -7)
        F.Theme.StyleGlassSurface(closeBtn, {
            accent = { 0.93, 0.36, 0.43 },
            bgAlpha = 0.78,
            borderAlpha = 0.62,
            restAura = 0.04,
            hoverAura = 0.34,
            borderTintMix = 0.10,
        })
        local cxIcon = closeBtn:CreateTexture(nil, "OVERLAY", nil, 4)
        cxIcon:SetSize(10, 10)
        cxIcon:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
        cxIcon:SetTexture(F.Theme.ICONS .. "Close.tga")
        cxIcon:SetTexCoord(0, 1, 0, 1)
        cxIcon:SetVertexColor(0.80, 0.84, 0.90, 0.92)
        closeBtn:SetScript("OnEnter", function(self)
            F.Theme.SetGlassState(self, true, false)
            cxIcon:SetVertexColor(1.0, 0.88, 0.90, 1.0)
        end)
        closeBtn:SetScript("OnLeave", function(self)
            F.Theme.SetGlassState(self, false, false)
            cxIcon:SetVertexColor(0.80, 0.84, 0.90, 0.92)
        end)
        closeBtn:SetScript("OnClick", function() copyBoxFrame:Hide() end)

        local eb = CreateFrame("EditBox", nil, copyBoxFrame)
        eb:SetSize(272, 26)
        eb:SetPoint("BOTTOM", 0, 12)
        eb:SetAutoFocus(true)
        F.Theme.StylePanel(eb, 0.98, 0.6)
        F.Theme.ApplyFont(eb, 13, "", 1, 1, 1, 1)
        eb:SetTextInsets(6, 6, 0, 0)
        eb:SetScript("OnEscapePressed", function()
            eb:ClearFocus()
            copyBoxFrame:Hide()
        end)
        eb:SetScript("OnEnterPressed", function()
            eb:ClearFocus()
            copyBoxFrame:Hide()
        end)
        copyBoxFrame:SetScript("OnHide", function()
            if eb.ClearFocus then eb:ClearFocus() end
        end)
        copyBoxFrame.editBox = eb

        F.Theme.RegisterEscapeClose(copyBoxFrame, function()
            if eb.ClearFocus then eb:ClearFocus() end
            copyBoxFrame:Hide()
        end)
    end
    copyBoxFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    copyBoxFrame:SetFrameLevel(260)
    copyBoxFrame:Show()
    copyBoxFrame:Raise()
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
    local name = GetPlayerMailName()
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
        -- 无限服如果之前只记录了无姓氏的半个名字，顺手清掉以免重复
        local firstOnly = F.PlainString(_G.UnitName("player"), nil)
        if firstOnly and firstOnly ~= name and db.alts[realm][faction][firstOnly] then
            db.alts[realm][faction][firstOnly] = nil
        end
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
    local selfName = GetPlayerMailName()

    local list = {}
    local seen = {}
    local alts = db.alts[realm] and db.alts[realm][faction]
    if type(alts) == "table" then
        for n, cls in pairs(alts) do
            if n ~= selfName then
                list[#list + 1] = { name = n, class = cls, tag = "小号", kind = "alt" }
                seen[n] = true
            end
        end
    end
    for n, cls in pairs(db.favorites or {}) do
        if not seen[n] then
            list[#list + 1] = { name = n, class = cls, tag = "常用", kind = "fav" }
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
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
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
        row._kind = item.kind
        if not row._clickSet then
            row._clickSet = true
            row:SetScript("OnClick", function(self, btn)
                if btn == "RightButton" and self._recipient then
                    local sdb = mod:GetDB()
                    if self._kind == "fav" and type(sdb.favorites) == "table" then
                        sdb.favorites[self._recipient] = nil
                    elseif self._kind == "alt" then
                        local rlm = (_G.GetRealmName and _G.GetRealmName()) or "Default"
                        local fac = _G.UnitFactionGroup and _G.UnitFactionGroup("player") or "Neutral"
                        if sdb.alts and sdb.alts[rlm] and sdb.alts[rlm][fac] then
                            sdb.alts[rlm][fac][self._recipient] = nil
                        end
                    end
                    F.Print("已从快捷收件人移除：" .. self._recipient)
                    RefreshMailDrawer()
                    return
                end
                if _G.SendMailNameEditBox and self._recipient then
                    _G.SendMailNameEditBox:SetText(self._recipient)
                end
            end)
            row:SetScript("OnEnter", function(self)
                if _G.GameTooltip and self._recipient then
                    _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    _G.GameTooltip:AddLine(self._recipient, 1, 1, 1)
                    _G.GameTooltip:AddLine("左键：填入收件人", 0.37, 0.83, 0.65)
                    _G.GameTooltip:AddLine("右键：从列表移除", 0.85, 0.45, 0.45)
                    _G.GameTooltip:Show()
                end
            end)
            row:SetScript("OnLeave", function()
                if _G.GameTooltip then _G.GameTooltip:Hide() end
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
    local db = self:GetDB()
    -- 一次性清理：favorites 唯一来源是旧版从哈兰德整合包存档迁移来的原作者联系人（KkowoUI 本身从不写入 favorites），
    -- 整表清空即可，不必在公开仓库里硬编码他人的角色名
    if not db.v2CleanedLegacyFavs then
        db.v2CleanedLegacyFavs = true
        db.favorites = {}
    end
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
        tooltip = "打开寄信标签页时，在邮箱右侧列出同服同阵营小号与常用收件人（左键填入、右键移除）。",
        getValue = function() return db.mailContacts ~= false end,
        setValue = function(v) db.mailContacts = v == true; RefreshMailDrawer() end,
    }, {
        type = "button",
        text = "清空常用收件人",
        noCapture = true,
        tooltip = "清除「快捷收件人」中的所有常用收藏联系人（不影响已记录的同服小号）。",
        onClick = function()
            db.favorites = {}
            RefreshMailDrawer()
            F.Print("已清空快捷收件人中的常用收藏列表。")
        end,
    })
    y = y - h
    return y
end
