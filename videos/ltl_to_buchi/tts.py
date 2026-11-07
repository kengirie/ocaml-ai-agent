"""VOICEVOX でシーンごとのナレーションを作り、キューのタイミングを timing.json に書く。

キューの時刻：ナレーション中の "|" の直前までの文を別に audio_query して
モーラ数を数え、全文の audio_query でそのモーラを含むアクセント句の開始時刻を使う。
"""
import io
import json
import os
import sys
import urllib.parse
import urllib.request
import wave

import numpy as np

from config import BUILD, PAUSE_SCALE, SCENES, SPEAKER_NAME, SPEAKER_STYLE, SPEED, SR, plain, cue_prefixes

HOST = os.environ.get("VOICEVOX_URL", "http://127.0.0.1:50021")


def call(path, params=None, body=None, raw=False):
    url = HOST + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data = json.dumps(body).encode() if body is not None else (b"" if path != "/speakers" else None)
    req = urllib.request.Request(url, data=data, method="GET" if data is None else "POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        out = r.read()
    return out if raw else json.loads(out)


def speaker_id():
    for sp in call("/speakers"):
        if sp["name"] == SPEAKER_NAME:
            for st in sp["styles"]:
                if st["name"] == SPEAKER_STYLE:
                    return st["id"]
    raise SystemExit(f"話者 {SPEAKER_NAME}/{SPEAKER_STYLE} が見つかりません")


def mora_count(q):
    return sum(len(ap["moras"]) for ap in q["accent_phrases"])


def phrase_times(q):
    """アクセント句ごとの (開始, 終了, 先頭モーラ番号, かな) を、速度補正前の秒で返す。"""
    t = q["prePhonemeLength"]
    out, k = [], 0
    for ap in q["accent_phrases"]:
        st = t
        for m in ap["moras"]:
            t += (m["consonant_length"] or 0) + m["vowel_length"]
        out.append([st, t, k, "".join(m["text"] for m in ap["moras"])])
        k += len(ap["moras"])
        if ap.get("pause_mora"):
            t += ap["pause_mora"]["vowel_length"] * q.get("pauseLengthScale", 1.0)
    total = t + q["postPhonemeLength"]
    return out, total


def main():
    os.makedirs(os.path.join(BUILD, "voice"), exist_ok=True)
    sid = speaker_id()
    print("speaker id:", sid)
    timing = {"speaker_id": sid, "scenes": []}
    for sc in SCENES:
        text = plain(sc["say"])
        q = call("/audio_query", {"text": text, "speaker": sid})
        q["speedScale"] = SPEED
        q["pauseLengthScale"] = PAUSE_SCALE
        q["prePhonemeLength"] = 0.05
        q["postPhonemeLength"] = 0.05
        q["outputSamplingRate"] = SR
        q["outputStereo"] = False
        wav = call("/synthesis", {"speaker": sid}, body=q, raw=True)
        with wave.open(io.BytesIO(wav)) as w:
            n = w.getnframes()
            assert w.getframerate() == SR and w.getnchannels() == 1
            pcm = np.frombuffer(w.readframes(n), dtype=np.int16)
        dur = n / SR
        path = os.path.join(BUILD, "voice", f"scene{sc['id']}.wav")
        with open(path, "wb") as f:
            f.write(wav)

        phrases, total = phrase_times(q)
        k = dur / total  # 実際の長さに合わせて伸縮（速度補正も含む）
        cues = []
        for pre in cue_prefixes(sc["say"]):
            if not pre:
                cues.append(0.0)
                continue
            nm = mora_count(call("/audio_query", {"text": pre, "speaker": sid}))
            # nm 番目のモーラを含む（＝そこから始まる）アクセント句の開始時刻
            best = min(phrases, key=lambda p: abs(p[2] - nm))
            cues.append(round(best[0] * k, 3))
        kana = " / ".join(p[3] for p in phrases)
        timing["scenes"].append({
            "id": sc["id"], "voice": round(dur, 4), "cues": cues, "kana": kana,
            "phrases": [[round(p[0] * k, 3), round(p[1] * k, 3), p[3]] for p in phrases],
            "peak": int(np.abs(pcm).max()),
        })
        print(f"scene {sc['id']}: {dur:6.2f}s  cues={cues}")
        print("   ", kana)
    with open(os.path.join(BUILD, "timing.json"), "w") as f:
        json.dump(timing, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    sys.exit(main())
