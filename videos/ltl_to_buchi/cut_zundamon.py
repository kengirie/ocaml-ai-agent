"""ずんだもん立ち絵（背景が透明な全身 PNG）から、口パク用の差分を作る。

  python cut_zundamon.py 立ち絵.png

口は「開き（元の絵）・半開き・閉じ（ω 口）」の 3 枚。出力は config.ASSETS に置く（リポジトリには入れない）。
"""
import os
import sys

from PIL import Image, ImageDraw

from config import ASSETS

SIZE = (1082, 1650)            # 想定している元画像の大きさ
MOUTH = (462, 474, 526, 537)   # 口の範囲
SKIN = (252, 238, 216, 255)
LINE = (64, 57, 57, 255)
CLOSED = [(467, 486), (476, 483), (484, 480), (491, 479), (497, 483), (504, 484), (512, 483), (520, 486)]


def main(src):
    im = Image.open(src).convert("RGBA")
    assert im.size == SIZE, im.size
    mx0, my0, mx1, my1 = MOUTH

    def blank():
        b = im.copy()
        ImageDraw.Draw(b).ellipse([mx0 - 3, my0 - 3, mx1 + 1, my1 - 1], fill=SKIN)
        return b

    mouth = im.crop(MOUTH)
    half = blank()
    half.alpha_composite(mouth.resize((mx1 - mx0, (my1 - my0) * 34 // 63), Image.LANCZOS), (mx0, my0 + 2))
    closed = blank()
    S, ox, oy = 4, mx0 - 10, my0 - 10
    L = Image.new("RGBA", (90 * S, 40 * S))
    ImageDraw.Draw(L).line([((x - ox) * S, (y - oy) * S) for x, y in CLOSED], fill=LINE, width=5 * S, joint="curve")
    closed.alpha_composite(L.resize((90, 40), Image.LANCZOS), (ox, oy))

    box = im.getchannel("A").getbbox()
    os.makedirs(ASSETS, exist_ok=True)
    for name, img in (("open", im), ("half", half), ("closed", closed)):
        p = os.path.join(ASSETS, f"zunda_{name}.png")
        img.crop(box).save(p)
        print(p, img.crop(box).size)


if __name__ == "__main__":
    main(sys.argv[1])
