"""Private local object storage. No filename or command comes from an HTTP path."""
import hashlib
import os
import re
import sqlite3
import stat
import threading

MAXIMUM = 2097152
KEY = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}/(?:audio|image)/[a-f0-9]{32}_[A-Za-z0-9_.-]{1,64}|[a-z0-9][a-z0-9_-]{0,31}/validated/[a-f0-9]{32}/(?:[a-f0-9]{64}\.(?:png|wav)|pending)")


class Disk:
    def __init__(self, root, maximum=268435456, free_reserve=2147483648):
        if type(maximum) is not int or not MAXIMUM <= maximum <= 1073741824:
            raise ValueError("invalid_disk_budget")
        if type(free_reserve) is not int or free_reserve < 0:
            raise ValueError("invalid_free_reserve")
        self.maximum, self.free_reserve = maximum, free_reserve
        self.lock = threading.RLock()
        self.directories = {}
        # The operator owns the parent; reject an existing symlink or writable directory.
        os.makedirs(root, mode=0o700, exist_ok=True)
        self.root = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self._private_directory(self.root)
        for bucket in ("quarantine", "public"):
            try:
                os.mkdir(bucket, 0o700, dir_fd=self.root)
            except FileExistsError:
                pass
            fd = os.open(bucket, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root)
            self._private_directory(fd)
            self.directories[bucket] = fd
        # SQLite path never comes from a request; root and parent are trusted/private.
        dbpath = os.path.join(root, "objects.sqlite")
        if os.path.lexists(dbpath):
            info = os.lstat(dbpath)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
                raise ValueError("unsafe_index")
        self.db = sqlite3.connect(dbpath, check_same_thread=False)
        os.chmod(dbpath, 0o600)
        self.db.execute("CREATE TABLE IF NOT EXISTS objects (bucket TEXT, key TEXT, size INTEGER, mime TEXT, deleted INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(bucket,key))")
        self.db.commit()

    @staticmethod
    def _private_directory(fd):
        info = os.fstat(fd)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise ValueError("unsafe_directory")

    def close(self):
        self.db.close()
        for fd in self.directories.values():
            os.close(fd)
        os.close(self.root)

    def _usage(self):
        total = 0
        for fd in self.directories.values():
            for name in os.listdir(fd):
                info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                if not re.fullmatch(r"[a-f0-9]{64}", name) or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("unsafe_object")
                total += info.st_size
        return total

    def request(self, bucket, method, key, body=b"", mime=None, maximum=MAXIMUM):
        if bucket not in self.directories or not isinstance(key, str) or not KEY.fullmatch(key) or ".." in key:
            raise ValueError("invalid_key")
        if (bucket == "public") != ("/validated/" in key):
            raise ValueError("wrong_bucket")
        if method not in ("GET", "HEAD", "PUT", "DELETE") or not 0 < maximum <= MAXIMUM:
            raise ValueError("invalid_request")
        name = hashlib.sha256(key.encode()).hexdigest()
        fd = self.directories[bucket]
        with self.lock:
            row = self.db.execute("SELECT size,mime,deleted FROM objects WHERE bucket=? AND key=?", (bucket, key)).fetchone()
            if method == "DELETE":
                self._capacity(row)
                self.db.execute("INSERT INTO objects VALUES (?,?,0,NULL,1) ON CONFLICT(bucket,key) DO UPDATE SET deleted=1", (bucket, key))
                self.db.commit()  # Reject late PUT even if unlink fails or process stops.
                try:
                    os.unlink(name, dir_fd=fd)
                    os.fsync(fd)
                except FileNotFoundError:
                    pass
                return 204, b""
            if method == "PUT":
                if key.endswith("/pending"):
                    raise ValueError("pending_not_writable")
                if row:
                    return 412, b""
                self._capacity(row)
                if not isinstance(body, bytes) or not 0 < len(body) <= maximum or not isinstance(mime, str) or len(mime) > 64:
                    raise ValueError("invalid_content")
                disk = os.fstatvfs(self.root)
                if self._usage() + len(body) > self.maximum or disk.f_bavail * disk.f_frsize - len(body) < self.free_reserve:
                    raise ValueError("disk_budget_exceeded")
                try:
                    out = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
                except FileExistsError:
                    return 412, b""  # An interrupted unindexed write is never promoted/replaced.
                with os.fdopen(out, "wb") as stream:
                    stream.write(body)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.fsync(fd)
                self.db.execute("INSERT INTO objects VALUES (?,?,?,?,0)", (bucket, key, len(body), mime))
                self.db.commit()
                return 201, b""
            if not row or row[2]:
                return 404, b""
            try:
                opened = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                return 404, b""
            with os.fdopen(opened, "rb") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != row[0] or info.st_size > maximum:
                    raise ValueError("object_changed")
                data = stream.read(maximum + 1)
            if len(data) != row[0]:
                raise ValueError("object_changed")
            return 200, ({"size": row[0], "mime": row[1]} if method == "HEAD" else data)

    def _capacity(self, existing):
        if not existing and self.db.execute("SELECT COUNT(*) FROM objects").fetchone()[0] >= 4096:
            raise ValueError("storage_index_full")


class LocalObjects:
    def __init__(self, disk, bucket):
        self.disk, self.bucket = disk, bucket

    def request(self, method, key, body=b"", mime=None, maximum=MAXIMUM):
        return self.disk.request(self.bucket, method, key, body, mime, maximum)
