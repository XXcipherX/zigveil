/* Optional Linux workload tool, compiled by Zig. Never linked into the daemon.
 * Bounded echo credit, exact deterministic payload checks and ready/go barriers.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <linux/sockios.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PERIOD (1u << 20)
#define QUEUE 65536u
#define BATCH 1024
#define FD_CAP 65536
static unsigned char pattern[PERIOD];
static volatile sig_atomic_t stopping;
static char failure[160];

typedef struct {
    int fd;
    uint32_t mask;
    uint64_t tx, rx, peak;
    int eof, fin;
} Stream;

typedef struct {
    int fd, eof;
    uint32_t mask;
    unsigned head, len;
    unsigned char data[QUEUE];
} Echo;

typedef struct {
    int port, count, control, fast_echo;
    unsigned chunk, window;
    double duration, warmup, drain;
} Options;

static uint64_t now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static int fail(const char *what) {
    if (!failure[0]) snprintf(failure, sizeof(failure), "%s", what);
    return -1;
}

static int rearm(int epoll, int fd, uint32_t *old, uint32_t mask, uint32_t index) {
    if (*old == mask) return 0;
    struct epoll_event event = {.events = mask, .data.u32 = index};
    if (epoll_ctl(epoll, *old ? EPOLL_CTL_MOD : EPOLL_CTL_ADD, fd, &event)) return fail("epoll registration");
    *old = mask;
    return 0;
}

static void on_signal(int signum) { (void)signum; stopping = 1; }

static int serve(int port, int fast_echo) {
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    int epoll = epoll_create1(EPOLL_CLOEXEC), yes = 1;
    Echo **slots = calloc(FD_CAP, sizeof(*slots));
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (listener < 0 || epoll < 0 || !slots) return fail("origin startup");
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes)) ||
        bind(listener, (struct sockaddr *)&addr, sizeof(addr)) || listen(listener, 4096)) return fail("origin listen");
    uint32_t listener_mask = 0;
    if (rearm(epoll, listener, &listener_mask, EPOLLIN, FD_CAP)) return -1;
    int shared_pipe[2] = {-1, -1}, pipe_error = 0;
    if (fast_echo && (pipe2(shared_pipe, O_NONBLOCK | O_CLOEXEC) || fcntl(shared_pipe[0], F_SETPIPE_SZ, (int)QUEUE) != (int)QUEUE)) {
        pipe_error = errno;
        if (shared_pipe[0] >= 0) { close(shared_pipe[0]); close(shared_pipe[1]); }
        shared_pipe[0] = shared_pipe[1] = -1;
        fast_echo = 0;
    }
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    printf("{\"event\":\"origin_ready\",\"port\":%d,\"engine\":\"native\",\"echo_io\":\"%s\",\"pipe_capacity\":%u,\"pipe_error\":%d}\n",
           port, fast_echo ? "shared-splice" : "buffered", fast_echo ? QUEUE : 0, pipe_error);
    fflush(stdout);
    struct epoll_event events[BATCH];
    while (!stopping) {
        int count = epoll_wait(epoll, events, BATCH, 250);
        if (count < 0) { if (errno == EINTR) continue; return fail("origin epoll wait"); }
        for (int i = 0; i < count; i++) {
            uint32_t index = events[i].data.u32;
            if (index == FD_CAP) {
                for (int calls = 0; calls < 64; calls++) {
                    int fd = accept4(listener, NULL, NULL, SOCK_NONBLOCK | SOCK_CLOEXEC);
                    if (fd < 0) { if (errno == EAGAIN) break; if (errno == EINTR) continue; return fail("origin accept"); }
                    if (fd >= FD_CAP) { close(fd); return fail("origin fd capacity"); }
                    Echo *e = calloc(1, sizeof(*e));
                    if (!e) { close(fd); return fail("origin queue allocation"); }
                    e->fd = fd;
                    slots[fd] = e;
                    if (setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes)) || rearm(epoll, fd, &e->mask, EPOLLIN | EPOLLRDHUP, (uint32_t)fd)) return -1;
                }
                continue;
            }
            Echo *e = slots[index];
            if (!e) continue;
            int read_blocked = 0, write_blocked = 0, dead = 0;
            for (int calls = 0; calls < 128;) {
                int progress = 0;
                if (e->len && !write_blocked) {
                    size_t queued = e->len < QUEUE - e->head ? e->len : QUEUE - e->head;
                    ssize_t n = send(e->fd, e->data + e->head, queued, MSG_NOSIGNAL);
                    calls++;
                    if (n < 0) {
                        if (errno == EINTR) continue;
                        if (errno == EAGAIN) write_blocked = 1; else { dead = 1; break; }
                    } else if (n == 0) { dead = 1; break; }
                    else { e->head = (e->head + (unsigned)n) % QUEUE; e->len -= (unsigned)n; if (!e->len) e->head = 0; progress = 1; }
                }
                if (fast_echo && !e->eof && !read_blocked && !e->len && calls < 128) {
                    ssize_t n = splice(e->fd, NULL, shared_pipe[1], NULL, QUEUE, SPLICE_F_NONBLOCK);
                    calls++;
                    if (n < 0) {
                        if (errno == EINTR) continue;
                        if (errno == EAGAIN) read_blocked = 1; else { dead = 1; break; }
                    } else if (!n) { e->eof = 1; progress = 1; }
                    else {
                        unsigned pending = (unsigned)n;
                        while (pending && calls < 128) {
                            ssize_t written = splice(shared_pipe[0], NULL, e->fd, NULL, pending, SPLICE_F_NONBLOCK);
                            calls++;
                            if (written < 0) {
                                if (errno == EINTR) continue;
                                if (errno == EAGAIN) write_blocked = 1; else dead = 1;
                                break;
                            }
                            if (!written) { dead = 1; break; }
                            pending -= (unsigned)written;
                        }
                        /* One shared pipe avoids per-stream pipe quotas in the
                         * origin. Partial/blocked output is copied into that
                         * stream's bounded reference queue before another
                         * connection may borrow the pipe. It is always empty
                         * when this callback ends, including resets/budget exits. */
                        unsigned copied = 0;
                        while (copied < pending) {
                            ssize_t drained = read(shared_pipe[0], e->data + copied, pending - copied);
                            if (drained < 0 && errno == EINTR) continue;
                            if (drained <= 0) return fail("origin shared pipe reclamation");
                            copied += (unsigned)drained;
                        }
                        e->head = 0;
                        e->len = dead ? 0 : pending;
                        progress = 1;
                        if (dead) break;
                    }
                } else if (!e->eof && !read_blocked && e->len < QUEUE && calls < 128) {
                    unsigned tail = (e->head + e->len) % QUEUE;
                    unsigned room = QUEUE - e->len < QUEUE - tail ? QUEUE - e->len : QUEUE - tail;
                    ssize_t n = recv(e->fd, e->data + tail, room, 0);
                    calls++;
                    if (n < 0) {
                        if (errno == EINTR) continue;
                        if (errno == EAGAIN) read_blocked = 1; else { dead = 1; break; }
                    } else { if (n == 0) e->eof = 1; else e->len += (unsigned)n; progress = 1; }
                }
                if (e->eof && !e->len) { shutdown(e->fd, SHUT_WR); dead = 1; break; }
                if (!progress) break;
            }
            if (dead) { epoll_ctl(epoll, EPOLL_CTL_DEL, e->fd, NULL); close(e->fd); slots[index] = NULL; free(e); }
            else {
                uint32_t mask = (!e->eof && e->len < QUEUE ? EPOLLIN | EPOLLRDHUP : 0) | (e->len ? EPOLLOUT : 0);
                if (rearm(epoll, e->fd, &e->mask, mask, index)) return -1;
            }
        }
    }
    for (int i = 0; i < FD_CAP; i++) if (slots[i]) { close(slots[i]->fd); free(slots[i]); }
    free(slots);
    close(listener);
    close(epoll);
    if (shared_pipe[0] >= 0) { close(shared_pipe[0]); close(shared_pipe[1]); }
    return 0;
}

static unsigned hello(unsigned char *wire) {
    /* TLS record + handshake + bounded ClientHello with example.com outer name. */
    unsigned char value[] = {
        0x16,3,1,0,67, 1,0,0,63, 3,3,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,2,0x13,1,1,0,0,20, 0,0,0,16,0,14,0,0,11,
        'e','x','a','m','p','l','e','.','c','o','m'
    };
    memcpy(wire, value, sizeof(value));
    return sizeof(value);
}

static int establish(int port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), yes = 1;
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0};
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (fd < 0) return fail("client socket");
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) ||
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes)) ||
        connect(fd, (struct sockaddr *)&addr, sizeof(addr))) { close(fd); return fail("client connect"); }
    unsigned char wire[256], echoed[256];
    unsigned length = hello(wire), sent = 0, received = 0;
    while (sent < length) {
        ssize_t n = send(fd, wire + sent, length - sent, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return fail("ClientHello send"); }
        sent += (unsigned)n;
    }
    while (received < length) {
        ssize_t n = recv(fd, echoed + received, length - received, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return fail("ClientHello echo"); }
        received += (unsigned)n;
    }
    if (memcmp(wire, echoed, length)) { close(fd); return fail("ClientHello corruption"); }
    if (fcntl(fd, F_SETFL, O_NONBLOCK)) { close(fd); return fail("client nonblocking"); }
    return fd;
}

static int command(int fd, const char *expected) {
    if (fd < 0) return 0;
    char line[256];
    unsigned length = 0;
    while (length + 1 < sizeof(line)) {
        ssize_t n = read(fd, line + length, 1);
        if (n < 0 && errno == EINTR) continue;
        if (n != 1) return fail("coordinator command EOF");
        if (line[length++] == '\n') break;
    }
    line[length] = 0;
    char token[64];
    snprintf(token, sizeof(token), "\"%s\"", expected);
    return strstr(line, token) ? 0 : fail("unexpected coordinator command");
}

static int verify(const unsigned char *data, size_t length, uint64_t offset) {
    while (length) {
        unsigned at = (unsigned)(offset % PERIOD);
        size_t n = length < PERIOD - at ? length : PERIOD - at;
        if (memcmp(data, pattern + at, n)) return fail("bulk echo corruption");
        offset += n; data += n; length -= n;
    }
    return 0;
}

static void totals(Stream *streams, int count, uint64_t *tx, uint64_t *rx, uint64_t *peak, int *completed) {
    *tx = *rx = *peak = 0; *completed = 0;
    for (int i = 0; i < count; i++) {
        *tx += streams[i].tx; *rx += streams[i].rx;
        if (streams[i].peak > *peak) *peak = streams[i].peak;
        if (streams[i].eof && streams[i].tx == streams[i].rx) (*completed)++;
    }
}

static int traffic(Stream *streams, const Options *o, double seconds, int finish, uint64_t *elapsed_ns) {
    int epoll = epoll_create1(EPOLL_CLOEXEC);
    if (epoll < 0) return fail("generator epoll");
    struct epoll_event events[BATCH];
    unsigned char input[QUEUE];
    uint64_t start = now_ns(), deadline = start + (uint64_t)(seconds * 1e9), drain_deadline = deadline + (uint64_t)(o->drain * 1e9);
    int ended = 0, result = 0, completed = 0;
    uint64_t tx = 0, rx = 0, peak = 0;
    for (int i = 0; i < o->count; i++) {
        streams[i].mask = 0;
        if (rearm(epoll, streams[i].fd, &streams[i].mask, EPOLLIN | EPOLLOUT | EPOLLRDHUP, (uint32_t)i)) { result = -1; goto done; }
    }
    while (1) {
        uint64_t now = now_ns();
        if (!ended && now >= deadline) {
            ended = 1;
            totals(streams, o->count, &tx, &rx, &peak, &completed);
            if (finish && o->control >= 0) {
                dprintf(o->control, "{\"event\":\"window\",\"start_ns\":%llu,\"end_ns\":%llu,\"tx\":%llu,\"rx\":%llu}\n",
                        (unsigned long long)start, (unsigned long long)now, (unsigned long long)tx, (unsigned long long)rx);
                if (command(o->control, "ack")) { result = -1; goto done; }
            }
            for (int i = 0; i < o->count; i++) {
                if (finish) {
                    if (shutdown(streams[i].fd, SHUT_WR)) { result = fail("generator half-close"); goto done; }
                    streams[i].fin = 1;
                }
                if (rearm(epoll, streams[i].fd, &streams[i].mask, EPOLLIN | EPOLLRDHUP, (uint32_t)i)) { result = -1; goto done; }
            }
        }
        if (ended) {
            totals(streams, o->count, &tx, &rx, &peak, &completed);
            if ((finish && completed == o->count) || (!finish && tx == rx)) break;
            if (now >= drain_deadline) { result = fail("payload/FIN drain timed out"); goto done; }
        }
        int timeout = ended ? 100 : (int)((deadline - now + 999999) / 1000000);
        int count = epoll_wait(epoll, events, BATCH, timeout);
        if (count < 0) { if (errno == EINTR) continue; result = fail("generator epoll wait"); goto done; }
        for (int j = 0; j < count; j++) {
            Stream *s = &streams[events[j].data.u32];
            if (s->eof) continue;
            for (int calls = 0; calls < 32; calls++) {
                ssize_t n = recv(s->fd, input, sizeof(input), 0);
                if (n < 0) { if (errno == EINTR) continue; if (errno == EAGAIN) break; result = fail("generator recv"); goto done; }
                if (!n) {
                    if (!s->fin || s->rx != s->tx) { result = fail("premature EOF or lost bytes"); goto done; }
                    s->eof = 1;
                    epoll_ctl(epoll, EPOLL_CTL_DEL, s->fd, NULL);
                    break;
                }
                if (s->rx + (uint64_t)n > s->tx || verify(input, (size_t)n, s->rx)) { result = fail("unexpected echo bytes"); goto done; }
                s->rx += (uint64_t)n;
            }
            if (s->eof) continue;
            for (int calls = 0; calls < 32 && !ended && now_ns() < deadline && s->tx - s->rx < o->window; calls++) {
                unsigned offset = (unsigned)(s->tx % PERIOD);
                unsigned size = o->chunk;
                uint64_t credit = o->window - (s->tx - s->rx);
                if (size > credit) size = (unsigned)credit;
                if (size > PERIOD - offset) size = PERIOD - offset;
                ssize_t n = send(s->fd, pattern + offset, size, MSG_NOSIGNAL);
                if (n < 0) { if (errno == EINTR) continue; if (errno == EAGAIN) break; result = fail("generator send"); goto done; }
                if (!n) { result = fail("generator zero write"); goto done; }
                s->tx += (uint64_t)n;
                if (s->tx - s->rx > s->peak) s->peak = s->tx - s->rx;
            }
            uint32_t mask = EPOLLIN | EPOLLRDHUP | (!ended && s->tx - s->rx < o->window ? EPOLLOUT : 0);
            if (rearm(epoll, s->fd, &s->mask, mask, events[j].data.u32)) { result = -1; goto done; }
        }
    }
done:
    if (result) {
        int reported = 0;
        for (int i = 0; i < o->count && reported < 8; i++) {
            Stream *s = &streams[i];
            if (s->tx == s->rx && (!finish || s->eof)) continue;
            struct tcp_info info = {0};
            socklen_t size = sizeof(info);
            int receive_queue = -1, send_queue = -1;
            int valid = !getsockopt(s->fd, IPPROTO_TCP, TCP_INFO, &info, &size);
            (void)ioctl(s->fd, FIONREAD, &receive_queue);
            (void)ioctl(s->fd, SIOCOUTQ, &send_queue);
            fprintf(stderr, "unfinished stream=%d tx=%llu rx=%llu fin=%d eof=%d recv_queue=%d send_queue=%d tcp_info=%d state=%u unacked=%u rcv_space=%u\n",
                    i, (unsigned long long)s->tx, (unsigned long long)s->rx, s->fin, s->eof,
                    receive_queue, send_queue, valid, info.tcpi_state, info.tcpi_unacked, info.tcpi_rcv_space);
            reported++;
        }
    }
    *elapsed_ns = now_ns() - start;
    close(epoll);
    return result;
}

static int run(const Options *o) {
    Stream *streams = calloc((size_t)o->count, sizeof(*streams));
    if (!streams) return fail("stream allocation");
    for (int i = 0; i < o->count; i++) streams[i].fd = -1;
    uint64_t seed = 0x7a69677665696cULL;
    for (unsigned i = 0; i < PERIOD; i += 8) {
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        memcpy(pattern + i, &seed, 8);
    }
    int result = 0, established = 0;
    uint64_t elapsed = 0;
    for (int i = 0; i < o->count; i++) {
        streams[i].fd = establish(o->port);
        if (streams[i].fd < 0) { result = -1; goto done; }
        established++;
    }
    if (o->warmup && traffic(streams, o, o->warmup, 0, &elapsed)) { result = -1; goto done; }
    for (int i = 0; i < o->count; i++) { streams[i].tx = streams[i].rx = streams[i].peak = 0; }
    if (o->control >= 0) {
        dprintf(o->control, "{\"event\":\"ready\",\"streams\":%d,\"warmup_s\":%.3f}\n", o->count, o->warmup);
        if (command(o->control, "go")) { result = -1; goto done; }
    }
    result = traffic(streams, o, o->duration, 1, &elapsed);
done:
    for (int i = 0; i < o->count; i++) if (streams[i].fd >= 0) close(streams[i].fd);
    uint64_t tx, rx, peak;
    int completed;
    totals(streams, o->count, &tx, &rx, &peak, &completed);
    double seconds = elapsed / 1e9;
    if (o->control >= 0 && established == o->count && !result) {
        dprintf(o->control, "{\"event\":\"drained\",\"valid\":true}\n");
        if (command(o->control, "finish")) result = -1;
    }
    printf("{\"mode\":\"bulk\",\"engine\":\"native\",\"concurrency\":%d,\"valid\":%s,\"seconds\":%.9f,"
           "\"duration_requested_s\":%.3f,\"drain_seconds\":%.9f,\"bytes_client_to_backend\":%llu,\"bytes_backend_to_client\":%llu,"
           "\"connections\":%d,\"completed_streams\":%d,\"failed_streams\":%d,\"unfinished_streams\":%d,\"unfinished_workers\":%d,"
           "\"inflight_bytes_per_stream\":%u,\"max_observed_inflight_bytes_per_stream\":%llu,\"unreturned_bytes\":%llu,"
           "\"round_trips\":0,\"round_trips_per_second\":null,\"connections_per_second\":null,\"latency_sample_count\":0,"
           "\"latency_us_p50\":null,\"latency_us_p90\":null,\"latency_us_p95\":null,\"latency_us_p99\":null,\"latency_us_p999\":null,\"latency_us_max\":null,"
           "\"corruption_events\":%d,\"timed_out\":%s,\"error_count\":%d,",
           o->count, result ? "false" : "true", seconds, o->duration, seconds > o->duration ? seconds - o->duration : 0,
           (unsigned long long)tx, (unsigned long long)rx, completed, completed, result ? 1 : 0,
           o->count - completed, o->count - completed, o->window, (unsigned long long)peak,
           (unsigned long long)(tx >= rx ? tx - rx : 0), strstr(failure, "corruption") != NULL,
           strstr(failure, "timed out") ? "true" : "false", result ? 1 : 0);
    if (result) printf("\"echo_goodput_gbit_s\":null,\"aggregate_forwarded_gbit_s\":null,\"errors\":[\"%s\"]}\n", failure);
    else printf("\"echo_goodput_gbit_s\":%.9f,\"aggregate_forwarded_gbit_s\":%.9f,\"errors\":[]}\n", rx * 8. / seconds / 1e9, (tx + rx) * 8. / seconds / 1e9);
    free(streams);
    return result ? 1 : 0;
}

int main(int argc, char **argv) {
    Options o = {.port = 9443, .count = 1, .control = -1, .chunk = 65536, .window = 262144, .duration = 30, .warmup = 0, .drain = 15};
    if (argc < 2 || (strcmp(argv[1], "serve") && strcmp(argv[1], "run"))) { fprintf(stderr, "expected serve or run\n"); return 2; }
    for (int i = 2; i + 1 < argc; i += 2) {
        const char *key = argv[i], *value = argv[i + 1];
        if (!strcmp(key, "--port")) o.port = atoi(value);
        else if (!strcmp(key, "--concurrency")) o.count = atoi(value);
        else if (!strcmp(key, "--control-fd")) o.control = atoi(value);
        else if (!strcmp(key, "--chunk-bytes")) o.chunk = (unsigned)strtoul(value, NULL, 10);
        else if (!strcmp(key, "--inflight-bytes")) o.window = (unsigned)strtoul(value, NULL, 10);
        else if (!strcmp(key, "--duration")) o.duration = strtod(value, NULL);
        else if (!strcmp(key, "--warmup")) o.warmup = strtod(value, NULL);
        else if (!strcmp(key, "--drain-timeout")) o.drain = strtod(value, NULL);
        else if (!strcmp(key, "--echo-io") && (!strcmp(value, "buffered") || !strcmp(value, "splice"))) o.fast_echo = !strcmp(value, "splice");
        else if (!strcmp(key, "--mode") && !strcmp(value, "bulk")) {}
        else { fprintf(stderr, "unsupported native option: %s\n", key); return 2; }
    }
    if ((argc - 2) % 2 || o.port < 1 || o.port > 65535 || o.count < 1 || o.count > 10000 ||
        o.chunk < 256 || o.chunk > PERIOD || o.chunk % 256 || o.window < o.chunk || o.window > (1u << 26) ||
        !isfinite(o.duration) || o.duration <= 0 || o.duration > 60 || !isfinite(o.warmup) || o.warmup < 0 || o.warmup > 30 ||
        !isfinite(o.drain) || o.drain <= 0 || o.drain > 120) { fprintf(stderr, "native argument out of range\n"); return 2; }
    signal(SIGPIPE, SIG_IGN);
    int result = !strcmp(argv[1], "serve") ? serve(o.port, o.fast_echo) : run(&o);
    if (result && failure[0]) fprintf(stderr, "%s\n", failure);
    return result < 0 ? 1 : result;
}
