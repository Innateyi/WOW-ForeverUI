# ForeverUI 现代 MMO 界面配置与切换清单

本清单适用于你**退出游戏准备切换测试 ForeverUI** 时参考，所有改动均安全可回退。

## 1. 推荐在游戏插件列表中停用的插件

| 插件名 | 原因 |
|---|---|
| `EUI_Haalandtool` | 核心功能已全部模块化迁入 `ForeverUI`（无污染、无全局泄漏、修完已知 Bug） |
| `ForeverLootSparkles` | 已内置到 `ForeverUI` 的「采集与拾取闪光提醒」模块 |
| `ArcUI` | 官方声明的一次性迁移存根，迁到 `ArcAuras` 后不再需要 |
| `BlizzMove` & `BlizzMove_Debug` | 已被 `EllesmereUI` 内置 Shifter 替代，且后者为调试插件 |
| `QuestieTrace` | 调试追踪插件，单角色存档已膨胀至 2.58 MB |
| `EllesmereUICooldownManager` | 与 `ArcAuras` 冲突（你目前已停用，保持停用即可） |
| `QFXSystemBar`（可选） | 停用后 `ForeverUI` 内置的「极简现代系统栏」自动接管；保留则自动让位 |
| `PrettyTooltip`（可选） | 停用后 `ForeverUI` 内置的「极简现代鼠标提示」自动接管；保留则自动让位 |

## 2. 推荐保留并微调的第三方插件设置

1. **`EllesmereUI`**：
   - 全局设置 → 主题强调色（Accent Color）→ 开启 **Use Class Color（职业主题色）**，与 `ForeverUI` 默认的职业主题色完全统一！
   - 字体轮廓保持 `Shadow`（轻量投影），质感最接近现代 MMO。
2. **`Leatrix_Maps`**（保留船艇、飞点、副本入口图标）：
   - 关闭 **显示区域等级（ShowZoneLevels）**，避免与 `ForeverUI` 地图区域等级重叠。
3. **`WaypointUI`**：
   - 正常保持启用；`ForeverUI` 不再碰 `SuperTrackedFrame`，彻底消除世界地图 `SetPassThroughButtons` 报错。
4. **`Polestar` + `Polestar_Extras_Mei`**：
   - 正常保持启用；可在 `Polestar` 主题设置里把强调色设为职业色，与全界面统一。
5. **如保留 `QFXSystemBar`**：
   - 建议关闭 `customMicroMenuShowDurabilityBadge`（已在 EUI 次要属性下有 `ForeverUI` 耐久度），时钟描边从 `THICKOUTLINE` 改为无描边或细描边。

## 3. 游戏内常用命令

- `/fui`：在 `EllesmereUI` 面板顶部直接打开 **ForeverUI** 设置
- `/fui status`：查看全部 17 个模块的实时启用 / 自动让位状态
- `/fui unlock`：触发 `EllesmereUI` 解锁模式拖动所有框体（平时也可按住 `Shift + 左键` 直接拖动）
