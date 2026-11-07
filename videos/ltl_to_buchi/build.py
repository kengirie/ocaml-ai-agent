"""シーン mp4 を連結し、ミックス音声（AAC）と合わせて最終 mp4 を作り、検証する。

全体の流れ:
  python tts.py          # VOICEVOX でナレーション → timing.json
  python render.py stills
  python render.py video # シーンごとの mp4 と効果音イベント
  python audio.py        # BGM・効果音・ナレーションのミックス → mix.wav
  python build.py        # 連結・多重化・検証
"""
import json
import os
import subprocess

import numpy as np

from audio import read_wav
from config import BUILD, FPS, OUT, SR


def probe(path, sel):
    r = subprocess.run(["ffprobe", "-v", "error", "-select_streams", sel, "-count_frames", "-show_entries",
                        "stream=codec_name,width,height,r_frame_rate,duration,nb_read_frames,sample_rate,channels",
                        "-of", "json", path], capture_output=True, text=True, check=True)
    return json.loads(r.stdout)["streams"][0]


def main():
    sc = os.path.join(BUILD, "scenes")
    video = os.path.join(BUILD, "video_concat.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i",
                    os.path.join(sc, "list.txt"), "-c", "copy", video], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", video, "-i", os.path.join(BUILD, "mix.wav"),
                    "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                    "-ar", str(SR), "-movflags", "+faststart", OUT], check=True)
    verify()


def verify():
    with open(os.path.join(BUILD, "sfx.json")) as f:
        info = json.load(f)
    total = info["total_frames"] / FPS
    v = probe(OUT, "v:0")
    a = probe(OUT, "a:0")
    print("映像:", v["codec_name"], f"{v['width']}x{v['height']}", v["r_frame_rate"], "fps,",
          v["nb_read_frames"], "フレーム,", v["duration"], "秒")
    print("音声:", a["codec_name"], a["sample_rate"], "Hz,", a["channels"], "ch,", a["duration"], "秒")
    print("差（音声−映像）:", round(float(a["duration"]) - float(v["duration"]), 3), "秒 / 予定", round(total, 3), "秒")
    # ラウドネス
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", OUT, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True)
    summ = r.stderr[r.stderr.rindex("Summary:"):]
    print("ラウドネス:", " ".join(summ.split()))
    # 途切れ：最終 mp4 の音声をデコードして 50ms ごとの RMS を見る
    dec = os.path.join(BUILD, "final_decoded.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", OUT, "-ac", "1", "-ar", str(SR), dec], check=True)
    x = read_wav(dec)
    win = int(0.05 * SR)
    n = len(x) // win
    rms = np.sqrt(np.mean(x[:n * win].reshape(n, win) ** 2, 1) + 1e-12)
    db = 20 * np.log10(rms)
    inner = db[int(1.5 / 0.05):-int(2.5 / 0.05)]  # BGM のフェードイン・アウト部分は除く
    quiet = np.where(inner < -50)[0]
    print("途切れ（-50 dBFS 未満の 50ms 区間、頭尾のフェード除く）:", len(quiet), "個")
    # ナレーションの重なり
    with open(os.path.join(BUILD, "voice_spans.json")) as f:
        spans = json.load(f)
    over = [(i, spans[i][1], spans[i + 1][0]) for i in range(len(spans) - 1) if spans[i][1] > spans[i + 1][0]]
    gaps = [round(spans[i + 1][0] - spans[i][1], 2) for i in range(len(spans) - 1)]
    print("ナレーション同士の重なり:", over if over else "なし", "/ シーン間のすき間（秒）:", gaps)
    print("出力:", OUT, f"{os.path.getsize(OUT) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
