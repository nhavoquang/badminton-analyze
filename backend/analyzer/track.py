"""Pass 2: pick on-court players, keep identities per side, smooth court positions, compute speed/distance."""
import json, cv2, numpy as np
from scipy.ndimage import gaussian_filter1d, median_filter
from . import court

BOUNDS = (-1.0, 7.1, -1.5, 14.9)  # x0,x1,y0,y1 in metres (court + run-off)
NET_Y = court.L / 2

def foot_points(H, dets):
    if not dets: return []
    feet = [((d[0] + d[2]) / 2, d[3]) for d in dets]
    cm = court.to_court(np.array(H), feet)
    out = []
    for d, (x, y) in zip(dets, cm):
        if BOUNDS[0] <= x <= BOUNDS[1] and BOUNDS[2] <= y <= BOUNDS[3]:
            out.append({'box': d[:4], 'conf': d[4], 'xy': np.array([x, y])})
    return out

def run(det_json):
    D = json.load(open(det_json)); fps = D['fps']; F = D['frames']
    n = len(F)
    shots = {}
    for f in F:
        if f['H'] is not None:
            f['ok'] = court.plausible(np.array(f['H']))
            shots.setdefault(f['shot'], []).append(f['i'])
    # temporal consistency: inside a shot the camera is (nearly) fixed, so frames whose court fit
    # disagrees with the shot's median fit are wrong re-fits -> replace with the median homography
    for s_, idx in shots.items():
        C = np.array([court.to_img(np.array(F[i]['H']), [(0, 0), (court.W, 0), (court.W, court.L), (0, court.L)]) for i in idx])
        good = np.array([F[i]['ok'] for i in idx])
        if good.mean() < 0.5:  # shot is not a usable main-camera view
            for i in idx: F[i]['H'] = None
            shots[s_] = []; continue
        med = np.median(C[good], 0)
        Hmed = cv2.getPerspectiveTransform(np.float32([(0, 0), (court.W, 0), (court.W, court.L), (0, court.L)]), np.float32(med))
        for i, c in zip(idx, C):
            if not F[i]['ok'] or np.abs(c - med).max() > 40: F[i]['H'] = Hmed.tolist()
    shots = {k: v for k, v in shots.items() if v}
    players = []  # list of dict: shot, side, slot, frames->xy/box
    for s, idx in shots.items():
        cand = {i: foot_points(F[i]['H'], F[i]['dets']) for i in idx}
        for side in ('far', 'near'):
            per = {}
            for i in idx:
                c = [p for p in cand[i] if (p['xy'][1] < NET_Y) == (side == 'far') and p['conf'] >= 0.4]
                c.sort(key=lambda p: -p['conf'])
                keep = []
                for p in c:
                    if all(np.linalg.norm(p['xy'] - q['xy']) > 0.6 for q in keep): keep.append(p)
                per[i] = keep[:2]
            two = np.mean([len(v) >= 2 for v in per.values()])
            k = 2 if two > 0.4 else 1
            slots = [dict(shot=s, side=side, slot=j, pos={}, box={}) for j in range(k)]
            last = [None] * k
            for i in idx:
                c = per[i][:k]
                if not c: continue
                if k == 1 or len(c) == 1:
                    if k == 1: j = 0
                    else:
                        d = [np.linalg.norm(c[0]['xy'] - l) if l is not None else 1e9 for l in last]
                        j = int(np.argmin(d)) if min(d) < 1e9 else (0 if c[0]['xy'][0] < 3.05 else 1)
                    assign = [(j, c[0])]
                else:
                    def cost(perm):
                        return sum(np.linalg.norm(c[p]['xy'] - last[j]) if last[j] is not None else abs(c[p]['xy'][0] - (1.5 if j == 0 else 4.5)) for j, p in enumerate(perm))
                    perm = min([(0, 1), (1, 0)], key=cost)
                    assign = [(j, c[p]) for j, p in enumerate(perm)]
                for j, p in assign:
                    if last[j] is not None and np.linalg.norm(p['xy'] - last[j]) > 0.35 and i - max(slots[j]['pos'], default=i) <= 2:
                        continue  # >~75 km/h jump between consecutive frames: detection glitch
                    slots[j]['pos'][i] = p['xy']; slots[j]['box'][i] = p['box']; last[j] = p['xy']
            for sl in slots:
                if len(sl['pos']) > 0.3 * len(idx): players.append(sl)
    # series: fill short gaps, smooth, speeds
    for p in players:
        fr = sorted(p['pos']); a, b = fr[0], fr[-1]
        t = np.arange(a, b + 1)
        xy = np.array([p['pos'][i] for i in fr])
        X = np.interp(t, fr, xy[:, 0]); Y = np.interp(t, fr, xy[:, 1])
        # physical limit: a player's ground position can't move faster than ~8 m/s. Faster apparent motion is
        # almost always a jump (feet leave the floor, bbox bottom rises) -> clamp it instead of trusting it.
        X, Y = median_filter(X, 9), median_filter(Y, 9)
        mx = 8.0 / fps
        for k in range(1, len(X)):
            d = np.hypot(X[k] - X[k - 1], Y[k] - Y[k - 1])
            if d > mx:
                X[k] = X[k - 1] + (X[k] - X[k - 1]) * mx / d; Y[k] = Y[k - 1] + (Y[k] - Y[k - 1]) * mx / d
        X = gaussian_filter1d(X, 6); Y = gaussian_filter1d(Y, 6)
        v = np.hypot(np.gradient(X), np.gradient(Y)) * fps * 3.6
        v = np.clip(gaussian_filter1d(v, 6), 0, 35)
        step = np.hypot(np.diff(X, prepend=X[0]), np.diff(Y, prepend=Y[0]))
        p.update(t0=a, t1=b, X=X, Y=Y, v=v, dist=np.cumsum(step), vmax=np.maximum.accumulate(v))
        # box: nearest available detection (for label placement)
        bf = np.array(fr)
        p['boxf'] = {i: p['box'][bf[np.argmin(abs(bf - i))]] for i in t}
    return D, players
