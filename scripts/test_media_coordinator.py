"""Real decoder with synthetic storage; never credentials or external services."""
import hashlib
import os
import tempfile
import unittest
import json
import threading
import http.client
from pathlib import Path

from media_coordinator import Coordinator, serve
from test_media_sandbox import png


class Storage:
    def __init__(self, bucket):
        self.bucket = bucket
        self.objects = {}
        self.puts = 0

    def request(self, method, key, body=b"", mime=None, maximum=2097152):
        if method == "PUT":
            if key in self.objects:
                return 412, b""
            self.puts += 1
            self.objects[key] = body
            return 200, b""
        if method == "DELETE":
            self.objects.pop(key, None)
            return 204, b""
        data = self.objects.get(key)
        if data is None:
            return 404, b""
        if len(data) > maximum:
            raise ValueError("storage_size")
        return 200, data


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.private = Storage("private")
        self.public = Storage("public")
        self.journal = str(Path(self.directory.name) / "jobs.sqlite")
        self.service = Coordinator(self.private, self.public, os.environ["MEDIA_VALIDATOR_IMAGE"], self.journal)
        self.job = {"job": "a" * 32, "handle": "creator", "key": "creator/image/" + "b" * 32 + "_image.png", "category": "image", "size": len(png())}
        self.private.objects[self.job["key"]] = png()

    def tearDown(self):
        self.service.db.close()
        self.directory.cleanup()

    def test_normalize_promote_and_retry_after_coordinator_restart(self):
        result = self.service.normalize(self.job)
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["output_sha256"], hashlib.sha256(self.public.objects[result["key"]]).hexdigest())
        self.assertNotIn(self.job["key"], self.public.objects)
        self.service.db.close()
        self.service = Coordinator(self.private, self.public, os.environ["MEDIA_VALIDATOR_IMAGE"], self.journal)
        self.assertEqual(self.service.normalize(self.job), result)
        self.assertEqual(self.public.puts, 1)
        self.public.objects[result["key"]] = b"changed"
        with self.assertRaisesRegex(ValueError, "published_object_changed"):
            self.service.normalize(self.job)

    def test_cross_profile_key_and_changed_job_binding_rejected(self):
        with self.assertRaisesRegex(ValueError, "invalid_key"):
            self.service.normalize({**self.job, "handle": "other"})
        self.service.normalize(self.job)
        with self.assertRaisesRegex(ValueError, "job_binding_changed"):
            self.service.normalize({**self.job, "size": self.job["size"] + 1})

    def test_quarantine_deletion_requires_reconciliation(self):
        result = self.service.delete({"key": self.job["key"], "bucket": "quarantine"})
        self.assertEqual(result, {"state": "reconcile"})
        self.assertIn(self.job["key"], self.private.objects)

    def test_sealed_cleanup_and_journal_compaction_require_absence(self):
        result = self.service.normalize(self.job)
        self.service.sealed = True
        with self.assertRaisesRegex(ValueError, "uploads_sealed"):
            self.service.normalize(self.job)
        with self.assertRaisesRegex(ValueError, "quarantine_not_empty"):
            self.service.compact_sealed()
        self.assertEqual(self.service.delete({"key": self.job["key"], "bucket": "quarantine"}), {"state": "deleted", "sealed": True})
        self.assertEqual(self.service.delete({"key": result["key"], "bucket": "public"}), {"state": "deleted", "sealed": True})
        self.service.compact_sealed()
        self.assertEqual(self.service.db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0], 0)
        self.assertEqual(self.private.objects, {})
        self.assertEqual(self.public.objects, {})

    def test_deleted_public_job_cannot_be_promoted_again(self):
        result = self.service.normalize(self.job)
        self.service.delete({"key": result["key"], "bucket": "public"})
        with self.assertRaisesRegex(ValueError, "job_cancelled"):
            self.service.normalize(self.job)
        self.assertEqual(self.public.objects, {})

    def test_ambiguous_public_put_retains_reservation_for_late_write(self):
        original = self.public.request
        delayed = []

        def timeout_put(method, key, body=b"", mime=None, maximum=2097152):
            if method == "PUT":
                delayed.append((key, body))
                raise TimeoutError("put_in_flight")
            return original(method, key, body, mime, maximum)

        self.public.request = timeout_put
        with self.assertRaisesRegex(TimeoutError, "put_in_flight"):
            self.service.normalize(self.job)
        pending = "creator/validated/" + self.job["job"] + "/pending"
        self.assertEqual(self.service.delete({"key": pending, "bucket": "public"}), {"state": "reconcile"})
        self.assertEqual(self.public.objects, {})
        key, body = delayed[0]
        self.public.objects[key] = body  # Earlier remote PUT completes after GET404.
        with self.assertRaisesRegex(ValueError, "job_cancelled"):
            self.service.normalize(self.job)
        self.service.sealed = True  # Test operator has drained the delayed write.
        self.assertEqual(self.service.delete({"key": pending, "bucket": "public"}), {"state": "deleted", "sealed": True})
        self.assertEqual(self.public.objects, {})

    def test_confirmed_retry_does_not_erase_prior_write_uncertainty(self):
        original = self.public.request

        def timeout_put(method, key, body=b"", mime=None, maximum=2097152):
            if method == "PUT":
                raise TimeoutError("put_in_flight")
            return original(method, key, body, mime, maximum)

        self.public.request = timeout_put
        with self.assertRaises(TimeoutError):
            self.service.normalize(self.job)
        self.public.request = original
        result = self.service.normalize(self.job)
        self.service.db.close()
        self.service = Coordinator(self.private, self.public, os.environ["MEDIA_VALIDATOR_IMAGE"], self.journal)
        self.assertEqual(self.service.delete({"key": result["key"], "bucket": "public"}), {"state": "reconcile"})
        self.assertIn(result["key"], self.public.objects)

    def test_real_private_http_to_decoder_to_promotion(self):
        token = "t" * 43
        server = serve(self.service, token, 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for authorization, expected in [("Bearer wrong", 401), ("Bearer " + token, 200)]:
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=10)
                try:
                    body = json.dumps(self.job) if expected == 200 else None
                    connection.request("POST", "/normalize", body, {"Authorization": authorization, "Content-Type": "application/json"})
                    response = connection.getresponse()
                    body = response.read(2049)
                    self.assertEqual(response.status, expected)
                    if expected == 200:
                        report = json.loads(body)
                        self.assertEqual(report["output_sha256"], hashlib.sha256(self.public.objects[report["key"]]).hexdigest())
                finally:
                    connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(5)


if __name__ == "__main__":
    unittest.main()
