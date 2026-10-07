"""Local backend launcher around the unchanged, approved normalization boundary."""
import hmac
import json
import os
import re
import sqlite3
import subprocess
from pathlib import Path
from http.server import HTTPServer

from local_media_store import Disk, LocalObjects, MAXIMUM
from media_coordinator import Coordinator, serve


class LocalCoordinator(Coordinator):
    def _delete(self, item):
        # The local store commits a per-key write tombstone before unlink. Unlike a
        # remote presigned PUT, no late upload can recreate that key. Parent lock
        # serializes this assertion with normalization and journal cancellation.
        previous = self.sealed
        self.sealed = True
        try:
            return super()._delete(item)
        finally:
            self.sealed = previous


def local_server(coordinator, disk, token, host="127.0.0.1", port=4199):
    if host not in ("127.0.0.1", "172.30.96.1"):
        raise ValueError("invalid_private_bind")
    original = serve(coordinator, token, 0)
    parent = original.RequestHandlerClass
    original.server_close()

    class Handler(parent):
        def authorized(self):
            auth = self.headers.get_all("Authorization", [])
            return len(auth) == 1 and hmac.compare_digest(auth[0], "Bearer " + token)

        def do_POST(self):
            if not self.authorized():
                self.send_error(401)
                return
            super().do_POST()

        def object_request(self, method):
            try:
                if not self.authorized():
                    self.send_error(401)
                    return
                if self.path not in ("/object/quarantine", "/object/public"):
                    raise ValueError("invalid_route")
                bucket = self.path.rsplit("/", 1)[1]
                if method == "PUT" and bucket != "quarantine" or method == "GET" and bucket != "public":
                    raise ValueError("invalid_method")
                keys = self.headers.get_all("X-Object-Key", [])
                if len(keys) != 1 or self.headers.get("Transfer-Encoding"):
                    raise ValueError("invalid_headers")
                data, mime = b"", None
                if method == "PUT":
                    if coordinator.sealed:
                        raise ValueError("uploads_sealed")
                    lengths = self.headers.get_all("Content-Length", [])
                    types = self.headers.get_all("Content-Type", [])
                    maximum = 524288 if "/image/" in keys[0] else MAXIMUM
                    if len(lengths) != 1 or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= maximum or len(types) != 1:
                        raise ValueError("invalid_body")
                    data = self.rfile.read(int(lengths[0]))
                    if len(data) != int(lengths[0]):
                        raise ValueError("incomplete_body")
                    mime = types[0]
                status, result = disk.request(bucket, method, keys[0], data, mime)
                if method == "HEAD" and status == 200:
                    self.send_response(200)
                    self.send_header("Content-Type", result["mime"])
                    self.send_header("Content-Length", str(result["size"]))
                    self.end_headers()
                    return
                if method == "GET" and status == 200:
                    mime = "image/png" if keys[0].endswith(".png") else "audio/wav"
                    body = result
                else:
                    mime = "application/json"
                    body = json.dumps(result if isinstance(result, dict) else {"ok": status in (200, 201)}, separators=(",", ":")).encode()
            except (ValueError, TypeError, KeyError, OSError, sqlite3.Error):
                status, mime, body = 422, "application/json", b'{"state":"failed"}'
            self.send_response(status)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if method != "HEAD":
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

        def do_PUT(self):
            self.object_request("PUT")

        def do_GET(self):
            self.object_request("GET")

        def do_HEAD(self):
            self.object_request("HEAD")

    class Server(HTTPServer):
        request_queue_size = 8

    return Server((host, port), Handler)


if __name__ == "__main__":
    os.umask(0o077)
    root = os.environ["MEDIA_LOCAL_ROOT"]
    if not os.path.isabs(root):
        raise ValueError("absolute_storage_root_required")
    disk = Disk(root, int(os.environ.get("MEDIA_LOCAL_MAX_BYTES", "268435456")))
    coordinator = LocalCoordinator(LocalObjects(disk, "quarantine"), LocalObjects(disk, "public"),
                                   os.environ["MEDIA_VALIDATOR_IMAGE"], os.path.join(root, "jobs.sqlite"),
                                   sealed=os.environ.get("MEDIA_UPLOADS_SEALED") == "1")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", coordinator.image):
        raise ValueError("immutable_decoder_required")
    from decoder_vex import verified_document
    identity = json.loads(subprocess.check_output(["docker", "image", "inspect", coordinator.image], timeout=10))[0]
    verified_document(Path(__file__).resolve().parent.parent, identity)
    port = int(os.environ.get("MEDIA_COORDINATOR_PORT", "4199"))
    if not 1024 <= port <= 65535:
        raise ValueError("invalid_private_port")
    local_server(coordinator, disk, os.environ["MEDIA_COORDINATOR_TOKEN"],
                 os.environ.get("MEDIA_COORDINATOR_HOST", "127.0.0.1"),
                 port).serve_forever()
