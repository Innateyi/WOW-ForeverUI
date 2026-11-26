# kkowoUI

面向《魔兽世界：无限》（WoW Forever，Interface 16001）的模块化界面增强插件，建立在 [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui)（EUI）之上。27 个模块都可以单独开关，设置页挂在 EUI 设置面板里，游戏内输入 `/kk` 打开。

当前版本：**1.3.1**。插件名为 `kkowoUI`（区分大小写），曾用名 KkowoUI、ForeverUI，旧名的设置会自动迁移。

## 安装

**整合包（推荐）**：解压压缩包，双击「安装.bat」，在弹出的窗口里选择 World of Warcraft 文件夹（例如 `E:\Program Files\World of Warcraft`）。

- 安装前会把原来的全部插件、图标、字体整夹移进 `World of Warcraft\kkowoUI安装备份_日期`，WTF 配置完整复制一份进去，全程不删除文件。
- 插件只保留整合包这一套，避免和其他插件冲突。
- 配置按插件合并：你配置过的插件保留你的设置和布局，没配置过的插件使用整合包布局。
- 新账号要先进游戏登录一次再安装。

**只装插件**：把 `Addon/kkowoUI` 复制到 `_forever_\Interface\AddOns\kkowoUI`（文件夹名必须是 `kkowoUI`），并安装 EllesmereUI。

## 功能

### 任务与练级

| 模块 | 作用 |
| --- | --- |
| 自动接交任务 | 自动接取、提交任务，单选项对话自动选；按住 Shift 临时跳过 |
| 任务快捷条 | 「接 / 交 / 通告」按钮嵌入任务追踪标题栏，一键切换自动接交和小队进度通告 |
| 任务等级与经验标注 | 任务追踪里显示难度着色的 [等级] 和预计经验 |
| 经验与声望条 | 圆角柔光经验条，左侧职业徽印、等级和装等；可交任务预览、双倍经验、经验速率（右键重置） |
| 采集与拾取闪光提醒 | 草药、矿脉、任务物件和钓鱼浮漂上方显示提醒，联动 Questie |
| 地图区域等级 | 大陆地图上标注各区域等级区间，兼容 Leatrix_Maps |
| 游戏物件英文名汉化 | 传送门等只有英文名的物件，名牌改显示中文 |

### 战斗与音效

| 模块 | 作用 |
| --- | --- |
| 职业预设冷却条 | 在 EUI 冷却管理器里为当前职业加一组常用技能冷却条，冷却中才显示，学会新技能自动补上 |
| 进/脱战警报 | 进战、脱战的剑盾提示 |
| Roll 点增强 | 扁平风装备 Roll 点条；开启 EUI「拾取掷点框」时自动让位 |
| 快捷标记条 | 8 个团队标记加清除、就位确认、倒数 |
| 灵魂石到期提醒 | 监控术士绑在队友或自己身上的灵魂石，快到期时提醒，可语音播报 |
| 猎人技能音效 | 射击、陷阱等技能的自定义音效，自动区分枪械和弓弩 |

### 社交与工具

| 模块 | 作用 |
| --- | --- |
| 融合聊天条与窗口美化 | 频道切换和复制、设置、回到底部按钮合成一条，贴在聊天框左侧 |
| 头顶聊天气泡统一 | 所有头顶气泡统一为圆角卡片，淡入淡出（副本内气泡受暴雪保护，保持原样） |
| 右键菜单与邮件联系人 | 右键玩家可复制「名字-服务器」、公会邀请；寄信时一键填入小号和收藏联系人 |
| 趣味职业表情喊话 | 按职业的表情和喊话（坐下喝水报法力、复活、拉人、开门等），可自定义文案 |
| 背包清理与拾取增强 | 无闪烁快速拾取、包满时的低价值物品清单、背包金币对齐、宏界面放大 |
| 现代拾取与收益微播报 | 屏幕侧边堆叠显示拾取物品、金币、经验、声望，同类自动合并 |
| 核心属性与装备耐久面板 | 核心属性和装备耐久合在一个面板，悬停看各部位耐久和修理费 |

### 现代视觉与性能

| 模块 | 作用 |
| --- | --- |
| 现代视觉统一与修复 | 职业主题色、角色面板重设计、鸿蒙字体防顶切、静音攻击喊声、地图坐标去重、施法条统一等 |
| 拍卖行合并与界面统一 | 以暴雪原版「购买 / 出售 / 拍卖」为主，只保留 Auctionator 的「压价扫描」作为第 4 页 |
| 姓名板与主城减卡优化 | 主城或全局隐藏友方玩家名字，缓解主城卡顿 |
| 场景性能自动档位 | 主城人多或大型团本时自动换稳帧设置，离开后还原 |
| 沉浸探索模式 | 非战斗、无目标时自动淡化次要界面，进战或鼠标移上立刻恢复 |
| 一体化系统微菜单栏 | 微菜单、好友和公会在线数、炉石、时钟、帧率、延迟合成一条；装了 QFXSystemBar 时自动让位 |
| 悬浮提示美化与字号统一 | 全部悬浮提示统一为 PrettyTooltip 风格，可调整字号和紧凑度 |

## 游戏内命令

| 命令 | 作用 |
| --- | --- |
| `/kk` | 打开设置（别名 `/kkowoui`、`/fui`、`/foreverui`） |
| `/kk status` | 显示版本和各模块运行状态 |
| `/kk unlock` | 进入 EUI 解锁模式调整框体位置 |
| `/kk slim` / `/kk restore` | 一键停用闲置和重复的插件 / 还原 |
| `/kk deadguard on\|off` | 登录时自动停用 DD 反复装回来的无效插件（ArcUI、QuestieTrace 等） |
| `/kk deadguard arc on\|off` | 是否用 EUI 冷却管理器替代 ArcAuras（默认不碰 ArcAuras） |
| `/kk emote ...` | 趣味喊话：`preview` 只在自己聊天框预览，`drink` / `utility` / `combat` 可绑进宏 |
| `/kk kw 词1,词2` / `/kk kw clear` | 聊天关键词提醒 |
| `/kk world 频道名` | 设置世界频道名 |
| `/kk hud` / `/kk perf` / `/kk friendly` | 切换沉浸模式 / 强制稳帧 / 友方名字显示方式 |
| `/kk toast` / `/kk ss` | 预览拾取播报 / 预览灵魂石提醒 |

## 第三方插件与本地补丁

kkowoUI 依赖 EllesmereUI，并会和这些插件联动（装了才生效）：PrettyTooltip、Auctionator、Polestar、Questie、Leatrix_Maps、WaypointUI、BugSack、QFXSystemBar。大型插件都保持原版，不并进 kkowoUI。

少数问题只能改第三方插件的文件来修，放在 `Patches/`。每个补丁都可以重复执行，执行前会把原文件备份：

| 补丁 | 改的插件 | 作用 |
| --- | --- | --- |
| `eui_np_questtext_name.py` | EllesmereUINameplates | 姓名板任务计数不再压住怪物名字，字号同步 |
| `eui_friendly_player_names.py` | EllesmereUINameplates | 不再每次登录强制打开友方玩家名字 |
| `eui_chat_tab_fast.py` | EllesmereUIChat | 聊天标签点击即时切换 |
| `vss_kkowo_rename.py` | VamoosesSlipstream | 改名为 `VamoosesSlipstream_kkowo`（极速导航 kkowo优化版），网易 DD 不会再用原版覆盖它；设置自动迁移 |
| `vss_corpse_toggle.py` | 极速导航 | 加「死亡后提示跑尸路线」开关 |
| `polestar_zhcn_fill.py` | Polestar_zhCN | 补齐 Polestar 未翻译的界面和指南文字 |

网易 DD 更新 EllesmereUI、Polestar 或极速导航后，补丁会被覆盖：退出游戏，双击 `Tools\DD更新后重打补丁.bat` 即可重新打上。EUI 子插件和 Polestar_zhCN 是被主插件按文件夹名加载的，不能改名，所以只能这样重打。

## 开发

### 目录

- `Addon/kkowoUI/`：插件本体（`Core/` 框架与设置面板，`Modules/` 各模块，`Data/` 数据，`Media/` 图标、贴图、字体、音效）
- `Patches/`：第三方插件补丁
- `Tools/`：检查、部署、补丁、打包和素材生成脚本；`Tools/friend_pack/` 是整合包的安装脚本模板
- `Profiles/`：网易 DD 分享说明和各版本更新公告

### 修改流程

1. 改代码后运行 `node Tools\check.js`，必须 0 错误 0 警告（检查语法、未声明的全局写入、先用后声明）。
2. 退出游戏，运行 `powershell -ExecutionPolicy Bypass -File Tools\deploy.ps1`，把插件复制成游戏 AddOns 里的真实文件夹。
3. 进游戏，`/kk status` 确认版本和模块状态。

约定：
- 游戏里的 `kkowoUI` 必须是真实文件夹，不用目录链接（网易 DD 会顺着链接监视、占用仓库文件）。
- 脚本只移动和复制，旧文件一律移进备份，不删除；唯一的删除是确认是目录链接后、非递归地移除链接本身。
- 12.x 的保密值一律经过 `F.PlainNumber` / `F.PlainString` / `F.IsSecret` 再使用；不往暴雪核心框体和全局表上写自定义字段；只用 EUI 公开接口。

### 脚本

| 脚本 | 作用 |
| --- | --- |
| `node Tools\check.js` | 静态检查 |
| `Tools\deploy.ps1` | 部署插件（需退出游戏）；顺带把旧名 KkowoUI / ForeverUI 的文件夹、存档和 AddOns.txt 迁移成 kkowoUI |
| `python -I Tools\apply_patches.py --check` / `--apply` | 查看 / 应用全部补丁（`--apply` 需退出游戏）；`Tools\DD更新后重打补丁.bat` 等同于 `--apply` |
| `python -I Tools\make_friend_pack.py` | 生成整合包压缩包到仓库同级的 `share\`（游戏开着也能打包，配置先脱敏并做隐私扫描） |
| `Tools\网易DD分享上传.bat` | 网易 DD 配置分享上传助手（脱敏副本换入、上传后换回，需退出游戏） |
| `python -I Tools\compare_update.py <新版.zip>` | 对比第三方插件新版与当前安装（只读） |
| `python -I Tools\slim_addons.py` | 游戏外批量停用闲置插件（先备份 AddOns.txt） |
| `python -I Tools\archive_disabled_addons.py` | 把已停用的插件移到备份目录归档（附还原清单） |
| `python -I Tools\install_mmo_fonts.py --src <字体目录>` / `--rollback` | 安装 / 回滚界面字体 |
| `python -I Tools\deploy_raid_markers.py --install` / `--uninstall` | 部署 / 卸载 3D 团队标记图集 |
| `gen_*.py` / `gen_hd_icons.js` | 重新生成图标、贴图、冷却预设数据和猎人音效 |

### 路径环境变量（游戏不在默认位置时设置）

| 变量 | 含义 | 默认 |
| --- | --- | --- |
| `WOW_FOREVER_DIR` | 客户端目录（含 `Interface`、`Fonts`、`WTF`） | `E:\Program Files\World of Warcraft\_forever_` |
| `WOW_BACKUP_ROOT` | 备份总目录 | 仓库同级的 `backups` |
| `WOW_ACCOUNT_DIR` | `WTF\Account\<账号目录>` | 分享上传和整合包脚本在只有一个账号时自动识别；`pack_share.py`、`apply_live_config.py` 需手动设置 |
| `WOW_ADDONS_TXT` | 角色的 `AddOns.txt`（瘦身、归档脚本用） | 无 |
| `WOW_SHARE_DIR` | 网易 DD 分享的脱敏副本目录 | 仓库同级的 `share-kkowo` |
| `LUAPARSE_PATH` | `check.js` 用的 luaparse | `Tools/node_modules/luaparse` |

## 版本

- **1.3.1**：插件正式定名为 kkowoUI，设置自动迁移；整合包安装改为先完整备份再干净安装。
- **1.3.0**：悬浮提示、聊天气泡、拍卖行、角色面板、经验条统一风格；新增职业预设冷却条、静音攻击喊声、地图坐标去重、物件名汉化；极速导航改名防 DD 覆盖。

各版本的详细说明见 `Profiles/网易DD更新公告_*.md`。

## 许可

kkowoUI 本身以 MIT 许可发布（见 `LICENSE`）。EllesmereUI、Polestar、极速导航等第三方插件的版权归各自作者所有。
