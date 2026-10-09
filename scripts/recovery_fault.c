/* Development-only syscall faults. Never included in a release image. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

static int fault(int fd) {
  char link[64], path[4096];
  snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
  ssize_t n = readlink(link, path, sizeof(path) - 1);
  if (n < 0) return 0;
  path[n] = 0;
  if (strncmp(path, "/faultout/.recovery-", 20) ||
      !strstr(path, "/payload")) return 0;
  const char *mode = getenv("RECOVERY_FAULT_MODE");
  if (mode && !strcmp(mode, "kill")) kill(getpid(), SIGKILL);
  if (mode && !strcmp(mode, "eio")) { errno = EIO; return 1; }
  return 0;
}

ssize_t write(int fd, const void *buf, size_t count) {
  static ssize_t (*real)(int, const void *, size_t);
  if (!real) real = dlsym(RTLD_NEXT, "write");
  if (fault(fd)) return -1;
  return real(fd, buf, count);
}

ssize_t writev(int fd, const struct iovec *iov, int count) {
  static ssize_t (*real)(int, const struct iovec *, int);
  if (!real) real = dlsym(RTLD_NEXT, "writev");
  if (fault(fd)) return -1;
  return real(fd, iov, count);
}

ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset) {
  static ssize_t (*real)(int, const void *, size_t, off_t);
  if (!real) real = dlsym(RTLD_NEXT, "pwrite");
  if (fault(fd)) return -1;
  return real(fd, buf, count, offset);
}
