# kkowoUI

![kkowoUI v2.0](KkowoUI_cover.png)

面向《魔兽世界：无限》（WoW Forever，Interface `16001`）的模块化界面增强套件，基于 [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) 构建，游戏内输入 `/kk` 打开设置面板。

当前版本：**v2.0.0**（旧版 `KkowoUI` / `ForeverUI` 存档自动迁移，设置不丢失）。

## 安装

将仓库 `Addon/` 下的全部 9 个 `kkowoUI*` 目录复制到 `_forever_\Interface\AddOns\`，并确保已安装 EllesmereUI。

如同时使用 EllesmereUIChat 与 Polestar，可在退出游戏后运行：

```bash
python Tools/apply_patches.py --apply
```

仅包含 2 个极简补丁（聊天标签瞬切 + Polestar 导航优化），不新增其他第三方文件修改。

## 模块结构

| 子插件 | 加载方式 | 说明 |
| --- | --- | --- |
| `kkowoUI` | 常驻 | 核心框架、主题与安全圆角引擎、存档、守卫与 ESC 队列 |
| `kkowoUI_Media` | 常驻 | 字体、材质、图标、光柱与音效资源 |
| `kkowoUI_CoreHUD` | 常驻 | 双翼血蓝条与技能球、低血量提醒、施法/挥砍/动作条/姓名板/增益动效 |
| `kkowoUI_QoL` | 常驻 | 任务接交与快捷条、经验条、3D 地图光柱、Roll 点条、拾取播报、标记条、聊天条、系统栏、耐久与装备一览 |
| `kkowoUI_Tooltip` | 常驻 | 内嵌 PrettyTooltip（MIT）与全界面圆角提示框样式 |
| `kkowoUI_Integrations` | 常驻 | EUI / Polestar / Auctionator / 伤害统计美化、运行时修复、常用插件运行时简体中文补全、主城减卡 |
| `kkowoUI_ClassPack` | 常驻 | 术士灵魂石提醒、猎人技能音效、武器附魔/特效计时条、职业表情喊话 |
| `kkowoUI_Options` | 按需加载 | `/kk` 设置面板（6 组 24 页）、总控台与 `/kk selftest` / `/kk doctor` |
| `kkowoUI_KeybindBoard` | 按需加载 | `/kkkeys` 可视化键位图，支持拖拽绑键与多种键盘尺寸 |

## 主要功能

- **战斗 HUD 与动效**：双翼血蓝条、职业技能球、平滑施法条与挥砍条、武器附魔/特效计时条、EUI 冷却预设条、统一脱战淡隐。
- **地图标记与任务**：大地图/小地图 `Ctrl/Shift+左键` 落点联动 3D 光柱与北极星导航（距离显示为「米」，支持手动落点门控开关）、自动接交任务、任务等级与经验估算、经验速率条、采集提醒。
- **拾取、Roll 与标记**：紧凑尾淡拾取微播报（支持 0.11s 依次错峰滑入/滑出与同类合并）、扁平 Roll 点条、快捷团队标记条、敌方/友方/仅名字板统一头顶标记大小及当前目标放大。
- **聊天与面板美化**：左侧融合聊天条（与聊天框同步淡隐）、战斗记录标签瞬切、圆角聊天气泡、人物面板装备一览、拍卖行精简合并、一键 ESC 关闭主流插件窗口。
- **零补丁运行时汉化**：为 Polestar、GTFO、Auctionator、BigWigs_Classic、EllesmereUIQoL 与提示框设置页按需补齐简体中文，官方译文优先。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `/kk` | 打开设置面板（别名 `/kkowoui`、`/fui`） |
| `/kk keys` | 打开可视化键位图 |
| `/kk unlock` | 进入 EUI 解锁模式调整框体位置 |
| `/kk status` | 查看版本与各模块运行状态 |
| `/kk doctor` / `/kk selftest` | 插件环境体检 / 自动化自检 |
| `/kk slim` / `/kk restore` | 停用冗余插件 / 还原 |
| `/kk hud` / `/kk perf` / `/kk friendly` | 切换脱战淡隐 / 场景稳帧 / 友方姓名板模式 |
| `/kk toast` / `/kk ss` / `/kk wp` | 预览拾取播报 / 灵魂石提醒 / 武器特效条 |

## 更新日志

### v2.0.0
- **架构重构**：拆分为 9 个独立子插件（资源分离至 `kkowoUI_Media`，设置页与键位图改为 `LoadOnDemand` 按需加载；内嵌 MIT 版 `kkowoUI_Tooltip`）；拆分 `CoreHUD` 与 `ModernChrome` 大文件。
- **设置面板与文案**：重组为 6 组 24 页，统一开关与折叠「高级」区，全面精简 897 条界面文案并通过自动化规则校验。
- **聊天与战斗记录**：升级 `eui_chat_tab_fast` 至 v5，战斗记录统一走 EUI 渲染与细滚动条，标签瞬切无重排；左侧聊天条与 EUI 聊天框 1:1 同步淡隐与悬停唤醒。
- **头顶标记统一**：单一滑块同步敌方、友方与友方仅名字板标记大小，支持当前目标额外放大与呼吸箭头避让，关闭后无损还原。
- **视觉与动效升级**：新增 3D 地图渐变光柱（支持 5 色主题、任务追踪音效、小地图快捷插旗与手动标记门控）；升级拾取微播报为紧凑尾淡风格并支持依次错峰滑入/滑出；优化施法条、冷却条、武器特效条与 Roll 点条平滑度。
- **运行态零补丁汉化**：退役旧 `polestar_zhcn_fill` 补丁（总补丁数缩减至 2 个），改由 `kkowoUI_Integrations` 运行时注入 Polestar（含实体名与指南正文）、GTFO、Auctionator、BigWigs_Classic、EllesmereUIQoL 与提示框简体中文。
- **12.1 引擎合规与稳定**：总控台改用安全路径指引避免 `Settings.OpenToCategory` 触发界面保护；完善键位图与三方插件窗口层级及 ESC 返回；补齐离线 Lua 5.1 回归测试套件（13 项全通过）。

### 历史版本
- **v1.5.1**：修复 12.1 引擎 9 宫格圆角遮罩空图问题，新增 1024×1024 SDF 高清团队标记与 Roll 点条层级优化。
- **v1.5.0**：新增武器附魔/特效计时条，脱战淡隐合并为统一开关。
- **v1.4.0**：圆角与战斗动效改版，新增人物面板装备一览与可视化键位图。
- **v1.3.x**：正式定名 `kkowoUI`，统一提示框、气泡、拍卖行、角色面板与经验条风格。

## 许可

kkowoUI 原创代码、贴图与脚本采用 **CC BY-NC-SA 4.0**（署名-非商业性使用-相同方式共享 4.0）许可发布（见 [LICENSE](LICENSE)）：

- 欢迎个人免费游玩、学习及非商业分享（须保留 `Innateyi / kkowoUI` 署名与仓库链接，修改后公开分发须采用相同协议）。
- **禁止一切商业用途**（含平台售卖、付费群/付费链接分发、商业打包搭售等）。
- `Addon/kkowoUI_Tooltip/Vendor/` 保留上游 PrettyTooltip 原 MIT 许可；EllesmereUI、Polestar 等第三方插件版权归各自作者所有。
