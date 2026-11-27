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


# ---------------------------------------------------------------------------
#  3D World Waypoint Medallion & Luminous Beam Assets (Media/Waypoint/*.tga)
#  Analytical SDF pure-white masters so WoW GPU SetGradient renders crisp
#  glacier / class / brand / gold / violet gradients at any scale!
# ---------------------------------------------------------------------------
def _sd_poly(x, y, pts):
    n = len(pts)
    d2 = np.full_like(x, 1e12, dtype=np.float32)
    sign = np.ones_like(x, dtype=np.float32)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        wx, wy = x - ax, y - ay
        t = np.clip((wx * ex + wy * ey) / (ex * ex + ey * ey + 1e-12), 0.0, 1.0)
        qx = wx - ex * t
        qy = wy - ey * t
        d2 = np.minimum(d2, qx * qx + qy * qy)
        c1 = y >= ay
        c2 = y < by
        c3 = ex * wy > ey * wx
        sign = np.where((c1 & c2 & c3) | ((~c1) & (~c2) & (~c3)), -sign, sign)
    return sign * np.sqrt(d2)


def _sd_seg(x, y, ax, ay, bx, by):
    ex, ey = bx - ax, by - ay
    t = np.clip(((x - ax) * ex + (y - ay) * ey) / (ex * ex + ey * ey + 1e-12), 0.0, 1.0)
    return np.hypot(x - ax - ex * t, y - ay - ey * t)


def _sstep(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def make_waypoint_disc(n=256):
    """Deep frosted obsidian circular medallion with subtle outer ambient shadow & radial depth."""
    c = (np.arange(n, dtype=np.float32) + 0.5) / n * 2.0 - 1.0
    x, y = np.meshgrid(c, c)
    r = np.hypot(x, y)
    r_disc = 0.78
    aa = 2.0 / n * 1.4

    # Soft dark ambient outer shadow separating medallion from bright sky/terrain
    sh_a = (1.0 - _sstep(r_disc - 0.04, r_disc + 0.16, r)) * 0.48
    # Main dark obsidian circle
    disc_a = 1.0 - _sstep(r_disc - aa, r_disc + aa, r)
    # Subtle depth gradient: deep midnight center -> slightly luminous slate edge + faint lower glow catch
    rad_t = np.clip(r / r_disc, 0.0, 1.0)
    # Center darker (#070A12), outer slightly lifted (#111726)
    base_r = 0.032 + 0.036 * (rad_t ** 1.6)
    base_g = 0.042 + 0.046 * (rad_t ** 1.6)
    base_b = 0.072 + 0.070 * (rad_t ** 1.6)

    # Subtle inner glass bevel ring just inside the perimeter
    inner_ring = np.exp(-((r - (r_disc - 0.04)) / 0.025) ** 2) * 0.06
    base_r = np.clip(base_r + inner_ring, 0.0, 1.0)
    base_g = np.clip(base_g + inner_ring, 0.0, 1.0)
    base_b = np.clip(base_b + inner_ring * 1.15, 0.0, 1.0)

    body_a = disc_a * 0.90
    out_a = body_a + sh_a * (1.0 - body_a)
    safe = np.where(out_a > 1e-5, out_a, 1.0)
    out_r = (base_r * body_a) / safe
    out_g = (base_g * body_a) / safe
    out_b = (base_b * body_a) / safe

    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0] = np.round(np.clip(out_r, 0, 1) * 255).astype(np.uint8)
    rgba[..., 1] = np.round(np.clip(out_g, 0, 1) * 255).astype(np.uint8)
    rgba[..., 2] = np.round(np.clip(out_b, 0, 1) * 255).astype(np.uint8)
    rgba[..., 3] = np.round(np.clip(out_a, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_waypoint_crescent_rim(n=256):
    """Iconic lower crescent rim glow where vertical beam joins the medallion (pure white master)."""
    c = (np.arange(n, dtype=np.float32) + 0.5) / n * 2.0 - 1.0
    x, y = np.meshgrid(c, c)
    r = np.hypot(x, y)
    r_rim = 0.785
    # Angle measured from 6 o'clock (y = +1 -> 0 rad; top y = -1 -> pi rad)
    ang = np.abs(np.arctan2(x, y))  # [0..pi], 0 at bottom center!

    # Crisp rim stroke thickest & brightest at bottom (ang=0), tapering gracefully toward sides & faint upper hairline
    # Lower crescent weight: 1.0 at bottom, smooth falloff to 0.06 at top
    crescent = np.clip(1.0 - (ang / (math.pi * 0.62)) ** 1.55, 0.0, 1.0)
    hairline_w = 0.016 + 0.022 * crescent
    d_rim = np.abs(r - r_rim)
    core_rim = np.exp(-((d_rim / hairline_w) ** 2.4)) * (0.14 + 0.86 * crescent)

    # Soft outer luminous bloom focused on lower crescent (where beam enters)
    bloom_radial = np.exp(-((r - (r_rim + 0.01)) / 0.095) ** 2) * (1.0 - _sstep(0.96, 1.0, r))
    bloom_ang = np.clip(1.0 - (ang / (math.pi * 0.55)) ** 1.35, 0.0, 1.0)
    bloom = bloom_radial * bloom_ang * 0.52

    # Extra hot-spot node right at 6 o'clock beam junction
    hot = np.exp(-(((x / 0.14) ** 2) + (((y - r_rim) / 0.065) ** 2))) * 0.78

    a = np.clip(np.maximum(core_rim, bloom) + hot * 0.45, 0.0, 1.0)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_waypoint_beam_core(w=64, h=256):
    """Razor-crisp feathered vertical light shaft (brightest at top meeting medallion, fading softly to ground)."""
    x = (np.arange(w, dtype=np.float32) + 0.5) / w * 2.0 - 1.0
    y = (np.arange(h, dtype=np.float32) + 0.5) / h  # 0=top (medallion), 1=bottom (ground)
    X, Y = np.meshgrid(x, y)
    # Slight graceful taper toward bottom ground point (must use abs(X) for fractional power!)
    sigma_x = 0.25 - 0.08 * Y
    horiz = np.exp(-((np.abs(X) / sigma_x) ** 2.2))
    # Bright white-hot core near top joining crescent rim, fading gently down to ground flare
    top_cap = _sstep(0.0, 0.015, Y)
    bot_fade = np.clip((1.0 - Y) / 0.88, 0.0, 1.0) ** 0.72 * (1.0 - _sstep(0.92, 1.0, Y))
    a = np.clip(horiz * top_cap * (0.22 + 0.78 * bot_fade), 0.0, 1.0)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_waypoint_beam_halo(w=64, h=256):
    """Atmospheric outer bloom surrounding the vertical light beam (ADD blend + vertical gradient)."""
    x = (np.arange(w, dtype=np.float32) + 0.5) / w * 2.0 - 1.0
    y = (np.arange(h, dtype=np.float32) + 0.5) / h
    X, Y = np.meshgrid(x, y)
    sigma_x = 0.44 - 0.12 * Y
    horiz = np.exp(-((np.abs(X) / sigma_x) ** 2.0)) * (1.0 - _sstep(0.88, 1.0, np.abs(X)))
    top_cap = _sstep(0.0, 0.03, Y)
    bot_fade = (1.0 - Y) ** 0.85
    a = np.clip(horiz * top_cap * bot_fade, 0.0, 1.0)
    rgba = np.zeros((h, w, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_waypoint_sweep(n=256):
    """Lush 270-deg luminous comet sweep ring on exact r=0.785 orbit matching WaypointCrescentRim."""
    c = (np.arange(n, dtype=np.float32) + 0.5) / n * 2.0 - 1.0
    x, y = np.meshgrid(c, c)
    r = np.hypot(x, y)
    r_rim = 0.785

    # Thick crisp core ring + generous soft luminous outer/inner bloom
    d_rim = np.abs(r - r_rim)
    core = np.exp(-((d_rim / 0.032) ** 2.2))
    bloom = np.exp(-((d_rim / 0.088) ** 2.0)) * 0.58 * (1.0 - _sstep(0.95, 1.0, r))

    # Angle clockwise from 6 o'clock (where beam joins) -> 0 at bottom, increasing clockwise
    ang = (np.arctan2(-x, y) + 2.0 * math.pi) % (2.0 * math.pi)
    # Lush 280-deg trailing comet tail peaking at ang=0 (bright rounded head)
    tail = np.clip((ang - math.radians(75)) / math.radians(285), 0.0, 1.0) ** 1.35
    head = np.exp(-((np.minimum(ang, 2.0 * math.pi - ang) / 0.24) ** 2.0)) * 1.0
    # Subtle full-circle rim sheen so ring feels full & radiant during sweep
    angular = np.maximum(0.20, np.maximum(tail * 0.96, head))

    a = np.clip(np.maximum(core * angular, bloom * angular), 0.0, 1.0)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_waypoint_ripple(n=128):
    """Crisp expanding luminous ground ring for waypoint spawn impact."""
    c = (np.arange(n, dtype=np.float32) + 0.5) / n * 2.0 - 1.0
    x, y = np.meshgrid(c, c)
    r = np.hypot(x, y)
    ring = np.exp(-(((r - 0.76) / 0.055) ** 2))
    inner_glow = np.exp(-(((r - 0.66) / 0.14) ** 2)) * 0.34
    a = np.clip((ring + inner_glow) * (1.0 - _sstep(0.92, 1.0, r)), 0.0, 1.0)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def _render_waypoint_icon(n, sdf_fn, glow_strength=0.22):
    """Renders crisp pure-white SDF icon with subtle inner-edge glow for luminous SetGradient tinting."""
    c = (np.arange(n, dtype=np.float32) + 0.5) / n * 2.0 - 1.0
    x, y = np.meshgrid(c, c)
    d = sdf_fn(x, y)
    aa = 2.0 / n * 1.4
    fg = 1.0 - _sstep(-aa, aa, d)
    # Subtle soft neon halo closely hugging the strokes
    halo = np.exp(-((np.maximum(d, 0.0) / 0.11) ** 1.8)) * glow_strength * (1.0 - _sstep(0.88, 0.99, np.hypot(x, y)))
    a = np.clip(np.maximum(fg, halo), 0.0, 1.0)
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.round(a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_waypoint_pin_icon(n=256):
    """kkowoUI-styled geometric double-nested diamond (clean crisp silhouette even at 22px)."""
    def sdf(x, y):
        # Slightly elongated vertical crystal diamond (ratio ~0.76 x 1.0) matching reference video
        outer_pts = [(0.0, -0.78), (0.59, 0.0), (0.0, 0.78), (-0.59, 0.0)]
        d_outer_solid = _sd_poly(x, y, outer_pts) - 0.016
        d_outer_frame = np.abs(d_outer_solid + 0.068) - 0.068  # Bold crisp hollow outer diamond
        # Crisp solid inner crystal diamond with generous negative space gutter
        inner_pts = [(0.0, -0.34), (0.25, 0.0), (0.0, 0.34), (-0.25, 0.0)]
        d_inner_solid = _sd_poly(x, y, inner_pts) - 0.012
        return np.minimum(d_outer_frame, d_inner_solid)
    return _render_waypoint_icon(n, sdf, glow_strength=0.28)


def make_waypoint_quest_icon(n=256):
    """kkowoUI-styled quest waypoint: crisp outer diamond frame + refined centered exclamation."""
    def sdf(x, y):
        outer_pts = [(0.0, -0.76), (0.58, 0.0), (0.0, 0.76), (-0.58, 0.0)]
        d_outer = np.abs(_sd_poly(x, y, outer_pts) + 0.040) - 0.048
        # Crisp exclamation stem + diamond dot inside
        d_stem = _sd_seg(x, y, 0.0, -0.30, 0.0, 0.12) - 0.062
        dot_pts = [(0.0, 0.24), (0.085, 0.34), (0.0, 0.44), (-0.085, 0.34)]
        d_dot = _sd_poly(x, y, dot_pts) - 0.012
        return np.minimum(d_outer, np.minimum(d_stem, d_dot))
    return _render_waypoint_icon(n, sdf, glow_strength=0.24)


def make_waypoint_corpse_icon(n=256):
    """kkowoUI-styled corpse waypoint: sleek geometric cross crest inside diamond horizon."""
    def sdf(x, y):
        d_v = _sd_seg(x, y, 0.0, -0.58, 0.0, 0.58) - 0.068
        d_h = _sd_seg(x, y, -0.38, -0.14, 0.38, -0.14) - 0.068
        d_ring = np.abs(np.hypot(x, y + 0.14) - 0.22) - 0.036
        return np.minimum(np.minimum(d_v, d_h), d_ring)
    return _render_waypoint_icon(n, sdf, glow_strength=0.24)


def make_waypoint_arrow_icon(n=128):
    """Sleek upward-pointing modern double chevron for off-screen medallion orbit."""
    def sdf(x, y):
        ax = np.abs(x)
        # Main crisp chevron pointing UP (y = -0.55)
        c1 = _sd_seg(ax, y, 0.0, -0.56, 0.56, 0.10) - 0.095
        # Subtle smaller inner chevron tucked below
        c2 = _sd_seg(ax, y, 0.0, -0.14, 0.34, 0.26) - 0.062
        return np.minimum(c1, c2)
    return _render_waypoint_icon(n, sdf, glow_strength=0.28)


def save_tga(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, format="TGA", compression=None)
    print("wrote", os.path.normpath(path), os.path.getsize(path), "bytes")


def _tint_grad(img, c_top, c_bot):
    """Preview helper: applies vertical gradient tint onto pure-white RGBA master."""
    arr = np.asarray(img, dtype=np.float32) / 255.0
    h = arr.shape[0]
    t = np.linspace(0.0, 1.0, h, dtype=np.float32)[:, None, None]
    ct = np.array(c_top, dtype=np.float32)
    cb = np.array(c_bot, dtype=np.float32)
    col = ct * (1.0 - t) + cb * t
    out = np.empty_like(arr)
    out[..., :3] = arr[..., :3] * col
    out[..., 3] = arr[..., 3]
    return Image.fromarray(np.round(np.clip(out, 0, 1) * 255).astype(np.uint8), "RGBA")


def generate_waypoint_assets(preview_dir=None):
    wp_dir = os.path.join(ROOT, "Waypoint")
    disc = make_waypoint_disc(256)
    rim = make_waypoint_crescent_rim(256)
    sweep = make_waypoint_sweep(256)
    bcore = make_waypoint_beam_core(64, 256)
    bhalo = make_waypoint_beam_halo(64, 256)
    ripple = make_waypoint_ripple(128)
    pin = make_waypoint_pin_icon(256)
    quest = make_waypoint_quest_icon(256)
    corpse = make_waypoint_corpse_icon(256)
    arrow = make_waypoint_arrow_icon(128)

    save_tga(disc, os.path.join(wp_dir, "WaypointDisc.tga"))
    save_tga(rim, os.path.join(wp_dir, "WaypointCrescentRim.tga"))
    save_tga(sweep, os.path.join(wp_dir, "WaypointSweep.tga"))
    save_tga(bcore, os.path.join(wp_dir, "WaypointBeamCore.tga"))
    save_tga(bhalo, os.path.join(wp_dir, "WaypointBeamHalo.tga"))
    save_tga(ripple, os.path.join(wp_dir, "WaypointRipple.tga"))
    save_tga(pin, os.path.join(wp_dir, "WaypointPin.tga"))
    save_tga(quest, os.path.join(wp_dir, "WaypointQuest.tga"))
    save_tga(corpse, os.path.join(wp_dir, "WaypointCorpse.tga"))
    save_tga(arrow, os.path.join(wp_dir, "WaypointArrow.tga"))

    if preview_dir:
        os.makedirs(preview_dir, exist_ok=True)
        # Render realistic night-terrain backdrop composite of all 5 presets + all 3 icons!
        W, H = 900, 360
        bg = Image.new("RGBA", (W, H), (22, 26, 36, 255))
        presets = [
            ("Glacier",  (0.64, 0.96, 1.00), (0.35, 0.48, 1.00), pin),
            ("Hunter",   (0.76, 0.96, 0.68), (0.34, 0.68, 0.30), pin),
            ("Brand",    (0.66, 1.00, 0.82), (0.20, 0.78, 0.44), quest),
            ("Gold",     (1.00, 0.95, 0.70), (0.90, 0.58, 0.18), pin),
            ("Violet",   (0.90, 0.81, 1.00), (0.48, 0.32, 0.94), corpse),
        ]
        for idx, (_, ct, cb, ic_img) in enumerate(presets):
            cx = 95 + idx * 178
            # Ground ripple
            rip_im = _tint_grad(ripple, ct, cb).resize((56, 24), Image.LANCZOS)
            bg.alpha_composite(rip_im, (cx - 28, 300 - 12))
            # Beam halo & core
            bh_im = _tint_grad(bhalo, ct, cb).resize((26, 195), Image.LANCZOS)
            bc_im = _tint_grad(bcore, (1, 1, 1), ct).resize((8, 195), Image.LANCZOS)
            bg.alpha_composite(bh_im, (cx - 13, 108))
            bg.alpha_composite(bc_im, (cx - 4, 108))
            # Medallion disc + crescent rim + inner icon
            d_im = disc.resize((72, 72), Image.LANCZOS)
            r_im = _tint_grad(rim, ct, cb).resize((72, 72), Image.LANCZOS)
            i_im = _tint_grad(ic_img, (1.0, 1.0, 1.0), cb).resize((40, 40), Image.LANCZOS)
            bg.alpha_composite(d_im, (cx - 36, 46))
            bg.alpha_composite(r_im, (cx - 36, 46))
            bg.alpha_composite(i_im, (cx - 20, 62))
            # Off-screen arrow mini preview above
            a_im = _tint_grad(arrow, ct, cb).resize((20, 20), Image.LANCZOS)
            bg.alpha_composite(a_im, (cx - 10, 18))
        out_p = os.path.join(preview_dir, "waypoint_medallion_preview.png")
        bg.save(out_p)
        print("wrote preview", out_p)


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
    generate_waypoint_assets(args.preview)
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
