#!/usr/bin/env python3
r"""
KkowoUI — Ultra-Smooth Vector Icon & Global Raid Marker Generator
1) Redraws all 10 active SystemBar Lucide icons using mathematical Signed Distance Fields (SDF)
   rendered at 512x512 -> premultiplied-alpha Lanczos mipmap chain (128->64->32->16->8->4->2->1)
   encoded as lossless 32-bit BGRA BLP2 (colorEncoding=3, alphaDepth=8, hasMips=1).
   Zero DXT5 block noise, zero jaggedness at 16-28px in-game!
2) Composites MarkBar's Mark1.tga..Mark8.tga into a 512x512 4x4 sprite sheet
   UI-RaidTargetingIcons.blp (lossless BGRA BLP2 with full mipmaps) and deploys to:
     - Addon/KkowoUI/Media/MarkBar/UI-RaidTargetingIcons.blp
     - E:\Program Files\World of Warcraft\_forever_\Interface\TargetingFrame\UI-RaidTargetingIcons.blp
3) Writes visual inspection contact sheets (PNG) to scratch directory for verification.
"""
import math
import os
import struct
import numpy as np
from PIL import Image

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUCIDE_OUT = os.path.join(REPO_ROOT, "Addon", "KkowoUI", "Media", "SystemBar", "Lucide")
MARK_DIR = os.path.join(REPO_ROOT, "Addon", "KkowoUI", "Media", "MarkBar")
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


def sdf_player_spells(x, y):
    # Lucide book-open: crisp symmetrical open tome with smooth curved top/bottom spines
    s = SW * 0.95
    ax = np.abs(x)
    # Outer vertical edge
    outer_v = sd_segment(ax, y, 0.75, -0.50, 0.75, 0.48) - s
    # Center spine vertical seam
    spine_v = sd_segment(ax, y, 0.0, -0.32, 0.0, 0.56) - s
    # Top page curve (smooth arch from outer edge down into center spine)
    top_edge = sd_segment(ax, y, 0.28, -0.52, 0.73, -0.52) - s
    top_curve = sd_bezier_quad(ax, y, (0.28, -0.52), (0.04, -0.52), (0.0, -0.30)) - s
    # Bottom page curve (smooth arch meeting cleanly at center spine without pointy spike)
    bot_edge = sd_segment(ax, y, 0.28, 0.48, 0.73, 0.48) - s
    bot_curve = sd_bezier_quad(ax, y, (0.28, 0.48), (0.08, 0.48), (0.0, 0.58)) - s
    return np.minimum.reduce([outer_v, spine_v, top_edge, top_curve, bot_edge, bot_curve])


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
    ("PlayerSpells", sdf_player_spells),
    ("Achievement",  sdf_achievement),
    ("Guild",        sdf_guild),
    ("LFD",          sdf_lfd),
    ("Collections",  sdf_collections),
    ("Hearthstone",  sdf_hearthstone),
    ("MainMenu",     sdf_main_menu),
]


# ---------------------------------------------------------------------------
#  Premultiplied-Alpha Mipmap Chain + Lossless BGRA BLP2 Encoder
# ---------------------------------------------------------------------------
def build_mipmaps_rgba(master_rgba_f32: np.ndarray, base_size: int):
    """
    Downsamples float32 straight-alpha RGBA (HxWx4, [0..1]) into a full power-of-2 mip chain
    [base_size, base_size//2, ..., 1] using premultiplied-alpha Lanczos filtering so transparent
    borders NEVER produce dark fringes or jagged edges!
    """
    pm = np.empty_like(master_rgba_f32)
    pm[:, :, :3] = master_rgba_f32[:, :, :3] * master_rgba_f32[:, :, 3:4]
    pm[:, :, 3] = master_rgba_f32[:, :, 3]

    # Convert premultiplied float channels to 4 separate high-precision PIL F-mode planes
    planes = [Image.fromarray(pm[:, :, c], mode="F") for c in range(4)]

    mips = []
    sz = base_size
    while sz >= 1:
        resized = [p.resize((sz, sz), Image.Resampling.LANCZOS) for p in planes]
        arr = np.stack([np.asarray(r, dtype=np.float32) for r in resized], axis=-1)
        a = np.clip(arr[:, :, 3], 0.0, 1.0)
        safe_a = np.where(a > 1e-4, a, 1.0)
        rgb = np.where(a[:, :, None] > 1e-4, np.clip(arr[:, :, :3] / safe_a[:, :, None], 0.0, 1.0), 1.0)
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


def generate_raid_marker_atlas():
    """
    Composites Mark1.tga..Mark8.tga (128x128 each) into Blizzard's 4x4 512x512 layout:
      Row 0: Mark1 (Star), Mark2 (Circle), Mark3 (Diamond), Mark4 (Triangle)
      Row 1: Mark5 (Moon), Mark6 (Square), Mark7 (Cross),   Mark8 (Skull)
      Rows 2-3: Transparent
    Writes both Addon/KkowoUI/Media/MarkBar/UI-RaidTargetingIcons.blp
    and client loose override Interface/TargetingFrame/UI-RaidTargetingIcons.blp
    """
    atlas = np.zeros((512, 512, 4), dtype=np.float32)
    for idx in range(1, 9):
        src = os.path.join(MARK_DIR, f"Mark{idx}.tga")
        im = Image.open(src).convert("RGBA")
        if im.size != (128, 128):
            im = im.resize((128, 128), Image.Resampling.LANCZOS)
        arr = np.asarray(im, dtype=np.float32) / 255.0
        # Slight optical padding (92% inside 128x128 cell) so mipmap bleeding never leaks across grid cells!
        pad_sz = 118
        off = (128 - pad_sz) // 2
        pm = np.empty_like(arr)
        pm[:, :, :3] = arr[:, :, :3] * arr[:, :, 3:4]
        pm[:, :, 3] = arr[:, :, 3]
        planes = [Image.fromarray(pm[:, :, c], mode="F").resize((pad_sz, pad_sz), Image.Resampling.LANCZOS) for c in range(4)]
        shrunk = np.stack([np.asarray(p, dtype=np.float32) for p in planes], axis=-1)
        a = np.clip(shrunk[:, :, 3], 0.0, 1.0)
        sa = np.where(a > 1e-4, a, 1.0)
        rgb = np.where(a[:, :, None] > 1e-4, np.clip(shrunk[:, :, :3] / sa[:, :, None], 0.0, 1.0), 0.0)
        cell = np.zeros((128, 128, 4), dtype=np.float32)
        cell[off : off + pad_sz, off : off + pad_sz, :3] = rgb
        cell[off : off + pad_sz, off : off + pad_sz, 3] = a

        row = (idx - 1) // 4
        col = (idx - 1) % 4
        atlas[row * 128 : (row + 1) * 128, col * 128 : (col + 1) * 128] = cell

    mips = build_mipmaps_rgba(atlas, 512)

    addon_blp = os.path.join(MARK_DIR, "UI-RaidTargetingIcons.blp")
    write_blp2_bgra(addon_blp, mips)
    print(f"Addon Raid Atlas: {addon_blp} ({os.path.getsize(addon_blp)} bytes, {len(mips)} mips)")

    # Save visual preview of top 2 rows on dark slate bg
    bg = Image.new("RGBA", (512, 256), (22, 25, 30, 255))
    fg = Image.fromarray(mips[0][:256, :, :], mode="RGBA")
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
