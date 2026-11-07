"""フレームを描いてシーンごとの mp4 を作る。

  python render.py stills   … 各シーンの終わり近く（情報量最大）の静止画と、はみ出し・重なりの検査
  python render.py video    … 全シーンの mp4（映像のみ）と効果音イベント sfx.json
"""
import json
import math
import os
import subprocess
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image, ImageDraw

from config import BUILD, COL, FPS, H, PAD_POST, PAD_PRE, SAFE_B, SAFE_L, SAFE_R, SAFE_T, SCENES, W, cue_prefixes, plain
from gfx import Txt, in_safe, panel, paste, ss_canvas, ss_done, txt
from scenes import BUILDERS


# ---------------------------------------------------------------- タイミング
def load_timing():
    p = os.path.join(BUILD, "timing.json")
    if os.path.exists(p):
        with open(p) as f:
            tj = json.load(f)
        return {s["id"]: s for s in tj["scenes"]}, False
    # VOICEVOX がまだ無いときの仮タイミング（文字数から推定）
    est = {}
    for sc in SCENES:
        n = len(plain(sc["say"]))
        v = n * 0.125
        cues = [len(p) * 0.125 for p in cue_prefixes(sc["say"])]
        est[sc["id"]] = {"voice": v, "cues": cues}
    return est, True


def scene_plan():
    tm, estimated = load_timing()
    plan, start = [], 0
    for sc in SCENES:
        s = tm[sc["id"]]
        frames = math.ceil((PAD_PRE + s["voice"] + PAD_POST) * FPS)
        plan.append({"id": sc["id"], "chip": sc["chip"], "voice": s["voice"], "frames": frames,
                     "start_frame": start, "cues": [PAD_PRE + c for c in s["cues"]]})
        start += frames
    return plan, start, estimated


# ---------------------------------------------------------------- 共通の背景・進行バー・チップ
_BG = None


def background():
    global _BG
    if _BG is None:
        y = np.linspace(0, 1, H)[:, None, None]
        c0, c1 = np.array(COL["bg0"]), np.array(COL["bg1"])
        g = (c0 * (1 - y) + c1 * y) * np.ones((1, W, 1))
        # うっすら光
        yy, xx = np.mgrid[0:H, 0:W]
        glow = np.exp(-(((xx - 300) / 700) ** 2 + ((yy - 500) / 600) ** 2))[..., None] * np.array([12, 20, 40])
        img = Image.fromarray(np.clip(g + glow, 0, 255).astype(np.uint8)).convert("RGBA")
        d = ImageDraw.Draw(img)
        for x in range(40, W, 60):  # 点の格子
            for yv in range(40, H, 60):
                d.point((x, yv), fill=(60, 80, 125, 255))
        _BG = img
    return _BG


_CHIPS = {}


def chip(label):
    if label not in _CHIPS:
        t = Txt(label, 32)
        w, h = t.w + 36, t.h + 8
        p = panel(w, h, fill="panel", border="c", radius=h / 2, bw=3)
        p.alpha_composite(t.img, (18, 4))
        _CHIPS[label] = p
    return _CHIPS[label]


def progress(frame, gf, total, plan):
    d = ImageDraw.Draw(frame)
    d.rectangle([0, 0, W, 12], fill=(30, 44, 84, 255))
    x = int(W * (gf + 1) / total)
    d.rectangle([0, 0, x, 12], fill=COL["c"] + (255,))
    for s in plan[1:]:
        xs = int(W * s["start_frame"] / total)
        d.rectangle([xs - 1, 0, xs + 1, 12], fill=COL["bg0"] + (255,))


def frame_at(sp, els, f, total, plan):
    t = f / FPS
    fr = background().copy()
    progress(fr, sp["start_frame"] + f, total, plan)
    if sp["chip"]:
        paste(fr, chip(sp["chip"]), SAFE_L, 44)
    for e in els:
        e.draw(fr, t)
    # シーン切り替えのフェード（頭 0.2 秒）
    if t < 0.2 and sp["id"] != 0:
        bg = background().copy()
        fr = Image.blend(bg, fr, t / 0.2)
    return fr


# ---------------------------------------------------------------- 検査
def lint(sp, els, t):
    probs = []
    vis = [e for e in els if e.visible(t)]
    for e in vis:
        if not in_safe(e.bbox):
            probs.append(f"安全領域外: {getattr(e, 'name', type(e).__name__)} bbox={tuple(int(v) for v in e.bbox)}")
    texts = [e for e in vis if not e.deco]
    for i in range(len(texts)):
        for j in range(i + 1, len(texts)):
            a, b = texts[i].bbox, texts[j].bbox
            ox = min(a[2], b[2]) - max(a[0], b[0])
            oy = min(a[3], b[3]) - max(a[1], b[1])
            if ox > 4 and oy > 4:
                probs.append(f"重なり: {tuple(int(v) for v in a)} と {tuple(int(v) for v in b)}")
    return probs


def build(sp):
    dur = sp["frames"] / FPS
    return BUILDERS[sp["id"]](sp["cues"], dur)


def stills(guides=True):
    plan, total, est = scene_plan()
    os.makedirs(os.path.join(BUILD, "stills"), exist_ok=True)
    ok = True
    paths = []
    for sp in plan:
        els = build(sp)
        f = sp["frames"] - int(0.4 * FPS)
        img = frame_at(sp, els, f, total, plan).convert("RGB")
        if guides:  # Shorts の UI 領域を赤く示す（確認用）
            ov = Image.new("RGBA", (W, H))
            d = ImageDraw.Draw(ov)
            d.rectangle([0, SAFE_B, W, H], fill=(255, 0, 0, 50))
            d.rectangle([SAFE_R, 0, W, SAFE_B], fill=(255, 0, 0, 50))
            img = Image.alpha_composite(img.convert("RGBA"), ov).convert("RGB")
        p = os.path.join(BUILD, "stills", f"scene{sp['id']}.png")
        img.save(p)
        paths.append(p)
        probs = lint(sp, els, f / FPS)
        print(f"scene {sp['id']}: {sp['frames'] / FPS:5.2f}s  {'OK' if not probs else ''}")
        for pr in probs:
            ok = False
            print("   ", pr)
    # 一覧（縮小して並べる）
    th = [Image.open(p).resize((270, 480)) for p in paths]
    sheet = Image.new("RGB", (270 * 5 + 40, 480 * 2 + 30), (0, 0, 0))
    for i, t in enumerate(th):
        sheet.paste(t, (5 + (i % 5) * 275, 5 + (i // 5) * 490))
    sheet.save(os.path.join(BUILD, "stills", "contact.png"))
    print("仮タイミング" if est else "VOICEVOX のタイミング", "/ 合計", round(total / FPS, 2), "秒")
    return ok


def render_scene(sp_total):
    sp, total, plan = sp_total
    els = build(sp)
    out = os.path.join(BUILD, "scenes", f"scene{sp['id']}.mp4")
    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
           "-r", str(FPS), "-i", "-", "-c:v", "libx264", "-preset", "medium", "-crf", "18",
           "-pix_fmt", "yuv420p", "-profile:v", "high", "-g", str(FPS * 2), "-r", str(FPS),
           "-video_track_timescale", "15360", out]
    pr = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for f in range(sp["frames"]):
        pr.stdin.write(frame_at(sp, els, f, total, plan).convert("RGB").tobytes())
    pr.stdin.close()
    assert pr.wait() == 0
    ev = []
    for e in els:
        if hasattr(e, "events"):
            for (t, kind, g) in e.events():
                if kind and t < sp["frames"] / FPS:
                    ev.append([round(sp["start_frame"] / FPS + t, 4), kind, g])
    return sp["id"], ev


def video():
    plan, total, est = scene_plan()
    if est:
        print("注意: 仮タイミングで書き出します（timing.json がありません）")
    os.makedirs(os.path.join(BUILD, "scenes"), exist_ok=True)
    with Pool(min(4, os.cpu_count())) as pool:
        res = pool.map(render_scene, [(sp, total, plan) for sp in plan], chunksize=1)
    events = sorted(e for _, ev in res for e in ev)
    with open(os.path.join(BUILD, "sfx.json"), "w") as f:
        json.dump({"events": events, "plan": plan, "total_frames": total}, f, ensure_ascii=False, indent=1)
    with open(os.path.join(BUILD, "scenes", "list.txt"), "w") as f:
        for sp in plan:
            f.write(f"file 'scene{sp['id']}.mp4'\n")
    print("scenes done; total", total, "frames =", total / FPS, "s")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "stills"
    if cmd == "stills":
        sys.exit(0 if stills() else 1)
    elif cmd == "video":
        video()
