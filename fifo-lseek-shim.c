/*
 * fifo-lseek-shim.c
 *
 * LD_PRELOAD shim that lets vanilla minidlna 1.3.0 stream video from a
 * named pipe (fifo) instead of a regular file.
 *
 * Why this is needed:
 *   - minidlna's SendResp_dlnafile() calls lseek(fd, 0, SEEK_END) to get
 *     the file size. On a fifo that returns -1/ESPIPE, so its send loop
 *     never executes and the client receives an empty body.
 *   - Its send_file() first tries sendfile64(). On a fifo that returns
 *     -1/ESPIPE, and minidlna only falls back to read/write on EINVAL or
 *     EOVERFLOW.
 *   - If a fifo ever reaches EOF (all write ends closed) while the HTTP
 *     client is still connected, minidlna's read/write fallback would
 *     otherwise spin forever on read() == 0.
 *
 * This shim, for fifo fds only:
 *   - makes lseek/lseek64 report a huge fake size (so the send loop runs),
 *   - makes sendfile/sendfile64 return EINVAL (so the read/write fallback
 *     is used),
 *   - turns a fifo read() EOF into EPIPE (so minidlna breaks cleanly
 *     instead of spinning).
 *
 * Regular files are passed through untouched.
 */

#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/sendfile.h>
#include <unistd.h>
#include <dlfcn.h>
#include <errno.h>

/* Content-Length reported to the client. Big enough that minidlna keeps
 * streaming until the client disconnects. 1 TiB. */
static off_t fake_size = (off_t)1 << 40;

static int is_fifo(int fd) {
    struct stat st;
    if (fstat(fd, &st) == 0 && S_ISFIFO(st.st_mode)) return 1;
    return 0;
}

typedef off_t (*lseek_fn)(int, off_t, int);
typedef off64_t (*lseek64_fn)(int, off64_t, int);
typedef ssize_t (*sendfile_fn)(int, int, off_t *, size_t);
typedef ssize_t (*sendfile64_fn)(int, int, off64_t *, size_t);
typedef ssize_t (*read_fn)(int, void *, size_t);

off_t lseek(int fd, off_t offset, int whence) {
    static lseek_fn real = NULL;
    if (!real) real = (lseek_fn)dlsym(RTLD_NEXT, "lseek");
    if (is_fifo(fd)) {
        if (whence == SEEK_END) return fake_size;
        if (whence == SEEK_SET) return offset;
        errno = ESPIPE;
        return (off_t)-1;
    }
    return real(fd, offset, whence);
}

off64_t lseek64(int fd, off64_t offset, int whence) {
    static lseek64_fn real = NULL;
    if (!real) real = (lseek64_fn)dlsym(RTLD_NEXT, "lseek64");
    if (is_fifo(fd)) {
        if (whence == SEEK_END) return (off64_t)fake_size;
        if (whence == SEEK_SET) return offset;
        errno = ESPIPE;
        return (off64_t)-1;
    }
    return real(fd, offset, whence);
}

ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count) {
    static sendfile_fn real = NULL;
    if (!real) real = (sendfile_fn)dlsym(RTLD_NEXT, "sendfile");
    if (is_fifo(in_fd)) { errno = EINVAL; return (ssize_t)-1; }
    return real(out_fd, in_fd, offset, count);
}

ssize_t sendfile64(int out_fd, int in_fd, off64_t *offset, size_t count) {
    static sendfile64_fn real = NULL;
    if (!real) real = (sendfile64_fn)dlsym(RTLD_NEXT, "sendfile64");
    if (is_fifo(in_fd)) { errno = EINVAL; return (ssize_t)-1; }
    return real(out_fd, in_fd, offset, count);
}

ssize_t read(int fd, void *buf, size_t count) {
    static read_fn real = NULL;
    if (!real) real = (read_fn)dlsym(RTLD_NEXT, "read");
    ssize_t r = real(fd, buf, count);
    if (r == 0 && is_fifo(fd)) {
        errno = EPIPE;
        return (ssize_t)-1;
    }
    return r;
}
