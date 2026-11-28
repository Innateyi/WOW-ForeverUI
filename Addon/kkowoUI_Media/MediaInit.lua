----------------------------------------------------------------------
--  kkowoUI_Media — MediaInit.lua
--  向 LibSharedMedia-3.0 注册 kkowoUI 内置字体与状态条材质（含原 YaMedia MerfinMain）
----------------------------------------------------------------------
local _G = _G
local pcall = pcall

local MEDIA = "Interface\\AddOns\\kkowoUI_Media\\Media\\"
local LSM = _G.LibStub and _G.LibStub("LibSharedMedia-3.0", true)
if LSM and LSM.Register then
    pcall(LSM.Register, LSM, "font", "kkowoUI 战伤·优设标题黑", MEDIA .. "Fonts\\YouSheBiaoTiHei.ttf", 255)
    pcall(LSM.Register, LSM, "font", "kkowoUI 战伤·得意黑", MEDIA .. "Fonts\\SmileySans.ttf", 255)
    pcall(LSM.Register, LSM, "statusbar", "MerfinMain", MEDIA .. "Textures\\MerfinMain.tga")
    pcall(LSM.Register, LSM, "statusbar", "kkowoUI 柔光明暗", MEDIA .. "Textures\\BarFillShaded.tga")
end
