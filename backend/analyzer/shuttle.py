"""Shuttlecock tracking with TrackNetV3 weights (Chen et al.), our own minimal inference code.

Weights: TrackNet_best.pt from the TrackNetV3 release, path in $TRACKNET_WEIGHTS
(default: backend/weights/TrackNet_best.pt). Loaded with weights_only=True.

Output per frame: (x, y) in image pixels or None, plus detected hits:
a hit is where the shuttle's vertical image motion reverses (it changes court side direction).
"""
import os

import cv2
import numpy as np
import torch
import torch.nn as nn

H_IN, W_IN, SEQ = 288, 512, 8
DEFAULT_WEIGHTS = os.path.join(os.path.dirname(__file__), '..', 'weights', 'TrackNet_best.pt')


# --- network (same layer names as the published checkpoint) -----------------------------------
class _Conv(nn.Module):
    def __init__(self, i, o):
        super().__init__()
        self.conv = nn.Conv2d(i, o, 3, padding='same', bias=False)
        self.bn = nn.BatchNorm2d(o)
        self.relu = nn.ReLU()

    def forward(self, x): return self.relu(self.bn(self.conv(x)))


class _Stack(nn.Module):
    def __init__(self, i, o, n):
        super().__init__()
        self.conv_1 = _Conv(i, o); self.conv_2 = _Conv(o, o)
        if n == 3: self.conv_3 = _Conv(o, o)
        self.n = n

    def forward(self, x):
        x = self.conv_2(self.conv_1(x))
        return self.conv_3(x) if self.n == 3 else x


class TrackNet(nn.Module):
    def __init__(self, in_dim=(SEQ + 1) * 3, out_dim=SEQ):
        super().__init__()
        self.down_block_1 = _Stack(in_dim, 64, 2); self.down_block_2 = _Stack(64, 128, 2)
        self.down_block_3 = _Stack(128, 256, 3); self.bottleneck = _Stack(256, 512, 3)
        self.up_block_1 = _Stack(768, 256, 3); self.up_block_2 = _Stack(384, 128, 2)
        self.up_block_3 = _Stack(192, 64, 2)
        self.predictor = nn.Conv2d(64, out_dim, 1)

    def forward(self, x):
        pool, up = nn.functional.max_pool2d, lambda t: nn.functional.interpolate(t, scale_factor=2, mode='nearest')
        x1 = self.down_block_1(x); x2 = self.down_block_2(pool(x1, 2)); x3 = self.down_block_3(pool(x2, 2))
        x = self.bottleneck(pool(x3, 2))
        x = self.up_block_1(torch.cat([up(x), x3], 1))
        x = self.up_block_2(torch.cat([up(x), x2], 1))
        x = self.up_block_3(torch.cat([up(x), x1], 1))
        return torch.sigmoid(self.predictor(x))


def load(weights=None):
    path = weights or os.environ.get('TRACKNET_WEIGHTS') or DEFAULT_WEIGHTS
    ck = torch.load(path, map_location='cpu', weights_only=True)
    m = TrackNet()
    m.load_state_dict(ck['model'])
    return m.eval()


def _prep(frame_bgr):
    rgb = cv2.cvtColor(cv2.resize(frame_bgr, (W_IN, H_IN), interpolation=cv2.INTER_AREA), cv2.COLOR_BGR2RGB)
    return np.moveaxis(rgb, -1, 0).astype(np.float32) / 255.0


def _blobs(hm, thr=0.35):
    """All heatmap blobs above thr: (x, y, peak) in heatmap pixels."""
    m = (hm > thr).astype(np.uint8)
    if not m.any(): return []
    n, lab, stats, cent = cv2.connectedComponentsWithStats(m)
    out = []
    for k in range(1, n):
        peak = float(hm[lab == k].max())
        out.append((float(cent[k][0]), float(cent[k][1]), peak))
    return out


def tiles(W, H):
    """Landscape crops the network sees at close to native scale. A wide frame is one tile; a portrait
    phone video is cut into overlapping 16:9 bands (squashing it into 512x288 makes the shuttle vanish)."""
    if W / H >= 1.4: return [(0, 0, int(W), int(H))]
    th = int(round(W * 9 / 16))
    n = int(np.ceil((H - th) / (0.9 * th))) + 1
    ys = np.linspace(0, H - th, n).astype(int)
    return [(0, int(y), int(W), th) for y in ys]


def track_segment(model, cap, start, end, progress=None):
    """Track the shuttle on frames [start, end) of an open cv2.VideoCapture. Returns frame -> list of
    candidates (x, y, score) in image pixels; pick() turns them into one trajectory."""
    W = cap.get(cv2.CAP_PROP_FRAME_WIDTH); H = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    T = tiles(W, H)
    # background = per-pixel median of up to 60 frames of this camera shot
    idx = np.linspace(start, end - 1, min(60, end - start)).astype(int)
    samples = []
    for i in idx:
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(i)); ok, f = cap.read()
        if ok: samples.append(f)
    med = np.median(np.array(samples), 0).astype(np.uint8)
    crop = lambda img, t: img[t[1]:t[1] + t[3], t[0]:t[0] + t[2]]
    medians = [_prep(crop(med, t)) for t in T]
    cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    out = {}
    i = start
    with torch.inference_mode():
        while i < end:
            frames = []
            for _ in range(SEQ):
                if i + len(frames) >= end: break
                ok, f = cap.read()
                if not ok: break
                frames.append(f)
            if not frames: break
            n = len(frames)
            frames += [frames[-1]] * (SEQ - n)
            batch = np.stack([np.concatenate([medians[ti]] + [_prep(crop(f, t)) for f in frames], 0) for ti, t in enumerate(T)])
            hms = model(torch.from_numpy(batch)).numpy()
            for k in range(n):
                cands = []
                for ti, t in enumerate(T):
                    sx, sy = t[2] / W_IN, t[3] / H_IN
                    for x, y, pk in _blobs(hms[ti, k]):
                        cands.append((t[0] + x * sx, t[1] + y * sy, pk))
                out[i + k] = _dedupe(cands, 0.02 * W)
            i += n
            if progress: progress((i - start) / max(end - start, 1))
    return out


def motion_candidates(cap, start, end, boxes=None, score=0.5):
    """Second detector for what TrackNet misses, mostly a shuttle high up against a dark ceiling or wall:
    small bright blobs that are brighter than both the previous and the next frame (a light object passing
    through). Blobs on players (boxes: frame -> [x0, y0, x1, y1, ...]) are ignored; pick() keeps only
    candidates that form a smooth flight path."""
    W = cap.get(cv2.CAP_PROP_FRAME_WIDTH); H = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    amax = 0.00025 * W * H; smax = 0.04 * W
    cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    gray = lambda f: cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).astype(np.int16)
    buf, out, k = [], {}, np.ones((2, 2), np.uint8)
    for i in range(start, end):
        ok, f = cap.read()
        if not ok: break
        buf.append(gray(f))
        if len(buf) < 3: continue
        a, b, c = buf[-3:]; buf = buf[-2:]; fi = i - 1
        d = np.minimum(b - a, b - c)
        m = cv2.morphologyEx((d > 18).astype(np.uint8), cv2.MORPH_OPEN, k)
        n, lab, st, cen = cv2.connectedComponentsWithStats(m)
        bx = [q for q in (boxes or {}).get(fi, []) if q[4] > 0.4]
        res = []
        for j in range(1, n):
            x, y, w, h, area = st[j]
            if not (3 <= area <= amax and max(w, h) <= smax): continue
            px, py = cen[j]
            if b[lab == j].mean() < 120: continue
            if any(q[0] - 0.1 * (q[2] - q[0]) <= px <= q[2] + 0.1 * (q[2] - q[0]) and q[1] <= py <= q[3] for q in bx): continue
            res.append((float(px), float(py), score))
        if res: out[fi] = res
    return out


def merge(a, b, width):
    """Add detector b's candidates to a's where a has nothing close by."""
    out = {f: list(v) for f, v in a.items()}
    for f, v in b.items():
        out[f] = _dedupe(out.get(f, []) + list(v), 0.02 * width)
    return out


def _dedupe(c, r):
    c = sorted(c, key=lambda p: -p[2]); keep = []
    for p in c:
        if all(np.hypot(p[0] - q[0], p[1] - q[1]) > r for q in keep): keep.append(p)
    return keep


def pick(cands, fps, width):
    """Choose one candidate per frame so the path is physically continuous (Viterbi over candidates +
    a 'not visible' state). Fast shuttles move up to ~6% of the frame width per frame at 30 fps."""
    frames = sorted(cands)
    if not frames: return {}
    gate = 0.06 * width * 30 / fps
    MISS = 1.2  # cost of a frame without the shuttle
    states, back = [], []
    prev = None
    for f in frames:
        opts = [None] + [c for c in cands[f]]
        cost = []
        bp = []
        for o in opts:
            emit = MISS if o is None else 1.0 - o[2]
            if prev is None:
                cost.append(emit); bp.append(-1); continue
            best, arg = 1e9, -1
            for j, (po, pc) in enumerate(zip(prev_opts, prev)):
                if o is None or po is None: tr = 0.0 if o is None else 0.3
                else:
                    d = np.hypot(o[0] - po[0], o[1] - po[1])
                    tr = (d / gate) ** 2 if d < 2 * gate else 1e6
                if pc + tr < best: best, arg = pc + tr, j
            cost.append(best + emit); bp.append(arg)
        states.append(opts); back.append(bp)
        prev, prev_opts = cost, opts
    j = int(np.argmin(prev)); out = {}
    for t in range(len(frames) - 1, -1, -1):
        o = states[t][j]
        out[frames[t]] = (o[0], o[1]) if o is not None else None
        j = back[t][j] if back[t][j] >= 0 else 0
    return out


def clean(points, fps, max_jump_frac=0.08, width=1920):
    """Drop isolated detections and fill short gaps (<= 0.15 s) linearly."""
    fr = sorted(k for k, v in points.items() if v is not None)
    keep = {}
    lim = max_jump_frac * width
    for j, f in enumerate(fr):
        nb = [points[g] for g in fr[max(0, j - 2):j + 3] if g != f and abs(g - f) <= 4]
        if any(np.hypot(points[f][0] - q[0], points[f][1] - q[1]) < lim for q in nb):
            keep[f] = points[f]
    # a shuttle in play never sits still: drop detections that stay put for ~0.3 s (shoes, lines, logos)
    fr = sorted(keep); half = max(3, int(0.15 * fps))
    still = set()
    for j, f in enumerate(fr):
        win = [keep[g] for g in fr[max(0, j - half):j + half + 1] if abs(g - f) <= half]
        if len(win) >= half and np.ptp([p[0] for p in win]) < 12 and np.ptp([p[1] for p in win]) < 12:
            still.add(f)
    keep = {f: v for f, v in keep.items() if f not in still}
    fr = sorted(keep)
    for a, b in zip(fr, fr[1:]):
        if 1 < b - a <= int(0.4 * fps) + 1:
            # fit a parabola (free flight) through a few points on each side of the gap
            ctx = [g for g in fr if a - 6 <= g <= a] + [g for g in fr if b <= g <= b + 6]
            if len(ctx) >= 4 and b - a > int(0.15 * fps) + 1:
                t = np.array(ctx, float)
                px = np.polyfit(t, [keep[g][0] for g in ctx], 2); py = np.polyfit(t, [keep[g][1] for g in ctx], 2)
                for f in range(a + 1, b): keep[f] = (float(np.polyval(px, f)), float(np.polyval(py, f)))
            elif b - a <= int(0.15 * fps) + 1:
                for f in range(a + 1, b):
                    t = (f - a) / (b - a)
                    keep[f] = (keep[a][0] * (1 - t) + keep[b][0] * t, keep[a][1] * (1 - t) + keep[b][1] * t)
    return keep


def find_hits(pts, fps, min_gap_s=0.3):
    """Candidate racket contacts: sharp turns or sudden speed-ups of the shuttle's image velocity.
    A free flight (rise, apex, fall) bends smoothly; a racket hit changes the velocity abruptly."""
    fr = sorted(pts)
    if len(fr) < 10: return []
    k = max(3, int(0.06 * fps))
    P = {f: np.array(pts[f], float) for f in fr}
    score = []
    for f in fr:
        if not all(g in P for g in (f - k, f, f + k)): continue
        vin, vout = (P[f] - P[f - k]) / k, (P[f + k] - P[f]) / k
        sin, sout = np.linalg.norm(vin), np.linalg.norm(vout)
        if max(sin, sout) < 2.0: continue  # barely moving
        cos = float(np.dot(vin, vout) / (sin * sout + 1e-9))
        turn = np.degrees(np.arccos(np.clip(cos, -1, 1)))
        jump = sout / (sin + 1e-6)
        if turn > 60 or (jump > 2.2 and sout > 6):
            score.append((f, turn + 20 * min(jump, 5)))
    # keep the strongest candidate in each burst
    hits = []
    for f, sc in score:
        if hits and f - hits[-1][0] < min_gap_s * fps:
            if sc > hits[-1][1]: hits[-1] = (f, sc)
        else:
            hits.append((f, sc))
    return [f for f, _ in hits]
