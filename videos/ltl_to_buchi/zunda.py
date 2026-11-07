"""ずんだもん解説版：左下に立ち絵を置き、話している間は小さく弾ませる。"""
import math
import os
from functools import lru_cache

from PIL import Image

from config import ASSETS, CHAR_BOX, PAD_PRE, ZUNDA_POSES
from gfx import ease_out, paste

CHAR_H = 640      # 立ち絵の高さ（足元は Shorts の UI の下に隠れてよい）
CHAR_W = 300      # 幅の上限（ポーズで横に広い絵は小さくなる）
CHAR_X = 30       # 左端
CHAR_TOP = 1170   # 頭のてっぺん


@lru_cache(None)
def pose_img(pid):
    im = Image.open(os.path.join(ASSETS, f"zunmon{pid}.png")).convert("RGBA")
    im = im.crop(im.getchannel("A").getbbox())
    s = min(CHAR_H / im.size[1], CHAR_W / im.size[0])
    return im.resize((int(im.size[0] * s), int(im.size[1] * s)), Image.LANCZOS)


class Zundamon:
    deco = True

    def __init__(self, scene_id, cues, phrases, first_scene=False):
        self.poses = [(cues[k], pid) for k, pid in ZUNDA_POSES[scene_id]]
        self.talk = [(PAD_PRE + a, PAD_PRE + b) for a, b, _ in phrases]
        self.first = first_scene
        self.bbox = CHAR_BOX
        self.t = 0.0

    def visible(self, t):
        return True

    def events(self):
        return []

    def _talking(self, t):
        return any(a <= t <= b for a, b in self.talk)

    def draw(self, frame, t):
        # 現在の立ち絵と、直前の立ち絵からのクロスフェード
        cur, prev, tc = self.poses[0][1], None, -1
        for (tp, pid) in self.poses:
            if t >= tp:
                if pid != cur:
                    prev, cur = cur, pid
                tc = tp
        bob = 0.0
        if self._talking(t):
            bob = -10 * abs(math.sin(math.pi * 3.2 * t))
        breathe = 2 * math.sin(2 * math.pi * 0.5 * t)
        im = pose_img(cur)
        y = CHAR_TOP + (CHAR_H - im.size[1]) * 0.35 + bob + breathe
        a = 1.0
        if self.first:  # 最初のシーンは下から登場
            k = ease_out(t / 0.6)
            y += (1 - k) * 220
            a = k
        k = ease_out((t - tc) / 0.25) if prev and t - tc < 0.25 else 1.0
        if prev and k < 1:
            pi = pose_img(prev)
            paste(frame, pi, CHAR_X, y, a * (1 - k))
        if prev and k < 1:  # 切り替え時に少し跳ねる
            y -= 24 * math.sin(math.pi * k)
        paste(frame, im, CHAR_X, y, a * k)
