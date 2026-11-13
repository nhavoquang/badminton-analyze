"""End-to-end pipeline: (optional) trim -> detect -> track -> render, keeping the original audio."""
import json
import os
import subprocess

import numpy as np

from . import detect, render, shuttle, tools, track

STEPS = ['court', 'players', 'shuttle', 'hits', 'render']


def trim(src, dst, start=None, duration=None):
    """Cut [start, start+duration] and KEEP the audio track (re-encode video for frame-accurate cuts)."""
    cmd = [tools.ffmpeg(), '-v', 'error', '-y']
    if start: cmd += ['-ss', str(start)]
    cmd += ['-i', src]
    if duration: cmd += ['-t', str(duration)]
    cmd += ['-map', '0:v:0', '-map', '0:a?', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-c:a', 'aac', '-b:a', '192k', dst]
    subprocess.run(cmd, check=True)
    return dst


def stats_json(players, fps, names=None, hits=()):
    names = names or {}
    out = []
    for p in players:
        key = f"{p['side']}{p['slot']}"
        out.append({
            'id': key,
            'name': names.get(key) or render.name_of(p, players),
            'side': p['side'],
            'shot': p['shot'],
            'start_s': round(p['t0'] / fps, 2),
            'end_s': round(p['t1'] / fps, 2),
            'max_speed_kmh': round(float(p['vmax'][-1]), 1),
            'avg_speed_kmh': round(float(np.mean(p['v'])), 1),
            'distance_m': round(float(p['dist'][-1]), 1),
            # time share by court zone (depth from own baseline): net / mid / back
            'zones': _zones(p),
            'hits': sum(1 for h in hits if h['key'] == key and p['t0'] <= h['f'] <= p['t1']),
            'fastest_shot_kmh': max([round(h['kmh'], 1) for h in hits if h['key'] == key and h.get('kmh') and p['t0'] <= h['f'] <= p['t1']], default=None),
        })
    return out


def _zones(p):
    y = np.asarray(p['Y'])
    depth = np.where(p['side'] == 'far', y, 13.4 - y)  # metres from own baseline
    back = float(np.mean(depth < 2.5)); net = float(np.mean(depth > 4.7))
    return {'net': round(net, 2), 'mid': round(1 - net - back, 2), 'back': round(back, 2)}


def run(src, work_dir, start=None, duration=None, layers=None, names=None, progress=None, marks=None, seed=None, colors=None):
    """seed: {'t': seconds into the clip, 'players': {slot: [x, y] court metres}} from the app's preview."""
    """progress(step_name, fraction_of_step, overall_fraction)"""
    os.makedirs(work_dir, exist_ok=True)
    weights = {'court': 0.05, 'players': 0.4, 'shuttle': 0.3, 'hits': 0.0, 'render': 0.25}
    done = 0.0

    def rep(step):
        def f(x):
            if progress: progress(step, x, done + weights[step] * x)
        return f

    clip = os.path.join(work_dir, 'clip.mp4')
    trim(src, clip, start, duration)
    rep('court')(1.0); done += weights['court']

    det = os.path.join(work_dir, 'det.json')
    detect.run(clip, det, progress=rep('players'), marks=marks)
    done += weights['players']

    sh_json = None
    if shuttle_available():
        sh_json = os.path.join(work_dir, 'shuttle.json')
        track_shuttle(clip, det, sh_json, rep('shuttle'))
    done += weights['shuttle']

    out = os.path.join(work_dir, 'result.mp4')
    players = render.run(clip, det, out, layers=set(layers) if layers else None, names=names,
                         progress=rep('render'), shuttle_json=sh_json,
                         seed=dict(f=round(seed.get('t', 0) * json.load(open(det, encoding='utf-8'))['fps']), players=seed.get('players')) if seed else None,
                         colors=colors)
    done += weights['render']
    fps = json.load(open(det, encoding='utf-8'))['fps']
    hits = getattr(render.run, 'hits', [])
    stats = {'players': stats_json(players, fps, names, hits),
             'hits': [{'t': round(h['f'] / fps, 2), 'player': h['key'], 'kmh': round(h['kmh'], 1) if h.get('kmh') else None} for h in hits]}
    json.dump(stats, open(os.path.join(work_dir, 'stats.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    if progress: progress('render', 1.0, 1.0)
    return out, stats


def shuttle_available():
    path = os.environ.get('TRACKNET_WEIGHTS') or shuttle.DEFAULT_WEIGHTS
    return os.path.exists(path)


def track_shuttle(clip, det_json, out_json, progress=None):
    """Run TrackNet on every main-camera shot (frames that have a court homography)."""
    import cv2
    from . import court
    D = json.load(open(det_json, encoding='utf-8')); F = D['frames']
    for f in F:
        if f['H'] is not None and not D.get('manual') and not court.plausible(np.array(f['H']), D.get('w', 1920), D.get('h', 1080)):
            f['H'] = None
    fps = json.load(open(det_json, encoding='utf-8'))['fps']
    runs, cur = [], None
    for f in F:
        if f['H'] is not None and (cur is None or f['shot'] != cur[2] or f['i'] != cur[1]):
            if cur: runs.append(cur)
            cur = [f['i'], f['i'] + 1, f['shot']]
        elif f['H'] is not None:
            cur[1] = f['i'] + 1
    if cur: runs.append(cur)
    total = sum(b - a for a, b, _ in runs) or 1
    boxes = {f['i']: f.get('dets', []) for f in F}
    model = shuttle.load()
    cap = cv2.VideoCapture(clip)
    width = cap.get(cv2.CAP_PROP_FRAME_WIDTH)
    pts, cands, done = {}, [], 0
    for a, b, _ in runs:
        raw = shuttle.track_segment(model, cap, a, b,
                                    progress=(lambda x, a=a, b=b: progress((done + x * (b - a)) / total)) if progress else None)
        raw = shuttle.merge(raw, shuttle.motion_candidates(cap, a, b, boxes), width)
        seg = shuttle.clean(shuttle.pick(raw, fps, width), fps, width=width)
        pts.update(seg)
        cands += shuttle.find_hits(seg, fps)
        done += b - a
    json.dump({'pts': {str(k): [round(v[0], 1), round(v[1], 1)] for k, v in pts.items()}, 'cands': cands}, open(out_json, 'w', encoding='utf-8'))
    return out_json
