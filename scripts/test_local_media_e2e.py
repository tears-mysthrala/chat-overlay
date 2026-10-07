"""Real Linux disk/coordinator/isolated decoder, synthetic fixtures, no upstream."""
import hashlib
import os
import tempfile
import unittest
from pathlib import Path
from local_media_store import Disk, LocalObjects
from local_media_coordinator import LocalCoordinator
from test_media_sandbox import png, wav


class LocalE2ETests(unittest.TestCase):
    def test_normalize_restart_delete_and_late_upload(self):
        with tempfile.TemporaryDirectory(prefix="local-media-e2e-") as root:
            disk = Disk(root, free_reserve=0)
            image = os.environ["MEDIA_VALIDATOR_IMAGE"]
            journal = str(Path(root) / "jobs.sqlite")
            coordinator = LocalCoordinator(LocalObjects(disk, "quarantine"), LocalObjects(disk, "public"), image, journal)
            try:
                for number, (category, data) in enumerate([("image", png()), ("audio", wav(2))], 1):
                    identifier = f"{number:032x}"
                    key = "creator/" + category + "/" + identifier + "_fixture"
                    self.assertEqual(disk.request("quarantine", "PUT", key, data, "image/png" if category == "image" else "audio/wav")[0], 201)
                    job = {"job":identifier, "handle":"creator", "key":key, "category":category, "size":len(data)}
                    result = coordinator.normalize(job)
                    self.assertEqual(result["state"], "ready")
                    status, output = disk.request("public", "GET", result["key"])
                    self.assertEqual(status, 200)
                    self.assertEqual(hashlib.sha256(output).hexdigest(), result["output_sha256"])
                    coordinator.db.close()
                    disk.close()
                    disk = Disk(root, free_reserve=0)
                    coordinator = LocalCoordinator(LocalObjects(disk, "quarantine"), LocalObjects(disk, "public"), image, journal)
                    self.assertEqual(coordinator.normalize(job), result)
                    self.assertEqual(coordinator.delete({"key":key, "bucket":"quarantine"})["state"], "deleted")
                    self.assertEqual(disk.request("quarantine", "PUT", key, data, "image/png")[0], 412)
                    self.assertEqual(coordinator.delete({"key":result["key"], "bucket":"public"})["state"], "deleted")
                    self.assertEqual(disk.request("public", "GET", result["key"])[0], 404)
                    with self.assertRaisesRegex(ValueError, "job_cancelled"):
                        coordinator.normalize(job)
            finally:
                coordinator.db.close()
                disk.close()


if __name__ == "__main__":
    unittest.main()
