"""シーンごとの画面構成。各 build_N(c, dur) は描画要素のリストを返す。
c[k] は k 番目のキュー（ナレーション "|" の位置）のシーン内時刻（秒）。"""
import math

from PIL import Image, ImageDraw

from config import COL, SAFE_L, SAFE_R
from gfx import (SS, Automaton, El, Pulse, Txt, Q, boxed, clamp, dot_sprite, ease_io, ease_out,
                 fade_mask, glow_sprite, mul_alpha, panel, paste, pill, ss_canvas, ss_done, txt)

CX = (SAFE_L + SAFE_R) // 2  # 安全領域の中央 x
CW = SAFE_R - SAFE_L         # 安全領域の幅


def title(markup, t=0.05, size=66, y=150):
    return El(txt(markup, size), CX, y, t, anchor="ct", sfx=None, name="title")


# ================================================================ 0 つかみ
def build_0(c, dur):
    els = [
        El(txt("{y:『いつか必ず』}を", 100), CX, 330, 0.05, anchor="ct", anim="pop", sfx="pon"),
        El(txt("グラフにする方法", 100), CX, 470, 0.35, anchor="ct", anim="pop", sfx=None),
        El(txt("{y:LTL}  →  {c:ビュッヒ・オートマトン}", 56), CX, 640, c[1], anchor="ct"),
        El(pill("90秒で解説", 44, border="y"), CX, 750, c[2], anchor="ct", anim="pop", sfx="pon"),
    ]
    a = Automaton((360, 1090), (700, 1090), 72)
    t0 = 0.6
    for k, n in enumerate(["start", "q0", "loop0", "edge", "q1", "loop1"]):
        els.append(a.el(n, t0 + 0.12 * k, sfx=None))
    els.append(Pulse(700, 1090, 72, c[1] + 0.4, sfx=None))
    return els


# ================================================================ 1 LTL とは
def dots(pattern, r=12, gap=50):
    """時間軸の点：g=p 成立、o=不成立、q=q 成立"""
    w = gap * (len(pattern) - 1) + 2 * r + 60
    h = 2 * r + 34
    img, d = ss_canvas(w, h)
    y = (h - r - 6) * SS
    for i, ch in enumerate(pattern):
        x = (r + 2 + i * gap) * SS
        if ch == "g":
            d.ellipse([x - r * SS, y - r * SS, x + r * SS, y + r * SS], fill=COL["g"] + (255,))
        elif ch == "q":
            d.ellipse([x - r * SS, y - r * SS, x + r * SS, y + r * SS], fill=COL["y"] + (255,))
        else:
            d.ellipse([x - r * SS, y - r * SS, x + r * SS, y + r * SS], outline=COL["line"] + (255,),
                      width=3 * SS)
    xe = (r + 2 + (len(pattern) - 1) * gap + 22) * SS
    d.line([(xe, y), (xe + 26 * SS, y)], fill=COL["m"] + (255,), width=3 * SS)
    d.polygon([(xe + 36 * SS, y), (xe + 24 * SS, y - 7 * SS), (xe + 24 * SS, y + 7 * SS)], fill=COL["m"] + (255,))
    img = ss_done(img, w, h)
    return img


def build_1(c, dur):
    els = [
        title("{y:LTL} ＝ 線形時相論理", size=72),
        El(txt("時間の流れについての性質を書く論理", 42, "m"), CX, 262, c[1], anchor="ct"),
    ]
    rows = [("G p", "いつも", "ggggggggg"), ("F p", "いつか", "oooooгooo".replace("г", "g")),
            ("X p", "次の瞬間に", "ogooooooo"), ("p U q", "{y:q} になるまでずっと {y:p}", "ggggqoooo")]
    for i, (f, mean, pat) in enumerate(rows):
        y = 345 + i * 145
        t = c[2 + i]
        els.append(El(panel(CW, 130, border=None), SAFE_L, y, t, deco=True, sfx=None))
        els.append(El(txt("{y:%s}" % f, 60), SAFE_L + 30, y + 65, t, anchor="lc", sfx=None))
        els.append(El(txt(mean, 46), SAFE_L + 255, y + 10, t, sfx="tick"))
        els.append(El(dots(pat), SAFE_L + 262, y + 72, t + 0.1, sfx=None))
    y = 945
    ex = boxed([("{m:例}　{y:G(要求 → F 応答)}", 60), ("要求されたら、いつか必ず応答する", 42)],
               CW, border="y", gap=6)
    els.append(El(ex, SAFE_L, y, c[6], anim="pop", sfx="pon"))
    return els


# ================================================================ 2 ビュッヒ・オートマトンとは
class Band:
    """状態が並んで流れていく帯。受理状態（ピンク二重丸）が何度も現れる。"""

    def __init__(self, x, y, w, t, speed=95):
        self.x, self.y, self.w, self.t, self.speed = x, y, w, t, speed
        self.pitch, self.r = 124, 36
        pat = "sAssA"
        self.period = self.pitch * len(pat)
        n = int(w / self.pitch) + len(pat) * 2 + 2
        self.h = 2 * self.r + 20
        sw = n * self.pitch
        img, d = ss_canvas(sw, self.h)
        cy = self.h / 2 * SS
        for i in range(n):
            cx = (self.r + 8 + i * self.pitch) * SS
            acc = pat[i % len(pat)] == "A"
            col = COL["p" if acc else "c"] + (255,)
            r = self.r * SS
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=COL["panel"] + (255,), outline=col, width=5 * SS)
            if acc:
                ri = r - 10 * SS
                d.ellipse([cx - ri, cy - ri, cx + ri, cy + ri], outline=col, width=4 * SS)
            x0, x1 = cx + r + 6 * SS, cx + (self.pitch - self.r - 6) * SS
            d.line([(x0, cy), (x1 - 10 * SS, cy)], fill=COL["c"] + (255,), width=4 * SS)
            d.polygon([(x1, cy), (x1 - 16 * SS, cy - 9 * SS), (x1 - 16 * SS, cy + 9 * SS)], fill=COL["c"] + (255,))
        self.strip = ss_done(img, sw, self.h)
        self.mask = fade_mask(int(w), self.h, left=50, right=90)
        self.deco = False
        self.bbox = (x, y, x + w, y + self.h)
        self.sfx = None

    def visible(self, t):
        return t >= self.t

    def draw(self, frame, t):
        if t < self.t:
            return
        off = (self.speed * (t - self.t)) % self.period
        win = self.strip.crop((int(off), 0, int(off) + int(self.w), self.h))
        paste(frame, mul_alpha(win, self.mask), self.x, self.y - (1 - ease_out((t - self.t) / 0.35)) * -20,
              ease_out((t - self.t) / 0.35))

    def events(self):
        return [(self.t, "tick", 1.0)]


def build_2(c, dur):
    els = [
        title("{c:ビュッヒ・オートマトン}", size=70),
        El(txt("終わらない入力を読む状態遷移図", 44), CX, 262, c[1], anchor="ct"),
    ]
    bw = (CW - 30) // 2
    left = boxed([("普通のオートマトン", 36), ("{m:入力：有限}", 34), ("最後の状態で判定", 34)], bw, border="line")
    right = boxed([("{c:ビュッヒ}", 36), ("{m:入力：無限に続く}", 34), ("最後の状態がない！", 34)], bw, border="c")
    els.append(El(left, SAFE_L, 370, c[1] + 0.5))
    els.append(El(right, SAFE_L + bw + 30, 370, c[1] + 0.8))
    els.append(El(txt("入力が終わらない → 状態の列も終わらない", 36, "m"), CX, 690, c[2], anchor="ct", sfx=None))
    els.append(Band(SAFE_L, 770, CW, c[2]))
    els.append(El(txt("{p:◎} ＝ 受理状態", 34), SAFE_R, 875, c[2] + 0.2, anchor="rt", sfx=None))
    concl = boxed([("{p:受理状態}を {p:無限回} 通れば {p:受理}", 52)], CW, border="p", align="c", pad=34)
    els.append(El(concl, SAFE_L, 1010, c[3], anim="pop", sfx="pon"))
    return els


# ================================================================ 3 なぜ変換するのか
def build_3(c, dur):
    els = [title("なぜ変換するのか")]
    bw = 600
    els.append(El(boxed([("{c:システムのモデル}", 48)], bw, border="c", align="c"), CX, 290, c[1], anchor="ct"))
    els.append(El(txt("×", 64), CX, 410, c[2], anchor="ct", sfx=None))
    els.append(El(boxed([("{y:¬φ} の{c:オートマトン}", 48)], bw, border="c", align="c"), CX, 500, c[2], anchor="ct"))
    els.append(El(txt("（φ ＝ 守りたい仕様、¬φ ＝ それが破られる様子）", 30, "m"), CX, 625, c[2] + 0.3,
                  anchor="ct", sfx=None))
    els.append(El(txt("↓", 44, "m"), CX, 668, c[2] + 1.0, anchor="ct", sfx=None))
    q = boxed([("両方が受け入れる{p:無限の実行}はある？", 46)], CW, border="w", align="c")
    els.append(El(q, SAFE_L, 745, c[2] + 1.2, anim="pop", sfx="pon"))

    def row(tag, tagc, body, y, t, sfx):
        tg = pill(tag, 40, fill=tagc, border=None, default="bg0")
        p = panel(CW, 106, border=tagc)
        p.alpha_composite(tg, (24, (106 - tg.size[1]) // 2))
        b = Txt(body, 42)
        p.alpha_composite(b.img, (24 + tg.size[0] + 22, (106 - b.h) // 2))
        return El(p, SAFE_L, y, t, anim="pop", sfx=sfx)

    els.append(row("ある", "p", "→ バグの実例（反例）が見つかる", 895, c[3], "pon"))
    els.append(row("ない", "g", "→ 仕様は{g:必ず守られる}", 1020, c[4], "pon"))
    return els


# ================================================================ 4 展開則
def build_4(c, dur):
    els = [title("変換のカギ ＝ {y:展開則}")]
    segs = [("F p", "y", ""), (" ≡ ", "w", ""), ("p", "y", ""), (" ∨ ", "w", ""), ("X ", "y", ""), ("F p", "y", "")]
    big = Txt(None, 100, segs=segs)
    segs2 = segs[:-1] + [("F p", "c", "")]
    big2 = Txt(None, 100, segs=segs2)
    fx, fy = CX - big.w / 2, 300
    els.append(El(big.img, fx, fy, c[1], anim="pop", sfx="pon"))
    els.append(El(big2.img, fx, fy, c[4], anim="fade", sfx=None, deco=True))

    base = fy + big.h - 8

    def bracket(s0, s1, col):
        x0, x1 = big.spans[s0][0] + 4, big.spans[s1][1] - 4
        w = x1 - x0
        img, d = ss_canvas(w + 8, 22)
        cc = COL[col] + (255,)
        d.line([(4 * SS, 2 * SS), (4 * SS, 14 * SS), ((w + 4) * SS, 14 * SS), ((w + 4) * SS, 2 * SS)],
               fill=cc, width=4 * SS)
        return ss_done(img, w + 8, 22), fx + x0 - 4

    for (s0, s1, lab, t) in [(0, 0, "いつか p", c[1] + 0.3), (2, 2, "今 p", c[2]),
                             (4, 5, "次の瞬間から見て|いつか p", c[3])]:
        bimg, bx = bracket(s0, s1, "y")
        els.append(El(bimg, bx, base, t, sfx=None, deco=True))
        mid = fx + (big.spans[s0][0] + big.spans[s1][1]) / 2
        for k, line in enumerate(lab.split("|")):
            els.append(El(txt(line, 34), mid, base + 30 + k * 46, t, anchor="ct", sfx="tick" if k == 0 else None))

    y = 640
    els.append(El(txt("ほかの演算子も同じ形", 32, "m"), SAFE_L, y, c[4], sfx=None))
    r1 = Txt(None, 46, segs=[("G p", "y", ""), (" ≡ ", "w", ""), ("p ∧ X ", "y", ""), ("G p", "c", "")])
    r2 = Txt(None, 46, segs=[("p U q", "y", ""), (" ≡ ", "w", ""), ("q ∨ (p ∧ X ", "y", ""),
                             ("(p U q)", "c", ""), (")", "y", "")])
    els.append(El(r1.img, SAFE_L + 10, y + 50, c[4] + 0.15, sfx=None))
    els.append(El(r2.img, SAFE_L + 10, y + 118, c[4] + 0.3, sfx=None))

    box = boxed([("{y:X} のうしろ ＝ {c:次へ持ち越す約束}", 48)], CW, border="c", align="c")
    els.append(El(box, SAFE_L, 860, c[5], sfx="tick"))

    # 約束 F p → 状態
    r = 82
    img, d = ss_canvas(2 * r + 12, 2 * r + 12)
    d.ellipse([6 * SS, 6 * SS, (2 * r + 6) * SS, (2 * r + 6) * SS], fill=COL["panel"] + (255,),
              outline=COL["c"] + (255,), width=6 * SS)
    st = ss_done(img, 2 * r + 12, 2 * r + 12)
    t = Txt("{c:F p}", 52)
    st.alpha_composite(t.img, ((st.size[0] - t.w) // 2, (st.size[1] - t.h) // 2 - 2))
    els.append(El(st, CX + 40, 1005, c[6], anim="pop", sfx="pon"))
    els.append(El(txt("そのまま", 44), CX + 10, 1030, c[6] + 0.15, anchor="rt", sfx=None))
    els.append(El(txt("{c:状態} になる", 56), CX + 10, 1090, c[6] + 0.15, anchor="rt", sfx=None))
    return els


# ================================================================ 5 例：F p
def build_5(c, dur):
    els = [title("例：{y:F p} の変換")]
    a = Automaton((300, 600), (700, 600), 80)
    els += [a.el("start", c[1], sfx="tick"), a.el("q0", c[1], anim="pop", sfx=None),
            a.el("loop0", c[2]), a.el("edge", c[3]), a.el("q1", c[3] + 0.25, anim="pop", sfx=None),
            a.el("loop1", c[4])]
    els.append(Pulse(700, 600, 80, c[5], sfx="kiran"))
    lines = [
        (Q(0) + " ＝「{y:F p}」を約束中", c[1]),
        ("{y:¬p} なら → 約束を持ち越す", c[2]),
        ("{y:p} が来たら → 約束達成、" + Q(1) + " へ", c[3]),
        (Q(1) + " では何が来ても OK（{y:true}）", c[4]),
    ]
    for k, (m, t) in enumerate(lines):
        els.append(El(txt(m, 44), SAFE_L + 10, 780 + k * 88, t, sfx=None))
    fin = boxed([("約束を果たした " + Q(1, "p") + " が", 46), ("＝ {p:受理状態}", 54)], SAFE_R - 360, border="p",
                align="c")
    els.append(El(fin, SAFE_R, 1120, c[5], anchor="rt", anim="pop", sfx=None))
    return els


# ================================================================ 6 入力を流すデモ
class Demo:
    """入力テープ・光る点・受理状態の通過回数。phase A（p が来る）→ phase B（ずっと ¬p）。"""

    STEP = 0.42  # 点が辺を移動する時間

    def __init__(self, auto, tape_y, readsA, tB, readsB, counter_xy):
        self.a, self.tape_y, self.tB = auto, tape_y, tB
        self.readsA, self.readsB = readsA, readsB
        self.trA = self._transitions(readsA)
        self.trB = self._transitions(readsB)
        self.pitch, self.cw, self.ch = 116, 102, 92
        self.wx, self.ww = SAFE_L + 8, CW - 16
        self.head_x = self.wx + self.pitch * 1 + (self.pitch - self.cw) // 2
        self.cells = {}
        for sym, m in (("n", "{y:¬p}"), ("p", "{y:p}")):
            p = panel(self.cw, self.ch, fill="panel", border="line" if sym == "n" else "y", radius=14)
            t = Txt(m, 48)
            p.alpha_composite(t.img, ((self.cw - t.w) // 2, (self.ch - t.h) // 2 - 2))
            self.cells[sym] = p
        self.mask = fade_mask(self.ww, self.ch + 8, left=0, right=110)
        self.counter_xy = counter_xy
        self.ctr_label = txt("受理状態を通った回数", 40)
        self.num_cache = {}
        self.deco = False
        self.bbox = (self.wx, tape_y - 4, self.wx + self.ww, counter_xy[1] + 80)
        self.t = 0.0
        self.sfx = None

    def _transitions(self, reads):
        st, out = 0, []
        for (t, sym) in reads:
            if st == 0:
                kind, to = ("edge", 1) if sym == "p" else ("loop0", 0)
            else:
                kind, to = "loop1", 1
            out.append((t, st, to, kind))
            st = to
        return out

    def visible(self, t):
        return True

    def events(self):
        ev, first = [], True
        for (t, fr, to, kind) in self.trA:
            if to == 1:
                ev.append((t + self.STEP, "kiran", 1.0 if first else 0.22))
                first = False
        return ev

    def _num(self, n):
        if n not in self.num_cache:
            self.num_cache[n] = txt("{p:%d}" % n, 76)
        return self.num_cache[n]

    def _tape(self, frame, reads, t, alpha, seq):
        # 何マス読んだか（スクロール量）
        s = 0.0
        for k, (tk, _) in enumerate(reads):
            if t >= tk:
                s = k + ease_io((t - tk - 0.18) / 0.26)
        win = Image.new("RGBA", (self.ww, self.ch + 8))
        for i in range(max(0, int(s) - 2), int(s) + 9):
            x = (self.pitch * 1 + (self.pitch - self.cw) // 2) + (i - s) * self.pitch
            if x < -self.pitch or x > self.ww:
                continue
            sym = seq[i] if i < len(seq) else "n"
            read = i < len(reads) and t >= reads[i][0] + 0.3
            win.alpha_composite(self.cells[sym] if not read else _dim(self.cells[sym]), (int(round(x)), 4))
        paste(frame, mul_alpha(win, self.mask), self.wx, self.tape_y - 4, alpha)

    def _dot_and_glow(self, frame, t, trs, alpha):
        a = self.a
        cur, moving = 0, None
        for (tk, fr, to, kind) in trs:
            if t >= tk:
                if t < tk + self.STEP:
                    moving = (kind, (t - tk) / self.STEP)
                    cur = fr
                else:
                    cur = to
        if moving:
            kind, u = moving
            u = ease_io(u)
            if kind == "edge":
                x, y = a.edge_pt(u)
            else:
                x, y = a.loop_pt(0 if kind == "loop0" else 1, u)
            dsp = dot_sprite("p" if kind != "loop0" else "c")
            paste(frame, dsp, x - dsp.size[0] / 2, y - dsp.size[1] / 2, alpha)
        else:
            (sx, sy) = a.q[cur]
            g = glow_sprite(a.r, "p" if cur == 1 else "c")
            paste(frame, g, sx - g.size[0] / 2, sy - g.size[1] / 2, alpha * 0.9)
        return cur

    def draw(self, frame, t):
        kB = clamp((t - self.tB) / 0.3)
        seqA = ["n", "n", "n", "p"] + ["n"] * 40
        seqB = ["n"] * 60
        if kB < 1:
            self._tape(frame, self.readsA, t, ease_out(clamp(t / 0.35)) * (1 - kB), seqA)
        if kB > 0:
            self._tape(frame, self.readsB, t, kB, seqB)
        # 読み取り位置
        hx = self.wx + self.head_x - self.wx
        # 点
        if t < self.tB:
            self._dot_and_glow(frame, t, self.trA, ease_out(clamp((t - 0.3) / 0.3)))
        else:
            self._dot_and_glow(frame, t, self.trB, kB)
        # カウンタ
        if t < self.tB:
            n = sum(1 for (tk, fr, to, k) in self.trA if to == 1 and t >= tk + self.STEP)
        else:
            n = 0
        cx, cy = self.counter_xy
        paste(frame, self.ctr_label, cx, cy, ease_out(clamp((t - 0.3) / 0.3)))
        num = self._num(n)
        bump = 0
        for (tk, fr, to, k) in (self.trA if t < self.tB else []):
            if to == 1 and 0 <= t - (tk + self.STEP) < 0.25:
                bump = 1 - (t - tk - self.STEP) / 0.25
        if bump:
            s = 1 + 0.25 * bump
            num = num.resize((int(num.size[0] * s), int(num.size[1] * s)), Image.BILINEAR)
        lx = cx + self.ctr_label.size[0] + 24
        paste(frame, num, lx, cy + self.ctr_label.size[1] / 2 - num.size[1] / 2,
              ease_out(clamp((t - 0.3) / 0.3)))


_dim_cache = {}


def _dim(img):
    k = id(img)
    if k not in _dim_cache:
        d = img.copy()
        d.putalpha(d.getchannel("A").point(lambda v: int(v * 0.4)))
        _dim_cache[k] = d
    return _dim_cache[k]


def build_6(c, dur):
    els = [title("入力を流してみる", size=62, y=140)]
    a = Automaton((300, 640), (700, 640), 76)
    for n in ["start", "q0", "loop0", "edge", "q1", "loop1"]:
        els.append(a.el(n, 0.05, sfx=None))
    tape_y = 290
    # 読み取り位置の枠と ▼
    hx = SAFE_L + 8 + 116 * 1 + (116 - 102) // 2
    img, d = ss_canvas(118, 108)
    d.rounded_rectangle([3 * SS, 3 * SS, 115 * SS, 105 * SS], radius=18 * SS, outline=COL["c"] + (255,), width=5 * SS)
    els.append(El(ss_done(img, 118, 108), hx - 8, tape_y - 12, 0.2, sfx=None, deco=True))
    els.append(El(txt("{c:▼} 読む位置", 30), hx - 8, tape_y - 60, 0.2, sfx=None))
    # 読み取りのスケジュール
    s0 = 0.3 + 0.6
    da = max(0.45, (c[1] - s0) / 3)
    s0 = c[1] - 3 * da
    readsA = [(s0 + k * da, "n") for k in range(3)] + [(c[1], "p")]
    t = c[1] + 0.6
    while t < c[4] - 0.35:
        readsA.append((t, "n"))
        t += 0.6
    readsB = []
    t = c[4] + 0.45
    while t < dur - 0.25:
        readsB.append((t, "n"))
        t += 0.6
    els.append(Demo(a, tape_y, readsA, c[4], readsB, (SAFE_L + 10, 800)))

    def row(markup, border, y, t, sfx):
        return El(boxed([(markup, 46)], CW, border=border, pad=16), SAFE_L, y, t, anim="pop", sfx=sfx)

    els.append(row("{y:p} が来た → " + Q(1, "p") + " を無限回 → {p:受理 ✓}", "p", 905, c[3], "kiran"))
    els.append(El(txt("ずっと {y:¬p} → " + Q(0) + " で約束を先延ばし…", 38, "m"), SAFE_L + 10, 1016, c[5], sfx="tick"))
    els.append(row("ずっと {y:¬p} なら → {r:不受理}", "r", 1077, c[6], "boo"))
    return els


# ================================================================ 7 一般の手順
def build_7(c, dur):
    els = [title("一般の手順")]
    steps = ["否定 {y:¬} を内側へ押し込む",
             "{y:展開則}で「今」と「次」に分ける",
             "約束の組み合わせ ＝ {c:状態}",
             "{y:U}・{y:F} ごとに 先延ばし禁止の{p:受理条件}"]
    for i, s in enumerate(steps):
        y = 290 + i * 140
        p = panel(CW, 120, border="line")
        img, d = ss_canvas(76, 76)
        d.ellipse([2 * SS, 2 * SS, 74 * SS, 74 * SS], fill=COL["c"] + (255,))
        num = ss_done(img, 76, 76)
        nt = Txt(None, 44, segs=[(str(i + 1), "bg0", "")])
        num.alpha_composite(nt.img, ((76 - nt.w) // 2, (76 - nt.h) // 2 - 2))
        p.alpha_composite(num, (22, 22))
        t = Txt(s, 40)
        p.alpha_composite(t.img, (118, (120 - t.h) // 2))
        els.append(El(p, SAFE_L, y, c[1 + i]))
    els.append(El(pill("これが {y:タブロー法}", 54, border="y", padx=40, pady=14), CX, 870, c[5],
                  anchor="ct", anim="pop", sfx="pon"))
    els.append(El(txt("・状態数は最悪 2{m^:(式の長さ)}", 40, "m"), SAFE_L + 10, 1005, c[5] + 0.25, sfx=None))
    els.append(El(txt("・実務では {c:Spot}・{c:LTL2BA} が自動でやる", 40, "m"), SAFE_L + 10, 1075, c[5] + 0.45,
                  sfx=None))
    return els


# ================================================================ 8 まとめ
def build_8(c, dur):
    els = [title("まとめ", size=80, y=160)]
    cards = [("{y:LTL 式}", "＝ 未来への約束", "y"),
             ("{c:状態}", "＝ まだ果たしていない約束", "c"),
             ("{p:受理条件}", "＝ 先延ばし禁止", "p")]
    for i, (lab, body, col) in enumerate(cards):
        b = boxed([(lab, 60), (body, 50)], CW, border=col, pad=30, gap=4)
        els.append(El(b, SAFE_L, 330 + i * 270, c[1 + i], anim="pop", sfx="pon"))
    return els


BUILDERS = [build_0, build_1, build_2, build_3, build_4, build_5, build_6, build_7, build_8]
