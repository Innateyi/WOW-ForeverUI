# -*- coding: utf-8 -*-
"""
kkowoUI 条形明暗填充与柔和火花贴图生成器（2-T）
严格确定性、纯程序化数学生成、不删除任何文件、不引用或复制任何外部插件资产。
全部输出为 2 的幂尺寸、32 位无压缩 BGRA TGA（兼容 WoW 12.x 客户端，规避怪癖 8/9）：
  1. BarFillShaded.tga   (64x64) — 灰阶轻微上下明暗条体（顶部约 +6%、底部约 -8%，水平无缝）
  2. BarFillSeamless.tga (64x64) — 叠加段无缝灰阶变体（供治疗预估与护盾接续使用，两端无接缝）
  3. SparkSoft.tga       (64x64) — 柔和二维高斯前沿光刃（比 SparkBlade 更细腻、边缘无硬框）
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
    水平完全无缝的纯灰阶垂直明暗条体：
      • 中心基准亮度 ~0.943 (240/255)
      • 顶部亮约 +6% -> 1.000 (255/255)
      • 底部暗约 -8% -> 0.867 (221/255)
      • 顶部 2 像素极克制的柔和顶缘微光，便于被 SetGradient 与职业色自然染色
    """
    y = np.linspace(0.0, 1.0, size, dtype=np.float64)
    # 平滑余弦坡度：从 0 处 0.992 到 0.5 处 0.943 再到底部 0.867
    base = 0.943 + 0.056 * np.cos(y * math.pi) - 0.014 * (y ** 2)
    # 顶部柔和高光（仅顶缘 12% 高度平滑过渡）
    top_lift = 0.012 * np.exp(-((y / 0.09) ** 2))
    lum = np.clip(base + top_lift, 0.855, 1.0)
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
    水平严格恒定无端点衰减，垂直明暗略平缓（顶部 +4%、底部 -6%），过渡浑然一体。
    """
    y = np.linspace(0.0, 1.0, size, dtype=np.float64)
    lum = np.clip(0.950 + 0.042 * np.cos(y * math.pi) - 0.010 * (y ** 2), 0.880, 1.0)
    gray = np.round(lum * 255.0).astype(np.uint8)

    img = np.empty((size, size, 4), dtype=np.uint8)
    img[:, :, 0] = gray[:, None]
    img[:, :, 1] = gray[:, None]
    img[:, :, 2] = gray[:, None]
    img[:, :, 3] = 255
    return img


def make_spark_soft(size: int = 64) -> np.ndarray:
    """
    柔和二维高斯光刃（供 AttachEdgeSpark ADD 混合叠加）：
      • 纯白 RGB + 柔和双层高斯 Alpha（紧致核心 + 羽化外晕）
      • 贴图四边外缘严格衰减到 0，绝不出现方形截断硬边
    """
    coords = np.linspace(-1.0, 1.0, size, dtype=np.float64)
    xx, yy = np.meshgrid(coords, coords)

    core = np.exp(-((xx / 0.16) ** 2 + (yy / 0.56) ** 2))
    halo = 0.42 * np.exp(-((xx / 0.42) ** 2 + (yy / 0.72) ** 2))
    # 边缘归零窗函数，确保最外圈 2 像素 alpha 严格为 0
    edge_x = np.clip((1.0 - np.abs(xx)) / 0.12, 0.0, 1.0)
    edge_y = np.clip((1.0 - np.abs(yy)) / 0.12, 0.0, 1.0)
    window = (edge_x * edge_y) ** 2

    alpha = np.clip((core + halo) * window, 0.0, 1.0)
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
