# -*- coding: utf-8 -*-
"""Generate kkowoUI brand & motion textures (writes into Addon/kkowoUI_Media/Media).

  Media/Icons/kkowoUI.tga          128x128 flat grass-green geometric emblem (transparent bg)
  Media/Textures/SoftGlow.tga       64x64  radial soft glow (white, alpha falloff)
  Media/Textures/BarPillMask.tga     7x7   nine-slice rounded-rect mask (radius=3)
  Media/Textures/BarPillRim.tga      7x7   nine-slice 1px rounded hairline rim (radius=3)
  Media/Textures/BarPillMask6.tga   13x13  nine-slice rounded-rect mask (radius=6)
  Media/Textures/BarPillRim6.tga    13x13  nine-slice 1px rounded hairline rim (radius=6)
  Media/Textures/CircleMask.tga    128x128 anti-aliased SDF circle mask
  Media/Textures/CircleRing.tga    128x128 crisp anti-aliased hollow ring frame
  Media/Textures/CircleArcGlow.tga 128x128 feathered crescent glow arc for rotating orb timer
  Media/Textures/SparkBlade.tga     64x64  leading-edge luminous spark blade with soft trail
  Media/Textures/VignetteEdge.tga  128x128 directional smooth falloff edge for screen vignette
  Media/Textures/DiagStripes.tga    64x64  seamless 45-deg high-contrast diagonal stripes

All outputs are 32-bit uncompressed TGA.
Usage:  python Tools/gen_brand_textures.py [--preview DIR]
"""
import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Addon", "kkowoUI_Media", "Media")
SIZE = 128

# Fresh vibrant grass green (#52D669), pure flat monochrome matching EUI eg-logo.tga style
GRASS_GREEN = (82, 214, 105)


def make_logo():
    """Pure flat transparent-background geometric grass-green 'K' circular monogram.
    Designed in the exact flat architectural cutout family of EUI's eg-logo.tga:
    no rounded-square card, no gradient, no drop shadow, no gloss.
    """
    ss = 8
    W = SIZE * ss
    c = W * 0.5
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    dx = x - c
    dy = y - c
    r = np.sqrt(dx * dx + dy * dy)

    # 1) Outer circular ring (bold flat geometric stroke)
    r_outer = W * 0.435
    r_inner = W * 0.315
    ring = (r <= r_outer) & (r >= r_inner)

    # 2) Clean right-side portal cut on the outer ring (creates dynamic 'K' negative space)
    gap_half = W * 0.052
    right_cut = (dx > W * 0.12) & (np.abs(dy) < gap_half)
    # Also cut clean separation notches where the K diagonals exit the right arc
    ring = ring & (~right_cut)

    # 3) Inner bold geometric 'K' monogram harmonized with the ring stroke weight
    stroke = W * 0.115
    stem_x = -W * 0.145
    stem_top = -W * 0.245
    stem_bot = W * 0.245
    stem = (np.abs(dx - stem_x) <= stroke * 0.52) & (dy >= stem_top) & (dy <= stem_bot)

    # Upper & lower 45-degree K arms meeting the stem cleanly
    # Distance to line segment helper
    def seg_mask(x1, y1, x2, y2, half_w):
        vx, vy = x2 - x1, y2 - y1
        l2 = vx * vx + vy * vy
        t = np.clip(((dx - x1) * vx + (dy - y1) * vy) / l2, 0.0, 1.0)
        px = x1 + t * vx
        py = y1 + t * vy
        dist = np.sqrt((dx - px) ** 2 + (dy - py) ** 2)
        return dist <= half_w

    # Clean diagonal bars clipped inside outer circle so arms merge seamlessly into the emblem
    arm_half = stroke * 0.46
    # Use crisp flat-ended oriented boxes instead of round caps for ultra-modern EUI geometry
    def rect_bar(x1, y1, x2, y2, half_w):
        vx, vy = x2 - x1, y2 - y1
        length = math.hypot(vx, vy)
        ux, uy = vx / length, vy / length
        nx, ny = -uy, ux
        rx, ry = dx - x1, dy - y1
        along = rx * ux + ry * uy
        perp = np.abs(rx * nx + ry * ny)
        return (along >= 0.0) & (along <= length) & (perp <= half_w)

    # K arms start with a crisp architectural gap from the vertical stem? No: solid unified K reads crisper at 16px!
    # Start right at the stem center-right edge, angled cleanly to the upper-right and lower-right ring
    arm_up = rect_bar(stem_x - W * 0.01, W * 0.015, W * 0.27, -W * 0.255, arm_half)
    arm_dn = rect_bar(stem_x + W * 0.055, -W * 0.035, W * 0.27, W * 0.255, arm_half)

    # Clip the K inside the inner circle + small clean gutter so the K floats crisply inside the ring!
    # Wait: let's add a crisp negative-space gutter around the ring inner edge, OR let the ring stay unbroken
    # except right-center horizontal break, and float the bold K inside with crisp clearance!
    inner_clip = r <= (r_inner - W * 0.058)
    k_shape = (stem | arm_up | arm_dn) & inner_clip

    # Wait: if clipped inside inner_clip (radius ~0.257W), let's ensure K proportions are generous and super legible at 16px!
    # Actually even cleaner & bolder (exact EUI eg-logo.tga silhouette weight!):
    # Make a bold outer ring (r_outer=0.45W, r_inner=0.34W) broken cleanly on the right-middle,
    # and connect the K's vertical stem and right diagonals directly with architectural negative-space cuts!
    r_outer = W * 0.445
    r_inner = W * 0.338
    ring2 = (r <= r_outer) & (r >= r_inner)
    # Break right side of circle into clean C-like frame that hugs K's open right mouth
    angle = np.arctan2(dy, dx)
    mouth_cut = (dx > 0) & (np.abs(angle) < math.radians(34))
    ring2 = ring2 & (~mouth_cut)

    # Bold K inside with strong, crisp strokes (readable even at 16x16)
    st_x = -W * 0.135
    st_w = W * 0.062
    st_h = W * 0.235
    k_stem = (np.abs(dx - st_x) <= st_w) & (np.abs(dy) <= st_h)
    k_up = rect_bar(st_x - W * 0.01, W * 0.035, W * 0.265, -W * 0.240, W * 0.056)
    k_dn = rect_bar(st_x + W * 0.045, -W * 0.030, W * 0.275, W * 0.245, W * 0.056)
    # Clip the right tips cleanly along a vertical architectural line & inside r_outer
    k_body = (k_stem | k_up | k_dn) & (r <= r_outer) & (dx <= W * 0.275) & (np.abs(dy) <= W * 0.235)
    # Carve a crisp negative-space channel separating the K from the inner ring edge (except right tips stay inside)
    k_body = k_body & (r <= (r_inner - W * 0.042))
    # Extend the right tips cleanly into the open right mouth of the ring!
    k_tips = (k_up | k_dn) & (dx > W * 0.04) & (np.abs(dy) <= W * 0.235) & (r <= r_outer * 0.96) & (np.abs(angle) < math.radians(48))

    # Re-check: let's keep the K completely inside the ring with generous spacing, OR merge cleanly.
    # Actually let's check both geometrically: K inside an open C-ring with tips extending cleanly out through the right opening
    # gives an iconic, razor-sharp flat silhouette at 16px, 32px, and 128px!
    # Trim ring cleanly with a small gap around the K arms where they exit!
    ring_gap_up = rect_bar(st_x - W * 0.01, W * 0.035, W * 0.45, -W * 0.425, W * 0.095)
    ring_gap_dn = rect_bar(st_x + W * 0.045, -W * 0.030, W * 0.45, W * 0.425, W * 0.095)
    ring_final = (r <= r_outer) & (r >= r_inner) & (~mouth_cut) & (~ring_gap_up) & (~ring_gap_dn)

    k_final = (k_stem | k_up | k_dn) & (np.abs(dy) <= W * 0.235) & (r <= r_outer * 0.94)
    # Ensure K stem doesn't collide with ring inner wall (r_inner=0.338W; corner of stem is sqrt(0.197^2 + 0.235^2)=0.306W < 0.338W -> clean 0.032W gap!)
    shape = (ring_final | k_final).astype(np.float32)

    alpha = shape.reshape(SIZE, ss, SIZE, ss).mean(axis=(1, 3))
    rgba = np.zeros((SIZE, SIZE, 4), dtype=np.uint8)
    rgba[..., 0] = GRASS_GREEN[0]
    rgba[..., 1] = GRASS_GREEN[1]
    rgba[..., 2] = GRASS_GREEN[2]
    rgba[..., 3] = np.clip(np.round(alpha * 255.0), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_soft_glow():
    n = 64
    y, x = np.mgrid[0:n, 0:n].astype(np.float32)
    c = (n - 1) / 2.0
    r2 = ((x - c) / c) ** 2 + ((y - c) / c) ** 2
    a = np.exp(-r2 * 3.2)
    a = np.clip((a - np.exp(-3.2)) / (1 - np.exp(-3.2)), 0, 1)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_pill_mask(radius=3):
    n = radius * 2 + 1
    ss = 16
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    r_px = radius * ss
    cx = np.clip(x, r_px, W - r_px)
    cy = np.clip(y, r_px, W - r_px)
    dist = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    cov = np.clip(r_px - dist + 0.5, 0.0, 1.0)
    alpha = cov.reshape(n, ss, n, ss).mean(axis=(1, 3))
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_pill_rim(radius=3):
    n = radius * 2 + 1
    ss = 16
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    r_px = radius * ss
    cx = np.clip(x, r_px, W - r_px)
    cy = np.clip(y, r_px, W - r_px)
    dist = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    outer = np.clip(r_px - dist + 0.5, 0.0, 1.0)
    r_in = max(0.0, (radius - 1) * ss)
    dist2 = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    inner = np.clip(r_in - dist2 + 0.5, 0.0, 1.0)
    cov = np.clip(outer - inner, 0.0, 1.0)
    alpha = cov.reshape(n, ss, n, ss).mean(axis=(1, 3))
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_circle_mask(n=128):
    ss = 4
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    c = W * 0.5
    r = np.sqrt((x - c) ** 2 + (y - c) ** 2)
    rad = W * 0.485
    cov = np.clip(rad - r + 0.5, 0.0, 1.0)
    alpha = cov.reshape(n, ss, n, ss).mean(axis=(1, 3))
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_circle_ring(n=128, thickness=0.075):
    ss = 4
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    c = W * 0.5
    r = np.sqrt((x - c) ** 2 + (y - c) ** 2)
    r_out = W * 0.485
    r_in = r_out - W * thickness
    outer = np.clip(r_out - r + 0.5, 0.0, 1.0)
    inner = np.clip(r_in - r + 0.5, 0.0, 1.0)
    cov = np.clip(outer - inner, 0.0, 1.0)
    alpha = cov.reshape(n, ss, n, ss).mean(axis=(1, 3))
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_circle_arc_glow(n=128):
    """Feathered luminous crescent arc around perimeter for rotating orb ring."""
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) + 0.5
    c = n * 0.5
    dx = x - c
    dy = y - c
    r = np.sqrt(dx * dx + dy * dy) / (n * 0.5)
    # Ring profile peaking at r = 0.88 with soft bloom
    radial = np.exp(-((r - 0.88) / 0.085) ** 2)
    radial *= np.clip((0.99 - r) / 0.04, 0.0, 1.0)
    # Angular sweep: bright head at top (-pi/2), fading smoothly clockwise over ~240 deg
    ang = (np.arctan2(dy, dx) + math.pi * 0.5) % (2.0 * math.pi)
    # Head at ang=0, trailing backward (ang close to 2*pi -> bright; ang=0..pi -> faint)
    # Smooth bright comet tail spanning 220 deg
    tail = np.clip((ang - math.radians(120)) / math.radians(240), 0.0, 1.0) ** 1.65
    # Small soft leading cap near ang=0
    head = np.exp(-(np.minimum(ang, 2.0 * math.pi - ang) / 0.14) ** 2) * 0.95
    a = np.clip(radial * np.maximum(tail, head), 0.0, 1.0)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(a * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_spark_blade(n=64):
    """Vertical razor-bright leading spark with soft horizontal bloom (centered at x=0.72)."""
    y, x = np.mgrid[0:n, 0:n].astype(np.float32) + 0.5
    nx = x / n
    ny = (y - n * 0.5) / (n * 0.5)
    # Vertical envelope (bright across middle, softly tapered at top/bottom)
    vy = np.clip(1.0 - (np.abs(ny) ** 2.4), 0.0, 1.0)
    # Sharp core at nx = 0.68, longer soft glow trailing left, short bloom right
    dx = nx - 0.68
    core = np.exp(-(dx / 0.06) ** 2)
    trail = np.where(dx < 0, np.exp(-(dx / 0.34) ** 2) * 0.52, np.exp(-(dx / 0.14) ** 2) * 0.40)
    a = np.clip(vy * np.maximum(core, trail), 0.0, 1.0)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(a * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_vignette_edge(n=128):
    """Smooth directional edge fade: opaque at y=0 (top), smooth power fade to 0 at y=n-1."""
    y = np.linspace(0.0, 1.0, n, dtype=np.float32)[:, None]
    a = np.clip((1.0 - y) ** 2.2, 0.0, 1.0)
    a = np.repeat(a, n, axis=1)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(a * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_diag_stripes(n=64):
    """Tileable 45-degree high-contrast white diagonal stripes with smooth AA."""
    ss = 4
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    period = W / 4.0  # 4 stripes per 64px tile -> seamless repeat
    phase = ((x + y) % period) / period
    # Crisp stripe occupying 38% of period
    edge = 0.04
    c1 = np.clip((phase - (0.31 - edge)) / (2 * edge), 0.0, 1.0)
    c2 = np.clip(((0.69 + edge) - phase) / (2 * edge), 0.0, 1.0)
    cov = np.minimum(c1, c2)
    alpha = cov.reshape(n, ss, n, ss).mean(axis=(1, 3))
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def save_tga(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="TGA", compression=None)
    print("wrote", os.path.normpath(path), os.path.getsize(path), "bytes")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", help="also write PNG previews into this directory")
    args = ap.parse_args()
    logo = make_logo()
    save_tga(logo, os.path.join(ROOT, "Icons", "kkowoUI.tga"))
    save_tga(make_soft_glow(), os.path.join(ROOT, "Textures", "SoftGlow.tga"))
    save_tga(make_pill_mask(3), os.path.join(ROOT, "Textures", "BarPillMask.tga"))
    save_tga(make_pill_rim(3), os.path.join(ROOT, "Textures", "BarPillRim.tga"))
    save_tga(make_pill_mask(6), os.path.join(ROOT, "Textures", "BarPillMask6.tga"))
    save_tga(make_pill_rim(6), os.path.join(ROOT, "Textures", "BarPillRim6.tga"))
    save_tga(make_circle_mask(128), os.path.join(ROOT, "Textures", "CircleMask.tga"))
    save_tga(make_circle_ring(128), os.path.join(ROOT, "Textures", "CircleRing.tga"))
    save_tga(make_circle_arc_glow(128), os.path.join(ROOT, "Textures", "CircleArcGlow.tga"))
    save_tga(make_spark_blade(64), os.path.join(ROOT, "Textures", "SparkBlade.tga"))
    save_tga(make_vignette_edge(128), os.path.join(ROOT, "Textures", "VignetteEdge.tga"))
    save_tga(make_diag_stripes(64), os.path.join(ROOT, "Textures", "DiagStripes.tga"))
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)
        big = logo.resize((256, 256), Image.LANCZOS)
        bg = Image.new("RGBA", (620, 290), (22, 24, 30, 255))
        bg.paste(big, (16, 16), big)
        for i, s in enumerate((16, 20, 32, 64)):
            small = logo.resize((s, s), Image.LANCZOS)
            bg.paste(small, (300 + i * 76, 110), small)
        bg.save(os.path.join(args.preview, "logo_grass_preview.png"))


if __name__ == "__main__":
    main()
