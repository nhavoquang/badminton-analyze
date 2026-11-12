"""Command line: python cli.py input.mp4 out_dir [--start 12] [--duration 30]"""
import argparse

from analyzer import pipeline

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('video'); ap.add_argument('out_dir')
    ap.add_argument('--start', type=float); ap.add_argument('--duration', type=float)
    a = ap.parse_args()
    out, stats = pipeline.run(a.video, a.out_dir, a.start, a.duration,
                              progress=lambda s, f, o: print(f'\r{s:8s} {o * 100:5.1f}%', end='', flush=True))
    print('\n', out)
    for p in stats['players']: print(p)
