#!/usr/bin/env python3
r"""
kkowoUI — Ultra-Smooth Vector Icon & Global Raid Marker Generator
1) Redraws all 10 active SystemBar Lucide icons using mathematical Signed Distance Fields (SDF)
   rendered at 512x512 -> premultiplied-alpha Lanczos mipmap chain (128->64->32->16->8->4->2->1)
   encoded as lossless 32-bit BGRA BLP2 (colorEncoding=3, alphaDepth=8, hasMips=1).
   Zero DXT5 block noise, zero jaggedness at 16-28px in-game!
2) Redraws all 8 Raid Target Markers (Mark1..Mark8) using analytical Signed Distance Fields (SDF)
   at 1024x1024 supersampled master -> 256x256 Mark1.tga..Mark8.tga AND 1024x1024 4x4 sprite sheet
   UI-RaidTargetingIcons.blp (256x256 per cell, lossless BGRA BLP2 with full premultiplied-alpha
   Lanczos mipmaps + RGB edge-color dilation on every mip level for zero halo & zero jaggedness
   even when enlarged to 48-96px on nameplates or 3D overhead billboards!).
   Deploys to:
     - Addon/kkowoUI_Media/Media/MarkBar/Mark1.tga .. Mark8.tga
     - Addon/kkowoUI_Media/Media/MarkBar/UI-RaidTargetingIcons.blp
     - E:\Program Files\World of Warcraft\_forever_\Interface\TargetingFrame\UI-RaidTargetingIcons.blp
3) Writes visual inspection contact sheets (PNG) to Tools/_preview for verification.
"""
import math
import os
import struct
import numpy as np
from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE_OUT = os.path.join(REPO_ROOT, "Addon", "kkowoUI_Media", "Media", "SystemBar", "Lucide")
GAMEICONS_OUT = os.path.join(REPO_ROOT, "Addon", "kkowoUI_Media", "Media", "SystemBar", "GameIcons")
MARK_DIR = os.path.join(REPO_ROOT, "Addon", "kkowoUI_Media", "Media", "MarkBar")
WOW_TARGETING_DIR = os.environ.get(
    "WOW_TARGETING_DIR",
    r"E:\Program Files\World of Warcraft\_forever_\Interface\TargetingFrame",
)
PREVIEW_DIR = os.path.join(REPO_ROOT, "Tools", "_preview")

MASTER = 512
OUT_SIZE = 128

# Normalized [-1, 1] grid at MASTER resolution (y-down, like SVG/screen)
_coords = (np.arange(MASTER, dtype=np.float32) + 0.5) / MASTER * 2.0 - 1.0
GX, GY = np.meshgrid(_coords, _coords)


# ---------------------------------------------------------------------------
#  Analytical SDF Primitives (Vectorized NumPy — exact C^inf curves)
# ---------------------------------------------------------------------------
def sd_circle(x, y, cx, cy, r):
    return np.hypot(x - cx, y - cy) - r


def sd_ring(x, y, cx, cy, r, half_w):
    return np.abs(np.hypot(x - cx, y - cy) - r) - half_w


def sd_segment(x, y, ax, ay, bx, by):
    pax = x - ax
    pay = y - ay
    bax = bx - ax
    bay = by - ay
    denom = bax * bax + bay * bay
    if denom < 1e-12:
        return np.hypot(pax, pay)
    h = np.clip((pax * bax + pay * bay) / denom, 0.0, 1.0)
    return np.hypot(pax - bax * h, pay - bay * h)


def sd_polyline(x, y, pts):
    d = np.full_like(x, 1e6, dtype=np.float32)
    for i in range(len(pts) - 1):
        d = np.minimum(d, sd_segment(x, y, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1]))
    return d


def sd_arc(x, y, cx, cy, r, a0, a1):
    """Distance to circular arc centered at (cx, cy), radius r, angle [a0, a1] radians (y-down)."""
    dx = x - cx
    dy = y - cy
    ang = np.arctan2(dy, dx)
    mid = 0.5 * (a0 + a1)
    diff = (ang - mid + math.pi) % (2.0 * math.pi) - math.pi
    half_span = 0.5 * (a1 - a0)
    in_arc = np.abs(diff) <= half_span
    d_arc = np.abs(np.hypot(dx, dy) - r)
    d_end0 = np.hypot(x - (cx + math.cos(a0) * r), y - (cy + math.sin(a0) * r))
    d_end1 = np.hypot(x - (cx + math.cos(a1) * r), y - (cy + math.sin(a1) * r))
    return np.where(in_arc, d_arc, np.minimum(d_end0, d_end1))


def sd_round_box(x, y, cx, cy, bx, by, r):
    qx = np.abs(x - cx) - bx + r
    qy = np.abs(y - cy) - by + r
    return np.hypot(np.maximum(qx, 0.0), np.maximum(qy, 0.0)) + np.minimum(np.maximum(qx, qy), 0.0) - r


def sd_bezier_quad(x, y, p0, p1, p2, steps=28):
    ts = np.linspace(0.0, 1.0, steps + 1)
    pts = [
        (
            (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0],
            (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1],
        )
        for t in ts
    ]
    return sd_polyline(x, y, pts)


def sd_bezier_cubic(x, y, p0, p1, p2, p3, steps=36):
    ts = np.linspace(0.0, 1.0, steps + 1)
    pts = [
        (
            (1 - t) ** 3 * p0[0]
            + 3 * (1 - t) ** 2 * t * p1[0]
            + 3 * (1 - t) * t ** 2 * p2[0]
            + t ** 3 * p3[0],
            (1 - t) ** 3 * p0[1]
            + 3 * (1 - t) ** 2 * t * p1[1]
            + 3 * (1 - t) * t ** 2 * p2[1]
            + t ** 3 * p3[1],
        )
        for t in ts
    ]
    return sd_polyline(x, y, pts)


def smoothstep(e0, e1, v):
    t = np.clip((v - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def render_sdf_to_rgba(sdf_fn):
    """
    Renders analytical SDF into MASTERxMASTER RGBA float image:
    - Foreground is PURE luminous white (255, 255, 255) for crisp class-color SetVertexColor tinting
    - Subtle soft dark drop shadow behind stroke for readability on bright grass/snow without muddy rims
    """
    d = sdf_fn(GX, GY)
    # Anti-aliased foreground coverage (smooth over ~1.4 master pixels -> silky at all mip levels)
    aa = 2.0 / MASTER * 1.4
    fg_a = 1.0 - smoothstep(-aa, aa, d)

    # Subtle soft drop shadow offset slightly downward
    d_sh = sdf_fn(GX, GY - 0.032)
    sh_a = (1.0 - smoothstep(-0.02, 0.085, d_sh)) * 0.34

    # Composite pure white foreground over soft black shadow (straight alpha output)
    out_a = fg_a + sh_a * (1.0 - fg_a)
    safe_a = np.where(out_a > 1e-5, out_a, 1.0)
    # Premultiplied RGB = fg_a * 1.0 + sh_a * (1-fg_a) * 0.0 = fg_a
    rgb = np.where(out_a > 1e-5, np.clip(fg_a / safe_a, 0.0, 1.0), 1.0)

    rgba = np.zeros((MASTER, MASTER, 4), dtype=np.float32)
    rgba[:, :, 0] = rgb
    rgba[:, :, 1] = rgb
    rgba[:, :, 2] = rgb
    rgba[:, :, 3] = np.clip(out_a, 0.0, 1.0)
    return rgba


# ---------------------------------------------------------------------------
#  10 Redesigned Ultra-Smooth Lucide Icons (calibrated for 16-28px clarity)
# ---------------------------------------------------------------------------
SW = 0.068  # Standard Lucide half-stroke width in [-1, 1] (~8.7px stroke in 128px, ~1.36px at 20px)


def sdf_character(x, y):
    # Sleek head ring + wide graceful rounded shoulder arch
    head = np.abs(sd_circle(x, y, 0.0, -0.34, 0.30)) - SW
    # Shoulders: smooth rounded arch from x=-0.62 to +0.62
    left_v = sd_segment(x, y, -0.60, 0.68, -0.60, 0.44) - SW
    right_v = sd_segment(x, y, 0.60, 0.68, 0.60, 0.44) - SW
    top_bar = sd_segment(x, y, -0.30, 0.14, 0.30, 0.14) - SW
    arc_l = sd_arc(x, y, -0.30, 0.44, 0.30, math.pi, 1.5 * math.pi) - SW
    arc_r = sd_arc(x, y, 0.30, 0.44, 0.30, -0.5 * math.pi, 0.0) - SW
    return np.minimum.reduce([head, left_v, right_v, top_bar, arc_l, arc_r])


def sdf_social(x, y):
    # Two clean overlapping users (Lucide users)
    s = SW * 0.94
    # Primary user (left-center)
    h1 = np.abs(sd_circle(x, y, -0.22, -0.32, 0.25)) - s
    b1 = np.minimum.reduce([
        sd_segment(x, y, -0.72, 0.66, -0.72, 0.44) - s,
        sd_segment(x, y, 0.28, 0.66, 0.28, 0.44) - s,
        sd_segment(x, y, -0.48, 0.18, 0.04, 0.18) - s,
        sd_arc(x, y, -0.48, 0.44, 0.26, math.pi, 1.5 * math.pi) - s,
        sd_arc(x, y, 0.04, 0.44, 0.24, -0.5 * math.pi, 0.0) - s,
    ])
    # Secondary user (right)
    h2 = sd_arc(x, y, 0.34, -0.30, 0.21, -0.62 * math.pi, 0.55 * math.pi) - s
    b2 = np.minimum(
        sd_arc(x, y, 0.48, 0.44, 0.24, -0.48 * math.pi, 0.0) - s,
        sd_segment(x, y, 0.72, 0.44, 0.72, 0.66) - s,
    )
    return np.minimum.reduce([h1, b1, h2, b2])


def sdf_profession(x, y):
    # Lucide hammer: tilted 45 deg sleek crafting hammer with sculpted head & open shaft
    s = SW * 0.95
    # Rotate coordinates -45 deg so handle runs vertically along +v, head at -v
    c = math.cos(math.pi / 4.0)
    sn = math.sin(math.pi / 4.0)
    u = x * c + y * sn
    v = -x * sn + y * c

    # Shaft (rounded rectangle outline from v=-0.12 to +0.86, half-width 0.105)
    shaft = np.abs(sd_round_box(u, v, 0.0, 0.38, 0.115, 0.47, 0.095)) - s
    # Keep shaft open where it joins head (mask top edge of shaft inside head)
    # Hammer head: wider asymmetric forging hammer from u=-0.34..+0.42, v=-0.56..-0.14
    head_pts = [
        (-0.34, -0.18),
        (-0.34, -0.52),
        (0.06, -0.56),
        (0.42, -0.40),
        (0.38, -0.22),
        (0.16, -0.18),
        (-0.34, -0.18),
    ]
    head = sd_polyline(u, v, head_pts) - s
    # Flat striking face accent
    face = sd_segment(u, v, -0.34, -0.52, -0.34, -0.18) - s
    # Clean union of shaft below head + full head
    shaft_clipped = np.where(v < -0.18, 1.0, shaft)
    return np.minimum.reduce([head, face, shaft_clipped])


def sdf_spellbook(x, y):
    # Lucide open grimoire with crisp symmetrical 4-point concave arcane sparkle (✦) above spine
    # Unified stroke weight with Character / Profession / Talents / Achievement
    s = SW * 0.94
    ax = np.abs(x)
    # Open tome in lower ~70% with spacious top room for the magic sparkle
    outer_v = sd_segment(ax, y, 0.74, -0.22, 0.74, 0.60) - s
    spine_v = sd_segment(ax, y, 0.0, -0.04, 0.0, 0.68) - s
    top_edge = sd_segment(ax, y, 0.28, -0.24, 0.72, -0.24) - s
    top_curve = sd_bezier_quad(ax, y, (0.28, -0.24), (0.04, -0.24), (0.0, -0.03)) - s
    bot_edge = sd_segment(ax, y, 0.28, 0.60, 0.72, 0.60) - s
    bot_curve = sd_bezier_quad(ax, y, (0.28, 0.60), (0.08, 0.60), (0.0, 0.70)) - s
    # Crisp page text accents (two short clean lines on each page, clearly legible at 20px)
    page_l1 = sd_segment(ax, y, 0.24, 0.08, 0.52, 0.08) - (SW * 0.68)
    page_l2 = sd_segment(ax, y, 0.24, 0.34, 0.46, 0.34) - (SW * 0.68)
    # Symmetrical concave 4-point arcane sparkle (✦) above spine (0.0, -0.57) — unmistakably magic!
    sy = y + 0.57
    rx, ry = 0.27, 0.25
    u = np.abs(x) / rx
    v = np.abs(sy) / ry
    # Astroid-like concave 4-point star SDF approximation (exact smooth flare, never looks like a cross)
    p = 0.56
    f = (np.maximum(u, 1e-6) ** p + np.maximum(v, 1e-6) ** p) ** (1.0 / p)
    sparkle = (f - 1.0) * 0.14
    return np.minimum.reduce([
        outer_v, spine_v, top_edge, top_curve, bot_edge, bot_curve,
        page_l1, page_l2, sparkle,
    ])


def sdf_talents(x, y):
    # Lucide symmetrical 3-branch skill/talent tree (root -> 3 upper talent nodes)
    # Instantly distinguishable from SpellBook and matching Lucide stroke weight & proportions
    s = SW * 0.94
    ax = np.abs(x)
    # Node centers & radii
    r_root = 0.175
    r_top = 0.175
    r_side = 0.165
    y_root = 0.54
    y_top = -0.54
    x_side, y_side = 0.54, -0.15

    # Hollow circular talent nodes
    n_root = np.abs(sd_circle(x, y, 0.0, y_root, r_root)) - s
    n_top = np.abs(sd_circle(x, y, 0.0, y_top, r_top)) - s
    n_side = np.abs(sd_circle(ax, y, x_side, y_side, r_side)) - s

    # Central trunk connecting root rim cleanly up to top apex rim
    trunk = sd_segment(x, y, 0.0, y_root - r_root, 0.0, y_top + r_top) - s

    # Smooth symmetrical branches curving from trunk junction (0, 0.18) out to side nodes (0.54, -0.15)
    # Clipped cleanly outside the side node interior so lines meet the ring cleanly!
    branch_raw = sd_bezier_quad(ax, y, (0.0, 0.18), (0.36, 0.18), (x_side, y_side + r_side)) - s
    inside_side = sd_circle(ax, y, x_side, y_side, r_side - 0.01) < 0.0
    branch = np.where(inside_side, 1.0, branch_raw)

    return np.minimum.reduce([n_root, n_top, n_side, trunk, branch])


def sdf_player_spells(x, y):
    # Legacy alias kept in sync with redesigned Talents icon
    return sdf_talents(x, y)


def sdf_gameicon_spellbook(x, y):
    # Matching solid-silhouette GameIcons variant for SpellBook
    ax = np.abs(x)
    # Left/right filled page silhouettes separated by a crisp dark spine gap
    top_y = -0.28 + 0.18 * np.exp(-((ax / 0.22) ** 2))
    bot_y = 0.56 + 0.10 * np.exp(-((ax / 0.22) ** 2))
    d_x = np.maximum(0.055 - ax, ax - 0.74)
    d_y = np.maximum(top_y - y, y - bot_y)
    page_body = np.maximum(d_x, d_y) - 0.02
    # Carve two clean rune bars out of each page for crisp readability
    cut1 = sd_segment(ax, y, 0.24, 0.02, 0.54, 0.02) - 0.042
    cut2 = sd_segment(ax, y, 0.24, 0.26, 0.48, 0.26) - 0.042
    pages = np.maximum(page_body, -np.minimum(cut1, cut2))
    # Solid 4-point arcane star above spine
    sy = y + 0.56
    star_d = (np.abs(x) ** 0.72 + np.abs(sy) ** 0.72) ** (1.0 / 0.72) - 0.22
    return np.minimum(pages, star_d)


def sdf_gameicon_talents(x, y):
    # Matching solid-silhouette GameIcons variant for Talents (filled nodes + bold stems)
    ax = np.abs(x)
    n_root = sd_circle(x, y, 0.0, 0.54, 0.21)
    n_top = sd_circle(x, y, 0.0, -0.54, 0.21)
    n_side = sd_circle(ax, y, 0.54, -0.15, 0.195)
    trunk = sd_segment(x, y, 0.0, 0.48, 0.0, -0.48) - 0.072
    branch = sd_bezier_quad(ax, y, (0.0, 0.18), (0.36, 0.18), (0.54, -0.05)) - 0.068
    return np.minimum.reduce([n_root, n_top, n_side, trunk, branch])


def sdf_achievement(x, y):
    # Lucide trophy: smooth U-cup, rounded side handles, stem & clean flat base
    s = SW * 0.94
    ax = np.abs(x)
    # Top rim
    rim = sd_segment(ax, y, 0.0, -0.66, 0.44, -0.66) - s
    # Vertical cup sides + smooth U bottom
    cup_side = sd_segment(ax, y, 0.44, -0.66, 0.44, -0.14) - s
    cup_bot = sd_arc(ax, y, 0.0, -0.14, 0.44, 0.0, math.pi) - s
    # Side handles (smooth rounded C-ears tucked nicely against cup)
    h_top = sd_segment(ax, y, 0.44, -0.50, 0.62, -0.50) - s
    h_arc = sd_arc(ax, y, 0.62, -0.32, 0.18, -0.5 * math.pi, 0.5 * math.pi) - s
    h_bot = sd_segment(ax, y, 0.44, -0.14, 0.62, -0.14) - s
    # Stem & pedestal base
    stem = sd_segment(ax, y, 0.0, 0.30, 0.0, 0.64) - s
    base = sd_segment(ax, y, 0.0, 0.66, 0.42, 0.66) - s
    return np.minimum.reduce([rim, cup_side, cup_bot, h_top, h_arc, h_bot, stem, base])


def sdf_guild(x, y):
    # Sleek heraldic shield with central chevron crest (for Guild & Community)
    s = SW * 0.95
    ax = np.abs(x)
    top_edge = sd_segment(ax, y, 0.0, -0.68, 0.60, -0.52) - s
    side_v = sd_segment(ax, y, 0.60, -0.52, 0.60, -0.02) - s
    bot_curve = sd_bezier_quad(ax, y, (0.60, -0.02), (0.56, 0.46), (0.0, 0.72)) - s
    # Inner guild emblem chevron
    chev = sd_segment(ax, y, 0.0, -0.14, 0.28, 0.12) - (s * 0.88)
    star_dot = sd_circle(x, y, 0.0, -0.36, 0.09)
    return np.minimum.reduce([top_edge, side_v, bot_curve, chev, star_dot])


def sdf_lfd(x, y):
    # Lucide scan-eye: 4 clean corner brackets + smooth almond eye + centered pupil
    s = SW * 0.94
    ax = np.abs(x)
    ay = np.abs(y)
    # Corner bracket in quadrant (+x, +y): radius 0.22 corner centered at (0.52, 0.52) -> outer edge 0.74
    c_arc = sd_arc(ax, ay, 0.50, 0.50, 0.24, 0.0, 0.5 * math.pi) - s
    c_h = sd_segment(ax, ay, 0.34, 0.74, 0.50, 0.74) - s
    c_v = sd_segment(ax, ay, 0.74, 0.34, 0.74, 0.50) - s
    # Almond eye formed by smooth upper & lower circular arcs meeting at (±0.50, 0)
    # Circle center (0, +0.46), radius R = hypot(0.50, 0.46) = 0.6794 -> apex at y = -0.22
    r_eye = math.hypot(0.50, 0.46)
    ang_span = math.atan2(0.50, 0.46)
    eye_top = sd_arc(x, y, 0.0, 0.46, r_eye, -0.5 * math.pi - ang_span, -0.5 * math.pi + ang_span) - s
    eye_bot = sd_arc(x, y, 0.0, -0.46, r_eye, 0.5 * math.pi - ang_span, 0.5 * math.pi + ang_span) - s
    # Crisp pupil dot
    pupil = sd_circle(x, y, 0.0, 0.0, 0.145)
    return np.minimum.reduce([c_arc, c_h, c_v, eye_top, eye_bot, pupil])


def sdf_collections(x, y):
    # Lucide boxes: 3 stacked isometric cubes (1 top, 2 bottom) with clean spacious geometry
    s = SW * 0.86
    # Isometric cube helper centered at (cx, cy) with radius R
    def iso_cube(cx, cy, R):
        dx = R * 0.8660254
        dy = R * 0.5
        t = (cx, cy - R)
        tr = (cx + dx, cy - dy)
        br = (cx + dx, cy + dy)
        b = (cx, cy + R)
        bl = (cx - dx, cy + dy)
        tl = (cx - dx, cy - dy)
        c = (cx, cy)
        segs = [
            (t, tr), (tr, br), (br, b), (b, bl), (bl, tl), (tl, t),
            (tl, c), (tr, c), (c, b),
        ]
        d = np.full_like(x, 1e6, dtype=np.float32)
        for p, q in segs:
            d = np.minimum(d, sd_segment(x, y, p[0], p[1], q[0], q[1]))
        return d - s

    R = 0.375
    dx = R * 0.8660254
    dy = R * 0.5
    # Stack 3 cubes sharing exact vertices seamlessly (zero overlap muddiness!)
    c_top = iso_cube(0.0, -0.375, R)
    c_bl = iso_cube(-dx, -0.375 + R + dy, R)
    c_br = iso_cube(dx, -0.375 + R + dy, R)
    return np.minimum.reduce([c_top, c_bl, c_br])


def sdf_hearthstone(x, y):
    # Iconic WoW Hearthstone: smooth organic rounded stone + silky mathematical swirl rune
    s = SW * 0.96
    # Smooth closed organic stone contour (slightly narrower top, flatter base)
    ts = np.linspace(0.0, 2.0 * math.pi, 121)
    stone_pts = []
    for a in ts:
        # Rounded egg-pebble silhouette
        ca = math.cos(a)
        sa = math.sin(a)
        rx = 0.65 - 0.10 * max(0.0, -sa) + 0.04 * (sa ** 2)
        ry = 0.72
        px = rx * ca
        py = ry * sa + 0.04 * (ca ** 2)
        # Gentle flat bottom stability
        if py > 0.64:
            py = 0.64 + (py - 0.64) * 0.35
        stone_pts.append((px, py))
    outline = sd_polyline(x, y, stone_pts) - s

    # Silky inner Archimedean spiral (2.15 turns, generous spacing between coils for 20px clarity!)
    sp_pts = []
    n_sp = 160
    t_max = 2.15 * 2.0 * math.pi
    for i in range(n_sp + 1):
        u = i / n_sp
        theta = u * t_max - 0.35 * math.pi
        r = 0.02 + 0.40 * (u ** 0.96)
        sx = r * math.cos(theta)
        sy = r * math.sin(theta) + 0.05
        sp_pts.append((sx, sy))
    spiral = sd_polyline(x, y, sp_pts) - (SW * 0.88)
    return np.minimum(outline, spiral)


def sdf_main_menu(x, y):
    # Precision 6-tooth modern Lucide gear cog (exact closed polyline for uniform stroke width)
    s = SW * 0.94
    n_pts = 180
    th_norm = math.tanh(2.5)
    pts = []
    for i in range(n_pts + 1):
        a = (i / n_pts) * 2.0 * math.pi
        tooth = math.tanh(2.5 * math.cos(6.0 * a)) / th_norm
        r = 0.595 + 0.145 * tooth
        pts.append((r * math.cos(a), r * math.sin(a)))
    outer_ring = sd_polyline(x, y, pts) - s
    inner_ring = np.abs(np.hypot(x, y) - 0.24) - s
    return np.minimum(outer_ring, inner_ring)


LUCIDE_SPECS = [
    ("Character",    sdf_character),
    ("Social",       sdf_social),
    ("Profession",   sdf_profession),
    ("SpellBook",    sdf_spellbook),
    ("Talents",      sdf_talents),
    ("PlayerSpells", sdf_player_spells),
    ("Achievement",  sdf_achievement),
    ("Guild",        sdf_guild),
    ("LFD",          sdf_lfd),
    ("Collections",  sdf_collections),
    ("Hearthstone",  sdf_hearthstone),
    ("MainMenu",     sdf_main_menu),
]

GAMEICON_SPECS = [
    ("SpellBook",    sdf_gameicon_spellbook),
    ("Talents",      sdf_gameicon_talents),
    ("PlayerSpells", sdf_gameicon_talents),
]


# ---------------------------------------------------------------------------
#  Premultiplied-Alpha Mipmap Chain + Edge RGB Dilation + Lossless BGRA BLP2
# ---------------------------------------------------------------------------
def dilate_edge_rgb(rgb: np.ndarray, alpha: np.ndarray, iters: int = 10, thresh: float = 0.015) -> np.ndarray:
    """
    Bleeds edge RGB colors outward into fully transparent pixels (alpha <= thresh)
    so GPU bilinear/trilinear filtering NEVER samples black (0,0,0) or white (1,1,1)
    fringes when magnifying or minifying colored icons!
    """
    out = rgb.copy()
    valid = alpha > thresh
    if not np.any(valid) or np.all(valid):
        return out
    for _ in range(iters):
        if np.all(valid):
            break
        acc = np.zeros_like(out)
        cnt = np.zeros(alpha.shape, dtype=np.float32)
        p_rgb = np.pad(out, ((1, 1), (1, 1), (0, 0)), mode="edge")
        p_val = np.pad(valid.astype(np.float32), ((1, 1), (1, 1)), mode="constant", constant_values=0.0)
        h, w = alpha.shape
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy == 0 and dx == 0:
                    continue
                weight = 1.0 if (dy == 0 or dx == 0) else 0.7071
                nv = p_val[1 + dy : 1 + dy + h, 1 + dx : 1 + dx + w] * weight
                acc += p_rgb[1 + dy : 1 + dy + h, 1 + dx : 1 + dx + w] * nv[:, :, None]
                cnt += nv
        fill = (~valid) & (cnt > 1e-6)
        if not np.any(fill):
            break
        out[fill] = acc[fill] / cnt[fill, None]
        valid = valid | fill
    return out


def build_mipmaps_rgba(master_rgba_f32: np.ndarray, base_size: int, white_bg: bool = True):
    """
    Downsamples float32 straight-alpha RGBA (HxWx4, [0..1]) into a full power-of-2 mip chain
    [base_size, base_size//2, ..., 1] using premultiplied-alpha Lanczos filtering.
    For monochrome white icons (white_bg=True), transparent RGB is kept 1.0;
    for colored icons (white_bg=False), edge RGB is dilated outward on every mip level
    so GPU filtering produces zero white/black fringe halos at any scale!
    """
    pm = np.empty_like(master_rgba_f32)
    pm[:, :, :3] = master_rgba_f32[:, :, :3] * master_rgba_f32[:, :, 3:4]
    pm[:, :, 3] = master_rgba_f32[:, :, 3]

    planes = [Image.fromarray(pm[:, :, c], mode="F") for c in range(4)]

    mips = []
    sz = base_size
    while sz >= 1:
        resized = [p.resize((sz, sz), Image.Resampling.LANCZOS) for p in planes]
        arr = np.stack([np.asarray(r, dtype=np.float32) for r in resized], axis=-1)
        a = np.clip(arr[:, :, 3], 0.0, 1.0)
        safe_a = np.where(a > 1e-4, a, 1.0)
        if white_bg:
            rgb = np.where(a[:, :, None] > 1e-4, np.clip(arr[:, :, :3] / safe_a[:, :, None], 0.0, 1.0), 1.0)
        else:
            rgb = np.where(a[:, :, None] > 1e-4, np.clip(arr[:, :, :3] / safe_a[:, :, None], 0.0, 1.0), 0.0)
            if sz >= 4:
                rgb = dilate_edge_rgb(rgb, a, iters=max(3, min(12, sz // 16)))
        out = np.empty((sz, sz, 4), dtype=np.uint8)
        out[:, :, 0] = np.round(rgb[:, :, 0] * 255.0).astype(np.uint8)
        out[:, :, 1] = np.round(rgb[:, :, 1] * 255.0).astype(np.uint8)
        out[:, :, 2] = np.round(rgb[:, :, 2] * 255.0).astype(np.uint8)
        out[:, :, 3] = np.round(a * 255.0).astype(np.uint8)
        mips.append(out)
        if sz == 1:
            break
        sz //= 2
    return mips


def write_tga_bgra(path: str, rgba_u8: np.ndarray):
    """Writes uncompressed 32-bit BGRA TGA (top-left origin, alphaDepth=8)."""
    h, w, _ = rgba_u8.shape
    header = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28)
    bgra = np.ascontiguousarray(rgba_u8[:, :, [2, 1, 0, 3]])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(header)
        f.write(bgra.tobytes())


def write_blp2_bgra(path: str, mips_rgba: list):
    """Writes WoW-native uncompressed 32-bit BGRA BLP2 (type=1, enc=3, adepth=8, aenc=8, mips=1)."""
    h, w, _ = mips_rgba[0].shape
    mip_blobs = []
    for m in mips_rgba:
        # RGBA -> BGRA (top-down row order verified against Questie & DungeonsForever BLP2)
        bgra = np.ascontiguousarray(m[:, :, [2, 1, 0, 3]])
        mip_blobs.append(bgra.tobytes())

    offsets = [0] * 16
    lengths = [0] * 16
    cur = 148 + 1024  # 148-byte BLP2 header + 1024-byte palette space (universal WoW compatibility)
    for i, blob in enumerate(mip_blobs[:16]):
        offsets[i] = cur
        lengths[i] = len(blob)
        cur += len(blob)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"BLP2")
        f.write(struct.pack("<IBBBBII", 1, 3, 8, 8, 1, w, h))
        f.write(struct.pack("<16I", *offsets))
        f.write(struct.pack("<16I", *lengths))
        f.write(b"\x00" * 1024)
        for blob in mip_blobs[:16]:
            f.write(blob)


def generate_lucide_icons():
    os.makedirs(LUCIDE_OUT, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)

    # Preview contact sheet: shows both 128px HD view + actual 20px tinted dark-bg view!
    n = len(LUCIDE_SPECS)
    sheet = Image.new("RGBA", (n * 140 + 20, 220), (20, 24, 28, 255))
    tint = np.array([171 / 255.0, 212 / 255.0, 115 / 255.0], dtype=np.float32)  # Hunter class green

    for idx, (name, fn) in enumerate(LUCIDE_SPECS):
        master = render_sdf_to_rgba(fn)
        mips = build_mipmaps_rgba(master, OUT_SIZE)
        out_path = os.path.join(LUCIDE_OUT, f"{name}.blp")
        write_blp2_bgra(out_path, mips)

        # Paste 128px tinted preview on top row
        m128 = mips[0].astype(np.float32) / 255.0
        m128[:, :, :3] *= tint
        im128 = Image.fromarray(np.round(m128 * 255).astype(np.uint8), mode="RGBA")
        sheet.alpha_composite(im128, (16 + idx * 140, 14))

        # Paste 24px (mip 32->24) & 20px actual in-game scale previews on bottom row
        m32 = mips[2].astype(np.float32) / 255.0
        m32[:, :, :3] *= tint
        im24 = Image.fromarray(np.round(m32 * 255).astype(np.uint8), mode="RGBA").resize((24, 24), Image.Resampling.LANCZOS)
        sheet.alpha_composite(im24, (16 + idx * 140 + 36, 168))
        im20 = Image.fromarray(np.round(m32 * 255).astype(np.uint8), mode="RGBA").resize((20, 20), Image.Resampling.LANCZOS)
        sheet.alpha_composite(im20, (16 + idx * 140 + 74, 170))
        print(f"Lucide HD BLP2: {name}.blp  ({os.path.getsize(out_path)} bytes, {len(mips)} mips)")

    preview_path = os.path.join(PREVIEW_DIR, "lucide_hd_preview.png")
    sheet.save(preview_path)
    print(f"Saved preview: {preview_path}")

    # Also generate matching solid-silhouette GameIcons for SpellBook & Talents
    os.makedirs(GAMEICONS_OUT, exist_ok=True)
    for name, fn in GAMEICON_SPECS:
        master = render_sdf_to_rgba(fn)
        mips = build_mipmaps_rgba(master, 64)
        out_path = os.path.join(GAMEICONS_OUT, f"{name}.blp")
        write_blp2_bgra(out_path, mips)
        print(f"GameIcons BLP2: {name}.blp  ({os.path.getsize(out_path)} bytes, {len(mips)} mips)")


# ---------------------------------------------------------------------------
#  Analytical SDF Ultra-HD Raid Target Markers (Mark1..Mark8)
#  Rendered at 1024x1024 master -> 256x256 TGAs + 1024x1024 4x4 BLP2 Atlas
# ---------------------------------------------------------------------------
RAID_MASTER = 1024
RAID_CELL = 256
_rc = (np.arange(RAID_MASTER, dtype=np.float32) + 0.5) / RAID_MASTER * 2.0 - 1.0
RX, RY = np.meshgrid(_rc, _rc)


def _smoothstep(e0: float, e1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def _smin(a: np.ndarray, b: np.ndarray, k: float) -> np.ndarray:
    h = np.clip(0.5 + 0.5 * (b - a) / k, 0.0, 1.0)
    return b * (1.0 - h) + a * h - k * h * (1.0 - h)


def _sd_polygon(x: np.ndarray, y: np.ndarray, pts) -> np.ndarray:
    """Exact signed distance to a closed 2D polygon (negative inside, positive outside)."""
    n = len(pts)
    d2 = np.full_like(x, 1e12, dtype=np.float32)
    sign = np.ones_like(x, dtype=np.float32)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        wx, wy = x - ax, y - ay
        denom = ex * ex + ey * ey + 1e-12
        t = np.clip((wx * ex + wy * ey) / denom, 0.0, 1.0)
        qx = wx - ex * t
        qy = wy - ey * t
        d2 = np.minimum(d2, qx * qx + qy * qy)
        # Winding flip test (Inigo Quilez exact polygon SDF)
        c1 = y >= ay
        c2 = y < by
        c3 = ex * wy > ey * wx
        cond = (c1 & c2 & c3) | ((~c1) & (~c2) & (~c3))
        sign = np.where(cond, -sign, sign)
    return sign * np.sqrt(d2)


def _sd_ellipse_approx(x: np.ndarray, y: np.ndarray, cx: float, cy: float, rx: float, ry: float) -> np.ndarray:
    px = (x - cx) / rx
    py = (y - cy) / ry
    k0 = np.hypot(px, py)
    k1 = np.hypot(px / rx, py / ry) + 1e-8
    return k0 * (k0 - 1.0) / k1


def _over(dst_rgb, dst_a, src_rgb, src_a):
    """Straight-alpha Porter-Duff src OVER dst."""
    out_a = src_a + dst_a * (1.0 - src_a)
    safe = np.where(out_a > 1e-6, out_a, 1.0)
    out_rgb = np.where(
        out_a[:, :, None] > 1e-6,
        (src_rgb * src_a[:, :, None] + dst_rgb * (dst_a * (1.0 - src_a))[:, :, None]) / safe[:, :, None],
        0.0,
    )
    return np.clip(out_rgb, 0.0, 1.0), np.clip(out_a, 0.0, 1.0)


def _vgrad(y: np.ndarray, y0: float, y1: float, c_top, c_bot) -> np.ndarray:
    t = np.clip((y - y0) / (y1 - y0), 0.0, 1.0)[:, :, None]
    ct = np.array(c_top, dtype=np.float32) / 255.0
    cb = np.array(c_bot, dtype=np.float32) / 255.0
    return ct * (1.0 - t) + cb * t


def _compose_marker_base(d_shape, d_shadow, fill_rgb, outline_col, outline_w=0.034, aa=0.0045):
    """
    Composes a crisp modern flat-vector marker with:
      1) Soft subtle ambient drop shadow (for 3D world & bright/dark background separation)
      2) Crisp dark outer contour (zero jaggedness, high readability when scaled up/down)
      3) Smooth anti-aliased interior fill
    """
    h, w = d_shape.shape
    rgb = np.zeros((h, w, 3), dtype=np.float32)
    a = np.zeros((h, w), dtype=np.float32)

    # 1) Soft drop shadow (tighter radius so larger ~88% icons never clip at cell edge)
    sh_a = (1.0 - _smoothstep(-0.01, 0.085, d_shadow)) * 0.44
    rgb, a = _over(rgb, a, np.zeros((h, w, 3), dtype=np.float32), sh_a)

    # 2) Outer dark contour
    d_out = d_shape - outline_w
    out_a = 1.0 - _smoothstep(-aa, aa, d_out)
    out_rgb = np.broadcast_to(np.array(outline_col, dtype=np.float32) / 255.0, (h, w, 3))
    rgb, a = _over(rgb, a, out_rgb, out_a)

    # 3) Main fill body
    fill_a = 1.0 - _smoothstep(-aa, aa, d_shape)
    rgb, a = _over(rgb, a, fill_rgb, fill_a)

    # 4) Subtle upper-edge inner specular rim for modern vector polish
    rim = _smoothstep(-0.08, -0.012, d_shape) * (1.0 - _smoothstep(-0.012, 0.005, d_shape))
    top_bias = np.clip((-RY + 0.45) / 1.25, 0.0, 1.0)
    spec_a = rim * top_bias * 0.24 * fill_a
    rgb, a = _over(rgb, a, np.ones((h, w, 3), dtype=np.float32), spec_a)

    return np.concatenate([rgb, a[:, :, None]], axis=-1)


def render_raid_mark1():
    """Mark1 — 星星 (Star): Bold ~88% fill 5-pointed rounded golden star + luminous inner core."""
    pts = []
    ro, ri = 0.855, 0.355
    cy = 0.042
    for i in range(10):
        ang = -math.pi * 0.5 + i * (math.pi / 5.0)
        r = ro if (i % 2 == 0) else ri
        pts.append((r * math.cos(ang), cy + r * math.sin(ang)))
    d = _sd_polygon(RX, RY, pts) - 0.024
    d_sh = _sd_polygon(RX, RY - 0.036, pts) - 0.024
    fill = _vgrad(RY, -0.82, 0.82, (255, 224, 92), (236, 180, 40))
    d_core = sd_circle(RX, RY, 0.0, cy + 0.01, 0.275)
    core_a = (1.0 - _smoothstep(-0.03, 0.045, d_core)) * 0.54
    core_col = np.array([255, 248, 152], dtype=np.float32) / 255.0
    fill = fill * (1.0 - core_a[:, :, None]) + core_col * core_a[:, :, None]
    return _compose_marker_base(d, d_sh, fill, (64, 40, 8), outline_w=0.034)


def render_raid_mark2():
    """Mark2 — 大饼 (Circle): Bold ~87% fill vibrant orange concentric ring + deep espresso inner ring."""
    d = sd_circle(RX, RY, 0.0, 0.0, 0.825)
    d_sh = sd_circle(RX, RY - 0.036, 0.0, 0.0, 0.825)
    fill = _vgrad(RY, -0.82, 0.82, (254, 188, 88), (236, 124, 40))
    r_dist = np.hypot(RX, RY)
    d_ring = np.abs(r_dist - 0.435) - 0.120
    ring_a = 1.0 - _smoothstep(-0.005, 0.005, d_ring)
    ring_col = _vgrad(RY, -0.56, 0.56, (66, 34, 14), (42, 20, 8))
    fill = fill * (1.0 - ring_a[:, :, None]) + ring_col * ring_a[:, :, None]
    d_dot = sd_circle(RX, RY, 0.0, 0.0, 0.312)
    dot_a = (1.0 - _smoothstep(-0.01, 0.01, d_dot)) * 0.15
    fill = np.clip(fill + dot_a[:, :, None] * np.array([0.16, 0.12, 0.05], dtype=np.float32), 0.0, 1.0)
    return _compose_marker_base(d, d_sh, fill, (52, 22, 6), outline_w=0.034)


def render_raid_mark3():
    """Mark3 — 菱形 (Diamond): Bold ~88% amethyst crystal diamond with clean faceted inner highlight."""
    pts = [(0.0, -0.865), (0.725, 0.0), (0.0, 0.865), (-0.725, 0.0)]
    d = _sd_polygon(RX, RY, pts) - 0.025
    d_sh = _sd_polygon(RX, RY - 0.036, pts) - 0.025
    fill = _vgrad(RY, -0.86, 0.86, (214, 140, 254), (162, 78, 232))
    right_facet = _smoothstep(-0.006, 0.006, RX)
    fill = fill * (1.0 - 0.11 * right_facet[:, :, None])
    in_pts = [(0.0, -0.50), (0.405, -0.02), (0.0, 0.46), (-0.405, -0.02)]
    d_in = _sd_polygon(RX, RY, in_pts) - 0.016
    in_a = (1.0 - _smoothstep(-0.006, 0.006, d_in)) * 0.44
    in_col = _vgrad(RY, -0.50, 0.46, (242, 196, 255), (210, 144, 252))
    fill = fill * (1.0 - in_a[:, :, None]) + in_col * in_a[:, :, None]
    return _compose_marker_base(d, d_sh, fill, (48, 16, 80), outline_w=0.034)


def render_raid_mark4():
    """Mark4 — 三角 (Triangle): Bold ~88% emerald inverted triangle + deep forest inner cutout."""
    pts = [(-0.835, -0.635), (0.835, -0.635), (0.0, 0.835)]
    d = _sd_polygon(RX, RY, pts) - 0.028
    d_sh = _sd_polygon(RX, RY - 0.036, pts) - 0.028
    fill = _vgrad(RY, -0.65, 0.85, (100, 244, 154), (42, 198, 108))
    in_pts = [(-0.455, -0.395), (0.455, -0.395), (0.0, 0.395)]
    d_in = _sd_polygon(RX, RY, in_pts) - 0.015
    in_a = 1.0 - _smoothstep(-0.005, 0.005, d_in)
    in_col = _vgrad(RY, -0.40, 0.40, (14, 54, 32), (8, 34, 20))
    fill = fill * (1.0 - in_a[:, :, None]) + in_col * in_a[:, :, None]
    return _compose_marker_base(d, d_sh, fill, (8, 38, 20), outline_w=0.034)


def render_raid_mark5():
    """Mark5 — 月亮 (Moon): Bold ~87% luminous silver-blue crescent moon with clean symmetrical cusps."""
    def moon_sdf(x, y):
        d_outer = sd_circle(x, y, -0.02, 0.02, 0.825)
        d_cut = sd_circle(x, y, 0.34, -0.16, 0.642)
        return -_smin(-d_outer, d_cut, 0.015)

    d = moon_sdf(RX, RY)
    d_sh = moon_sdf(RX, RY - 0.036)
    fill = _vgrad(RY, -0.82, 0.84, (238, 246, 255), (176, 198, 228))
    glow = np.clip(1.0 - np.hypot(RX + 0.40, RY + 0.18) / 0.74, 0.0, 1.0) * 0.18
    fill = np.clip(fill + glow[:, :, None], 0.0, 1.0)
    return _compose_marker_base(d, d_sh, fill, (28, 40, 60), outline_w=0.030)


def render_raid_mark6():
    """Mark6 — 方块 (Square): Bold ~86% optical sky-to-azure rounded square + navy recessed frame."""
    d = sd_round_box(RX, RY, 0.0, 0.0, 0.78, 0.78, 0.175)
    d_sh = sd_round_box(RX, RY - 0.036, 0.0, 0.0, 0.78, 0.78, 0.175)
    fill = _vgrad(RY, -0.78, 0.78, (108, 218, 255), (36, 152, 240))
    d_navy = sd_round_box(RX, RY, 0.0, 0.0, 0.50, 0.50, 0.068)
    navy_a = 1.0 - _smoothstep(-0.005, 0.005, d_navy)
    navy_col = _vgrad(RY, -0.50, 0.50, (20, 56, 92), (14, 38, 66))
    fill = fill * (1.0 - navy_a[:, :, None]) + navy_col * navy_a[:, :, None]
    d_inner = sd_round_box(RX, RY, 0.0, 0.0, 0.305, 0.305, 0.042)
    in_a = 1.0 - _smoothstep(-0.005, 0.005, d_inner)
    in_col = _vgrad(RY, -0.31, 0.31, (106, 214, 255), (48, 168, 244))
    fill = fill * (1.0 - in_a[:, :, None]) + in_col * in_a[:, :, None]
    return _compose_marker_base(d, d_sh, fill, (12, 36, 66), outline_w=0.034)


def render_raid_mark7():
    """Mark7 — 红叉 (Cross): Bold ~86% crimson-coral rounded X + soft center highlight."""
    arm = 0.535
    thick = 0.238
    d1 = sd_segment(RX, RY, -arm, -arm, arm, arm) - thick
    d2 = sd_segment(RX, RY, -arm, arm, arm, -arm) - thick
    d = np.minimum(d1, d2)
    d1s = sd_segment(RX, RY - 0.036, -arm, -arm, arm, arm) - thick
    d2s = sd_segment(RX, RY - 0.036, -arm, arm, arm, -arm) - thick
    d_sh = np.minimum(d1s, d2s)
    fill = _vgrad(RY, -0.78, 0.78, (252, 102, 108), (220, 48, 60))
    d_cen = sd_circle(RX, RY, 0.0, 0.0, 0.16)
    cen_a = (1.0 - _smoothstep(-0.03, 0.07, d_cen)) * 0.25
    fill = fill * (1.0 - cen_a[:, :, None]) + np.array([1.0, 0.72, 0.74], dtype=np.float32) * cen_a[:, :, None]
    return _compose_marker_base(d, d_sh, fill, (64, 10, 18), outline_w=0.034)


def render_raid_mark8():
    """Mark8 — 骷髅 (Skull): Bold ~88% pearl-white modern flat skull with hollow eyes, nose & teeth."""
    def skull_sdf(x, y):
        d_top = _sd_ellipse_approx(x, y, 0.0, -0.17, 0.75, 0.645)
        d_jaw = sd_round_box(x, y, 0.0, 0.41, 0.475, 0.405, 0.13)
        return _smin(d_top, d_jaw, 0.135)

    d = skull_sdf(RX, RY)
    d_sh = skull_sdf(RX, RY - 0.036)
    fill = _vgrad(RY, -0.82, 0.82, (252, 253, 255), (206, 214, 228))

    d_eye_l = _sd_ellipse_approx(RX, RY, -0.29, -0.03, 0.182, 0.192)
    d_eye_r = _sd_ellipse_approx(RX, RY,  0.29, -0.03, 0.182, 0.192)
    d_eyes = np.minimum(d_eye_l, d_eye_r)

    nose_pts = [(0.0, 0.13), (-0.108, 0.35), (0.108, 0.35)]
    d_nose = _sd_polygon(RX, RY, nose_pts) - 0.020

    d_t1 = sd_segment(RX, RY, -0.200, 0.56, -0.200, 0.89) - 0.042
    d_t2 = sd_segment(RX, RY,  0.000, 0.56,  0.000, 0.89) - 0.042
    d_t3 = sd_segment(RX, RY,  0.200, 0.56,  0.200, 0.89) - 0.042
    d_teeth = np.minimum(np.minimum(d_t1, d_t2), d_t3)

    d_features = np.minimum(np.minimum(d_eyes, d_nose), d_teeth)
    feat_a = 1.0 - _smoothstep(-0.005, 0.005, d_features)
    feat_col = np.array([17, 20, 28], dtype=np.float32) / 255.0
    fill = fill * (1.0 - feat_a[:, :, None]) + feat_col * feat_a[:, :, None]

    return _compose_marker_base(d, d_sh, fill, (14, 17, 24), outline_w=0.034)


RAID_MARK_RENDERERS = [
    render_raid_mark1,
    render_raid_mark2,
    render_raid_mark3,
    render_raid_mark4,
    render_raid_mark5,
    render_raid_mark6,
    render_raid_mark7,
    render_raid_mark8,
]


def _downsample_premul(rgba_f32: np.ndarray, out_sz: int) -> np.ndarray:
    """Premultiplied-alpha Lanczos downsample returning straight-alpha float32 (out_sz x out_sz x 4)."""
    pm = np.empty_like(rgba_f32)
    pm[:, :, :3] = rgba_f32[:, :, :3] * rgba_f32[:, :, 3:4]
    pm[:, :, 3] = rgba_f32[:, :, 3]
    planes = [Image.fromarray(pm[:, :, c], mode="F").resize((out_sz, out_sz), Image.Resampling.LANCZOS) for c in range(4)]
    arr = np.stack([np.asarray(p, dtype=np.float32) for p in planes], axis=-1)
    a = np.clip(arr[:, :, 3], 0.0, 1.0)
    sa = np.where(a > 1e-4, a, 1.0)
    rgb = np.where(a[:, :, None] > 1e-4, np.clip(arr[:, :, :3] / sa[:, :, None], 0.0, 1.0), 0.0)
    rgb = dilate_edge_rgb(rgb, a, iters=10)
    return np.concatenate([rgb, a[:, :, None]], axis=-1)


def generate_raid_marker_atlas():
    """
    Renders all 8 Raid Markers analytically at 1024x1024 master ->
      1) 256x256 Mark1.tga .. Mark8.tga (edge-dilated, zero halo/jaggedness)
      2) 1024x1024 4x4 UI-RaidTargetingIcons.blp (256x256 per cell, lossless BGRA BLP2,
         11-level premultiplied Lanczos mip chain with RGB edge dilation on every mip!)
         Row 0: Mark1 (Star), Mark2 (Circle), Mark3 (Diamond), Mark4 (Triangle)
         Row 1: Mark5 (Moon), Mark6 (Square), Mark7 (Cross),   Mark8 (Skull)
         Rows 2-3: Transparent
    """
    os.makedirs(MARK_DIR, exist_ok=True)
    os.makedirs(PREVIEW_DIR, exist_ok=True)

    atlas_master_cell = 512  # Build 2048x2048 master atlas -> 1024x1024 base mip for ultra-crisp Lanczos AA
    atlas_master = np.zeros((atlas_master_cell * 4, atlas_master_cell * 4, 4), dtype=np.float32)
    pad_sz = 488  # ~95.3% inside 512px master cell (12px safety border per side -> 0 mip cell bleed & ~88% icon fill!)
    off = (atlas_master_cell - pad_sz) // 2

    for idx, fn in enumerate(RAID_MARK_RENDERERS, start=1):
        master = fn()  # 1024x1024 float32 straight-alpha RGBA

        # 1) Save 256x256 Mark{idx}.tga (4x4 supersampled + edge-dilated)
        tga_f32 = _downsample_premul(master, RAID_CELL)
        tga_u8 = np.round(np.clip(tga_f32, 0.0, 1.0) * 255.0).astype(np.uint8)
        tga_path = os.path.join(MARK_DIR, f"Mark{idx}.tga")
        write_tga_bgra(tga_path, tga_u8)
        print(f"Raid Marker TGA: Mark{idx}.tga ({RAID_CELL}x{RAID_CELL}, {os.path.getsize(tga_path)} bytes)")

        # 2) Place into 2048x2048 master atlas cell (premultiplied downsample to pad_sz)
        pm = np.empty_like(master)
        pm[:, :, :3] = master[:, :, :3] * master[:, :, 3:4]
        pm[:, :, 3] = master[:, :, 3]
        planes = [Image.fromarray(pm[:, :, c], mode="F").resize((pad_sz, pad_sz), Image.Resampling.LANCZOS) for c in range(4)]
        shrunk = np.stack([np.asarray(p, dtype=np.float32) for p in planes], axis=-1)
        a = np.clip(shrunk[:, :, 3], 0.0, 1.0)
        sa = np.where(a > 1e-4, a, 1.0)
        rgb = np.where(a[:, :, None] > 1e-4, np.clip(shrunk[:, :, :3] / sa[:, :, None], 0.0, 1.0), 0.0)

        cell = np.zeros((atlas_master_cell, atlas_master_cell, 4), dtype=np.float32)
        cell[off : off + pad_sz, off : off + pad_sz, :3] = rgb
        cell[off : off + pad_sz, off : off + pad_sz, 3] = a

        row = (idx - 1) // 4
        col = (idx - 1) % 4
        atlas_master[
            row * atlas_master_cell : (row + 1) * atlas_master_cell,
            col * atlas_master_cell : (col + 1) * atlas_master_cell,
        ] = cell

    # Build full 1024 -> 512 -> ... -> 1 mip chain with colored edge RGB dilation on every level!
    mips = build_mipmaps_rgba(atlas_master, 1024, white_bg=False)

    addon_blp = os.path.join(MARK_DIR, "UI-RaidTargetingIcons.blp")
    write_blp2_bgra(addon_blp, mips)
    print(f"Addon Raid Atlas: {addon_blp} (1024x1024, {os.path.getsize(addon_blp)} bytes, {len(mips)} mips)")

    # Save visual preview of top 2 rows on dark slate bg (plus light bg comparison strip)
    bg = Image.new("RGBA", (1024, 512), (22, 25, 30, 255))
    fg = Image.fromarray(mips[0][:512, :, :], mode="RGBA")
    bg.alpha_composite(fg)
    preview_path = os.path.join(PREVIEW_DIR, "raid_markers_atlas_preview.png")
    bg.save(preview_path)
    print(f"Saved preview: {preview_path}")

    try:
        os.makedirs(WOW_TARGETING_DIR, exist_ok=True)
        client_blp = os.path.join(WOW_TARGETING_DIR, "UI-RaidTargetingIcons.blp")
        write_blp2_bgra(client_blp, mips)
        print(f"Client Raid Override: {client_blp} ({os.path.getsize(client_blp)} bytes)")
    except OSError as exc:
        # 无写权限（PermissionError）或本机没有该游戏目录（FileNotFoundError 等）时只跳过客户端覆盖，不中断生成
        print(f"Note: Skipped client deploy to Interface\\TargetingFrame ({type(exc).__name__}: {exc}).")


if __name__ == "__main__":
    generate_lucide_icons()
    generate_raid_marker_atlas()
