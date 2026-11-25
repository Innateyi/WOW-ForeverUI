# KkowoUI — 魔兽世界：无限（Interface 16001）现代模块化整合工程

专为《魔兽世界：无限》实战环境打造的**零污染模块化增强插件 + 第三方幂等补丁 + 高清矢量素材与多字重字体工具链**。

## 核心特性

1. **现代极简视觉与职业主题色**：默认跟随当前角色职业色（支持一键切换跟随 EllesmereUI 主色），统一烟熏玻璃质感、1px 精细描边与无锯齿 SDF 高清矢量图标；默认关闭非必要战斗淡出以降低动画开销。
2. **零污染 & 12.x 保密值安全**：
   - 仅使用 EllesmereUI 官方公开 API（`RegisterPlugin`、`RegisterSkin`、`RegisterQuestTrackerRow`、`MakeUnlockElement`）；
   - 严禁向暴雪核心框体/全局表（`WorldMapFrame`、`SuperTrackedFrame`、`GameTooltip`、`CharacterFrame`、`MacroFrame`、`BuffFrame`、`DebuffFrame`、`C_AddOnProfiler`）写入自定义字段；
   - 全部数值/文字读取通过 `F.PlainNumber / F.PlainString` 过滤 12.x `issecretvalue`。
3. **19 个独立可开关模块**（统一挂载于 `/kk`）：
   - **任务与练级**：自动接交任务、嵌入任务追踪标题栏的快捷条（接/交/通告/本图）、任务经验提示、融合经验/声望/AION2 冰青色装等条、采集与任务物件防闪烁头顶提醒、地图区域等级标注。
   - **战斗与音效**：进/脱战剑盾提醒、猎人枪械 & 弓弩双套自动切换技能音效（物理建模 6 枚弓箭音效）、现代 Roll 点条、现代扁平矢量标记条 + 全局 3D/单位框体团队标记替换。
   - **社交与工具**：左侧融合聊天条（支持 `Alt+左/右键` 自定义频道排序）、右键菜单与邮件联系人、零闪烁极速静默拾取与包满低价值助手、现代拾取微播报、装备耐久与属性对齐卡片。
   - **现代视觉与性能**：全局视觉统一（世界刷新横幅去重居中无拖影、坐鸟退出钮自动去重、技能伤害飘字字体与弧度选项）、沉浸探索模式、一体化系统微菜单栏（无损 32 位 BGRA 多级 Mipmap Lucide 矢量图标）、PrettyTooltip 紧缩均衡联动与 EUI 小卡片可读性增强。
4. **不强行合并大型第三方插件**：`EllesmereUI`、`Polestar`、`Questie`、`BigWigs`、`ArcAuras`、`DungeonsForever`、`Leatrix_Maps`、`WaypointUI` 等保持独立原版，通过 `Tools/compare_update.py` 与 `Patches/` 幂等补丁安全维护。

## 常用工具命令

```powershell
# 1. 静态语法与零污染检查（须保持 0 错误 0 警告）
node Tools\check.js

# 2. 只读检查 4 个第三方补丁状态（玩游戏时可安全运行）
python -I Tools\apply_patches.py --check

# 3. 退出游戏后，一键应用 4 个第三方补丁（带自动备份）
python -I Tools\apply_patches.py --apply

# 4. 退出游戏后，部署 KkowoUI 到游戏 AddOns（推荐 -Link 目录链接便于随时 /reload）
#    从旧名 ForeverUI 升级时会自动迁移 WTF 存档与 AddOns.txt 启用项，并移走旧的 AddOns\ForeverUI（原文件备份到 backups）
powershell -ExecutionPolicy Bypass -File Tools\deploy.ps1 -Link

# 5. 部署 / 卸载全局 3D 团队标记图集（UI-RaidTargetingIcons.blp）
python -I Tools\deploy_raid_markers.py --install
python -I Tools\deploy_raid_markers.py --uninstall

# 6. 多字重 MMO 字体 5 槽位安装与一键回滚（支持 HarmonyOS Sans SC / MiSans 等，自动清 .slug 缓存）
python -I Tools\install_mmo_fonts.py --src "<字体目录>"
python -I Tools\install_mmo_fonts.py --rollback

# 7. 重新生成高清矢量图标 / 团队标记图集 / 猎人弓箭音效
node Tools\gen_hd_icons.js
python -I Tools\gen_systembar_and_raid_icons.py
python -I Tools\gen_bow_sounds.py
```

### 路径环境变量（游戏不在默认位置时设置）

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `WOW_FOREVER_DIR` | 客户端根目录（含 `Interface`、`Fonts`） | `E:\Program Files\World of Warcraft\_forever_` |
| `WOW_BACKUP_ROOT` | 补丁/字体/归档备份总目录 | 仓库同级的 `backups` |
| `WOW_ACCOUNT_DIR` | `WTF\Account\<你的账号目录>`（打包、改配置类脚本需要） | 无，需手动设置 |
| `WOW_ADDONS_TXT` | 当前角色的 `AddOns.txt` | 无，需手动设置 |
| `LUAPARSE_PATH` | `check.js` 使用的 luaparse 路径 | `Tools/node_modules/luaparse` |

## 目录结构

- `Addon/KkowoUI/` — 统一模块化主插件（19 个独立模块 + 全套高清矢量图标与枪/弓音效素材）
- `Patches/` — 4 个幂等第三方补丁（姓名板任务计数防重叠与字号同步、友方玩家名、EUI 聊天标签 0 帧极速切换、VSS 尸体切换）
- `Tools/` — 静态检查、补丁管理、素材与音效合成、全局团队标记与多字重字体部署、脱敏打包脚本
- `Profiles/` — 现代 UI 切换与第三方插件搭配清单
- `Upstream/` — 上游插件更新对比报告归档目录
