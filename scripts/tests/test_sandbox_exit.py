"""Regression for a decoder publishing its rejection while logs are polled."""
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from media_sandbox import normalize_isolated


class DecoderExitTests(unittest.TestCase):
    def exercise(self, final_log, expected):
        replies = iter([b"container", b"", b"false\n", final_log, b""])
        commands = []

        def command(args, **kwargs):
            commands.append(args[1])
            return subprocess.CompletedProcess(args, 0, next(replies), b"")

        with patch("media_sandbox.subprocess.run", side_effect=command):
            with self.assertRaisesRegex(ValueError, expected):
                normalize_isolated(b"synthetic", "image", "sha256:" + "a" * 64)
        self.assertEqual(commands, ["run", "logs", "inspect", "logs", "rm"])

    def test_rejection_published_between_logs_and_exit_check(self):
        self.exercise(b'{"ok":false,"error":"animated_or_invalid_image"}',
                      "decoder_rejected: animated_or_invalid_image")

    def test_exit_without_report_remains_failure(self):
        self.exercise(b"", "validator_exited")

    def test_malformed_final_report_remains_failure(self):
        self.exercise(b"malformed", "Expecting value")
