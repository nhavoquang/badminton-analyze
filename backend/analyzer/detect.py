"""Pass 1: scene cuts, court homography per shot, person detections on court frames -> JSON."""
import sys, json, cv2, numpy as np
from ultralytics import YOLO
from . import court

def run(video, out_json, model_name='yolo11s.pt', imgsz=1280, progress=None):
    cap = cv2.VideoCapture(video)
    fps = cap.get(cv2.CAP_PROP_FPS); n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    model = YOLO(model_name)
    frames = []; prev = None; shot = 0; H = None; last_try = -999; last_fit = -999
    i = 0
    while True:
        ok, img = cap.read()
        if not ok: break
        thumb = cv2.resize(img, (160, 90)).astype(np.float32)
        if prev is not None and np.abs(thumb - prev).mean() > 25:
            shot += 1; H = None; last_try = -999; last_fit = -999
        prev = thumb
        # (re)fit court: every 15 frames while unknown, every 60 frames to follow small pans
        if (H is None and i - last_try >= 15) or (H is not None and i - last_fit >= 60):
            last_try = i
            Hn, sc = court.fit(img)
            if Hn is not None and sc > 0.7:
                H, last_fit = Hn, i
            elif H is not None and sc < 0.3:
                H = None  # view changed without a hard cut
        rec = {'i': i, 'shot': shot, 'H': None, 'dets': []}
        if H is not None:
            rec['H'] = H.tolist()
            r = model.predict(img, imgsz=imgsz, classes=[0], conf=0.3, verbose=False)[0]
            for b, c in zip(r.boxes.xyxy.tolist(), r.boxes.conf.tolist()):
                rec['dets'].append([round(v, 1) for v in b] + [round(c, 3)])
        frames.append(rec)
        if i % 30 == 0 and progress: progress(i / max(n, 1))
        i += 1
    json.dump({'fps': fps, 'frames': frames}, open(out_json, 'w'))

