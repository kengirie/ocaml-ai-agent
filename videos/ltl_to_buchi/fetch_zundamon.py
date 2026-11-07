"""ずんだもん解説版で使う公式立ち絵を、東北ずん子・ずんだもんプロジェクトの公式サイトから取得する。

利用条件: https://zunko.jp/guideline.html （クリエイターの非商用利用は申請不要。
公式イラストページの画像はそのまま使ってよい）。画像はリポジトリには入れず、ここで毎回取得する。
"""
import os
import urllib.request

from config import ASSETS, ZUNDA_POSES

URL = "https://zunko.jp/sozai/zundamon_s/zzm_zunmon{}.png"


def main():
    os.makedirs(ASSETS, exist_ok=True)
    ids = sorted({p for poses in ZUNDA_POSES.values() for _, p in poses})
    for i in ids:
        dst = os.path.join(ASSETS, f"zunmon{i}.png")
        if not os.path.exists(dst):
            urllib.request.urlretrieve(URL.format(i), dst)
        print(dst)


if __name__ == "__main__":
    main()
