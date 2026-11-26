# -*- coding: utf-8 -*-
"""Generate kkowoUI brand textures (run from anywhere; writes into Addon/kkowoUI/Media).

  Media/Icons/kkowoUI.tga       128x128 addon-list / minimap logo (TOC IconTexture)
  Media/Textures/SoftGlow.tga    64x64 radial soft glow (white, alpha falloff) for text halos

Both are 32-bit uncompressed TGA, the format the other kkowoUI icons use.
Usage:  python Tools/gen_brand_textures.py [--preview DIR]
"""
import argparse
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Addon", "kkowoUI", "Media")
SS = 4            # supersampling factor for the logo
SIZE = 128


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def vertical_gradient(w, h, top, bottom):
    t = np.linspace(0.0, 1.0, h, dtype=np.float32)[:, None, None]
    top = np.array(top, dtype=np.float32)[None, None, :]
    bottom = np.array(bottom, dtype=np.float32)[None, None, :]
    arr = top + (bottom - top) * t
    arr = np.repeat(arr, w, axis=1)
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA")


def rounded_mask(w, h, r, inset=0):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset, inset, w - 1 - inset, h - 1 - inset), radius=r, fill=255)
    return m


def load_bold_font(px):
    windir = os.environ.get("WINDIR", r"C:\Windows")
    path = os.path.join(windir, "Fonts", "bahnschrift.ttf")
    if os.path.exists(path):
        f = ImageFont.truetype(path, px)
        try:
            f.set_variation_by_name("Bold")
        except Exception:
            pass
        return f
    for name in ("segoeuib.ttf", "arialbd.ttf"):
        p = os.path.join(windir, "Fonts", name)
        if os.path.exists(p):
            return ImageFont.truetype(p, px)
    return ImageFont.load_default()


def sparkle(draw, cx, cy, r, fill):
    # four-point star: long vertical/horizontal points, pinched waist
    w = r * 0.26
    pts = [(cx, cy - r), (cx + w, cy - w), (cx + r, cy), (cx + w, cy + w),
           (cx, cy + r), (cx - w, cy + w), (cx - r, cy), (cx - w, cy - w)]
    draw.polygon(pts, fill=fill)


def make_logo():
    W = SIZE * SS
    pad = int(W * 0.035)
    radius = int(W * 0.23)

    # 1) tile: deep slate gradient with a faint warm glow from the lower left
    tile = vertical_gradient(W, W, (40, 44, 56, 255), (13, 15, 20, 255))
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((-W * 0.25, W * 0.45, W * 0.85, W * 1.35), fill=(220, 167, 127, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.12))
    tile = Image.alpha_composite(tile, glow)

    # glossy top sheen
    sheen = vertical_gradient(W, W // 2, (255, 255, 255, 34), (255, 255, 255, 0))
    sheen_full = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sheen_full.paste(sheen, (0, 0))
    tile = Image.alpha_composite(tile, sheen_full)

    out = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    out.paste(tile, (0, 0), rounded_mask(W, W, radius, pad))

    # 2) hairline gold rim
    rim = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    rd = ImageDraw.Draw(rim)
    rd.rounded_rectangle((pad, pad, W - 1 - pad, W - 1 - pad), radius=radius,
                         outline=(232, 190, 146, 150), width=max(2, int(W * 0.012)))
    out = Image.alpha_composite(out, rim)

    # 3) "K" monogram, champagne-gold gradient, soft drop shadow
    font = load_bold_font(int(W * 0.70))
    glyph = Image.new("L", (W, W), 0)
    gd = ImageDraw.Draw(glyph)
    bbox = gd.textbbox((0, 0), "K", font=font)
    gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    gx = (W - gw) // 2 - bbox[0] - int(W * 0.03)
    gy = (W - gh) // 2 - bbox[1] + int(W * 0.01)
    gd.text((gx, gy), "K", font=font, fill=255)

    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sh_alpha = glyph.filter(ImageFilter.GaussianBlur(W * 0.018)).point(lambda v: int(v * 0.75))
    shadow.putalpha(sh_alpha)
    shadow = shadow.transform((W, W), Image.AFFINE, (1, 0, -W * 0.006, 0, 1, -W * 0.014))
    out = Image.alpha_composite(out, shadow)

    gold = vertical_gradient(W, W, (250, 226, 190, 255), (201, 140, 92, 255))
    gold.putalpha(glyph)
    out = Image.alpha_composite(out, gold)

    # 4) sparkle (the "kkowo" twinkle) upper right
    sp = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sp)
    sparkle(sd, W * 0.765, W * 0.255, W * 0.115, (255, 241, 214, 255))
    sparkle(sd, W * 0.845, W * 0.415, W * 0.045, (255, 228, 190, 210))
    halo = sp.filter(ImageFilter.GaussianBlur(W * 0.02))
    out = Image.alpha_composite(out, halo)
    out = Image.alpha_composite(out, sp)

    return out.resize((SIZE, SIZE), Image.LANCZOS)


def make_soft_glow():
    # 64x64 white radial falloff (gaussian), alpha only: tinted + ADD-blended behind text/bars
    n = 64
    y, x = np.mgrid[0:n, 0:n].astype(np.float32)
    c = (n - 1) / 2.0
    r2 = ((x - c) / c) ** 2 + ((y - c) / c) ** 2
    a = np.exp(-r2 * 3.2)
    a = np.clip((a - np.exp(-3.2)) / (1 - np.exp(-3.2)), 0, 1)   # exactly 0 at the rim
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_pill_mask(radius=3):
    # (2r+1)x(2r+1) nine-sliceable rounded-rect mask (sliced at r texels on all 4 sides)
    n = radius * 2 + 1
    ss = 16
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    # Distance to rounded-rect inner box [r*ss, W - r*ss]
    r_px = radius * ss
    cx = np.clip(x, r_px, W - r_px)
    cy = np.clip(y, r_px, W - r_px)
    dist = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    # Smooth SDF coverage inside radius r_px
    cov = np.clip(r_px - dist + 0.5, 0.0, 1.0)
    alpha = cov.reshape(n, ss, n, ss).mean(axis=(1, 3))
    rgba = np.zeros((n, n, 4), dtype=np.uint8)
    rgba[..., 0:3] = 255
    rgba[..., 3] = np.clip(np.round(alpha * 255), 0, 255).astype(np.uint8)
    return Image.fromarray(rgba, "RGBA")


def make_pill_rim(radius=3):
    # (2r+1)x(2r+1) nine-sliceable 1px rounded hairline rim (sliced at r texels on all 4 sides)
    n = radius * 2 + 1
    ss = 16
    W = n * ss
    y, x = np.mgrid[0:W, 0:W].astype(np.float32) + 0.5
    r_px = radius * ss
    cx = np.clip(x, r_px, W - r_px)
    cy = np.clip(y, r_px, W - r_px)
    dist = np.sqrt((x - cx) ** 2 + (y - cy) ** 2)
    outer = np.clip(r_px - dist + 0.5, 0.0, 1.0)
    # Inner cutout inset by 1 texel (= ss subpixels)
    r_in = max(0.0, (radius - 1) * ss)
    cx2 = np.clip(x, r_px, W - r_px)
    cy2 = np.clip(y, r_px, W - r_px)
    dist2 = np.sqrt((x - cx2) ** 2 + (y - cy2) ** 2)
    inner = np.clip(r_in - dist2 + 0.5, 0.0, 1.0)
    cov = np.clip(outer - inner, 0.0, 1.0)
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
    if args.preview:
        os.makedirs(args.preview, exist_ok=True)
        big = logo.resize((384, 384), Image.LANCZOS)
        bg = Image.new("RGBA", (384 * 2 + 48, 400), (24, 24, 28, 255))
        bg.paste(big, (8, 8), big)
        for i, s in enumerate((16, 20, 32, 64)):
            small = logo.resize((s, s), Image.LANCZOS)
            bg.paste(small, (420 + i * 80, 160), small)
        bg.save(os.path.join(args.preview, "logo_preview.png"))


if __name__ == "__main__":
    main()
