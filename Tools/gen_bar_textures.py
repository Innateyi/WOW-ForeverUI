# -*- coding: utf-8 -*-
"""
kkowoUI 条形立体明暗填充、条内轻流光与前沿光晕贴图生成器（2-T / 任务 8）
严格确定性、纯程序化数学生成、不删除任何文件、不引用或复制任何外部插件资产。
全部输出为 2 的幂尺寸、32 位无压缩 BGRA TGA（兼容 WoW 12.x 客户端，规避怪癖 8/9）：
  1. BarFillShaded.tga   (64x64)  — 液态玻璃立体明暗条体（顶部 15% 高光 1.00 -> 中段 0.90 -> 底部 30% 柔和阴影 0.72）
  2. BarFillSeamless.tga (64x64)  — 叠加段无缝灰阶变体（供治疗预估与护盾接续使用，两端无接缝）
  3. SparkSoft.tga       (64x64)  — 柔和二维高斯前沿光刃（紧致亮核心 + 更宽羽化外晕，四边严格归零）
  4. BarFlowSheen.tga    (128x64) — 45° 斜向宽羽化丝绸轻流光带（供 fx_barFlow 与治疗扫光，四边严格归零）
  5. BarEdgeBloom.tga    (64x64)  — 柔和径向填充前沿微光 Bloom（供 AttachEdgeSpark，四边严格归零）
"""
import math
import pathlib
import struct
import sys

import numpy as np

REPO = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "Addon" / "kkowoUI_Media" / "Media" / "Textures"


def write_tga_rgba(path: pathlib.Path, rgba: np.ndarray) -> None:
    """以确定性 32 位无压缩 BGRA TGA（左上原点）落盘，不删除任何文件。"""
    h, w, c = rgba.shape
    assert c == 4, "Expected HxWx4 RGBA uint8 array"
    assert (w & (w - 1)) == 0 and (h & (h - 1)) == 0, f"Dimensions must be power-of-2: {w}x{h}"
    # TGA 18-byte header: imageType=2 (uncompressed true-color), 32bpp, descriptor=0x28 (top-left, 8-bit alpha)
    header = struct.pack(
        "<BBBHHBHHHHBB",
        0,     # idLength
        0,     # colorMapType
        2,     # imageType = uncompressed RGBA
        0, 0, 0,
        0, 0,
        w, h,
        32,    # pixelDepth
        0x28,  # top-left origin + 8 alpha bits
    )
    bgra = rgba[:, :, [2, 1, 0, 3]].astype(np.uint8)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(header + bgra.tobytes())


def make_bar_fill_shaded(size: int = 64) -> np.ndarray:
    """
    水平完全无缝的液态玻璃纵深灰阶条体：
      • 顶部 15% 清晰玻璃高光亮带（1.00 -> ~0.95）
      • 中段通透均匀（~0.90）
      • 底部 30% 柔和暗沉阴影（平滑落至 0.72）
      与横向职业色渐变叠加后呈现明显立体液态玻璃质感，同时保留高文字对比度。
    """
    y = np.linspace(0.0, 1.0, size, dtype=np.float64)
    # 中段基准 0.902 + 极轻线性坡度
    base = 0.902 - 0.020 * (y - 0.5)
    # 顶部 15% 柔和玻璃高光带（在 y=0 处将亮度推至 1.00）
    top_highlight = 0.098 * 0.5 * (1.0 - np.tanh((y - 0.13) / 0.06))
    # 底部 30% 平滑阴影（在 y=1.0 处将亮度柔和压至 0.720）
    bot_t = np.clip((y - 0.55) / 0.45, 0.0, 1.0)
    bot_shadow = -0.172 * (bot_t ** 1.65)
    lum = np.clip(base + top_highlight + bot_shadow, 0.720, 1.0)
    gray = np.round(lum * 255.0).astype(np.uint8)

    img = np.empty((size, size, 4), dtype=np.uint8)
    img[:, :, 0] = gray[:, None]
    img[:, :, 1] = gray[:, None]
    img[:, :, 2] = gray[:, None]
    img[:, :, 3] = 255
    return img


def make_bar_fill_seamless(size: int = 64) -> np.ndarray:
    """
    无缝接续变体：供治疗预估与吸收盾条紧贴主条填充边缘使用，
    水平严格恒定无端点衰减，垂直明暗略平缓（顶部 0.98、中段 0.91、底部 0.78），过渡浑然一体。
    """
    y = np.linspace(0.0, 1.0, size, dtype=np.float64)
    base = 0.910 - 0.015 * (y - 0.5)
    top_hi = 0.068 * 0.5 * (1.0 - np.tanh((y - 0.14) / 0.07))
    bot_t = np.clip((y - 0.56) / 0.44, 0.0, 1.0)
    bot_sh = -0.122 * (bot_t ** 1.60)
    lum = np.clip(base + top_hi + bot_sh, 0.780, 1.0)
    gray = np.round(lum * 255.0).astype(np.uint8)

    img = np.empty((size, size, 4), dtype=np.uint8)
    img[:, :, 0] = gray[:, None]
    img[:, :, 1] = gray[:, None]
    img[:, :, 2] = gray[:, None]
    img[:, :, 3] = 255
    return img


def make_spark_soft(size: int = 64) -> np.ndarray:
    """
    柔和二维高斯光刃（供 AttachEdgeSpark / 回蓝节拍 ADD 混合叠加）：
      • 纯白 RGB + 紧致亮核心与更宽羽化外晕
      • 贴图四边外缘严格衰减到 0，绝不出现方形截断硬边
    """
    coords = np.linspace(-1.0, 1.0, size, dtype=np.float64)
    xx, yy = np.meshgrid(coords, coords)

    core = np.exp(-((xx / 0.14) ** 2 + (yy / 0.54) ** 2))
    halo = 0.58 * np.exp(-((xx / 0.46) ** 2 + (yy / 0.76) ** 2))
    # 边缘归零窗函数，确保四边最外圈像素 alpha 严格为 0
    edge_x = np.clip((1.0 - np.abs(xx)) / 0.14, 0.0, 1.0)
    edge_y = np.clip((1.0 - np.abs(yy)) / 0.14, 0.0, 1.0)
    window = (edge_x * edge_y) ** 2

    alpha = np.clip((core + halo) * window, 0.0, 1.0)
    img = np.empty((size, size, 4), dtype=np.uint8)
    img[:, :, 0] = 255
    img[:, :, 1] = 255
    img[:, :, 2] = 255
    img[:, :, 3] = np.round(alpha * 255.0).astype(np.uint8)
    return img


def make_bar_flow_sheen(width: int = 128, height: int = 64) -> np.ndarray:
    """
    45° 斜向宽羽化丝绸轻流光带（128x64，供 fx_barFlow 与治疗光波扫条 ADD 混合叠加）：
      • 像素空间精确 45° 斜向高斯光带（主光带 + 极柔二次丝绸高光）
      • 四边严格归零窗，绝无硬边截断
    """
    xs = np.linspace(-1.0, 1.0, width, dtype=np.float64)
    ys = np.linspace(-1.0, 1.0, height, dtype=np.float64)
    xx, yy = np.meshgrid(xs, ys)

    # 宽高比 2:1，像素空间 45° 对应 u = xx - 0.5 * yy
    u = xx - 0.5 * yy
    main_band = 0.82 * np.exp(-((u / 0.28) ** 2))
    wide_silk = 0.34 * np.exp(-((u / 0.56) ** 2))
    accent_rib = 0.18 * np.exp(-(((u + 0.18) / 0.11) ** 2))

    # 顶部微提亮、底部略柔和，贴合玻璃顶光质感
    vert_silk = 0.88 + 0.12 * np.exp(-(((yy + 0.55) / 0.65) ** 2))

    edge_x = np.clip((1.0 - np.abs(xx)) / 0.16, 0.0, 1.0)
    edge_y = np.clip((1.0 - np.abs(yy)) / 0.14, 0.0, 1.0)
    window = (edge_x ** 2) * (edge_y ** 1.6)

    alpha = np.clip((main_band + wide_silk + accent_rib) * vert_silk * window, 0.0, 1.0)
    img = np.empty((height, width, 4), dtype=np.uint8)
    img[:, :, 0] = 255
    img[:, :, 1] = 255
    img[:, :, 2] = 255
    img[:, :, 3] = np.round(alpha * 255.0).astype(np.uint8)
    return img


def make_bar_edge_bloom(size: int = 64) -> np.ndarray:
    """
    柔和径向前沿微光 Bloom（64x64，供 AttachEdgeSpark ADD 混合叠加）：
      • 柔和径向羽化光晕 + 温润内芯，替代生硬细线
      • 四边严格归零，配合宿主圆角遮罩绝不外溢
    """
    coords = np.linspace(-1.0, 1.0, size, dtype=np.float64)
    xx, yy = np.meshgrid(coords, coords)

    inner = 0.68 * np.exp(-((xx / 0.24) ** 2 + (yy / 0.50) ** 2))
    outer = 0.52 * np.exp(-((xx / 0.54) ** 2 + (yy / 0.78) ** 2))

    edge_x = np.clip((1.0 - np.abs(xx)) / 0.16, 0.0, 1.0)
    edge_y = np.clip((1.0 - np.abs(yy)) / 0.16, 0.0, 1.0)
    window = (edge_x * edge_y) ** 2

    alpha = np.clip((inner + outer) * window, 0.0, 1.0)
    img = np.empty((size, size, 4), dtype=np.uint8)
    img[:, :, 0] = 255
    img[:, :, 1] = 255
    img[:, :, 2] = 255
    img[:, :, 3] = np.round(alpha * 255.0).astype(np.uint8)
    return img


def generate_all(out_dir: pathlib.Path = OUT_DIR) -> list:
    specs = [
        ("BarFillShaded.tga", make_bar_fill_shaded(64)),
        ("BarFillSeamless.tga", make_bar_fill_seamless(64)),
        ("SparkSoft.tga", make_spark_soft(64)),
        ("BarFlowSheen.tga", make_bar_flow_sheen(128, 64)),
        ("BarEdgeBloom.tga", make_bar_edge_bloom(64)),
    ]
    written = []
    for name, arr in specs:
        target = out_dir / name
        write_tga_rgba(target, arr)
        written.append(target)
    return written


def main() -> int:
    written = generate_all(OUT_DIR)
    for p in written:
        print(f"[OK] {p} ({p.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.exit(main())
