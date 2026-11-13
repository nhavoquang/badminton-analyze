"""Pass 2: pick on-court players, keep identities per side, smooth court positions, compute speed/distance."""
import json, cv2, numpy as np
from scipy.ndimage import gaussian_filter1d, median_filter
from . import court

def appearance(img, box):
    """Shirt colour descriptor: hue x saturation histogram of the torso (L1-normalised, 48 values)."""
    x0, y0, x1, y1 = box; w, h = x1 - x0, y1 - y0
    a = img[int(max(0, y0 + 0.2 * h)):int(max(0, y0 + 0.5 * h)), int(max(0, x0 + 0.25 * w)):int(max(0, x1 - 0.25 * w))]
    if a.size == 0: return None
    hsv = cv2.cvtColor(a, cv2.COLOR_BGR2HSV)
    hist = cv2.calcHist([hsv], [0, 1], None, [12, 4], [0, 180, 0, 256]).ravel()
    s = hist.sum()
    return [round(float(v), 3) for v in hist / s] if s else None


def _hd(a, b):
    """Hellinger distance between two descriptors (0 = same colours, 1 = nothing in common)."""
    if a is None or b is None: return 0.5
    return float(np.sqrt(max(0.0, 1 - np.sum(np.sqrt(np.asarray(a) * np.asarray(b))))))


BOUNDS = (-1.0, 7.1, -1.5, 14.9)  # x0,x1,y0,y1 in metres (court + run-off)
NET_Y = court.L / 2

def foot_points(H, dets):
    if not dets: return []
    feet = [((d[0] + d[2]) / 2, d[3]) for d in dets]
    cm = court.to_court(np.array(H), feet)
    out = []
    for d, (x, y) in zip(dets, cm):
        if BOUNDS[0] <= x <= BOUNDS[1] and BOUNDS[2] <= y <= BOUNDS[3]:
            out.append({'box': d[:4], 'conf': d[4], 'xy': np.array([x, y]), 'hist': d[5] if len(d) > 5 else None})
    return out

def _apply_seed(slots, side, seed):
    """Renumber a side's slots so they match the positions the user confirmed in the preview frame."""
    if not seed or not seed.get('players'): return
    want = {int(k[-1]): np.array(v, float) for k, v in seed['players'].items() if k.startswith(side)}
    if not want: return
    f = seed.get('f', 0)
    def near(sl):
        fr = [i for i in sl['pos'] if abs(i - f) <= 15]
        return sl['pos'][min(fr, key=lambda i: abs(i - f))] if fr else None
    pos = [near(sl) for sl in slots]
    if len(slots) == 1:
        if pos[0] is not None and len(want) == 1: slots[0]['slot'] = next(iter(want))
        return
    def cost(order):
        return sum(np.linalg.norm(pos[j] - want[s]) for j, s in enumerate(order) if pos[j] is not None and s in want)
    if cost((1, 0)) < cost((0, 1)):
        slots[0]['slot'], slots[1]['slot'] = 1, 0


def _assign(per, idx, k, T, fps, shot, side):
    slots = [dict(shot=shot, side=side, slot=j, pos={}, box={}) for j in range(k)]
    last, lastf = [None] * k, [-10 ** 9] * k
    for i in idx:
        c = per[i][:k]
        if not c: continue
        if k == 1:
            options = [[(0, c[0])]]
        elif len(c) == 1:
            options = [[(0, c[0])], [(1, c[0])]]
        else:
            options = [[(0, c[0]), (1, c[1])], [(0, c[1]), (1, c[0])]]

        def cost(opt):
            t = 0.0
            for j, p in opt:
                if last[j] is not None and i - lastf[j] <= fps:
                    t += min(np.linalg.norm(p['xy'] - last[j]), 3.0) / 3.0
                elif T is None:
                    t += abs(p['xy'][0] - (1.5 if j == 0 else 4.5)) / 6.0
                else:
                    t += 0.3
                if T is not None and T[j] is not None:
                    t += 1.5 * _hd(p.get('hist'), T[j])
            return t
        for j, p in min(options, key=cost):
            if last[j] is not None and np.linalg.norm(p['xy'] - last[j]) > 0.35 and i - lastf[j] <= 2:
                continue  # >~75 km/h jump between consecutive frames: detection glitch
            slots[j]['pos'][i] = p['xy']; slots[j]['box'][i] = p['box']; slots[j].setdefault('hist', {})[i] = p.get('hist')
            last[j] = p['xy']; lastf[j] = i
    return slots


def _mean_hist(hs):
    hs = [np.asarray(h) for h in hs if h is not None]
    return (np.mean(hs, 0)).tolist() if hs else None


def _templates(per, idx, k, side, seed, slots):
    """Shirt-colour template per slot, or None when colours can't tell the players apart.
    The side's detections are split into k colour clusters; the user-confirmed seed frame (or, without one,
    the position-only pass) decides which cluster belongs to which slot."""
    pts = [(i, p) for i in idx for p in per[i] if p.get('hist') is not None]
    if k != 2 or len(pts) < 20: return None
    X = np.sqrt(np.array([p['hist'] for _, p in pts], np.float32))  # Hellinger -> Euclidean
    _, lab, C = cv2.kmeans(X, 2, None, (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 1e-4), 5, cv2.KMEANS_PP_CENTERS)
    lab = lab.ravel(); C = C ** 2
    if _hd(C[0], C[1]) < 0.2 or min(np.bincount(lab, minlength=2)) < 0.1 * len(lab): return None  # shirts look alike
    want = {int(key[-1]): np.array(v, float) for key, v in ((seed or {}).get('players') or {}).items() if key.startswith(side)}
    want = {j: xy for j, xy in want.items() if j < k}
    votes = np.zeros((2, 2))  # slot x cluster
    if want:
        f = seed.get('f', 0)
        for n, (i, p) in enumerate(pts):
            if abs(i - f) > 15: continue
            for j, xy in want.items():
                if np.linalg.norm(p['xy'] - xy) < 1.2: votes[j, lab[n]] += 1
    if votes.sum() == 0:
        where = {(i, id(p)): n for n, (i, p) in enumerate(pts)}
        for j, sl in enumerate(slots):
            for i, xy in sl['pos'].items():
                for p in per[i]:
                    if p['xy'] is xy and (i, id(p)) in where: votes[j, lab[where[(i, id(p))]]] += 1
    if votes.sum() == 0: return None
    straight = votes[0, 0] + votes[1, 1]; crossed = votes[0, 1] + votes[1, 0]
    return [C[0].tolist(), C[1].tolist()] if straight >= crossed else [C[1].tolist(), C[0].tolist()]


def run(det_json, seed=None):
    """seed: {'f': frame, 'players': {'near0': [x, y], ...}} from the app's preview, so each slot keeps the name
    the user checked there."""
    D = json.load(open(det_json, encoding='utf-8')); fps = D['fps']; F = D['frames']
    n = len(F)
    shots = {}
    for f in F:
        if f['H'] is not None:
            f['ok'] = D.get('manual') or court.plausible(np.array(f['H']), D.get('w', 1920), D.get('h', 1080))
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
            # pass 1: positions only; pass 2: positions + shirt colour, with colour templates taken from the
            # frame the user confirmed in the app (seed) or else from frames where both players were seen
            slots = _assign(per, idx, k, None, fps, s, side)
            T = _templates(per, idx, k, side, seed, slots)
            if T is not None:
                slots = _assign(per, idx, k, T, fps, s, side)
            _apply_seed(slots, side, seed)
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
