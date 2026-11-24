/**
 * ForeverUI — HD Vector Icon Generator (Pure Node.js, 4x Supersampled SDF -> 128x128 32-bit BGRA TGA)
 * Generates crisp modern dark-slate & tintable luminous flat-vector icons for WoW Forever:
 *   Badge icons (with baked obsidian glass frame):
 *     - Media\Icons\PetHappy.tga       (Emerald happy badge)
 *     - Media\Icons\PetNeutral.tga     (Amber neutral badge)
 *     - Media\Icons\PetMad.tga         (Coral-crimson angry badge)
 *   Tintable flat-vector HUD & button icons (pure luminous white + soft dark drop shadow):
 *     - Media\Icons\VehicleLeave.tga   (Exit doorway + bold disembark arrow)
 *     - Media\Icons\GhostReturn.tga    (Sanctuary arch + glowing soul spark)
 *     - Media\Icons\Trash.tga          (Minimal trash bin)
 *     - Media\Icons\Close.tga          (Rounded geometric cross)
 *     - Media\Icons\RollNeed.tga       (5-pip rounded die)
 *     - Media\Icons\RollGreed.tga      (Coin ring + diamond stamp)
 *     - Media\Icons\RollDisenchant.tga (Arcane crystal shard + sparkles)
 *     - Media\Icons\Check.tga          (Bold optical checkmark)
 *     - Media\Icons\Refresh.tga        (Circular refresh arrow)
 *     - Media\Icons\Copy.tga           (Dual layered document copy)
 *     - Media\Icons\Settings.tga       (6-tooth modern gear)
 *     - Media\Icons\ScrollDown.tga     (Scroll-to-bottom chevron + bar)
 *     - Media\Icons\MoreDots.tga       (Three centered horizontal dots)
 */
const fs = require("fs");
const path = require("path");

const OUT_DIR = path.resolve(__dirname, "..", "Addon", "ForeverUI", "Media", "Icons");
fs.mkdirSync(OUT_DIR, { recursive: true });

const SIZE = 128;
const SS = 4; // 4x4 = 16 samples per output pixel for razor-sharp anti-aliasing

function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

function smoothstep(e0, e1, x) {
    const t = clamp((x - e0) / (e1 - e0), 0, 1);
    return t * t * (3 - 2 * t);
}

// Signed distance to a rounded box centered at (0,0) with half-size (bx,by) and corner radius r
function sdRoundBox(x, y, bx, by, r) {
    const qx = Math.abs(x) - bx + r;
    const qy = Math.abs(y) - by + r;
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

// Signed distance to line segment AB
function sdSegment(px, py, ax, ay, bx, by) {
    const pax = px - ax, pay = py - ay;
    const bax = bx - ax, bay = by - ay;
    const denom = bax * bax + bay * bay;
    const h = denom > 1e-9 ? clamp((pax * bax + pay * bay) / denom, 0, 1) : 0;
    return Math.hypot(pax - bax * h, pay - bay * h);
}

// Signed distance to an open circular arc centered at (cx,cy), radius R,
// spanning angles [a0, a1] (radians, y-down screen coordinates)
function sdArc(px, py, cx, cy, R, a0, a1) {
    const dx = px - cx, dy = py - cy;
    let ang = Math.atan2(dy, dx);
    const mid = 0.5 * (a0 + a1);
    while (ang - mid > Math.PI) ang -= 2 * Math.PI;
    while (ang - mid < -Math.PI) ang += 2 * Math.PI;
    if (ang >= a0 && ang <= a1) {
        return Math.abs(Math.hypot(dx, dy) - R);
    }
    const d0 = Math.hypot(px - (cx + Math.cos(a0) * R), py - (cy + Math.sin(a0) * R));
    const d1 = Math.hypot(px - (cx + Math.cos(a1) * R), py - (cy + Math.sin(a1) * R));
    return Math.min(d0, d1);
}

// Signed distance to a circle centered at (cx, cy) with radius r
function sdCircle(px, py, cx, cy, r) {
    return Math.hypot(px - cx, py - cy) - r;
}

// Signed distance to a convex polygon (vertices ordered CCW or CW)
function sdPolygon(px, py, verts) {
    let d = Infinity;
    let s = 1.0;
    const n = verts.length;
    for (let i = 0, j = n - 1; i < n; j = i, i++) {
        const vx = verts[i][0], vy = verts[i][1];
        const wx = verts[j][0], wy = verts[j][1];
        const ex = wx - vx, ey = wy - vy;
        const pxv = px - vx, pyv = py - vy;
        const denom = ex * ex + ey * ey;
        const t = denom > 1e-9 ? clamp((pxv * ex + pyv * ey) / denom, 0, 1) : 0;
        const bx = pxv - ex * t, by = pyv - ey * t;
        d = Math.min(d, bx * bx + by * by);
        const c1 = py >= vy;
        const c2 = py < wy;
        const c3 = ex * pyv > ey * pxv;
        if ((c1 && c2 && c3) || (!c1 && !c2 && !c3)) {
            s = -s;
        }
    }
    return s * Math.sqrt(d);
}

// Signed distance to a crisp 4-point concave sparkle star centered at (cx, cy)
function sdSparkle4(px, py, cx, cy, rOuter, rInner) {
    const x = Math.abs(px - cx);
    const y = Math.abs(py - cy);
    // Single quadrant diamond-star with concave waist at (rInner, rInner)
    const verts = [
        [0, 0],
        [rOuter, 0],
        [rInner, rInner],
        [0, rOuter],
    ];
    return sdPolygon(x, y, verts);
}

function mixColor(dst, src, a) {
    const alpha = clamp(a, 0, 1);
    return [
        dst[0] * (1 - alpha) + src[0] * alpha,
        dst[1] * (1 - alpha) + src[1] * alpha,
        dst[2] * (1 - alpha) + src[2] * alpha,
    ];
}

function makeTGAHeader() {
    const header = Buffer.alloc(18);
    header[2] = 2; // uncompressed true-color
    header.writeUInt16LE(SIZE, 12);
    header.writeUInt16LE(SIZE, 14);
    header[16] = 32; // 32 bpp
    header[17] = 0x08; // 8-bit alpha, bottom-left origin
    return header;
}

// =========================================================================
//  1) Pet Happiness Badges (Obsidian Slate + Neon Rim + Crisp Vector Face)
// =========================================================================
function renderPetBadge(kind) {
    const palettes = {
        happy: {
            accent: [72, 224, 134],
            glow:   [46, 180, 108],
            face:   [118, 248, 168],
        },
        neutral: {
            accent: [242, 186, 68],
            glow:   [210, 152, 42],
            face:   [255, 214, 102],
        },
        mad: {
            accent: [242, 74, 86],
            glow:   [205, 48, 60],
            face:   [255, 114, 122],
        },
    };
    const P = palettes[kind];
    const header = makeTGAHeader();
    const pixels = Buffer.alloc(SIZE * SIZE * 4);

    for (let py = 0; py < SIZE; py++) {
        const syBase = SIZE - 1 - py;
        for (let px = 0; px < SIZE; px++) {
            let accR = 0, accG = 0, accB = 0, accA = 0;

            for (let oy = 0; oy < SS; oy++) {
                for (let ox = 0; ox < SS; ox++) {
                    const nx = ((px + (ox + 0.5) / SS) / SIZE) * 2 - 1;
                    const ny = ((syBase + (oy + 0.5) / SS) / SIZE) * 2 - 1;

                    const dOuter = sdRoundBox(nx, ny, 0.90, 0.90, 0.24);
                    const badgeAlpha = 1 - smoothstep(-0.018, 0.018, dOuter);
                    if (badgeAlpha <= 0.001) continue;

                    const gradT = clamp((ny + 0.9) / 1.8, 0, 1);
                    let col = [
                        28 * (1 - gradT) + 15 * gradT,
                        33 * (1 - gradT) + 18 * gradT,
                        40 * (1 - gradT) + 23 * gradT,
                    ];

                    const distTop = Math.hypot(nx * 0.85, (ny + 0.55) * 1.15);
                    const aura = Math.max(0, 1 - distTop * 0.95);
                    col = mixColor(col, P.glow, aura * aura * 0.36);

                    const dBorderInner = sdRoundBox(nx, ny, 0.80, 0.80, 0.17);
                    const borderMask = smoothstep(-0.02, 0.015, dBorderInner);
                    const outerRim = smoothstep(-0.045, 0.0, dOuter);
                    col = mixColor(col, P.accent, borderMask * (1 - outerRim * 0.55) * 0.92);

                    const spec = (1 - smoothstep(0.0, 0.06, Math.abs(ny + 0.78))) * (1 - smoothstep(0.55, 0.72, Math.abs(nx)));
                    col = mixColor(col, [255, 255, 255], spec * 0.28);

                    const evalFace = (x, y) => {
                        if (kind === "happy") {
                            return Math.min(
                                sdArc(x, y, -0.28, -0.08, 0.16, -Math.PI * 0.85, -Math.PI * 0.15) - 0.072,
                                sdArc(x, y,  0.28, -0.08, 0.16, -Math.PI * 0.85, -Math.PI * 0.15) - 0.072,
                                sdArc(x, y,  0.0,  0.06, 0.37,  Math.PI * 0.16,  Math.PI * 0.84) - 0.082
                            );
                        } else if (kind === "neutral") {
                            return Math.min(
                                Math.hypot(x + 0.27, y + 0.16) - 0.115,
                                Math.hypot(x - 0.27, y + 0.16) - 0.115,
                                sdSegment(x, y, -0.28, 0.26, 0.28, 0.26) - 0.078
                            );
                        }
                        return Math.min(
                            sdSegment(x, y, -0.44, -0.34, -0.11, -0.14) - 0.068,
                            sdSegment(x, y,  0.44, -0.34,  0.11, -0.14) - 0.068,
                            Math.hypot(x + 0.25, y + 0.05) - 0.085,
                            Math.hypot(x - 0.25, y + 0.05) - 0.085,
                            sdArc(x, y, 0.0, 0.56, 0.34, -Math.PI * 0.78, -Math.PI * 0.22) - 0.076
                        );
                    };

                    const glyphDist = evalFace(nx, ny);
                    const shDist = evalFace(nx, ny - 0.04);
                    col = mixColor(col, [4, 6, 9], (1 - smoothstep(-0.02, 0.09, shDist)) * 0.55);
                    col = mixColor(col, P.accent, (1 - smoothstep(0.0, 0.16, glyphDist)) * 0.25);
                    col = mixColor(col, P.face, 1 - smoothstep(-0.018, 0.018, glyphDist));

                    accR += col[0] * badgeAlpha;
                    accG += col[1] * badgeAlpha;
                    accB += col[2] * badgeAlpha;
                    accA += badgeAlpha;
                }
            }

            const samples = SS * SS;
            const outA = accA / samples;
            const idx = (py * SIZE + px) * 4;
            if (outA > 0.001) {
                pixels[idx + 0] = clamp(Math.round(accB / accA), 0, 255);
                pixels[idx + 1] = clamp(Math.round(accG / accA), 0, 255);
                pixels[idx + 2] = clamp(Math.round(accR / accA), 0, 255);
                pixels[idx + 3] = clamp(Math.round(outA * 255), 0, 255);
            }
        }
    }
    return Buffer.concat([header, pixels]);
}

// =========================================================================
//  2) Tintable Luminous Flat-Vector HUD Icons (Matches MarkBar/SystemBar)
//     Pure white (255 -> 236 gentle top-to-bottom sheen) + soft dark drop shadow
// =========================================================================
const GLYPH_SDFS = {
    // 退出载具 / 提前降落：简洁现代出口门框 + 锐利向右离位箭头
    VehicleLeave(x, y) {
        const sw = 0.084;
        // 左侧开放圆角门框 [
        const dVert  = sdSegment(x, y, -0.58, -0.42, -0.58, 0.42) - sw;
        const dTopH  = sdSegment(x, y, -0.42, -0.58, -0.06, -0.58) - sw;
        const dBotH  = sdSegment(x, y, -0.42,  0.58, -0.06,  0.58) - sw;
        const dArcTL = sdArc(x, y, -0.42, -0.42, 0.16, Math.PI, Math.PI * 1.5) - sw;
        const dArcBL = sdArc(x, y, -0.42,  0.42, 0.16, Math.PI * 0.5, Math.PI) - sw;
        const dDoor  = Math.min(dVert, dTopH, dBotH, dArcTL, dArcBL);

        // 右向离场箭矢（杆 + 几何锐角箭翼）
        const dShaft = sdSegment(x, y, -0.14, 0.0, 0.54, 0.0) - sw;
        const dHeadT = sdSegment(x, y,  0.24, -0.34, 0.60, 0.0) - sw;
        const dHeadB = sdSegment(x, y,  0.24,  0.34, 0.60, 0.0) - sw;
        return Math.min(dDoor, dShaft, dHeadT, dHeadB);
    },

    // 返回墓地：圣殿拱门墓碑轮廓 + 内部空灵灵魂星芒
    GhostReturn(x, y) {
        const sw = 0.072;
        // 顶部拱弧 + 两侧石柱 + 稳重底座
        const dArch   = sdArc(x, y, 0.0, -0.14, 0.44, -Math.PI, 0.0) - sw;
        const dLeft   = sdSegment(x, y, -0.44, -0.14, -0.44, 0.56) - sw;
        const dRight  = sdSegment(x, y,  0.44, -0.14,  0.44, 0.56) - sw;
        const dBase   = sdSegment(x, y, -0.60,  0.56,  0.60, 0.56) - sw;
        // 内部发光灵魂星芒
        const dStar   = sdSparkle4(x, y, 0.0, 0.04, 0.27, 0.085);
        return Math.min(dArch, dLeft, dRight, dBase, dStar);
    },

    // 背包清理销毁：现代极简垃圾桶（顶盖提手 + 梯形桶身 + 两条竖纹）
    Trash(x, y) {
        const sw = 0.074;
        const dLid     = sdSegment(x, y, -0.56, -0.36, 0.56, -0.36) - sw;
        const dHandleT = sdSegment(x, y, -0.18, -0.56, 0.18, -0.56) - 0.066;
        const dHandleL = sdSegment(x, y, -0.22, -0.36, -0.18, -0.56) - 0.066;
        const dHandleR = sdSegment(x, y,  0.22, -0.36,  0.18, -0.56) - 0.066;

        const dWallL = sdSegment(x, y, -0.42, -0.32, -0.33, 0.56) - sw;
        const dWallR = sdSegment(x, y,  0.42, -0.32,  0.33, 0.56) - sw;
        const dBot   = sdSegment(x, y, -0.33,  0.56,  0.33, 0.56) - sw;

        const dSlatL = sdSegment(x, y, -0.14, -0.06, -0.11, 0.34) - 0.056;
        const dSlatR = sdSegment(x, y,  0.14, -0.06,  0.11, 0.34) - 0.056;
        return Math.min(dLid, dHandleT, dHandleL, dHandleR, dWallL, dWallR, dBot, dSlatL, dSlatR);
    },

    // 通用关闭 / 放弃 Roll：圆润几何 ×
    Close(x, y) {
        const sw = 0.098;
        return Math.min(
            sdSegment(x, y, -0.46, -0.46, 0.46, 0.46) - sw,
            sdSegment(x, y, -0.46,  0.46, 0.46, -0.46) - sw
        );
    },

    // Roll 需求：现代圆角五点骰子（实心骰体 + 5 枚通透圆点镂空，小尺寸极高辨识度）
    RollNeed(x, y) {
        const dBox = sdRoundBox(x, y, 0.58, 0.58, 0.17);
        const pipR = 0.105;
        const off = 0.285;
        const dPips = Math.min(
            sdCircle(x, y, 0, 0, pipR),
            sdCircle(x, y, -off, -off, pipR),
            sdCircle(x, y,  off, -off, pipR),
            sdCircle(x, y, -off,  off, pipR),
            sdCircle(x, y,  off,  off, pipR)
        );
        // Boolean subtract pips from die body
        return Math.max(dBox, -dPips);
    },

    // Roll 贪婪：现代镂空金币徽章（厚实外环 + 中央刻面菱星）
    RollGreed(x, y) {
        const dRing = Math.abs(Math.hypot(x, y) - 0.54) - 0.088;
        const dGem = sdPolygon(x, y, [
            [0.0, -0.29],
            [0.24, 0.0],
            [0.0,  0.29],
            [-0.24, 0.0],
        ]) - 0.02;
        return Math.min(dRing, dGem);
    },

    // Roll 分解：奥术水晶棱柱 + 双星芒火花
    RollDisenchant(x, y) {
        // 略微倾斜的水晶主棱柱（-20°）
        const ang = 0.34;
        const ca = Math.cos(ang), sa = Math.sin(ang);
        const rx = x * ca - y * sa + 0.06;
        const ry = x * sa + y * ca - 0.01;
        const dCrystalOuter = sdPolygon(rx, ry, [
            [ 0.00, -0.66],
            [ 0.33, -0.21],
            [ 0.28,  0.36],
            [ 0.00,  0.64],
            [-0.28,  0.36],
            [-0.33, -0.21],
        ]) - 0.02;
        // 内部一条细腻切面反光镂空线，营造立体晶体质感
        const dFacetCut = sdSegment(rx, ry, -0.02, -0.36, 0.08, 0.28) - 0.045;
        const dCrystal = Math.max(dCrystalOuter, -dFacetCut);

        // 右上星芒 + 左下星芒
        const dSpark1 = sdSparkle4(x, y,  0.50, -0.44, 0.26, 0.072);
        const dSpark2 = sdSparkle4(x, y, -0.50,  0.38, 0.20, 0.058);
        return Math.min(dCrystal, dSpark1, dSpark2);
    },

    // 现代复选框勾选 ✓
    Check(x, y) {
        const sw = 0.112;
        return Math.min(
            sdSegment(x, y, -0.46,  0.04, -0.12,  0.38) - sw,
            sdSegment(x, y, -0.12,  0.38,  0.50, -0.36) - sw
        );
    },

    // 世界刷新：顺时针环形刷新箭矢（标准 Lucide rotate-cw 轮廓）
    Refresh(x, y) {
        const sw = 0.086;
        const R = 0.49;
        // 从右下 (+0.24*PI) 经下、左、上顺时针至右上 (+1.76*PI = -0.24*PI)，缺口在右侧
        const aEnd = 1.76 * Math.PI;
        const dArc = sdArc(x, y, 0.0, 0.0, R, 0.24 * Math.PI, aEnd) - sw;
        // 右上端点处的顺时针箭翼（向左与向上伸出，锐利指向右下方缺口）
        const tx = Math.cos(aEnd) * R;
        const ty = Math.sin(aEnd) * R;
        const dHead1 = sdSegment(x, y, tx, ty, tx - 0.30, ty + 0.02) - sw;
        const dHead2 = sdSegment(x, y, tx, ty, tx + 0.02, ty - 0.30) - sw;
        return Math.min(dArc, dHead1, dHead2);
    },

    // 聊天复制：双层卡片文档图标
    Copy(x, y) {
        const sw = 0.072;
        // 前层圆角卡片（右下方）
        const dFrontOuter = sdRoundBox(x - 0.12, y - 0.12, 0.36, 0.42, 0.10);
        const dFront = Math.abs(dFrontOuter) - sw;
        // 后层卡片露出的左/上边
        const dBackL = sdSegment(x, y, -0.48, -0.42, -0.48, 0.18) - sw;
        const dBackT = sdSegment(x, y, -0.38, -0.52,  0.14, -0.52) - sw;
        const dBackC = sdArc(x, y, -0.38, -0.42, 0.10, Math.PI, Math.PI * 1.5) - sw;
        return Math.min(dFront, dBackL, dBackT, dBackC);
    },

    // 聊天设置：6 齿极简现代齿轮
    Settings(x, y) {
        const r = Math.hypot(x, y);
        const ang = Math.atan2(y, x);
        // 齿轮主体环
        const dBody = Math.max(r - 0.44, 0.21 - r);
        // 6 个均匀圆润齿轮齿
        let dTeeth = Infinity;
        for (let i = 0; i < 6; i++) {
            const a = (i * Math.PI) / 3;
            const ca = Math.cos(a), sa = Math.sin(a);
            const dT = sdSegment(x, y, ca * 0.36, sa * 0.36, ca * 0.56, sa * 0.56) - 0.105;
            if (dT < dTeeth) dTeeth = dT;
        }
        // 镂空内孔
        return Math.max(Math.min(dBody, dTeeth), 0.21 - r);
    },

    // 聊天回底：双向下尖括号 + 底线
    ScrollDown(x, y) {
        const sw = 0.082;
        const dC1L = sdSegment(x, y, -0.42, -0.44, 0.0, -0.06) - sw;
        const dC1R = sdSegment(x, y,  0.42, -0.44, 0.0, -0.06) - sw;
        const dC2L = sdSegment(x, y, -0.42, -0.06, 0.0,  0.32) - sw;
        const dC2R = sdSegment(x, y,  0.42, -0.06, 0.0,  0.32) - sw;
        const dBar = sdSegment(x, y, -0.44,  0.54, 0.44,  0.54) - sw;
        return Math.min(dC1L, dC1R, dC2L, dC2R, dBar);
    },

    // 聊天标签溢出：三枚水平居中圆点
    MoreDots(x, y) {
        const r = 0.145;
        return Math.min(
            sdCircle(x, y, -0.46, 0.0, r),
            sdCircle(x, y,  0.00, 0.0, r),
            sdCircle(x, y,  0.46, 0.0, r)
        );
    },

    // 经验条可交任务跳升小箭矢：利落现代右向细箭
    ArrowRight(x, y) {
        const sw = 0.095;
        const dShaft = sdSegment(x, y, -0.56, 0.0, 0.48, 0.0) - sw;
        const dTop   = sdSegment(x, y,  0.14, -0.36, 0.54, 0.0) - sw;
        const dBot   = sdSegment(x, y,  0.14,  0.36, 0.54, 0.0) - sw;
        return Math.min(dShaft, dTop, dBot);
    },
};

function renderTintableGlyph(sdfFn) {
    const header = makeTGAHeader();
    const pixels = Buffer.alloc(SIZE * SIZE * 4);

    for (let py = 0; py < SIZE; py++) {
        const syBase = SIZE - 1 - py;
        for (let px = 0; px < SIZE; px++) {
            let accR = 0, accG = 0, accB = 0, accA = 0;

            for (let oy = 0; oy < SS; oy++) {
                for (let ox = 0; ox < SS; ox++) {
                    const nx = ((px + (ox + 0.5) / SS) / SIZE) * 2 - 1;
                    const ny = ((syBase + (oy + 0.5) / SS) / SIZE) * 2 - 1;

                    const d = sdfFn(nx, ny);
                    const fgA = 1 - smoothstep(-0.016, 0.016, d);

                    // Soft dark drop shadow (stays dark black under WoW SetVertexColor)
                    const dSh = sdfFn(nx, ny - 0.045);
                    const shFalloff = 1 - smoothstep(-0.02, 0.16, dSh);
                    const shA = shFalloff * shFalloff * 0.58;

                    // Subtle top-to-bottom bright specular sheen (255 -> 238)
                    const sheen = 255 - clamp((ny + 0.7) / 1.4, 0, 1) * 17;

                    // Porter-Duff: fg (sheen, fgA) OVER shadow (0, shA)
                    const outA = fgA + shA * (1 - fgA);
                    if (outA > 0.0005) {
                        accR += sheen * fgA;
                        accG += sheen * fgA;
                        accB += sheen * fgA;
                        accA += outA;
                    }
                }
            }

            const samples = SS * SS;
            const alpha = accA / samples;
            const idx = (py * SIZE + px) * 4;
            if (alpha > 0.001) {
                const r = clamp(Math.round(accR / accA), 0, 255);
                const g = clamp(Math.round(accG / accA), 0, 255);
                const b = clamp(Math.round(accB / accA), 0, 255);
                const a = clamp(Math.round(alpha * 255), 0, 255);
                pixels[idx + 0] = b;
                pixels[idx + 1] = g;
                pixels[idx + 2] = r;
                pixels[idx + 3] = a;
            }
        }
    }
    return Buffer.concat([header, pixels]);
}

const PET_TARGETS = [
    ["happy",   "PetHappy.tga"],
    ["neutral", "PetNeutral.tga"],
    ["mad",     "PetMad.tga"],
];

for (const [kind, file] of PET_TARGETS) {
    const outPath = path.join(OUT_DIR, file);
    const buf = renderPetBadge(kind);
    fs.writeFileSync(outPath, buf);
    console.log(`Generated ${outPath} (${buf.length} bytes, ${SIZE}x${SIZE} 32-bit TGA)`);
}

for (const [name, sdfFn] of Object.entries(GLYPH_SDFS)) {
    const outPath = path.join(OUT_DIR, `${name}.tga`);
    const buf = renderTintableGlyph(sdfFn);
    fs.writeFileSync(outPath, buf);
    console.log(`Generated ${outPath} (${buf.length} bytes, ${SIZE}x${SIZE} 32-bit TGA)`);
}
