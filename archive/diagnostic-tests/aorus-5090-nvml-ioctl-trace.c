#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static int log_fd = -1;
static int (*real_ioctl_fn)(int, unsigned long, ...) = NULL;
static int (*real_open_fn)(const char *, int, ...) = NULL;
static int (*real_open64_fn)(const char *, int, ...) = NULL;
static int (*real_openat_fn)(int, const char *, int, ...) = NULL;
static int (*real_openat64_fn)(int, const char *, int, ...) = NULL;
static int (*real_close_fn)(int) = NULL;

static void write_fsynced(const char *buf)
{
    size_t len;

    if (log_fd < 0 || buf == NULL) {
        return;
    }

    len = strlen(buf);
    while (len > 0) {
        ssize_t written = syscall(SYS_write, log_fd, buf, len);
        if (written <= 0) {
            break;
        }
        buf += written;
        len -= (size_t)written;
    }

    syscall(SYS_fsync, log_fd);
}

static void fd_target(int fd, char *target, size_t target_len)
{
    char link_path[64];
    ssize_t rc;

    if (target_len == 0) {
        return;
    }

    snprintf(link_path, sizeof(link_path), "/proc/self/fd/%d", fd);
    rc = syscall(SYS_readlinkat, AT_FDCWD, link_path, target, target_len - 1);
    if (rc >= 0) {
        target[rc] = '\0';
        return;
    }

    snprintf(target, target_len, "unavailable(errno=%d)", errno);
}

static void log_event(const char *event, int fd, unsigned long request, void *arg, int rc, int saved_errno)
{
    struct timespec ts;
    char path[256];
    char line[768];
    long pid;
    long tid;

    syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts);
    pid = syscall(SYS_getpid);
    tid = syscall(SYS_gettid);
    fd_target(fd, path, sizeof(path));

    snprintf(line, sizeof(line),
             "%lld.%09ld pid=%ld tid=%ld %s fd=%d path=%s request=0x%lx arg=%p rc=%d errno=%d\n",
             (long long)ts.tv_sec, ts.tv_nsec, pid, tid, event, fd, path, request, arg, rc, saved_errno);
    write_fsynced(line);
}

static int needs_open_mode(int flags)
{
    if ((flags & O_CREAT) != 0) {
        return 1;
    }
#ifdef O_TMPFILE
    if ((flags & O_TMPFILE) == O_TMPFILE) {
        return 1;
    }
#endif
    return 0;
}

static int path_interesting(const char *path)
{
    return path != NULL && strstr(path, "nvidia") != NULL;
}

static int fd_interesting(int fd, char *target, size_t target_len)
{
    fd_target(fd, target, target_len);
    return strstr(target, "nvidia") != NULL;
}

static void log_open_event(const char *event, int dirfd, const char *path, int flags, mode_t mode, int rc, int saved_errno)
{
    struct timespec ts;
    char line[1024];
    long pid;
    long tid;

    syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts);
    pid = syscall(SYS_getpid);
    tid = syscall(SYS_gettid);

    snprintf(line, sizeof(line),
             "%lld.%09ld pid=%ld tid=%ld %s dirfd=%d path=%s flags=0x%x mode=0%o rc=%d errno=%d\n",
             (long long)ts.tv_sec, ts.tv_nsec, pid, tid, event, dirfd,
             path != NULL ? path : "(null)", flags, (unsigned int)mode, rc, saved_errno);
    write_fsynced(line);
}

static void log_close_event(const char *event, int fd, const char *target, int rc, int saved_errno)
{
    struct timespec ts;
    char line[1024];
    long pid;
    long tid;

    syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts);
    pid = syscall(SYS_getpid);
    tid = syscall(SYS_gettid);

    snprintf(line, sizeof(line),
             "%lld.%09ld pid=%ld tid=%ld %s fd=%d path=%s rc=%d errno=%d\n",
             (long long)ts.tv_sec, ts.tv_nsec, pid, tid, event, fd, target, rc, saved_errno);
    write_fsynced(line);
}

__attribute__((constructor))
static void init_trace(void)
{
    const char *path = getenv("AORUS_NVML_IOCTL_LOG");
    struct timespec ts;
    char line[256];

    if (path == NULL || path[0] == '\0') {
        path = "/root/aorus-5090-nvml-ioctl-trace.log";
    }

    log_fd = (int)syscall(SYS_openat, AT_FDCWD, path, O_CREAT | O_WRONLY | O_APPEND, 0600);
    real_ioctl_fn = dlsym(RTLD_NEXT, "ioctl");
    real_open_fn = dlsym(RTLD_NEXT, "open");
    real_open64_fn = dlsym(RTLD_NEXT, "open64");
    real_openat_fn = dlsym(RTLD_NEXT, "openat");
    real_openat64_fn = dlsym(RTLD_NEXT, "openat64");
    real_close_fn = dlsym(RTLD_NEXT, "close");

    syscall(SYS_clock_gettime, CLOCK_REALTIME, &ts);
    snprintf(line, sizeof(line), "%lld.%09ld trace_start pid=%ld real_ioctl=%p\n",
             (long long)ts.tv_sec, ts.tv_nsec, (long)syscall(SYS_getpid), (void *)real_ioctl_fn);
    write_fsynced(line);
}

__attribute__((destructor))
static void finish_trace(void)
{
    write_fsynced("trace_finish\n");
    if (log_fd >= 0) {
        syscall(SYS_close, log_fd);
        log_fd = -1;
    }
}

int ioctl(int fd, unsigned long request, ...)
{
    va_list ap;
    void *arg;
    int rc;
    int saved_errno;

    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);

    if (real_ioctl_fn == NULL) {
        real_ioctl_fn = dlsym(RTLD_NEXT, "ioctl");
    }

    log_event("ioctl_enter", fd, request, arg, -999999, 0);
    rc = real_ioctl_fn(fd, request, arg);
    saved_errno = errno;
    log_event("ioctl_exit", fd, request, arg, rc, saved_errno);
    errno = saved_errno;
    return rc;
}

int open(const char *pathname, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int rc;
    int saved_errno;
    int interesting = path_interesting(pathname);

    if (needs_open_mode(flags)) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    if (real_open_fn == NULL) {
        real_open_fn = dlsym(RTLD_NEXT, "open");
    }

    if (interesting) {
        log_open_event("open_enter", AT_FDCWD, pathname, flags, mode, -999999, 0);
    }

    if (needs_open_mode(flags)) {
        rc = real_open_fn(pathname, flags, mode);
    }
    else {
        rc = real_open_fn(pathname, flags);
    }

    saved_errno = errno;
    if (interesting) {
        log_open_event("open_exit", AT_FDCWD, pathname, flags, mode, rc, saved_errno);
    }
    errno = saved_errno;
    return rc;
}

int open64(const char *pathname, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int rc;
    int saved_errno;
    int interesting = path_interesting(pathname);

    if (needs_open_mode(flags)) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    if (real_open64_fn == NULL) {
        real_open64_fn = dlsym(RTLD_NEXT, "open64");
    }

    if (interesting) {
        log_open_event("open64_enter", AT_FDCWD, pathname, flags, mode, -999999, 0);
    }

    if (needs_open_mode(flags)) {
        rc = real_open64_fn(pathname, flags, mode);
    }
    else {
        rc = real_open64_fn(pathname, flags);
    }

    saved_errno = errno;
    if (interesting) {
        log_open_event("open64_exit", AT_FDCWD, pathname, flags, mode, rc, saved_errno);
    }
    errno = saved_errno;
    return rc;
}

int openat(int dirfd, const char *pathname, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int rc;
    int saved_errno;
    int interesting = path_interesting(pathname);

    if (needs_open_mode(flags)) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    if (real_openat_fn == NULL) {
        real_openat_fn = dlsym(RTLD_NEXT, "openat");
    }

    if (interesting) {
        log_open_event("openat_enter", dirfd, pathname, flags, mode, -999999, 0);
    }

    if (needs_open_mode(flags)) {
        rc = real_openat_fn(dirfd, pathname, flags, mode);
    }
    else {
        rc = real_openat_fn(dirfd, pathname, flags);
    }

    saved_errno = errno;
    if (interesting) {
        log_open_event("openat_exit", dirfd, pathname, flags, mode, rc, saved_errno);
    }
    errno = saved_errno;
    return rc;
}

int openat64(int dirfd, const char *pathname, int flags, ...)
{
    va_list ap;
    mode_t mode = 0;
    int rc;
    int saved_errno;
    int interesting = path_interesting(pathname);

    if (needs_open_mode(flags)) {
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    if (real_openat64_fn == NULL) {
        real_openat64_fn = dlsym(RTLD_NEXT, "openat64");
    }

    if (interesting) {
        log_open_event("openat64_enter", dirfd, pathname, flags, mode, -999999, 0);
    }

    if (needs_open_mode(flags)) {
        rc = real_openat64_fn(dirfd, pathname, flags, mode);
    }
    else {
        rc = real_openat64_fn(dirfd, pathname, flags);
    }

    saved_errno = errno;
    if (interesting) {
        log_open_event("openat64_exit", dirfd, pathname, flags, mode, rc, saved_errno);
    }
    errno = saved_errno;
    return rc;
}

int close(int fd)
{
    char target[256];
    int interesting;
    int rc;
    int saved_errno;

    if (real_close_fn == NULL) {
        real_close_fn = dlsym(RTLD_NEXT, "close");
    }

    interesting = fd_interesting(fd, target, sizeof(target));
    if (interesting) {
        log_close_event("close_enter", fd, target, -999999, 0);
    }

    rc = real_close_fn(fd);
    saved_errno = errno;
    if (interesting) {
        log_close_event("close_exit", fd, target, rc, saved_errno);
    }
    errno = saved_errno;
    return rc;
}
