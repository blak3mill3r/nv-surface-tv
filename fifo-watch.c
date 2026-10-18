/*
 * fifo-watch.c
 *
 * Waits for readers of a fifo without polling or privileges.
 *
 * Protocol on stdout (line-buffered):
 *   up     a reader has opened the fifo
 *   down   the last reader closed it
 *
 * How it works:
 *   open(fifo, O_WRONLY) blocks until a reader opens the fifo. Once the open
 *   succeeds, a reader is present. While we hold the write end, poll() on it
 *   reports POLLOUT while at least one reader exists and POLLERR once all
 *   readers are gone. We then close, print "down", and reopen (blocking) for
 *   the next reader.
 *
 * This is a drop-in replacement for the `sudo lsof` reader probe.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <signal.h>

static volatile sig_atomic_t stop = 0;

static void on_signal(int sig) {
    (void)sig;
    stop = 1;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s FIFO\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];

    setvbuf(stdout, NULL, _IONBF, 0);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    for (;;) {
        if (stop) break;

        /* Block until a reader opens the fifo. */
        int fd = open(path, O_WRONLY);
        if (fd < 0) {
            if (errno == EINTR) {
                if (stop) break;
                continue;   /* spurious EINTR: retry the blocking open */
            }
            perror("open");
            return 1;
        }

        if (printf("up\n") < 0 || fflush(stdout) != 0) {
            close(fd);
            return 0;
        }

        /* Hold until every reader is gone. We poll with events=0: on Linux
         * POLLERR/POLLHUP/POLLNVAL are reported even when not requested, so
         * this blocks (waking once a second for the timeout) until the write
         * end goes bad -- i.e. no readers left. Polling POLLOUT here would
         * spin while a reader is present. */
        for (;;) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = 0;
            pfd.revents = 0;

            int r = poll(&pfd, 1, 1000);
            if (r < 0) {
                if (errno == EINTR) {
                    if (stop) break;
                    continue;
                }
                perror("poll");
                close(fd);
                return 1;
            }
            if (r == 0) {
                /* Timeout: keep waiting (still has at least one reader). */
                continue;
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                /* All readers are gone. */
                break;
            }
        }

        close(fd);

        if (stop) break;

        if (printf("down\n") < 0 || fflush(stdout) != 0) {
            return 0;
        }
    }

    return 0;
}
