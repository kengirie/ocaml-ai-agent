"""BGM（ローファイ調）・効果音をプログラムで作り、ナレーションと混ぜて -14 LUFS に整える。"""
import json
import os
import subprocess
import wave

import numpy as np
from scipy.signal import butter, sosfilt

from config import BUILD, FPS, PAD_PRE, SR

DUCK_DB = -8.0
rng = np.random.default_rng(7)


def lp(x, f, order=2):
    return sosfilt(butter(order, f, "low", fs=SR, output="sos"), x)


def hp(x, f, order=2):
    return sosfilt(butter(order, f, "high", fs=SR, output="sos"), x)


def bp(x, lo, hi, order=2):
    return sosfilt(butter(order, [lo, hi], "band", fs=SR, output="sos"), x)


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def tt(d):
    return np.arange(int(d * SR)) / SR


def add(buf, x, t):
    i = int(round(t * SR))
    if i < 0:
        x, i = x[-i:], 0
    if i >= len(buf):
        return
    n = min(len(x), len(buf) - i)
    buf[i:i + n] += x[:n]


# ---------------------------------------------------------------- BGM
def epiano(freq, d):
    t = tt(d)
    env = np.exp(-t * 1.6) * np.minimum(1, t / 0.012)
    trem = 1 + 0.12 * np.sin(2 * np.pi * 4.2 * t)
    x = (np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(2 * np.pi * 2 * freq * t) * np.exp(-t * 3)
         + 0.08 * np.sin(2 * np.pi * 3 * freq * t) * np.exp(-t * 6))
    return x * env * trem


def bgm(total):
    bpm = 74
    beat = 60 / bpm
    bar = beat * 4
    chords = [[53, 57, 60, 64], [52, 55, 59, 62], [50, 53, 57, 60], [48, 52, 55, 59]]  # Fmaj7 Em7 Dm7 Cmaj7
    L = int((total + 1) * SR)
    keys, bass, drums = np.zeros(L), np.zeros(L), np.zeros(L)
    swing = beat * 0.5 * 1.16
    nbar = int(total / bar) + 2
    for b in range(nbar):
        t0 = b * bar
        ch = chords[b % 4]
        for k, n in enumerate(ch):  # 少しずらして弾く
            add(keys, epiano(midi(n), bar * 1.15) * 0.22, t0 + k * 0.018)
        # 薄い持続音（パッド）：小節をまたいで重ね、音が途切れないようにする
        t = tt(bar * 1.3)
        env = np.minimum(1, t / 0.6) * np.minimum(1, np.maximum(0, (bar * 1.3 - t) / 0.6))
        pad = sum(np.sin(2 * np.pi * midi(n) * t + 0.3 * np.sin(2 * np.pi * 0.7 * t)) for n in ch)
        add(keys, pad * env * 0.035, t0 - 0.15 * bar)
        for k, n in enumerate(ch[1:]):
            add(keys, epiano(midi(n + 12), beat * 1.3) * 0.07, t0 + 2 * beat + swing - beat * 0.5 + k * 0.02)
        # ベース
        for bt, n in ((0, ch[0] - 12), (2.5, ch[0] - 12 + 7)):
            t = tt(beat * 1.4)
            x = np.tanh(1.6 * np.sin(2 * np.pi * midi(n) * t)) * np.exp(-t * 2.2) * np.minimum(1, t / 0.01)
            add(bass, x * 0.32, t0 + bt * beat)
        # ドラム：キック 1・3 拍目（3 拍目の裏に小さく）、スネア 2・4、ハイハット 8 分（スイング）
        for off, amp in ((0, 0.55), (2 * beat, 0.55), (2 * beat + swing, 0.3)):
            t = tt(0.35)
            f = 50 + 70 * np.exp(-t * 30)
            x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)
            add(drums, x * amp, t0 + off)
        for bt in (1, 3):
            t = tt(0.25)
            nz = bp(rng.standard_normal(len(t)), 900, 5000) * np.exp(-t * 18)
            body = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25)
            add(drums, (nz * 0.22 + body * 0.18), t0 + bt * beat)
        for k in range(8):
            t = tt(0.06)
            nz = hp(rng.standard_normal(len(t)), 7000) * np.exp(-t * 70)
            off = (k // 2) * beat + (swing if k % 2 else 0)
            add(drums, nz * (0.07 if k % 2 else 0.1), t0 + off)
    mix = keys + bass + lp(drums, 6000)
    mix = lp(mix, 3200)  # こもらせてローファイ感
    # レコードのノイズ
    hiss = lp(hp(rng.standard_normal(L), 2000), 6000) * 0.006
    crackle = np.zeros(L)
    idx = rng.integers(0, L, int(total * 6))
    crackle[idx] = rng.uniform(-0.25, 0.25, len(idx))
    crackle = bp(crackle, 1500, 7000)
    mix = mix + hiss + crackle
    # ゆっくり揺らす（ワウ風）
    t = np.arange(L) / SR
    mix *= 1 + 0.04 * np.sin(2 * np.pi * 0.23 * t)
    mix = mix[: int(total * SR)]
    fade = np.ones(len(mix))
    fi, fo = int(1.2 * SR), int(2.0 * SR)
    fade[:fi] = np.linspace(0, 1, fi)
    fade[-fo:] = np.linspace(1, 0, fo)
    mix *= fade
    # ステレオ化（左右で少し遅らせる）
    d = int(0.012 * SR)
    left = mix
    right = np.concatenate([np.zeros(d), mix[:-d]])
    st = np.stack([left, right], 1)
    rms = np.sqrt(np.mean(st[int(2 * SR):int(-3 * SR)] ** 2))
    return st * (10 ** (-24 / 20) / rms)


# ---------------------------------------------------------------- 効果音
def sfx(kind):
    if kind == "tick":  # 文字が出るとき（小さく）
        t = tt(0.07)
        x = np.sin(2 * np.pi * 1750 * t) * np.exp(-t * 70) + 0.4 * np.sin(2 * np.pi * 2630 * t) * np.exp(-t * 90)
        return x * 0.10
    if kind == "pon":  # 強調（ポン）
        t = tt(0.35)
        f = 620 + 380 * np.exp(-t * 40)
        x = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 11) * np.minimum(1, t / 0.003)
        x += 0.25 * np.sin(2 * np.pi * 2 * np.cumsum(f) / SR) * np.exp(-t * 20)
        return x * 0.34
    if kind == "kiran":  # 受理状態（キラン）
        t = tt(1.1)
        x = np.zeros(len(t))
        for k, (f, a) in enumerate(((2093, 1.0), (3136, 0.8), (4186, 0.6), (5274, 0.4))):
            tk = np.maximum(0, t - k * 0.045)
            x += a * np.sin(2 * np.pi * f * tk) * np.exp(-tk * 4.5) * (t >= k * 0.045)
        sh = hp(rng.standard_normal(len(t)), 8000) * np.exp(-t * 7) * 0.25
        return (x + sh) * 0.13
    if kind == "boo":  # 不受理（低いブー）
        t = tt(0.6)
        f = 125 - 25 * t
        ph = np.cumsum(f) / SR
        saw = 2 * (ph % 1) - 1
        saw2 = 2 * ((ph * 1.012) % 1) - 1
        env = np.minimum(1, t / 0.02) * np.clip((0.6 - t) / 0.12, 0, 1)
        return lp(saw + saw2, 700) * env * 0.30
    raise ValueError(kind)


def read_wav(p):
    with wave.open(p) as w:
        assert w.getframerate() == SR
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float64) / 32768
        if w.getnchannels() == 2:
            x = x.reshape(-1, 2).mean(1)
    return x


def write_wav(p, x):
    x = np.clip(x, -1, 1)
    if x.ndim == 1:
        x = x[:, None]
    with wave.open(p, "wb") as w:
        w.setnchannels(x.shape[1])
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())


def main():
    with open(os.path.join(BUILD, "sfx.json")) as f:
        info = json.load(f)
    plan, total_frames = info["plan"], info["total_frames"]
    total = total_frames / FPS
    N = int(round(total * SR))
    voice = np.zeros(N)
    duck = np.zeros(N)
    voice_spans = []
    for sp in plan:
        st = sp["start_frame"] / FPS
        v = read_wav(os.path.join(BUILD, "voice", f"scene{sp['id']}.wav"))
        pk = np.abs(v).max()
        v = v * (10 ** (-3 / 20) / pk)  # ピーク -3 dBFS に揃える
        i0 = int(round((st + PAD_PRE) * SR))
        end_scene = int(round((sp["start_frame"] + sp["frames"]) / FPS * SR))
        assert i0 + len(v) <= end_scene, f"scene {sp['id']} の音声がシーンからはみ出しています"
        voice[i0:i0 + len(v)] += v
        duck[i0:i0 + len(v)] = 1
        voice_spans.append([i0 / SR, (i0 + len(v)) / SR])
    # ダッキング：ナレーション中は -8 dB（0.15 秒で滑らかに）
    k = int(0.15 * SR)
    kern = np.ones(k) / k
    dsm = np.clip(np.convolve(np.pad(duck, (k, k), mode="edge"), kern, mode="same")[k:-k], 0, 1)
    gain = 10 ** (DUCK_DB * dsm / 20)
    music = bgm(total)[:N]
    if len(music) < N:
        music = np.pad(music, ((0, N - len(music)), (0, 0)))
    music *= gain[:, None]
    fx = np.zeros(N)
    last = {}
    for (t, kind, g) in info["events"]:
        if kind == "tick" and t - last.get("tick", -1) < 0.08:
            continue  # 同時に出る文字は 1 回だけ鳴らす
        last[kind] = t
        add(fx, sfx(kind) * g, t)
    mix = music + (voice + fx)[:, None]
    pre = os.path.join(BUILD, "mix_pre.wav")
    write_wav(pre, mix * 0.5)
    # ラウドネス -14 LUFS（2 パス）
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", pre, "-af",
                        "loudnorm=I=-14:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                       capture_output=True, text=True)
    js = json.loads(r.stderr[r.stderr.rindex("{"):r.stderr.rindex("}") + 1])
    af = ("loudnorm=I=-14:TP=-1.5:LRA=11:linear=true:measured_I={input_i}:measured_TP={input_tp}:"
          "measured_LRA={input_lra}:measured_thresh={input_thresh}:offset={target_offset}").format(**js)
    out = os.path.join(BUILD, "mix.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", pre, "-af", af, "-ar", str(SR), out], check=True)
    with open(os.path.join(BUILD, "voice_spans.json"), "w") as f:
        json.dump(voice_spans, f)
    print("mix:", out, "measured input I =", js["input_i"])


if __name__ == "__main__":
    main()
