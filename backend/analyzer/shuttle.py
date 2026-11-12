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


def _locate(hm):
    """Centre of the largest blob in a binary heatmap, or None."""
    m = (hm > 0.5).astype(np.uint8)
    if not m.any(): return None
    cnts, _ = cv2.findContours(m, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    x, y, w, h = max((cv2.boundingRect(c) for c in cnts), key=lambda r: r[2] * r[3])
    return x + w / 2, y + h / 2


def track_segment(model, cap, start, end, progress=None):
    """Track the shuttle on frames [start, end) of an open cv2.VideoCapture."""
    W = cap.get(cv2.CAP_PROP_FRAME_WIDTH); H = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
    sx, sy = W / W_IN, H / H_IN
    # background = per-pixel median of up to 60 frames of this camera shot
    idx = np.linspace(start, end - 1, min(60, end - start)).astype(int)
    samples = []
    for i in idx:
        cap.set(cv2.CAP_PROP_POS_FRAMES, int(i)); ok, f = cap.read()
        if ok: samples.append(cv2.resize(f, (W_IN, H_IN), interpolation=cv2.INTER_AREA))
    median = _prep(np.median(np.array(samples), 0).astype(np.uint8))
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
            x = np.concatenate([median] + [_prep(f) for f in frames], 0)[None]
            hm = model(torch.from_numpy(x))[0].numpy()
            for k in range(n):
                p = _locate(hm[k])
                out[i + k] = (p[0] * sx, p[1] * sy) if p else None
            i += n
            if progress: progress((i - start) / max(end - start, 1))
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
    fr = sorted(keep)
    for a, b in zip(fr, fr[1:]):
        if 1 < b - a <= int(0.15 * fps) + 1:
            for f in range(a + 1, b):
                t = (f - a) / (b - a)
                keep[f] = (keep[a][0] * (1 - t) + keep[b][0] * t, keep[a][1] * (1 - t) + keep[b][1] * t)
    return keep


def find_hits(pts, fps, min_gap_s=0.35):
    """Frames where the vertical direction of travel flips (racket contact). Returns sorted frame list."""
    fr = sorted(pts)
    if len(fr) < 8: return []
    ys = np.array([pts[f][1] for f in fr], float)
    k = max(3, int(0.05 * fps))
    vy = np.convolve(np.gradient(ys), np.ones(k) / k, mode='same')
    hits, last = [], -10 ** 9
    for j in range(k, len(fr) - k):
        if fr[j + k] - fr[j - k] > 4 * k: continue  # not a continuous run
        before, after = vy[j - k:j].mean(), vy[j:j + k].mean()
        # up (negative y) -> down, or down -> up, with real speed on both sides
        if np.sign(before) != np.sign(after) and min(abs(before), abs(after)) > 1.0:
            if fr[j] - last >= min_gap_s * fps:
                hits.append(fr[j]); last = fr[j]
    return hits
