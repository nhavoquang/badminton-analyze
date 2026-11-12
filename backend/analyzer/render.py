"""Pass 3: draw overlay (foot ellipses on the court plane, labels, mini-map, stat cards) and encode video."""
import sys, subprocess, cv2, numpy as np
from PIL import Image, ImageDraw, ImageFont
from . import court, tools, track

import os
FONT_DIRS = [os.environ.get('ANALYZER_FONT_DIR', ''), '/usr/share/fonts/opentype/inter', '/usr/share/fonts/truetype/inter']
def font(w, s):
    for d in FONT_DIRS:
        for ext in ('otf', 'ttf'):
            p = os.path.join(d, f'Inter-{w}.{ext}')
            if d and os.path.exists(p): return ImageFont.truetype(p, s)
    win = os.path.join(os.environ.get('WINDIR', r'C:\Windows'), 'Fonts')
    seg = os.path.join(win, 'segoeuib.ttf' if w == 'Bold' else 'seguisb.ttf')
    for p in (seg, os.path.join(win, 'segoeui.ttf'), '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 'DejaVuSans.ttf'):
        try: return ImageFont.truetype(p, s)
        except OSError: pass
    return ImageFont.load_default()
_FONTS = {}
def fonts(w, s):
    s = max(8, s)
    if (w, s) not in _FONTS: _FONTS[(w, s)] = font(w, s)
    return _FONTS[(w, s)]
COL = {('far', 0): (45, 212, 191), ('far', 1): (167, 139, 250), ('near', 0): (251, 191, 36), ('near', 1): (251, 113, 133)}
NAMES = {('far', 0): 'Sân xa', ('far', 1): 'Sân xa 2', ('near', 0): 'Sân gần', ('near', 1): 'Sân gần 2'}
PANEL = (17, 20, 32, 210)

NAMES_OVERRIDE = {}  # e.g. {'near0': 'Huy'} from the app

def name_of(p, all_p):
    key = f"{p['side']}{p['slot']}"
    if key in NAMES_OVERRIDE and NAMES_OVERRIDE[key]: return NAMES_OVERRIDE[key]
    two = sum(1 for q in all_p if q['shot'] == p['shot'] and q['side'] == p['side']) > 1
    base = 'Sân xa' if p['side'] == 'far' else 'Sân gần'
    return f"{base} {p['slot'] + 1}" if two else base

def circle_poly(H, x, y, r=0.5, n=48):
    a = np.linspace(0, 2 * np.pi, n, endpoint=False)
    return court.to_img(H, np.stack([x + r * np.cos(a), y + r * np.sin(a)], 1)).astype(np.int32)

def draw_frame(img, i, fr, players, all_p, fps, shot_start, layers=None, sh=None):
    layers = layers or {'feet', 'speed', 'map', 'path', 'hits'}
    H = np.array(fr['H']) if fr['H'] is not None else None
    act = [p for p in players if p['t0'] <= i <= p['t1']] if H is not None else []
    lw = lambda v: max(1, round(v * min(img.shape[:2]) / 1080))
    # --- on-court layer (cv2, alpha blended): trails + foot ellipses
    if act and 'feet' in layers:
        ov = img.copy()
        for p in act:
            k = i - p['t0']; c = COL[(p['side'], p['slot'])][::-1]
            a = max(0, k - int(fps * 1.0))
            trail = court.to_img(H, np.stack([p['X'][a:k + 1], p['Y'][a:k + 1]], 1)).astype(np.int32)
            if len(trail) > 1: cv2.polylines(ov, [trail], False, c, lw(4), cv2.LINE_AA)
            cv2.fillPoly(ov, [circle_poly(H, p['X'][k], p['Y'][k])], c, cv2.LINE_AA)
        img = cv2.addWeighted(ov, 0.35, img, 0.65, 0)
        for p in act:
            k = i - p['t0']; c = COL[(p['side'], p['slot'])][::-1]
            cv2.polylines(img, [circle_poly(H, p['X'][k], p['Y'][k])], True, c, lw(3), cv2.LINE_AA)
    if sh and H is not None:
        img = draw_shuttle(img, i, sh, fps, layers)
    # --- UI layer (PIL); sizes are designed for 1080p and scaled to the frame (portrait phone videos too)
    im = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB)).convert('RGBA')
    ui = Image.new('RGBA', im.size, (0, 0, 0, 0)); d = ImageDraw.Draw(ui)
    W, Hh = im.size
    u = min(W, Hh) / 1080
    S = lambda v: v * u
    f_title, f_sub, f_name, f_big, f_small, f_tag = (fonts(w, round(z * u)) for w, z in
                                                    (('Bold', 30), ('Medium', 18), ('Bold', 24), ('Bold', 46), ('Medium', 17), ('Bold', 22)))
    m = S(24)
    # header
    hw = min(S(616), W - 2 * m - (S(34) * court.W + S(48) if act and 'map' in layers else 0))
    d.rounded_rectangle((m, S(20), m + hw, S(104)), S(16), fill=PANEL)
    d.text((m + S(20), S(30)), 'PHÂN TÍCH CẦU LÔNG', font=f_title, fill='white')
    d.text((m + S(20), S(70)), 'Tốc độ · Quãng đường · Vị trí', font=f_sub, fill=(180, 186, 200))
    if act:
        t = (i - shot_start) / fps
        d.text((m + hw - S(20), S(70)), f'{int(t // 60):02d}:{t % 60:04.1f}', font=f_sub, fill='white', anchor='ra')
    elif H is None:
        d.rounded_rectangle((m, S(116), m + S(376), S(156)), S(12), fill=PANEL)
        d.text((m + S(16), S(125)), 'Cảnh quay phụ · tạm dừng phân tích', font=f_small, fill=(180, 186, 200))
    if sh and 'hits' in layers and H is not None: hit_labels(d, i, sh, fps, all_p, u, f_tag)
    for p in (act if 'speed' in layers else []):
        k = i - p['t0']; c = COL[(p['side'], p['slot'])]
        bx = p['boxf'][i]; cx, top = (bx[0] + bx[2]) / 2, bx[1]
        label = name_of(p, all_p); sp = f"{p['v'][k]:.1f}"
        tw = d.textlength(label, font=f_tag) + d.textlength(sp, font=f_tag) + S(56)
        x0, y0 = cx - tw / 2, top - S(52)
        d.rounded_rectangle((x0, y0, x0 + tw, y0 + S(38)), S(19), fill=PANEL, outline=c + (255,), width=max(1, round(S(2))))
        d.ellipse((x0 + S(12), y0 + S(13), x0 + S(24), y0 + S(25)), fill=c)
        d.text((x0 + S(32), y0 + S(19)), label, font=f_tag, fill='white', anchor='lm')
        d.text((x0 + tw - S(12), y0 + S(19)), sp, font=f_tag, fill=c, anchor='rm')
        d.polygon([(cx - S(7), y0 + S(38)), (cx + S(7), y0 + S(38)), (cx, y0 + S(46))], fill=c)
    if act and 'map' in layers:
        # mini-map (top-down court), top right
        s = S(34); mw, mh = court.W * s, court.L * s; mx, my = W - mw - S(48), S(48)
        d.rounded_rectangle((mx - S(24), my - S(24), mx + mw + S(24), my + mh + S(24)), S(16), fill=PANEL)
        for (a, b) in court.SEG:
            d.line([(mx + a[0] * s, my + a[1] * s), (mx + b[0] * s, my + b[1] * s)], fill=(200, 205, 215, 200), width=max(1, round(S(2))))
        d.line([(mx - S(10), my + court.L / 2 * s), (mx + mw + S(10), my + court.L / 2 * s)], fill=(255, 255, 255, 255), width=max(1, round(S(4))))
        for p in act:
            k = i - p['t0']; c = COL[(p['side'], p['slot'])]
            a = max(0, k - int(fps * 3))
            pts = [(mx + x * s, my + y * s) for x, y in zip(p['X'][a:k + 1:3], p['Y'][a:k + 1:3])]
            if len(pts) > 1: d.line(pts, fill=c + (170,), width=max(1, round(S(4))), joint='curve')
            x, y = mx + p['X'][k] * s, my + p['Y'][k] * s
            d.ellipse((x - S(10), y - S(10), x + S(10), y + S(10)), fill=c, outline='white', width=max(1, round(S(2))))
    if act and 'speed' in layers:
        # stat cards along the bottom, wrapping into rows on narrow (portrait) frames
        gap = S(16); per_row = max(1, min(len(act), int((W - 2 * m + gap) // (S(330) + gap))))
        if W < Hh: per_row = min(len(act), 2)  # portrait: 2 x 2 grid
        cw = min(S(330) if W > Hh else 1e9, (W - 2 * m - (per_row - 1) * gap) / per_row); ch = S(150)
        rows = (len(act) + per_row - 1) // per_row
        for n, p in enumerate(sorted(act, key=lambda q: (q['side'] != 'far', q['slot']))):
            k = i - p['t0']; c = COL[(p['side'], p['slot'])]
            x0 = m + (n % per_row) * (cw + gap); y0 = Hh - m - (rows - n // per_row) * (ch + gap) + gap
            d.rounded_rectangle((x0, y0, x0 + cw, y0 + ch), S(16), fill=PANEL)
            d.rectangle((x0, y0 + S(16), x0 + S(5), y0 + ch - S(16)), fill=c)
            d.text((x0 + S(22), y0 + S(14)), name_of(p, all_p), font=f_name, fill='white')
            d.text((x0 + cw - S(70), y0 + S(8)), f"{p['v'][k]:.1f}", font=f_big, fill=c, anchor='ra')
            d.text((x0 + cw - S(18), y0 + S(26)), 'km/h', font=f_small, fill=(180, 186, 200), anchor='ra')
            d.text((x0 + S(22), y0 + S(66)), f"Tối đa {p['vmax'][k]:.1f} km/h  ·  {p['dist'][k]:.1f} m", font=f_small, fill=(200, 205, 215))
            a = max(0, k - int(fps * 6)); vs = p['v'][a:k + 1]
            if len(vs) > 1:
                gx0, gx1, gy0, gy1 = x0 + S(22), x0 + cw - S(18), y0 + S(100), y0 + ch - S(14)
                xs = np.linspace(gx0, gx1, int(fps * 6) + 1)[-len(vs):]
                ys = gy1 - np.clip(vs / 25, 0, 1) * (gy1 - gy0)
                d.line(list(zip(xs, ys)), fill=c, width=max(1, round(S(2))))
                d.ellipse((xs[-1] - S(4), ys[-1] - S(4), xs[-1] + S(4), ys[-1] + S(4)), fill='white')
    return cv2.cvtColor(np.array(Image.alpha_composite(im, ui).convert('RGB')), cv2.COLOR_RGB2BGR)

SHUTTLE = (10, 214, 255)  # BGR of iOS yellow #FFD60A


def draw_shuttle(img, i, sh, fps, layers):
    pts = sh['pts']; u = min(img.shape[:2]) / 1080
    lw = lambda v: max(1, round(v * u))
    if 'path' in layers:
        trail = [pts.get(f) for f in range(i - int(fps * 0.5), i + 1)]
        segs = [(a, b) for a, b in zip(trail, trail[1:]) if a is not None and b is not None]
        for n, (a, b) in enumerate(segs):
            w = lw(2 + 4 * (n + 1) / len(segs))
            cv2.line(img, (int(a[0]), int(a[1])), (int(b[0]), int(b[1])), SHUTTLE, w, cv2.LINE_AA)
        if pts.get(i):
            p = tuple(int(v) for v in pts[i])
            cv2.circle(img, p, lw(9), SHUTTLE, -1, cv2.LINE_AA); cv2.circle(img, p, lw(9), (255, 255, 255), lw(2), cv2.LINE_AA)
    if 'hits' in layers:
        for h in sh['hits']:
            age = i - h['f']
            if 0 <= age < fps * 1.0:
                r = lw(14 + age / fps * 30)
                cv2.circle(img, (int(h['xy'][0]), int(h['xy'][1])), r, (255, 255, 255), lw(3), cv2.LINE_AA)
    return img


def hit_labels(d, i, sh, fps, all_p, u=1.0, f_tag=None):
    f_tag = f_tag or fonts('Bold', 22)
    for h in sh['hits']:
        age = i - h['f']
        if 0 <= age < fps * 1.2:
            txt = f"CÚ ĐÁNH · {h['name']}"
            x, y = h['xy'][0], h['xy'][1] - 95 * u
            tw = d.textlength(txt, font=f_tag) + 28 * u
            d.rounded_rectangle((x - tw / 2, y - 20 * u, x + tw / 2, y + 20 * u), 20 * u, fill=(255, 214, 10, 235))
            d.text((x, y), txt, font=f_tag, fill=(0, 0, 0), anchor='mm')


def assign_hits(cands, pts, players, fps):
    """Keep direction flips that happen within racket reach of a player; attach the hitter and the
    average shuttle speed to the next hit (ground distance between the two hitters / flight time)."""
    hits = []
    for f in cands:
        x, y = pts[f]
        best = None
        for p in players:
            if not (p['t0'] <= f <= p['t1']): continue
            b = p['boxf'][f]; w, h = b[2] - b[0], b[3] - b[1]
            # racket reach: around the upper body, about one body height above and to the sides
            zx0, zx1, zy0, zy1 = b[0] - 0.9 * w, b[2] + 0.9 * w, b[1] - 0.9 * h, b[1] + 0.7 * h
            if zx0 <= x <= zx1 and zy0 <= y <= zy1:
                d = np.hypot(x - (b[0] + b[2]) / 2, y - (b[1] + 0.15 * h)) / h
                if best is None or d < best[0]: best = (d, p)
        if best:
            p = best[1]; k = f - p['t0']
            hits.append({'f': f, 'xy': (x, y), 'key': f"{p['side']}{p['slot']}", 'name': name_of(p, players),
                         'pos': (float(p['X'][k]), float(p['Y'][k])), 'shot': p['shot']})
    for a, b in zip(hits, hits[1:]):
        if a['shot'] == b['shot'] and a['key'] != b['key']:
            dt = (b['f'] - a['f']) / fps
            dist = np.hypot(a['pos'][0] - b['pos'][0], a['pos'][1] - b['pos'][1])
            if 0.15 < dt < 3: a['kmh'] = dist / dt * 3.6
    return hits


def run(video, det_json, out_mp4, layers=None, names=None, progress=None, shuttle_json=None):
    D, players = track.run(det_json)
    if names: NAMES_OVERRIDE.update(names)
    fps = D['fps']; F = D['frames']
    sh = None
    if shuttle_json:
        import json
        S = json.load(open(shuttle_json))
        pts = {int(k): tuple(v) for k, v in S['pts'].items()}
        sh = {'pts': pts, 'hits': assign_hits([c for c in S['cands'] if c in pts], pts, players, fps)}
        json.dump([{k: v for k, v in h.items()} for h in sh['hits']], open(shuttle_json.replace('.json', '_hits.json'), 'w'))
    cap = cv2.VideoCapture(video)
    w, h = int(cap.get(3)), int(cap.get(4))
    enc = subprocess.Popen([tools.ffmpeg(), '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', f'{w}x{h}', '-r', str(fps), '-i', '-',
                            '-i', video, '-map', '0:v', '-map', '1:a?', '-c:v', 'libx264', '-preset', 'medium', '-crf', '20', '-pix_fmt', 'yuv420p',
                            '-c:a', 'aac', '-shortest', '-movflags', '+faststart', out_mp4], stdin=subprocess.PIPE)
    starts = {}
    for p in players: starts[p['shot']] = min(starts.get(p['shot'], 1e9), p['t0'])
    for i, fr in enumerate(F):
        ok, img = cap.read()
        if not ok: break
        out = draw_frame(img, i, fr, [p for p in players if p['shot'] == fr['shot']], players, fps, starts.get(fr['shot'], i), layers, sh)
        enc.stdin.write(out.tobytes())
        if i % 30 == 0 and progress: progress(i / max(len(F), 1))
    enc.stdin.close(); enc.wait()
    run.hits = sh['hits'] if sh else []
    return players

