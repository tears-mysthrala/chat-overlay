"""Disposable offline decoder. Only fixed paths and enumerated categories reach FFmpeg."""
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import time
import wave
import zlib

LIMITS = {"image": 524288, "audio": 2097152}


def regular_bytes(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= maximum:
            raise ValueError("invalid_file")
        data = source.read(maximum + 1)
        if len(data) != info.st_size or len(data) > maximum:
            raise ValueError("file_changed")
        return data


def validate_output(data, category):
    """Independent coordinator check: bounded static PNG or mono PCM WAV only."""
    if category not in LIMITS or not 0 < len(data) <= LIMITS[category]:
        raise ValueError("output_size")
    if category == "audio":
        import io
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE" or len(data) < 44 or int.from_bytes(data[4:8], "little") + 8 != len(data):
            raise ValueError("output_audio_container")
        offset, chunks = 12, []
        while offset < len(data):
            if offset + 8 > len(data):
                raise ValueError("output_audio_chunk")
            kind = data[offset:offset + 4]
            length = int.from_bytes(data[offset + 4:offset + 8], "little")
            end = offset + 8 + length
            if end > len(data) or kind not in (b"fmt ", b"data"):
                raise ValueError("output_audio_chunk")
            if kind == b"fmt " and length != 16:
                raise ValueError("output_audio_format")
            chunks.append(kind)
            offset = end + length % 2
        if chunks != [b"fmt ", b"data"] or offset != len(data):
            raise ValueError("output_audio_chunk")
        with wave.open(io.BytesIO(data), "rb") as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 48000, "NONE"):
                raise ValueError("output_audio_format")
            frames = audio.getnframes()
            if not 0 < frames <= 480000 or len(audio.readframes(frames + 1)) != frames * 2:
                raise ValueError("output_audio_length")
        return {"mime": "audio/wav", "extension": ".wav"}

    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("output_image_format")
    offset, compressed, dimensions, ended = 8, bytearray(), None, False
    while offset < len(data):
        if offset + 12 > len(data):
            raise ValueError("output_png_truncated")
        length = int.from_bytes(data[offset:offset + 4], "big")
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + length
        if end > len(data) or kind not in (b"IHDR", b"IDAT", b"IEND", b"pHYs"):
            raise ValueError("output_png_chunk")
        payload = data[offset + 8:end - 4]
        if zlib.crc32(kind + payload) != int.from_bytes(data[end - 4:end], "big"):
            raise ValueError("output_png_crc")
        if kind == b"IHDR":
            if dimensions is not None or offset != 8 or length != 13:
                raise ValueError("output_png_header")
            w, h, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if not (1 <= w <= 1024 and 1 <= h <= 1024 and depth == 8 and color == 6 and compression == filtering == interlace == 0):
                raise ValueError("output_png_dimensions")
            dimensions = (w, h)
        elif kind == b"IDAT":
            if dimensions is None or ended:
                raise ValueError("output_png_order")
            compressed.extend(payload)
        elif kind == b"IEND":
            if length or end != len(data) or dimensions is None or not compressed:
                raise ValueError("output_png_end")
            ended = True
        elif kind == b"pHYs" and (length != 9 or dimensions is None):
            raise ValueError("output_png_metadata")
        offset = end
    if not ended:
        raise ValueError("output_png_incomplete")
    w, h = dimensions
    expected = h * (1 + 4 * w)
    decoder = zlib.decompressobj()
    raw = decoder.decompress(bytes(compressed), expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("output_png_pixels")
    if any(raw[row * (1 + 4 * w)] > 4 for row in range(h)):
        raise ValueError("output_png_filter")
    return {"mime": "image/png", "extension": ".png"}


def command(args, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise ValueError("decoder_timeout")
    result = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=remaining, check=False)
    if result.returncode or len(result.stdout) > 65536 or len(result.stderr) > 65536:
        raise ValueError("decoder_rejected")
    return result.stdout


def normalize(category, expected_hash):
    if category not in LIMITS or re.fullmatch(r"[0-9a-f]{64}", expected_hash) is None:
        raise ValueError("invalid_job")
    source = Path("/input/blob")
    data = regular_bytes(source, LIMITS[category])
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise ValueError("input_hash_changed")
    if category == "image":
        # Do not let a disabled animation decoder reinterpret APNG/WebP as one
        # static frame. Inspect bounded chunk structure before invoking FFprobe.
        if data.startswith(b"\x89PNG\r\n\x1a\n"):
            offset = 8
            while offset + 12 <= len(data):
                length = int.from_bytes(data[offset:offset + 4], "big")
                kind = data[offset + 4:offset + 8]
                if length > len(data) - offset - 12:
                    raise ValueError("invalid_image_chunks")
                if kind in (b"acTL", b"fcTL", b"fdAT"):
                    raise ValueError("animated_or_invalid_image")
                offset += length + 12
        elif data.startswith(b"RIFF") and data[8:12] == b"WEBP":
            offset = 12
            while offset + 8 <= len(data):
                kind = data[offset:offset + 4]
                length = int.from_bytes(data[offset + 4:offset + 8], "little")
                if length > len(data) - offset - 8:
                    raise ValueError("invalid_image_chunks")
                if kind in (b"ANIM", b"ANMF"):
                    raise ValueError("animated_or_invalid_image")
                offset += 8 + length + (length % 2)
    deadline = time.monotonic() + 9
    probe = json.loads(command(["ffprobe", "-v", "error", "-protocol_whitelist", "file",
        "-count_frames", "-show_streams", "-show_format", "-of", "json", str(source)], deadline))
    streams = probe.get("streams", [])
    if len(streams) != 1:
        raise ValueError("extra_streams")
    stream = streams[0]
    common = ["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-protocol_whitelist", "file",
              "-threads", "1", "-i", str(source), "-map_metadata", "-1", "-map_chapters", "-1"]
    if category == "image":
        if stream.get("codec_type") != "video" or stream.get("nb_read_frames") != "1":
            raise ValueError("animated_or_invalid_image")
        if not (1 <= stream.get("width", 0) <= 1024 and 1 <= stream.get("height", 0) <= 1024):
            raise ValueError("image_dimensions")
        destination = Path("/output/normalized.png")
        args = ["-map", "0:v:0", "-frames:v", "1", "-c:v", "png", "-pix_fmt", "rgba", "-threads", "1", "-bitexact", "-f", "image2", str(destination)]
    else:
        if stream.get("codec_type") != "audio":
            raise ValueError("invalid_audio")
        duration = float(probe.get("format", {}).get("duration", stream.get("duration", "nan")))
        # Streaming WebM can omit duration. Never trust it as proof of the
        # decoded limit: the complete PCM output is checked below, without -t.
        if not math.isnan(duration) and (not math.isfinite(duration) or not 0 < duration <= 10):
            raise ValueError("audio_duration")
        destination = Path("/output/normalized.wav")
        args = ["-map", "0:a:0", "-c:a", "pcm_s16le", "-ac", "1", "-ar", "48000", "-threads", "1", "-bitexact", "-f", "wav", str(destination)]
    command(common + args, deadline)
    output = regular_bytes(destination, LIMITS[category])
    if category == "audio":
        # FFmpeg may write encoder LIST metadata; publish only canonical PCM chunks.
        import io
        with wave.open(io.BytesIO(output), "rb") as audio:
            frames = audio.getnframes()
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getcomptype()) != (1, 2, 48000, "NONE") or not 0 < frames <= 480000:
                raise ValueError("output_audio_format")
            samples = audio.readframes(frames + 1)
            if len(samples) != frames * 2:
                raise ValueError("output_audio_length")
        canonical = io.BytesIO()
        with wave.open(canonical, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(48000)
            audio.writeframes(samples)
        output = canonical.getvalue()
        destination.write_bytes(output)
    metadata = validate_output(output, category)
    return {"input_sha256": expected_hash, "output_sha256": hashlib.sha256(output).hexdigest(),
            "size": len(output), "category": category, **metadata}


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--read-output" and sys.argv[2] in LIMITS:
            category = sys.argv[2]
            extension = ".png" if category == "image" else ".wav"
            sys.stdout.buffer.write(regular_bytes(Path("/output/normalized" + extension), LIMITS[category]))
            sys.exit(0)
        if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and sys.argv[3] != "--hold"):
            raise ValueError("invalid_job")
        print(json.dumps(normalize(sys.argv[1], sys.argv[2]), separators=(",", ":")), flush=True)
        if len(sys.argv) == 4:
            # Operator copies the output from tmpfs, then destroys this container.
            time.sleep(3600)
    except (ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired, wave.Error, zlib.error) as error:
        reason = str(error) if isinstance(error, ValueError) and re.fullmatch(r"[a-z_]+", str(error)) else "validation_rejected"
        print(json.dumps({"ok": False, "error": reason}), flush=True)
        sys.exit(1)
