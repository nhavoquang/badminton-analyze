"""Badminton court detection: white-line mask + Hough + model fitting -> homography (image -> court metres)."""
import cv2, numpy as np, itertools

W, L = 6.10, 13.40  # court width (x), length (y) in metres
HL = [0, 0.76, 4.72, 8.68, 12.64, 13.40]
VL = [0, 0.46, 5.64, 6.10]
def model_segments():
    s = [((0, y), (W, y)) for y in HL] + [((x, 0), (x, L)) for x in VL]
    s += [((3.05, 0), (3.05, 4.72)), ((3.05, 8.68), (3.05, L))]
    return s
SEG = model_segments()
SAMPLES = np.concatenate([np.linspace(a, b, 40) for a, b in [(np.array(p), np.array(q)) for p, q in SEG]])

def line_mask(img):
    # "whiteness" = darkest channel: high only where all of R,G,B are high (white paint),
    # low on any saturated court colour (green / red / blue)
    wht = img.min(axis=2)
    th = cv2.morphologyEx(wht, cv2.MORPH_TOPHAT, cv2.getStructuringElement(cv2.MORPH_RECT, (11, 11)))
    return ((th > 35) & (wht > 110)).astype(np.uint8) * 255

def _lines(mask):
    segs = cv2.HoughLinesP(mask, 1, np.pi / 360, 60, minLineLength=mask.shape[1] // 12, maxLineGap=12)
    if segs is None: return [], []
    hor, ver = [], []
    for x1, y1, x2, y2 in segs.reshape(-1, 4).astype(float):
        ang = np.degrees(np.arctan2(y2 - y1, x2 - x1)) % 180
        ln = np.cross([x1, y1, 1.0], [x2, y2, 1.0]); ln /= np.hypot(ln[0], ln[1])
        if ln[2] < 0: ln = -ln  # normalise sign... keep rho comparable
        (hor if (ang < 8 or ang > 172) else ver if 20 < ang < 160 else []).append((ln, np.hypot(x2-x1, y2-y1)))
    return _cluster(hor), _cluster(ver)

def _cluster(lines, tol=8):
    out = []
    for ln, length in sorted(lines, key=lambda t: -t[1]):
        for c in out:
            # compare by distance of line at image positions; approximate by comparing normals + offsets
            if np.dot(c[0][:2], ln[:2]) > 0.995 and abs(c[0][2] - ln[2]) < tol:
                break
        else:
            out.append([ln, length])
    return [c[0] for c in out[:14]]

def _inter(a, b):
    p = np.cross(a, b); return p[:2] / p[2] if abs(p[2]) > 1e-9 else None

def fit(img, scale=0.5):
    small = cv2.resize(img, None, fx=scale, fy=scale)
    mask = line_mask(small)
    hor, ver = _lines(mask)
    if len(hor) < 2 or len(ver) < 2: return None, 0.0
    dist = cv2.distanceTransform(255 - mask, cv2.DIST_L2, 3)
    h, w = mask.shape
    hor = sorted(hor, key=lambda l: _inter(l, np.array([1.0, 0, -w / 2]))[1])  # sort by y at x=w/2
    ver = sorted(ver, key=lambda l: _inter(l, np.array([0, 1.0, -h / 2]))[0])  # sort by x at y=h/2
    best = (None, 0.0)
    S0 = np.diag([1 / scale, 1 / scale, 1])
    hy = list(itertools.combinations(HL, 2))
    vx = list(itertools.combinations(VL, 2))
    hor, ver = hor[:9], ver[:7]
    for (i, j) in itertools.combinations(range(len(hor)), 2):
        for (k, l) in itertools.combinations(range(len(ver)), 2):
            pts = [_inter(hor[a], ver[b]) for a in (i, j) for b in (k, l)]
            if any(p is None for p in pts): continue
            img_pts = np.float32(pts)  # TL, TR, BL, BR (top line first, left first)
            for (y0, y1), (x0, x1) in itertools.product(hy, vx):
                mod = np.float32([[x0, y0], [x1, y0], [x0, y1], [x1, y1]])
                Hm2i = cv2.getPerspectiveTransform(mod, img_pts)
                c = cv2.perspectiveTransform(np.float32([[[0, 0], [W, 0], [0, L], [W, L]]]), Hm2i)[0]
                if not (c[0, 0] < c[1, 0] and c[2, 0] < c[3, 0] and c[0, 1] < c[2, 1] and c[1, 1] < c[3, 1]): continue
                if (c[3, 0] - c[2, 0]) < 0.3 * w or (c[2, 1] - c[0, 1]) < 0.3 * h: continue
                p = cv2.perspectiveTransform(SAMPLES[None].astype(np.float32), Hm2i)[0]
                ok = (p[:, 0] >= 0) & (p[:, 0] < w - 1) & (p[:, 1] >= 0) & (p[:, 1] < h - 1)
                if ok.mean() < 0.85: continue
                d = np.full(len(p), 99.0); q = p[ok].astype(int)
                d[ok] = dist[q[:, 1], q[:, 0]]
                sc = (d < 2.5).mean()
                if sc > best[1] and plausible(S0 @ Hm2i, w / scale, h / scale):
                    best = (Hm2i, sc)
    if best[0] is None: return None, 0.0
    S = np.diag([1 / scale, 1 / scale, 1])
    Hm2i = S @ best[0]
    return Hm2i, best[1]  # model(m) -> image(px)

def to_court(Hm2i, pts):
    Hi2m = np.linalg.inv(Hm2i)
    return cv2.perspectiveTransform(np.float32(pts).reshape(-1, 1, 2), Hi2m).reshape(-1, 2)

def to_img(Hm2i, pts):
    return cv2.perspectiveTransform(np.float32(pts).reshape(-1, 1, 2), Hm2i).reshape(-1, 2)

def plausible(Hm2i, w=1920, h=1080):
    """Reject degenerate fits (side/replay angles): convex quad, sane angles, far edge not tiny, corners near the frame."""
    c = to_img(Hm2i, [(0, 0), (W, 0), (W, L), (0, L)])  # TL, TR, BR, BL (clockwise)
    if np.any(c[:, 0] < -0.15 * w) or np.any(c[:, 0] > 1.15 * w) or np.any(c[:, 1] < -0.15 * h) or np.any(c[:, 1] > 1.15 * h):
        return False
    for k in range(4):
        a, b, d = c[k - 1], c[k], c[(k + 1) % 4]
        u, v = a - b, d - b
        ang = np.degrees(np.arccos(np.clip(np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-9), -1, 1)))
        if not 25 < ang < 155: return False
    far, near = np.linalg.norm(c[1] - c[0]), np.linalg.norm(c[2] - c[3])
    return far / (near + 1e-9) > 0.3
