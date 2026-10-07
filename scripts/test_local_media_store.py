"""Offline Linux filesystem security regressions for the local backend."""
import hashlib
import os
import tempfile
import unittest
import http.client
import threading
from types import SimpleNamespace
from local_media_store import Disk, MAXIMUM
from local_media_coordinator import local_server


class DiskTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.disk = Disk(self.directory.name, MAXIMUM, 0)
        self.key = "creator/image/" + "a" * 32 + "_test.png"
        self.public = "creator/validated/" + "b" * 32 + "/" + "c" * 64 + ".png"

    def tearDown(self):
        self.disk.close()
        self.directory.cleanup()

    def test_immutable_write_and_restart(self):
        self.assertEqual(self.disk.request("quarantine", "PUT", self.key, b"original", "image/png")[0], 201)
        self.assertEqual(self.disk.request("quarantine", "PUT", self.key, b"changed", "image/png")[0], 412)
        self.disk.close()
        self.disk = Disk(self.directory.name, MAXIMUM, 0)
        self.assertEqual(self.disk.request("quarantine", "GET", self.key), (200, b"original"))

    def test_delete_before_upload_survives_restart(self):
        self.assertEqual(self.disk.request("quarantine", "DELETE", self.key)[0], 204)
        self.disk.close()
        self.disk = Disk(self.directory.name, MAXIMUM, 0)
        self.assertEqual(self.disk.request("quarantine", "PUT", self.key, b"late", "image/png")[0], 412)
        self.assertEqual(self.disk.request("quarantine", "GET", self.key)[0], 404)

    def test_budget_is_shared_between_originals_and_outputs(self):
        self.disk.request("quarantine", "PUT", self.key, b"x" * (MAXIMUM - 1), "image/png")
        with self.assertRaisesRegex(ValueError, "disk_budget_exceeded"):
            self.disk.request("public", "PUT", self.public, b"xx", "image/png")

    def test_paths_and_bucket_confusion_rejected(self):
        for key in ("../secret", self.key + "/../x", "/" + self.key, self.key + "\x00"):
            with self.assertRaises(ValueError):
                self.disk.request("quarantine", "GET", key)
        with self.assertRaisesRegex(ValueError, "wrong_bucket"):
            self.disk.request("public", "GET", self.key)

    def test_orphan_never_served_or_replaced(self):
        name = hashlib.sha256(self.key.encode()).hexdigest()
        with open(os.path.join(self.directory.name, "quarantine", name), "wb") as stream:
            stream.write(b"partial")
        self.assertEqual(self.disk.request("quarantine", "GET", self.key)[0], 404)
        self.assertEqual(self.disk.request("quarantine", "PUT", self.key, b"new", "image/png")[0], 412)

    def test_symlink_blocks_reads_and_new_uploads(self):
        self.disk.request("quarantine", "PUT", self.key, b"original", "image/png")
        path = os.path.join(self.directory.name, "quarantine", hashlib.sha256(self.key.encode()).hexdigest())
        os.unlink(path)
        os.symlink("/etc/passwd", path)
        with self.assertRaises(OSError):
            self.disk.request("quarantine", "GET", self.key)
        with self.assertRaisesRegex(ValueError, "unsafe_object"):
            self.disk.request("public", "PUT", self.public, b"new", "image/png")

    def test_changed_size_rejected(self):
        self.disk.request("public", "PUT", self.public, b"normalized", "image/png")
        path = os.path.join(self.directory.name, "public", hashlib.sha256(self.public.encode()).hexdigest())
        with open(path, "ab") as stream:
            stream.write(b"changed")
        with self.assertRaisesRegex(ValueError, "object_changed"):
            self.disk.request("public", "GET", self.public)

    def test_private_http_auth_sealing_and_original_visibility(self):
        coordinator = SimpleNamespace(sealed=False)
        server = local_server(coordinator, self.disk, "a" * 43, port=0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=2)
        headers = {"Authorization": "Bearer " + "a" * 43, "X-Object-Key": self.key, "Content-Type": "image/png"}
        try:
            client.request("PUT", "/object/quarantine", b"DATA", {"X-Object-Key": self.key})
            response = client.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
            coordinator.sealed = True
            client.request("PUT", "/object/quarantine", b"DATA", headers)
            response = client.getresponse()
            self.assertEqual(response.status, 422)
            response.read()
            self.assertEqual(self.disk.request("quarantine", "GET", self.key)[0], 404)
            coordinator.sealed = False
            client.request("PUT", "/object/quarantine", b"DATA", headers)
            response = client.getresponse()
            self.assertEqual(response.status, 201)
            response.read()
            client.request("GET", "/object/quarantine", headers=headers)
            response = client.getresponse()
            self.assertEqual(response.status, 422)
            response.read()
        finally:
            client.close()
            server.shutdown()
            server.server_close()
            thread.join(2)


if __name__ == "__main__":
    unittest.main()
