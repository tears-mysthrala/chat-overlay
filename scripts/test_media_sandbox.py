"""Mandatory real-container validation; run with MEDIA_VALIDATOR_IMAGE=sha256:... ."""
import hashlib
import io
import os
import struct
import unittest
import json
import subprocess
from pathlib import Path
from unittest.mock import patch
import wave
import zlib

from media_sandbox import normalize_isolated
from media_validator import validate_output


def png(width=2, height=2):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = (b"\x00" + b"\xff\x00\x00\xff" * width) * height
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b""))


def wav(seconds=1):
    stream = io.BytesIO()
    with wave.open(stream, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(48000)
        output.writeframes(b"\x00\x00" * (48000 * seconds))
    return stream.getvalue()


class SandboxTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = os.environ["MEDIA_VALIDATOR_IMAGE"]

    def test_static_image_normalized_and_hash_bound(self):
        source = png()
        result, report = normalize_isolated(source, "image", self.image)
        self.assertEqual(report["mime"], "image/png")
        self.assertEqual(validate_output(result, "image")["extension"], ".png")
        import hashlib
        self.assertEqual(report["input_sha256"], hashlib.sha256(source).hexdigest())
        self.assertEqual(report["output_sha256"], hashlib.sha256(result).hexdigest())

    def test_audio_normalized_without_truncation(self):
        result, report = normalize_isolated(wav(), "audio", self.image)
        self.assertEqual(report["mime"], "audio/wav")
        with wave.open(io.BytesIO(result)) as audio:
            self.assertEqual(audio.getnframes(), 48000)
            self.assertEqual(audio.getnchannels(), 1)

    def test_admitted_compressed_formats_remain_supported(self):
        fixtures = Path(__file__).resolve().parent.parent / "test/fixtures/media"
        for name, category in [("static.webp", "image"), ("audio.mp3", "audio"), ("audio.ogg", "audio"), ("audio.webm", "audio")]:
            with self.subTest(name=name):
                output, _ = normalize_isolated((fixtures / name).read_bytes(), category, self.image)
                validate_output(output, category)

    def test_apng_and_animated_webp_are_rejected(self):
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        base = png()
        apng = base[:33] + chunk(b"acTL", struct.pack(">II", 1, 0)) + chunk(b"fcTL", struct.pack(">IIIIIHHBB", 0, 2, 2, 0, 0, 1, 10, 0, 0)) + base[33:]
        animated_webp = (Path(__file__).resolve().parent.parent / "test/fixtures/media/animated.webp").read_bytes()
        for data in (apng, animated_webp):
            with self.assertRaisesRegex(ValueError, "animated_or_invalid_image"):
                normalize_isolated(data, "image", self.image)

    def test_category_mismatch_and_invalid_bytes_rejected(self):
        for source, category in [(wav(), "image"), (png(), "audio"), (b"<svg></svg>", "image"), (b"not audio", "audio")]:
            with self.subTest(category=category, source=source[:8]):
                with self.assertRaises((ValueError, TimeoutError)):
                    normalize_isolated(source, category, self.image)

    def test_input_and_decoded_limits(self):
        for source, category in [(png(1025, 1), "image"), (wav(11), "audio"), (b"x" * 524289, "image")]:
            with self.subTest(category=category):
                with self.assertRaises((ValueError, TimeoutError)):
                    normalize_isolated(source, category, self.image)

    def test_coordinator_checks_crc_trailing_data_and_audio_length(self):
        altered = bytearray(png())
        altered[-1] ^= 1
        for data, category in [(bytes(altered), "image"), (png() + b"extra", "image"), (wav() + b"extra", "audio"), (wav(11), "audio")]:
            with self.assertRaises(ValueError):
                validate_output(data, category)

    def test_mutable_tag_is_not_an_approved_decoder(self):
        with self.assertRaises(ValueError):
            normalize_isolated(png(), "image", "chat-overlay:media-validator")

    def test_actual_container_isolation_and_timeout_cleanup(self):
        original = subprocess.run
        inspected = []
        name = None

        def observe(command, **kwargs):
            nonlocal name
            if command[:2] == ["docker", "run"]:
                name = command[command.index("--name") + 1]
                result = original(command, **kwargs)
                state = json.loads(original(["docker", "inspect", name], capture_output=True, check=True).stdout)[0]
                host = state["HostConfig"]
                self.assertEqual(state["Image"], self.image)
                self.assertEqual(state["Config"]["Entrypoint"], ["python3", "-I", "/validator.py"])
                self.assertEqual(state["Config"]["Cmd"], ["image", hashlib.sha256(png()).hexdigest(), "--hold"])
                self.assertEqual(host["NetworkMode"], "none")
                self.assertTrue(host["ReadonlyRootfs"])
                self.assertFalse(host["Privileged"])
                self.assertFalse(host["Devices"])
                self.assertFalse(host["DeviceRequests"])
                self.assertFalse(host["CapAdd"])
                self.assertEqual(state["Config"]["User"], "65532:65532")
                self.assertEqual(host["CapDrop"], ["ALL"])
                self.assertIn("no-new-privileges", host["SecurityOpt"])
                self.assertEqual(host["PidsLimit"], 32)
                self.assertEqual(host["Memory"], 256 * 1024 * 1024)
                self.assertEqual(host["MemorySwap"], 256 * 1024 * 1024)
                self.assertEqual(host["NanoCpus"], 1_000_000_000)
                self.assertFalse(any(entry.startswith(("AWS_", "R2_", "COORD_", "MEDIA_COORDINATOR_TOKEN="))
                                     for entry in state["Config"]["Env"]))
                self.assertEqual(host["LogConfig"]["Config"]["max-size"], "64k")
                mounts = [mount for mount in state["Mounts"] if mount["Type"] == "bind"]
                self.assertEqual(len(mounts), 1)
                self.assertEqual(mounts[0]["Destination"], "/input/blob")
                self.assertFalse(mounts[0]["RW"])
                self.assertNotIn("docker.sock", json.dumps(state["Mounts"]))
                inspected.append(name)
                return result
            if command[:2] == ["docker", "logs"]:
                raise TimeoutError("injected_deadline")
            return original(command, **kwargs)

        with patch("media_sandbox.subprocess.run", side_effect=observe):
            with self.assertRaisesRegex(TimeoutError, "injected_deadline"):
                normalize_isolated(png(), "image", self.image)
        self.assertEqual(len(inspected), 1)
        self.assertNotEqual(original(["docker", "inspect", name], capture_output=True).returncode, 0)

    def test_valid_animation_and_multiple_streams_are_rejected(self):
        # A constant-color FFmpeg source may be coalesced into one GIF frame.
        # This valid GIF contains two distinct image descriptors/palette indices.
        descriptor = b"\x2c" + struct.pack("<HHHH", 0, 0, 1, 1) + b"\x00"
        animation = (b"GIF89a" + struct.pack("<HHBBB", 1, 1, 0x80, 0, 0)
                     + b"\xff\x00\x00\x00\xff\x00"
                     + b"\x21\xf9\x04\x00\x0a\x00\x00\x00" + descriptor + b"\x02\x02\x44\x01\x00"
                     + b"\x21\xf9\x04\x00\x0a\x00\x00\x00" + descriptor + b"\x02\x02\x4c\x01\x00\x3b")
        probe = subprocess.run(["docker", "run", "--rm", "-i", "--network", "none", "--entrypoint", "ffprobe", self.image,
                                "-v", "error", "-count_frames", "-show_streams", "-of", "json", "pipe:0"],
                               input=animation, capture_output=True, timeout=10, check=True)
        self.assertEqual(json.loads(probe.stdout)["streams"][0]["nb_read_frames"], "2")
        with self.assertRaises(ValueError):
            normalize_isolated(animation, "image", self.image)
        cases = [
            ("audio", ["-f", "lavfi", "-i", "sine=frequency=440:duration=0.1", "-map", "0:a", "-map", "0:a", "-c:a", "pcm_s16le", "-f", "matroska", "pipe:1"]),
        ]
        for category, args in cases:
            fixture = subprocess.run(["docker", "run", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL", "--memory", "256m", "--pids-limit", "32", "--entrypoint", "ffmpeg", self.image, "-v", "error", *args], capture_output=True, timeout=10, check=True)
            self.assertGreater(len(fixture.stdout), 0)
            with self.assertRaises(ValueError):
                normalize_isolated(fixture.stdout, category, self.image)


if __name__ == "__main__":
    unittest.main()
