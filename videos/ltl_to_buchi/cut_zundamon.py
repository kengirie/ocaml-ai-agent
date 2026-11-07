"""ずんだもん立ち絵素材（一覧画像）から右側の大きいずんだもんを切り出し、口パク用の差分を作る。

  python cut_zundamon.py 素材画像.webp

灰色の背景（RGB 208 付近）を抜き、隣の絵と接している所は手で引いた切り取り線で分ける。
口は「開き（元の絵）・半開き・閉じ」の 3 枚を作る。出力は config.ASSETS に置く（リポジトリには入れない）。
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as nd

from config import ASSETS

BG = 208
# 隣の絵との切り取り線（元画像 1200x884 の座標）
CUT = [(676, 0), (684, 170), (688, 285), (708, 300), (714, 335), (750, 365), (756, 470), (742, 520),
       (708, 555), (716, 600), (748, 645), (776, 676), (790, 700), (752, 720), (745, 884)]
FACE = (950, 500)            # 大きいずんだもんの内側の点
MOUTH = (872, 286, 936, 349)  # 口の範囲
SKIN = (253, 238, 218, 255)
LINE = (64, 57, 57, 255)


def main(src):
    im = Image.open(src).convert("RGB")
    assert im.size == (1200, 884), im.size
    a = np.array(im).astype(int)
    bg = np.abs(a - BG).max(2) <= 6
    lab, n = nd.label(bg)
    sizes = nd.sum(bg, lab, range(1, n + 1))
    edge = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
    drop = np.concatenate([[False], [(i in edge or s > 150) for i, s in enumerate(sizes, 1)]])
    fg = ~drop[lab]
    cut = Image.new("L", im.size, 0)
    ImageDraw.Draw(cut).line(CUT, fill=255, width=3)
    fl, _ = nd.label(fg & (np.array(cut) == 0))
    m = nd.binary_fill_holes(fl == fl[FACE[1], FACE[0]]) & fg
    alpha = m.astype(float)
    # 画像の右端で切れているしっぽはふわっと消す
    x = np.arange(im.size[0])
    alpha *= np.clip((1195 - x) / 75, 0, 1)[None, :]
    rgba = Image.fromarray(np.dstack([np.array(im), (alpha * 255).astype(np.uint8)]))
    rgba = rgba.crop(rgba.getchannel("A").getbbox())
    ox, oy = Image.fromarray((alpha * 255).astype(np.uint8)).getbbox()[:2]
    mx0, my0, mx1, my1 = MOUTH[0] - ox, MOUTH[1] - oy, MOUTH[2] - ox, MOUTH[3] - oy

    def blank():
        b = rgba.copy()
        ImageDraw.Draw(b).ellipse([mx0 - 2, my0 - 2, mx1 + 1, my1 + 1], fill=SKIN)
        return b

    mouth = rgba.crop((mx0, my0, mx1, my1))
    half = blank()
    half.alpha_composite(mouth.resize((mx1 - mx0, (my1 - my0) * 34 // 63), Image.LANCZOS), (mx0, my0 + 2))
    closed = blank()
    S = 4
    L = Image.new("RGBA", (80 * S, 40 * S))
    pts = [(877, 298), (886, 295), (894, 292), (901, 291), (907, 295), (914, 296), (922, 295), (930, 298)]
    ImageDraw.Draw(L).line([((x - 866) * S, (y - 280) * S) for x, y in pts], fill=LINE, width=4 * S, joint="curve")
    closed.alpha_composite(L.resize((80, 40), Image.LANCZOS), (866 - ox, 280 - oy))

    os.makedirs(ASSETS, exist_ok=True)
    for name, img in (("open", rgba), ("half", half), ("closed", closed)):
        p = os.path.join(ASSETS, f"zunda_{name}.png")
        img.save(p)
        print(p, img.size)


if __name__ == "__main__":
    main(sys.argv[1])
