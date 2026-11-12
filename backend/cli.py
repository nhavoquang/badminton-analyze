"""Command line: python cli.py input.mp4 out_dir [--start 12] [--duration 30] [--court x,y x,y x,y x,y]"""
import argparse

from analyzer import pipeline

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('video'); ap.add_argument('out_dir')
    ap.add_argument('--start', type=float); ap.add_argument('--duration', type=float)
    ap.add_argument('--court', nargs=4, help='far-left, far-right, right post, left post as x,y fractions')
    a = ap.parse_args()
    out, stats = pipeline.run(a.video, a.out_dir, a.start, a.duration,
                              marks=[tuple(map(float, c.split(','))) for c in a.court] if a.court else None,
                              progress=lambda s, f, o: print(f'\r{s:8s} {o * 100:5.1f}%', end='', flush=True))
    print('\n', out)
    for p in stats['players']: print(p)
