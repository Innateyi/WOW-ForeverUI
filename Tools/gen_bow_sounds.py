#!/usr/bin/env python3
"""
KkowoUI — 猎人弓箭技能音效合成器（物理建模弦鸣 + 弓臂共振 + 箭羽破风）
生成 6 枚无损 16-bit PCM 32kHz WAV 音效至 Addon/KkowoUI/Media/SpellSounds/：
  - bow_autoshot.wav  : 轻弓弦鸣（自动射击）
  - bow_arcane.wav    : 奥术光箭（奥术射击）
  - bow_multishot.wav : 三连散射（多重射击）
  - bow_aimed.wav     : 重战弓破甲（瞄准射击）
  - bow_volley.wav    : 箭雨齐射（乱射，6 秒引导）
  - bow_sniper.wav    : 猎龙长弓（狙击射击）
"""
import os
import wave
import numpy as np
from scipy import signal

SR = 32000
OUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Addon", "KkowoUI", "Media", "SpellSounds",
)


def make_time(dur: float) -> np.ndarray:
    return np.arange(int(dur * SR), dtype=np.float64) / SR


def biquad_bandpass(x: np.ndarray, f_lo: float, f_hi: float, order: int = 2) -> np.ndarray:
    nyq = SR * 0.5
    lo = max(20.0, min(f_lo, nyq - 200.0)) / nyq
    hi = max(lo * nyq + 40.0, min(f_hi, nyq - 50.0)) / nyq
    sos = signal.butter(order, [lo, hi], btype="bandpass", output="sos")
    return signal.sosfilt(sos, x)


def biquad_lowpass(x: np.ndarray, cutoff: float, order: int = 2) -> np.ndarray:
    nyq = SR * 0.5
    sos = signal.butter(order, min(cutoff, nyq - 50.0) / nyq, btype="lowpass", output="sos")
    return signal.sosfilt(sos, x)


def biquad_highpass(x: np.ndarray, cutoff: float, order: int = 2) -> np.ndarray:
    nyq = SR * 0.5
    sos = signal.butter(order, max(20.0, cutoff) / nyq, btype="highpass", output="sos")
    return signal.sosfilt(sos, x)


def bow_string_twang(
    dur: float,
    f_start: float,
    f_end: float,
    decay: float,
    brightness: float = 1.0,
    seed: int = 42,
) -> np.ndarray:
    """物理建模弓弦释放：张力回落滑音 + 丰富阻尼泛音 + 轻度非线性弦击"""
    t = make_time(dur)
    # 弓弦张力在 25ms 内急剧回落至基频
    freq = f_end + (f_start - f_end) * np.exp(-t / 0.022)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR

    out = np.zeros_like(t)
    # 真实弓弦具有轻微非谐波刚度（stiffness），高次泛音衰减更快
    harmonics = [
        (1.00, 1.00, 1.00),
        (2.01, 0.62 * brightness, 0.72),
        (3.03, 0.42 * brightness, 0.52),
        (4.06, 0.25 * brightness, 0.36),
        (5.12, 0.16 * brightness, 0.26),
        (6.20, 0.10 * brightness, 0.19),
        (7.35, 0.06 * brightness, 0.14),
    ]
    for mult, amp, dscale in harmonics:
        env = np.exp(-t / (decay * dscale))
        out += amp * env * np.sin(phase * mult)

    # 护指离弦瞬间微弹瞬态（3-7ms 噪点塑形）
    rng = np.random.default_rng(seed)
    snap_noise = rng.standard_normal(len(t))
    snap = biquad_bandpass(snap_noise, 900.0, 4800.0, order=2) * np.exp(-t / 0.008)
    out += 0.55 * brightness * snap

    # 平滑 1.5ms 起音避免爆音
    attack = np.minimum(1.0, t / 0.0018)
    return out * attack


def wood_riser_thump(dur: float, f0: float = 165.0, f1: float = 72.0, decay: float = 0.045) -> np.ndarray:
    """硬木/复合弓臂回弹低频闷响"""
    t = make_time(dur)
    freq = f1 + (f0 - f1) * np.exp(-t / 0.015)
    phase = 2.0 * np.pi * np.cumsum(freq) / SR
    env = np.exp(-t / decay) * np.minimum(1.0, t / 0.002)
    body = np.sin(phase) + 0.35 * np.sin(2.0 * phase) * np.exp(-t / (decay * 0.5))
    return body * env


def arrow_whoosh(
    dur: float,
    delay: float,
    whoosh_len: float,
    f_start: float,
    f_end: float,
    q_narrow: float = 0.35,
    whistle_gain: float = 0.0,
    seed: int = 100,
) -> np.ndarray:
    """箭羽破风多普勒扫频：分段重叠动态带通滤波噪声 + 可选鸣镝啸声"""
    t = make_time(dur)
    out = np.zeros_like(t)
    i0 = int(delay * SR)
    n = min(int(whoosh_len * SR), len(t) - i0)
    if n <= 32:
        return out

    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(n)

    # 用 8 段平滑重叠带通切片近似连续时变共振峰扫频
    slices = 8
    lt = np.arange(n, dtype=np.float64) / SR
    u = lt / max(whoosh_len, 1e-4)
    # 羽箭离弦疾风包络：快速冲起、自然拉尾
    master_env = np.sin(np.pi * np.power(u, 0.58)) ** 1.35

    swept = np.zeros(n, dtype=np.float64)
    for s in range(slices):
        c = s / (slices - 1)
        fc = f_start * ((f_end / f_start) ** c)
        bw = fc * q_narrow
        band = biquad_bandpass(noise, max(120.0, fc - bw), min(SR * 0.46, fc + bw), order=2)
        w = np.exp(-0.5 * ((u - c) / (1.15 / slices)) ** 2)
        swept += band * w

    # 归一化扫频噪声幅度
    rms = np.sqrt(np.mean(swept ** 2)) + 1e-9
    swept = (swept / rms) * 0.28 * master_env

    # 可选箭头高速破空啸音（重箭/狙击箭专属）
    if whistle_gain > 0.0:
        wf = (f_start * 0.62) * ((f_end / f_start) ** (u ** 0.85))
        wph = 2.0 * np.pi * np.cumsum(wf) / SR
        # 细微空气颤振调制
        flutter = 1.0 + 0.08 * np.sin(2.0 * np.pi * 38.0 * lt)
        swept += whistle_gain * flutter * np.sin(wph) * (master_env ** 1.2)

    out[i0 : i0 + n] += swept
    return out


def simple_outdoor_tail(x: np.ndarray, mix: float = 0.16) -> np.ndarray:
    """极轻开阔野外早期反射（让弓声立体自然不干瘪）"""
    taps = [(0.017, 0.45), (0.031, 0.32), (0.053, 0.22), (0.089, 0.14), (0.137, 0.08)]
    wet = np.zeros_like(x)
    for d_sec, gain in taps:
        d = int(d_sec * SR)
        if d < len(x):
            wet[d:] += x[:-d] * gain
    wet = biquad_lowpass(wet, 3600.0, order=1)
    return x * (1.0 - mix * 0.3) + wet * mix


def finish_and_save(path: str, x: np.ndarray, target_peak: float = 0.86, drive: float = 1.25):
    # 去直流 + 柔饱和增加瞬态力度 + 淡入淡出防爆音
    x = x - np.mean(x)
    x = biquad_highpass(x, 38.0, order=1)
    peak = np.max(np.abs(x)) + 1e-9
    x = x / peak
    x = np.tanh(x * drive) / np.tanh(drive)
    peak2 = np.max(np.abs(x)) + 1e-9
    x = x * (target_peak / peak2)

    fade_in = min(int(0.002 * SR), len(x) // 8)
    fade_out = min(int(0.035 * SR), len(x) // 4)
    if fade_in > 1:
        x[:fade_in] *= np.linspace(0.0, 1.0, fade_in)
    if fade_out > 1:
        x[-fade_out:] *= np.linspace(1.0, 0.0, fade_out)

    pcm = np.clip(np.round(x * 32767.0), -32768, 32767).astype(np.int16)
    with wave.open(path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())
    print(f"Wrote {os.path.basename(path):20s}  {len(pcm)/SR:.2f}s  {os.path.getsize(path):7d} bytes")


def gen_bow_autoshot():
    """自动射击：清脆短促、不吵耳的猎弓弦鸣 + 箭羽破风"""
    dur = 0.68
    twang = bow_string_twang(dur, f_start=235.0, f_end=175.0, decay=0.14, brightness=0.95, seed=11)
    thump = wood_riser_thump(dur, f0=185.0, f1=88.0, decay=0.038)
    whoosh = arrow_whoosh(dur, delay=0.014, whoosh_len=0.28, f_start=3800.0, f_end=1050.0, q_narrow=0.40, whistle_gain=0.03, seed=12)
    mix = 0.68 * twang + 0.45 * thump + 1.05 * whoosh
    return simple_outdoor_tail(mix, mix=0.12)


def gen_bow_arcane():
    """奥术射击：高张力弓弦 + 晶莹奥术星辉泛音 + 能量流尾音"""
    dur = 1.08
    t = make_time(dur)
    twang = bow_string_twang(dur, f_start=310.0, f_end=230.0, decay=0.16, brightness=1.15, seed=21)
    thump = wood_riser_thump(dur, f0=210.0, f1=95.0, decay=0.035)
    whoosh = arrow_whoosh(dur, delay=0.012, whoosh_len=0.45, f_start=5600.0, f_end=1550.0, q_narrow=0.34, whistle_gain=0.07, seed=22)

    # 奥术水晶和弦泛音（E5 / B5 / F#6 / B6，带柔和颤音与微失谐闪烁）
    shimmer = np.zeros_like(t)
    freqs = [(659.25, 0.30, 0.36), (987.77, 0.28, 0.44), (1479.98, 0.22, 0.38), (1975.53, 0.14, 0.32), (2637.02, 0.08, 0.24)]
    for f0, amp, dec in freqs:
        vib = 1.0 + 0.008 * np.sin(2.0 * np.pi * 11.5 * t)
        ph1 = 2.0 * np.pi * np.cumsum(f0 * vib) / SR
        ph2 = 2.0 * np.pi * np.cumsum((f0 * 1.005) * vib) / SR
        env = np.exp(-np.maximum(0.0, t - 0.01) / dec) * np.minimum(1.0, t / 0.015)
        shimmer += amp * env * (0.55 * np.sin(ph1) + 0.45 * np.sin(ph2))

    # 高频星尘粒子扫频
    rng = np.random.default_rng(23)
    sparkle = biquad_bandpass(rng.standard_normal(len(t)), 4200.0, 9500.0, order=2)
    sparkle *= np.exp(-t / 0.26) * (0.5 + 0.5 * np.sin(2.0 * np.pi * 24.0 * t))

    mix = 0.58 * twang + 0.32 * thump + 0.95 * whoosh + 0.65 * shimmer + 0.16 * sparkle
    return simple_outdoor_tail(mix, mix=0.22)


def gen_bow_multishot():
    """多重射击：三箭密集扇形连发 + 交错弦鸣与多层箭羽扫风"""
    dur = 0.92
    n_total = int(dur * SR)
    mix = np.zeros(n_total, dtype=np.float64)

    shots = [
        (0.000, 240.0, 178.0, 4100.0, 1180.0, 1.00, 31),
        (0.046, 275.0, 205.0, 4700.0, 1380.0, 0.92, 32),
        (0.092, 212.0, 158.0, 3400.0,  940.0, 0.95, 33),
    ]
    for delay, fs, fe, ws, we, gain, sd in shots:
        sub_dur = dur - delay
        i0 = int(delay * SR)
        tw = bow_string_twang(sub_dur, f_start=fs, f_end=fe, decay=0.13, brightness=1.05, seed=sd)
        th = wood_riser_thump(sub_dur, f0=fs * 0.85, f1=85.0, decay=0.032)
        wh = arrow_whoosh(sub_dur, delay=0.010, whoosh_len=0.27, f_start=ws, f_end=we, q_narrow=0.38, whistle_gain=0.04, seed=sd + 10)
        seg = gain * (0.62 * tw + 0.38 * th + 1.05 * wh)
        m = min(len(seg), n_total - i0)
        mix[i0 : i0 + m] += seg[:m]

    return simple_outdoor_tail(mix, mix=0.16)


def gen_bow_aimed():
    """瞄准射击：百磅重战弓满弦蓄力释放 + 厚重低频回弹 + 破甲锐啸"""
    dur = 1.28
    t = make_time(dur)
    # 极短 22ms 满弦绷紧木质咯吱起势，立刻爆发
    twang = bow_string_twang(dur, f_start=172.0, f_end=112.0, decay=0.26, brightness=1.18, seed=41)
    thump = wood_riser_thump(dur, f0=145.0, f1=48.0, decay=0.085)
    # 额外低频打击脉冲（重弓厚实感）
    sub_punch = np.sin(2.0 * np.pi * np.cumsum(92.0 * np.exp(-t / 0.045) + 42.0) / SR) * np.exp(-t / 0.095)
    whoosh = arrow_whoosh(dur, delay=0.016, whoosh_len=0.44, f_start=4800.0, f_end=820.0, q_narrow=0.32, whistle_gain=0.11, seed=42)

    # 钢铁破甲箭头震颤瞬态
    rng = np.random.default_rng(43)
    crack = biquad_bandpass(rng.standard_normal(len(t)), 1800.0, 6800.0, order=2) * np.exp(-t / 0.018)

    mix = 0.72 * twang + 0.68 * thump + 0.42 * sub_punch + 1.15 * whoosh + 0.40 * crack
    return simple_outdoor_tail(mix, mix=0.20)


def gen_bow_volley():
    """乱射（6 秒引导）：开场齐射弦响 + 密集漫天箭雨呼啸与落地闷响"""
    dur = 5.95
    n_total = int(dur * SR)
    mix = np.zeros(n_total, dtype=np.float64)
    rng = np.random.default_rng(51)

    # 1) 前 0.35s 连续拉弓齐射释放
    for k in range(5):
        d = k * 0.068
        sdur = min(0.55, dur - d)
        i0 = int(d * SR)
        tw = bow_string_twang(sdur, f_start=200.0 + k * 14, f_end=145.0 + k * 8, decay=0.14, brightness=0.95, seed=60 + k)
        th = wood_riser_thump(sdur, f0=165.0, f1=75.0, decay=0.04)
        seg = 0.42 * tw + 0.28 * th
        mix[i0 : i0 + len(seg)] += seg

    # 2) 44 支错落有致的飞箭破空啸声覆盖 0.08s ~ 5.35s
    num_arrows = 44
    times = np.sort(rng.uniform(0.08, 5.25, size=num_arrows))
    for idx, t0 in enumerate(times):
        wlen = float(rng.uniform(0.24, 0.44))
        if t0 + wlen >= dur - 0.05:
            wlen = max(0.16, dur - 0.06 - t0)
        f_hi = float(rng.uniform(3100.0, 5600.0))
        f_lo = float(rng.uniform(720.0, 1350.0))
        gain = float(rng.uniform(0.45, 0.92))
        whistle = float(rng.uniform(0.02, 0.075))
        wh = arrow_whoosh(wlen + 0.02, delay=0.0, whoosh_len=wlen, f_start=f_hi, f_end=f_lo, q_narrow=0.34, whistle_gain=whistle, seed=200 + idx)
        i0 = int(t0 * SR)
        m = min(len(wh), n_total - i0)
        mix[i0 : i0 + m] += gain * wh[:m]

        # 约 55% 飞箭末端伴随轻微扎地/破风钝响
        if idx % 2 == 0 and (t0 + wlen * 0.85) < dur - 0.15:
            hit_i = int((t0 + wlen * 0.82) * SR)
            th = wood_riser_thump(0.11, f0=float(rng.uniform(135.0, 210.0)), f1=55.0, decay=0.028)
            hm = min(len(th), n_total - hit_i)
            mix[hit_i : hit_i + hm] += 0.22 * gain * th[:hm]

    # 3) 整体箭雨风场底噪（平滑呼吸感，绝不刺耳）
    t = make_time(dur)
    wind = biquad_bandpass(rng.standard_normal(n_total), 650.0, 2600.0, order=2)
    wind_env = np.minimum(1.0, t / 0.25) * np.minimum(1.0, np.maximum(0.0, (dur - t) / 0.45))
    wind_mod = 0.72 + 0.28 * np.sin(2.0 * np.pi * 1.9 * t)
    mix += 0.11 * wind * wind_env * wind_mod

    return simple_outdoor_tail(mix, mix=0.18)


def gen_bow_sniper():
    """狙击射击：超高压猎龙长弓崩弦 + 音爆尖啸 + 远距破空回响"""
    dur = 1.22
    t = make_time(dur)
    twang = bow_string_twang(dur, f_start=290.0, f_end=188.0, decay=0.22, brightness=1.35, seed=71)
    thump = wood_riser_thump(dur, f0=170.0, f1=54.0, decay=0.070)
    whoosh = arrow_whoosh(dur, delay=0.010, whoosh_len=0.38, f_start=6200.0, f_end=1350.0, q_narrow=0.26, whistle_gain=0.15, seed=72)

    # 0.16s 处超高速箭矢远端空气爆裂音（distinct from Aimed Shot）
    rng = np.random.default_rng(73)
    crack_t = np.maximum(0.0, t - 0.145)
    crack_mask = (t >= 0.145).astype(np.float64)
    crack = biquad_bandpass(rng.standard_normal(len(t)), 1200.0, 7200.0, order=2) * np.exp(-crack_t / 0.032) * crack_mask
    # 金属弓弦高音颤鸣
    zing = np.sin(2.0 * np.pi * np.cumsum(1180.0 * np.exp(-t / 0.08) + 920.0) / SR) * np.exp(-t / 0.11)

    mix = 0.68 * twang + 0.56 * thump + 1.15 * whoosh + 0.52 * crack + 0.14 * zing
    return simple_outdoor_tail(mix, mix=0.24)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    finish_and_save(os.path.join(OUT_DIR, "bow_autoshot.wav"), gen_bow_autoshot(), target_peak=0.84, drive=1.20)
    finish_and_save(os.path.join(OUT_DIR, "bow_arcane.wav"),   gen_bow_arcane(),   target_peak=0.84, drive=1.18)
    finish_and_save(os.path.join(OUT_DIR, "bow_multishot.wav"),gen_bow_multishot(),target_peak=0.86, drive=1.24)
    finish_and_save(os.path.join(OUT_DIR, "bow_aimed.wav"),    gen_bow_aimed(),    target_peak=0.88, drive=1.32)
    finish_and_save(os.path.join(OUT_DIR, "bow_volley.wav"),   gen_bow_volley(),   target_peak=0.82, drive=1.20)
    finish_and_save(os.path.join(OUT_DIR, "bow_sniper.wav"),   gen_bow_sniper(),   target_peak=0.88, drive=1.35)
    print("All 6 bow spell sounds generated successfully.")


if __name__ == "__main__":
    main()
