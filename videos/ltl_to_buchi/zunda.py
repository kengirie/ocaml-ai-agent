"""ずんだもん解説版：左下にずんだもんを置き、ナレーションの音量に合わせて口パクさせる。"""
import math
import os
import wave
from functools import lru_cache

import numpy as np
from PIL import Image

from config import ASSETS, BUILD, CHAR_BOX, FPS, PAD_PRE, SR, ZUNDA_HOPS
from gfx import ease_out, paste

CHAR_W = 340      # 表示幅
CHAR_X = 20       # 左端
CHAR_TOP = 1195   # 頭のてっぺん（体の下のほうは Shorts の UI の下に隠れてよい）
FADE = 110        # 下端をふわっと消す高さ


@lru_cache(None)
def mouth_img(state):
    im = Image.open(os.path.join(ASSETS, f"zunda_{state}.png")).convert("RGBA")
    s = CHAR_W / im.size[0]
    im = im.resize((CHAR_W, int(im.size[1] * s)), Image.LANCZOS)
    a = np.array(im.getchannel("A")).astype(float)
    h = a.shape[0]
    a *= np.clip((h - np.arange(h)) / FADE, 0, 1)[:, None]
    a *= np.clip(np.arange(h) / 14, 0, 1)[:, None]  # 元画像の上端で切れた葉っぱをなじませる
    im.putalpha(Image.fromarray(a.astype(np.uint8)))
    return im


def voice_env(scene_id):
    """ナレーション音声の 1 フレームごとの音量（0〜1）。"""
    with wave.open(os.path.join(BUILD, "voice", f"scene{scene_id}.wav")) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(float) / 32768
    hop = SR // FPS
    n = len(x) // hop
    rms = np.sqrt(np.mean(x[: n * hop].reshape(n, hop) ** 2, 1))
    return rms / (rms.max() + 1e-9)


class Zundamon:
    deco = True

    def __init__(self, scene_id, cues, phrases, first_scene=False):
        self.env = voice_env(scene_id)
        self.hops = [cues[k] for k in ZUNDA_HOPS[scene_id]]
        self.first = first_scene
        self.t = 0.0
        self.bbox = CHAR_BOX

    def visible(self, t):
        return True

    def events(self):
        return []

    def mouth(self, t):
        i = int(round((t - PAD_PRE) * FPS))
        if i < 0 or i >= len(self.env):
            return "closed"
        v = self.env[i]
        return "open" if v > 0.32 else "half" if v > 0.12 else "closed"

    def draw(self, frame, t):
        im = mouth_img(self.mouth(t))
        y = CHAR_TOP + 3 * math.sin(2 * math.pi * 0.45 * t)  # 呼吸
        for th in self.hops:  # ぴょん
            if 0 <= t - th < 0.4:
                y -= 36 * math.sin(math.pi * (t - th) / 0.4)
        a = 1.0
        if self.first:  # 最初のシーンは下から登場
            k = ease_out(t / 0.6)
            y += (1 - k) * 260
            a = k
        paste(frame, im, CHAR_X, y, a)
