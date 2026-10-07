"""Trusted operator service. Private authenticated metadata API; decoder has no secrets.

Single worker, bounded backlog and durable promotion journal. Never accept URLs,
commands, paths, bucket names or public keys from a browser.
"""
import datetime
import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import quote, urlsplit

from media_sandbox import normalize_isolated
from media_validator import LIMITS, validate_output


class S3:
    """Fixed HTTPS endpoint, separate bucket-scoped credentials, bounded reads, no redirects."""
    def __init__(self, endpoint, bucket, access, secret):
        uri = urlsplit(endpoint)
        if uri.scheme != "https" or uri.port not in (None, 443) or uri.path not in ("", "/") or uri.query or uri.fragment or uri.username:
            raise ValueError("storage_configuration")
        if not uri.hostname or not re.fullmatch(r"[a-z0-9.-]{3,63}", bucket):
            raise ValueError("storage_configuration")
        self.host, self.bucket, self.access, self.secret = uri.hostname, bucket, access, secret

    def request(self, method, key, body=b"", mime=None, maximum=2097152):
        path = "/" + self.bucket + "/" + quote(key, safe="/-_.~")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        date = stamp[:8]
        digest = hashlib.sha256(body).hexdigest()
        headers = {"host": self.host, "x-amz-content-sha256": digest, "x-amz-date": stamp}
        if method == "PUT":
            headers.update({"content-type": mime, "if-none-match": "*"})
        names = ";".join(sorted(headers))
        canonical = method + "\n" + path + "\n\n" + "".join(k + ":" + headers[k] + "\n" for k in sorted(headers)) + "\n" + names + "\n" + digest
        scope = date + "/auto/s3/aws4_request"
        signing = ("AWS4" + self.secret).encode()
        for value in (date, "auto", "s3", "aws4_request"):
            signing = hmac.new(signing, value.encode(), hashlib.sha256).digest()
        string = "AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + hashlib.sha256(canonical.encode()).hexdigest()
        signature = hmac.new(signing, string.encode(), hashlib.sha256).hexdigest()
        headers["authorization"] = f"AWS4-HMAC-SHA256 Credential={self.access}/{scope}, SignedHeaders={names}, Signature={signature}"
        connection = http.client.HTTPSConnection(self.host, timeout=5)
        deadline = time.monotonic() + 5
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            data = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("storage_timeout")
                if connection.sock:
                    connection.sock.settimeout(remaining)
                chunk = response.read1(min(65536, maximum + 1 - len(data)))
                if not chunk:
                    break
                data.extend(chunk)
                if len(data) > maximum:
                    raise ValueError("storage_size")
            return response.status, bytes(data)
        finally:
            connection.close()


class Coordinator:
    def __init__(self, quarantine, public, image, journal, sealed=False):
        if quarantine.bucket == public.bucket:
            raise ValueError("buckets_must_differ")
        self.quarantine, self.public, self.image = quarantine, public, image
        self.sealed = sealed
        self.db = sqlite3.connect(journal, check_same_thread=False)
        self.db.execute("CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, request TEXT NOT NULL, result TEXT)")
        self.db.execute("CREATE TABLE IF NOT EXISTS cancelled (id TEXT PRIMARY KEY)")
        self.db.execute("CREATE TABLE IF NOT EXISTS uncertain (id TEXT PRIMARY KEY)")
        self.db.execute("INSERT OR IGNORE INTO uncertain SELECT id FROM jobs WHERE result IS NULL")
        self.db.commit()
        self.lock = threading.Lock()

    def normalize(self, job):
        if not self.lock.acquire(blocking=False):
            raise ValueError("coordinator_busy")
        try:
            return self._normalize(job)
        finally:
            self.lock.release()

    def _normalize(self, job):
        if self.sealed:
            raise ValueError("uploads_sealed")
        if set(job) != {"job", "handle", "key", "category", "size"}:
            raise ValueError("invalid_job")
        if not re.fullmatch(r"[0-9a-f]{32}", job["job"]) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,31}", job["handle"]):
            raise ValueError("invalid_job")
        category = job["category"]
        if category not in LIMITS or type(job["size"]) is not int or not 0 < job["size"] <= LIMITS[category]:
            raise ValueError("invalid_job")
        if not re.fullmatch(re.escape(job["handle"]) + r"/(audio|image)/[a-f0-9]{32}_[A-Za-z0-9_.-]{1,64}", job["key"]) or ".." in job["key"]:
            raise ValueError("invalid_key")
        encoded = json.dumps(job, sort_keys=True)
        if self.db.execute("SELECT 1 FROM cancelled WHERE id=?", (job["job"],)).fetchone():
            raise ValueError("job_cancelled")
        existing = self.db.execute("SELECT request,result FROM jobs WHERE id=?", (job["job"],)).fetchone()
        if existing and existing[0] != encoded:
            raise ValueError("job_binding_changed")
        if not existing:
            if self.db.execute("SELECT COUNT(*) FROM jobs").fetchone()[0] >= 128:
                raise ValueError("journal_full")
            self.db.execute("INSERT INTO jobs VALUES (?,?,NULL)", (job["job"], encoded))
            self.db.commit()
        if existing and existing[1]:
            result = json.loads(existing[1])
            status, stored = self.public.request("GET", result["key"], maximum=LIMITS[category])
            if status != 200 or hashlib.sha256(stored).hexdigest() != result["output_sha256"]:
                raise ValueError("published_object_changed")
            return result
        status, data = self.quarantine.request("GET", job["key"], maximum=LIMITS[category])
        if status != 200 or len(data) != job["size"]:
            raise ValueError("quarantine_mismatch")
        output, report = normalize_isolated(data, category, self.image)
        metadata = validate_output(output, category)
        if report["input_sha256"] != hashlib.sha256(data).hexdigest() or report["output_sha256"] != hashlib.sha256(output).hexdigest() or report["size"] != len(output):
            raise ValueError("report_mismatch")
        result = {**report, "job": job["job"], "handle": job["handle"], "input_key": job["key"], "state": "ready",
                  "key": job["handle"] + "/validated/" + job["job"] + "/" + report["output_sha256"] + metadata["extension"]}
        # Journal BEFORE PUT: after timeout/restart only this immutable artifact may be retried.
        if existing and existing[1] is None:
            pass
        pending = self.db.execute("SELECT request FROM jobs WHERE id=?", (job["job"],)).fetchone()
        if pending[0] != encoded:
            raise ValueError("job_binding_changed")
        # Store expected hashes separately from readiness, including failed/ambiguous PUTs.
        self.db.execute("CREATE TABLE IF NOT EXISTS artifacts (id TEXT PRIMARY KEY, result TEXT NOT NULL)")
        old = self.db.execute("SELECT result FROM artifacts WHERE id=?", (job["job"],)).fetchone()
        serialized = json.dumps(result, sort_keys=True)
        if old and old[0] != serialized:
            raise ValueError("input_or_output_changed")
        self.db.execute("INSERT OR IGNORE INTO artifacts VALUES (?,?)", (job["job"], serialized))
        self.db.commit()
        # Keep evidence of any write that may outlive a client timeout/restart.
        # A later successful retry cannot prove an earlier request has drained.
        self.db.execute("CREATE TABLE IF NOT EXISTS uncertain (id TEXT PRIMARY KEY)")
        previous_uncertain = self.db.execute("SELECT 1 FROM uncertain WHERE id=?", (job["job"],)).fetchone()
        self.db.execute("INSERT OR IGNORE INTO uncertain VALUES (?)", (job["job"],))
        self.db.commit()
        status, _ = self.public.request("PUT", result["key"], output, metadata["mime"])
        if status not in (200, 201, 204, 412):
            raise ValueError("promotion_failed")
        status, stored = self.public.request("GET", result["key"], maximum=LIMITS[category])
        if status != 200 or stored != output:
            raise ValueError("promotion_unconfirmed")
        self.db.execute("UPDATE jobs SET result=? WHERE id=?", (serialized, job["job"]))
        if not previous_uncertain:
            self.db.execute("DELETE FROM uncertain WHERE id=?", (job["job"],))
        self.db.commit()
        return result

    def delete(self, item):
        if not self.lock.acquire(blocking=False):
            raise ValueError("coordinator_busy")
        try:
            return self._delete(item)
        finally:
            self.lock.release()

    def _delete(self, item):
        if set(item) != {"key", "bucket"} or item["bucket"] not in ("quarantine", "public"):
            raise ValueError("invalid_delete")
        if not isinstance(item["key"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,31}/[A-Za-z0-9_./-]{1,220}", item["key"]) or ".." in item["key"]:
            raise ValueError("invalid_delete")
        store = self.quarantine if item["bucket"] == "quarantine" else self.public
        # A sealed offline session is an operator assertion: issuance stopped,
        # upload credentials revoked and all in-flight writes drained. Default
        # mode never treats DELETE as proof against a late presigned upload.
        if item["bucket"] == "quarantine" and not self.sealed:
            return {"state": "reconcile"}
        # Public ambiguous transfers may have a hash-dependent key unknown to the app.
        keys = [item["key"]]
        if item["bucket"] == "public" and item["key"].endswith("/pending"):
            job_id = item["key"].split("/")[-2]
            self.db.execute("CREATE TABLE IF NOT EXISTS artifacts (id TEXT PRIMARY KEY, result TEXT NOT NULL)")
            row = self.db.execute("SELECT result FROM artifacts WHERE id=?", (job_id,)).fetchone()
            if row:
                keys = [json.loads(row[0])["key"]]
        if item["bucket"] == "public" and "/validated/" in item["key"]:
            job_id = item["key"].split("/")[-2]
            if not re.fullmatch(r"[0-9a-f]{32}", job_id):
                raise ValueError("invalid_delete")
            if self.db.execute("SELECT COUNT(*) FROM cancelled").fetchone()[0] >= 128 and not self.db.execute("SELECT 1 FROM cancelled WHERE id=?", (job_id,)).fetchone():
                raise ValueError("journal_full")
            self.db.execute("INSERT OR IGNORE INTO cancelled VALUES (?)", (job_id,))
            self.db.commit()
            self.db.execute("CREATE TABLE IF NOT EXISTS uncertain (id TEXT PRIMARY KEY)")
            uncertain = self.db.execute("SELECT 1 FROM uncertain WHERE id=?", (job_id,)).fetchone()
            if not self.sealed and (item["key"].endswith("/pending") or uncertain):
                return {"state": "reconcile"}
        for key in keys:
            status, _ = store.request("DELETE", key)
            if status not in (200, 204, 404):
                raise ValueError("cleanup_failed")
            status, _ = store.request("GET", key)
            if status != 404:
                raise ValueError("cleanup_unconfirmed")
        # Never release quarantine cost on DELETE alone: a presigned PUT can finish late.
        # Public ambiguous PUTs also retain their reservation until operator reconciliation.
        return {"state": "deleted", "sealed": self.sealed}

    def compact_sealed(self):
        """Offline maintenance only after every journaled input/output is absent.

        No HTTP route exposes this operation. Retain records on ambiguous reads.
        """
        if not self.sealed:
            raise ValueError("uploads_not_sealed")
        with self.lock:
            for job_id, request, result in self.db.execute("SELECT id,request,result FROM jobs").fetchall():
                job = json.loads(request)
                if self.quarantine.request("GET", job["key"])[0] != 404:
                    raise ValueError("quarantine_not_empty")
                artifact = self.db.execute("SELECT result FROM artifacts WHERE id=?", (job_id,)).fetchone() if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='artifacts'").fetchone() else None
                public_key = json.loads(result or artifact[0])["key"] if result or artifact else None
                if public_key and self.public.request("GET", public_key)[0] != 404:
                    raise ValueError("public_not_empty")
            self.db.execute("DELETE FROM jobs")
            if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='artifacts'").fetchone():
                self.db.execute("DELETE FROM artifacts")
            self.db.execute("DELETE FROM cancelled")
            self.db.execute("DELETE FROM uncertain")
            self.db.commit()


def serve(coordinator, token, port):
    if not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", token):
        raise ValueError("private_token_required")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def setup(self):
            super().setup()
            self.connection.settimeout(5)

        def log_message(self, *args):
            pass  # Never log tokens, signed URLs, jobs or content.

        def do_POST(self):
            try:
                if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                    self.send_error(401)
                    return
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isdigit() or not 0 < int(lengths[0]) <= 2048 or self.headers.get("Transfer-Encoding"):
                    raise ValueError("invalid_body")
                data = self.rfile.read(int(lengths[0]))
                if len(data) != int(lengths[0]):
                    raise ValueError("incomplete_body")
                job = json.loads(data)
                if not isinstance(job, dict):
                    raise ValueError("invalid_body")
                if self.path == "/normalize":
                    result = coordinator.normalize(job)
                elif self.path == "/delete":
                    result = coordinator.delete(job)
                else:
                    raise ValueError("invalid_route")
                status = 200
            except (ValueError, TypeError, KeyError, OSError, TimeoutError, sqlite3.Error):
                status, result = 422, {"state": "failed"}
            body = json.dumps(result, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except OSError:
                pass  # Durable journal allows retries after the control connection is lost.

    class PrivateServer(HTTPServer):
        request_queue_size = 8

    return PrivateServer(("127.0.0.1", port), Handler)


if __name__ == "__main__":
    import sys
    os.umask(0o077)
    quarantine = S3(os.environ["R2_ENDPOINT"], os.environ["R2_QUARANTINE_BUCKET"], os.environ["COORD_QUARANTINE_ACCESS_KEY"], os.environ["COORD_QUARANTINE_SECRET"])
    public = S3(os.environ["R2_ENDPOINT"], os.environ["R2_BUCKET"], os.environ["COORD_PUBLIC_ACCESS_KEY"], os.environ["COORD_PUBLIC_SECRET"])
    service = Coordinator(quarantine, public, os.environ["MEDIA_VALIDATOR_IMAGE"], os.environ["MEDIA_COORDINATOR_JOURNAL"], sealed=os.environ.get("MEDIA_UPLOADS_SEALED") == "1")
    if sys.argv[1:] == ["--compact-sealed"]:
        service.compact_sealed()
        print("sealed journal compacted")
    elif sys.argv[1:]:
        raise ValueError("invalid_operator_command")
    else:
        serve(service, os.environ["MEDIA_COORDINATOR_TOKEN"], int(os.environ.get("MEDIA_COORDINATOR_PORT", "4199"))).serve_forever()
