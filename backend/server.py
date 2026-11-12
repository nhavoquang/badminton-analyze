"""HTTP API used by the iOS app.

POST /jobs              multipart: video=<file>, options=<json>  -> {"id": ...}
GET  /jobs/{id}         -> {"status", "step", "progress", "error"}
GET  /jobs/{id}/video   -> annotated mp4 (with the original audio)
GET  /jobs/{id}/stats   -> per-player stats json

options: {"start": 12.0, "duration": 30, "layers": ["feet","path","hits","speed","map"],
          "names": {"near0": "Huy", "near1": "Dung", "far0": "Vương", "far1": "Vui"}}
Run:  uvicorn server:app --host 0.0.0.0 --port 8000
"""
import json
import os
import queue
import threading
import uuid

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

from analyzer import pipeline

DATA = os.environ.get('DATA_DIR', os.path.join(os.path.dirname(__file__), 'data'))
os.makedirs(DATA, exist_ok=True)
app = FastAPI(title='Badminton Analyze')
JOBS = {}
Q = queue.Queue()


def worker():
    while True:
        jid = Q.get()
        job = JOBS[jid]
        job['status'] = 'running'

        def prog(step, _frac, overall):
            job['step'], job['progress'] = step, round(overall, 3)
        try:
            pipeline.run(job['src'], job['dir'], job['opts'].get('start'), job['opts'].get('duration'),
                         job['opts'].get('layers'), job['opts'].get('names'), prog)
            job['status'], job['progress'] = 'done', 1.0
        except Exception as e:  # report to the app instead of crashing the worker
            job['status'], job['error'] = 'failed', str(e)


threading.Thread(target=worker, daemon=True).start()


@app.post('/jobs')
async def create_job(video: UploadFile = File(...), options: str = Form('{}')):
    jid = uuid.uuid4().hex[:12]
    d = os.path.join(DATA, jid); os.makedirs(d)
    src = os.path.join(d, 'source' + os.path.splitext(video.filename or '.mp4')[1])
    with open(src, 'wb') as f:
        while chunk := await video.read(1 << 20):
            f.write(chunk)
    JOBS[jid] = {'id': jid, 'dir': d, 'src': src, 'opts': json.loads(options or '{}'),
                 'status': 'queued', 'step': None, 'progress': 0.0, 'error': None}
    Q.put(jid)
    return {'id': jid}


def _job(jid):
    if jid not in JOBS: raise HTTPException(404, 'job not found')
    return JOBS[jid]


@app.get('/jobs/{jid}')
def job_status(jid: str):
    j = _job(jid)
    return {k: j[k] for k in ('id', 'status', 'step', 'progress', 'error')}


@app.get('/jobs/{jid}/video')
def job_video(jid: str):
    p = os.path.join(_job(jid)['dir'], 'result.mp4')
    if not os.path.exists(p): raise HTTPException(409, 'not ready')
    return FileResponse(p, media_type='video/mp4', filename=f'badminton-{jid}.mp4')


@app.get('/jobs/{jid}/stats')
def job_stats(jid: str):
    p = os.path.join(_job(jid)['dir'], 'stats.json')
    if not os.path.exists(p): raise HTTPException(409, 'not ready')
    return json.load(open(p))
