"""End-to-end pipeline: (optional) trim -> detect -> track -> render, keeping the original audio."""
import json
import os
import subprocess

import numpy as np

from . import detect, render, track

STEPS = ['court', 'players', 'shuttle', 'hits', 'render']


def trim(src, dst, start=None, duration=None):
    """Cut [start, start+duration] and KEEP the audio track (re-encode video for frame-accurate cuts)."""
    cmd = ['ffmpeg', '-v', 'error', '-y']
    if start: cmd += ['-ss', str(start)]
    cmd += ['-i', src]
    if duration: cmd += ['-t', str(duration)]
    cmd += ['-map', '0:v:0', '-map', '0:a?', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-c:a', 'aac', '-b:a', '192k', dst]
    subprocess.run(cmd, check=True)
    return dst


def stats_json(players, fps, names=None):
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
        })
    return out


def _zones(p):
    y = np.asarray(p['Y'])
    depth = np.where(p['side'] == 'far', y, 13.4 - y)  # metres from own baseline
    back = float(np.mean(depth < 2.5)); net = float(np.mean(depth > 4.7))
    return {'net': round(net, 2), 'mid': round(1 - net - back, 2), 'back': round(back, 2)}


def run(src, work_dir, start=None, duration=None, layers=None, names=None, progress=None):
    """progress(step_name, fraction_of_step, overall_fraction)"""
    os.makedirs(work_dir, exist_ok=True)
    weights = {'court': 0.05, 'players': 0.6, 'shuttle': 0.0, 'hits': 0.0, 'render': 0.35}
    done = 0.0

    def rep(step):
        def f(x):
            if progress: progress(step, x, done + weights[step] * x)
        return f

    clip = os.path.join(work_dir, 'clip.mp4')
    trim(src, clip, start, duration)
    rep('court')(1.0); done += weights['court']

    det = os.path.join(work_dir, 'det.json')
    detect.run(clip, det, progress=rep('players'))
    done += weights['players']

    out = os.path.join(work_dir, 'result.mp4')
    players = render.run(clip, det, out, layers=set(layers) if layers else None, names=names, progress=rep('render'))
    done += weights['render']
    fps = json.load(open(det))['fps']
    stats = {'players': stats_json(players, fps, names)}
    json.dump(stats, open(os.path.join(work_dir, 'stats.json'), 'w'), ensure_ascii=False, indent=1)
    if progress: progress('render', 1.0, 1.0)
    return out, stats
