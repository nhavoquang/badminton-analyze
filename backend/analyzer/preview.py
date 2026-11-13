"""One-frame preview for the app: court lines and where each named player slot would land."""
import cv2
import numpy as np

from . import court, track

_model = None


def _yolo():
    global _model
    if _model is None:
        from ultralytics import YOLO
        _model = YOLO('yolo11s.pt')
    return _model


def court_lines(H, w, h, n=24):
    """Court model lines in frame fractions, cut where they pass behind the camera."""
    out = []
    for a, b in court.SEG:
        t = np.linspace(0, 1, n)[:, None]
        pts = np.array(a) * (1 - t) + np.array(b) * t
        hom = np.c_[pts, np.ones(n)] @ np.array(H).T
        ok = hom[:, 2] > 1e-6
        xy = hom[:, :2] / np.where(ok, hom[:, 2], 1)[:, None]
        run = []
        for good, p in zip(ok, xy):
            if good: run.append([round(p[0] / w, 4), round(p[1] / h, 4)])
            elif len(run) > 1: out.append(run); run = []
            else: run = []
        if len(run) > 1: out.append(run)
    return out


def run(img, marks=None):
    h, w = img.shape[:2]
    if marks:
        H, mode = court.from_marks(marks, w, h), 'manual'
    else:
        H, sc = court.fit(img)
        if H is None or sc < 0.5 or not court.plausible(H, w, h):
            return {'court': None, 'players': [], 'message': 'Không tự nhận ra sân ở khung hình này. Hãy dùng Tự chấm sân.'}
        mode = 'auto'
    r = _yolo().predict(img, imgsz=1280, classes=[0], conf=0.3, verbose=False)[0]
    dets = [b + [c] for b, c in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist())]
    players = []
    for side in ('far', 'near'):
        c = [p for p in track.foot_points(H, dets) if (p['xy'][1] < track.NET_Y) == (side == 'far') and p['conf'] >= 0.4]
        c.sort(key=lambda p: -p['conf'])
        keep = []
        for p in c:
            if all(np.linalg.norm(p['xy'] - q['xy']) > 0.6 for q in keep): keep.append(p)
        keep = keep[:2]
        keep.sort(key=lambda p: p['xy'][0])  # slot 0 = left side of the court, as in tracking
        if len(keep) == 1 and keep[0]['xy'][0] >= court.W / 2:
            keep = [None, keep[0]]
        for j, p in enumerate(keep):
            if p is None: continue
            x0, y0, x1, y1 = p['box']
            players.append({'slot': f'{side}{j}', 'box': [round(x0 / w, 4), round(y0 / h, 4), round(x1 / w, 4), round(y1 / h, 4)],
                            'court_xy': [round(float(p['xy'][0]), 2), round(float(p['xy'][1]), 2)]})
    msg = None if players else 'Chưa thấy người chơi nào trong sân ở khung hình này.'
    return {'mode': mode, 'court': court_lines(H, w, h), 'players': players, 'message': msg}
