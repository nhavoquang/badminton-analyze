"""Path to an ffmpeg binary: the one on PATH, else the copy bundled with imageio-ffmpeg (pip)."""
import shutil


def ffmpeg():
    exe = shutil.which('ffmpeg')
    if exe: return exe
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        raise RuntimeError('Không tìm thấy ffmpeg. Chạy: pip install imageio-ffmpeg') from None
