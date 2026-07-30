/* fsx.c — tiny POSIX helpers for the crash-atomic commit path (Txn.hs).
 *
 * FFI'd directly rather than going through the `unix` package because the
 * openFd signature changed across unix versions and these three calls are
 * the whole surface we need. Works unchanged on Linux and macOS.
 */
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/types.h>

/* fsync the file (or directory) at path. Best-effort: returns -1 if the
 * path cannot be opened or the filesystem refuses (some network FSes do);
 * the caller treats failure as "no durability upgrade", not an error. */
int sol_fsync_path(const char *p) {
  int fd = open(p, O_RDONLY);
  if (fd < 0) return -1;
  int r = fsync(fd);
  close(fd);
  return r;
}

/* is the process alive? kill(pid, 0) probes without signalling; EPERM
 * means it exists but is not ours — still alive for lock purposes. */
int sol_pid_alive(int pid) {
  if (pid <= 0) return 0;
  if (kill((pid_t)pid, 0) == 0) return 1;
  return errno == EPERM;
}

int sol_getpid(void) { return (int)getpid(); }

/* crash NOW: no atexit handlers, no Haskell RTS shutdown, no buffered
 * flushes — the honest simulation of a kill -9 for SOL_CRASH_AT. */
void sol_hard_exit(int code) { _exit(code); }
