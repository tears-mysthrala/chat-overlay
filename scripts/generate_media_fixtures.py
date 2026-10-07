"""Development-only synthetic input fixtures; generator never receives user bytes."""
from pathlib import Path
import subprocess

image = "sha256:442d24edf3941083e3daa643a12b96dd8a54593f4fd3fc9ebd7bcc14c757bcc2"
output = Path("test/fixtures/media")
output.mkdir(parents=True, exist_ok=True)
cases = {
    "static.webp": ["-f", "lavfi", "-i", "color=c=blue:s=2x2", "-frames:v", "1", "-c:v", "libwebp", "-lossless", "1", "-f", "webp"],
    "animated.webp": ["-f", "lavfi", "-i", "testsrc=s=16x16:r=2:d=1", "-frames:v", "2", "-c:v", "libwebp_anim", "-loop", "0", "-f", "webp"],
    "audio.mp3": ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-c:a", "libmp3lame", "-f", "mp3"],
    "audio.ogg": ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-c:a", "libvorbis", "-f", "ogg"],
    "audio.webm": ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-c:a", "libopus", "-f", "webm"],
}
for name, args in cases.items():
    data = subprocess.check_output(["docker", "run", "--rm", "--network", "none",
        "--read-only", "--cap-drop", "ALL", "--memory", "256m", "--pids-limit", "32",
        "--entrypoint", "ffmpeg", image, "-v", "error", *args, "pipe:1"], timeout=10)
    (output / name).write_bytes(data)
    print(name, len(data))
