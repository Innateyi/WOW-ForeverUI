# -*- coding: utf-8 -*-
"""
kkowoUI 条形立体明暗填充、条内轻流光与前沿光晕贴图生成器（2-T / 任务 8）
严格确定性、纯程序化数学生成、不删除任何文件、不引用或复制任何外部插件资产。
全部输出为 2 的幂尺寸、32 位无压缩 BGRA TGA（兼容 WoW 12.x 客户端，规避怪癖 8/9）：
  1. BarFillShaded.tga   (64x64)  — 液态玻璃立体明暗条体（顶部 15% 高光 1.00 -> 中段 0.90 -> 底部 30% 柔和阴影 0.72）
  2. BarFillSeamless.tga (64x64)  — 叠加段无缝灰阶变体（供治疗预估与护盾接续使用，两端无接缝）
  3. SparkSoft.tga       (64x64)  — 柔和二维高斯前沿光刃（紧致亮核心 + 更宽羽化外晕，四边严格归零）
  4. BarFlowSheen.tga    (128x64) — 45° 斜向宽羽化丝绸轻流光带（供治疗光波扫条，四边严格归零）
  5. BarEdgeBloom.tga    (64x64)  — 柔和径向填充前沿微光 Bloom（供 AttachEdgeSpark，四边严格归零）
  6. BarFlowLiquid.tga   (256x64) — 水平 C∞ 无缝周期液态能量流丝带（供 fx_barFlow 主流光层，ADD 混合，上下缘归零）
  7. BarFlowCurrent.tga  (256x64) — 水平 C∞ 无缝周期液态暗涌深浅波（供 fx_barFlow 立体涌流层，BLEND 混合，上下缘归零）
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


def make_bar_flow_liquid(width: int = 256, height: int = 64) -> np.ndarray:
    """
    水平严格 C∞ 无缝周期的液态光流丝带（256x64，供 fx_barFlow ADD 混合连续滚动）：
      • 采用像素中心相位 theta = 2*pi*(x + 0.5)/W，确保左右无缝循环零接缝
      • 双条交错起伏的液态丝带 + 斜向焦散高光波，视觉上呈真实液体流动而非单次扫光
      • 上下边缘严格归零窗函数，绝无纵向硬边截断
    """
    theta = 2.0 * math.pi * (np.arange(width, dtype=np.float64) + 0.5) / width
    ys = np.linspace(-1.0, 1.0, height, dtype=np.float64)
    th, yy = np.meshgrid(theta, ys)

    # 主液态光流丝带（宽柔丝绸波动 + 纵向缓慢起伏 + 沿流向明暗呼吸）
    y1 = -0.16 + 0.24 * np.sin(th) + 0.11 * np.sin(2.0 * th + 1.05)
    w1 = 0.38 + 0.08 * np.cos(th - 0.55)
    mod1 = 0.42 + 0.58 * (0.5 + 0.5 * np.sin(th - 0.35))
    ribbon1 = 0.64 * mod1 * np.exp(-(((yy - y1) / w1) ** 2))

    # 次液态细流丝带（二倍频错相交织，营造丰富层次）
    y2 = 0.20 + 0.22 * np.sin(2.0 * th + 2.35) + 0.09 * np.cos(th + 0.4)
    w2 = 0.27 + 0.06 * np.sin(2.0 * th - 0.8)
    mod2 = 0.36 + 0.64 * (0.5 + 0.5 * np.cos(2.0 * th + 0.8))
    ribbon2 = 0.44 * mod2 * np.exp(-(((yy - y2) / w2) ** 2))

    # 斜向焦散液波（沿流向持续推进的柔光斜纹，强化液体“往前流”的动势）
    caustic1 = (0.5 + 0.5 * np.sin(2.0 * th - 2.4 * yy)) ** 2.6
    caustic2 = (0.5 + 0.5 * np.sin(3.0 * th - 1.9 * yy + 1.7)) ** 3.0
    caustics = 0.30 * caustic1 + 0.22 * caustic2

    # 顶部微提亮贴合玻璃顶光
    vert_bias = 0.84 + 0.16 * np.exp(-(((yy + 0.48) / 0.62) ** 2))
    edge_y = np.clip((1.0 - np.abs(yy)) / 0.18, 0.0, 1.0) ** 1.6

    alpha = np.clip((ribbon1 + ribbon2 + caustics) * vert_bias * edge_y, 0.0, 1.0)
    img = np.empty((height, width, 4), dtype=np.uint8)
    img[:, :, 0] = 255
    img[:, :, 1] = 255
    img[:, :, 2] = 255
    img[:, :, 3] = np.round(alpha * 255.0).astype(np.uint8)
    return img


def make_bar_flow_current(width: int = 256, height: int = 64) -> np.ndarray:
    """
    水平严格 C∞ 无缝周期的液态深浅暗涌波（256x64，供 fx_barFlow BLEND 混合双层视差滚动）：
      • 以深冷液态阴影波谷叠加在任意色相条体上（即便牧师亮白/盗贼明黄/猎人浅绿条也能清晰看出液体涌动）
      • 与 BarFlowLiquid.tga 以黄金比例周期视差叠加，形成有机不重复的持续流动感
      • 上下边缘严格归零
    """
    theta = 2.0 * math.pi * (np.arange(width, dtype=np.float64) + 0.5) / width
    ys = np.linspace(-1.0, 1.0, height, dtype=np.float64)
    th, yy = np.meshgrid(theta, ys)

    # 宽阔深浅涌浪（主浪 + 斜向次浪）
    swell1 = (0.5 + 0.5 * np.sin(th - 1.65 * yy)) ** 1.9
    swell2 = (0.5 + 0.5 * np.sin(2.0 * th + 1.35 * yy + 1.1)) ** 2.2
    core_band = 0.58 * swell1 + 0.42 * swell2

    # 中下部略深增强液体厚重感，顶部留出清晰顶光带
    vert_weight = 0.65 + 0.35 * (0.5 + 0.5 * yy)
    edge_y = np.clip((1.0 - np.abs(yy)) / 0.16, 0.0, 1.0) ** 1.5

    alpha = np.clip(core_band * vert_weight * edge_y, 0.0, 1.0)
    img = np.empty((height, width, 4), dtype=np.uint8)
    img[:, :, 0] = 10
    img[:, :, 1] = 20
    img[:, :, 2] = 42
    img[:, :, 3] = np.round(alpha * 255.0).astype(np.uint8)
    return img


def generate_all(out_dir: pathlib.Path = OUT_DIR) -> list:
    specs = [
        ("BarFillShaded.tga", make_bar_fill_shaded(64)),
        ("BarFillSeamless.tga", make_bar_fill_seamless(64)),
        ("SparkSoft.tga", make_spark_soft(64)),
        ("BarFlowSheen.tga", make_bar_flow_sheen(128, 64)),
        ("BarEdgeBloom.tga", make_bar_edge_bloom(64)),
        ("BarFlowLiquid.tga", make_bar_flow_liquid(256, 64)),
        ("BarFlowCurrent.tga", make_bar_flow_current(256, 64)),
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
