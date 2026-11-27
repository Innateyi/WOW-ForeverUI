# Third-Party Attribution — kkowoUI_Tooltip

`kkowoUI_Tooltip` vendors **PrettyTooltip v1.5.0** (WoW Forever / Camelot edition) under the terms of the **MIT License**.

- **Upstream Project**: PrettyTooltip (`https://github.com/FallenShard/PrettyTooltip`)
- **Upstream Author**: Copyright (c) 2026 FallenShard
- **License**: MIT License (full text preserved verbatim in [LICENSE](LICENSE) and [Vendor/LICENSE](Vendor/LICENSE))

## Minimal Integration Adaptations
To avoid addon folder conflicts with NetEase DD while keeping upstream updates easy to merge, minimal lines in `Vendor/` are adapted by `Tools/sync_vendored_tooltip.py`:
1. `Vendor/Data/Stats.lua`, `Vendor/Panel/Layout.lua`, `Vendor/Tooltips/Item.lua`, `Vendor/Tooltips/Unit.lua`: resolve `art\` via `ns._artPath` instead of a hardcoded `Interface\AddOns\PrettyTooltip\art\` path.
2. `Vendor/PrettyTooltip.lua`: respect `ns._yielded` set by `Bridge/Compat.lua` if a standalone `PrettyTooltip` addon is also loaded.
3. `Vendor/Panel/Layout.lua`: add 4px left/right measurement slack for double-column rows with inline `|T|t` icons / CJK glyphs and respect `GetNumLines()` on wrapped rows so third-party addon rows (e.g. Scales) never wrap their final CJK character or clip the next line.
4. Retail-only files under upstream `Retail/` are omitted (not loaded on WoW Forever `16001/camelot`).
