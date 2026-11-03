// In-process libssh2 C engine: connection/authentication/host-key checks and exec with stdin/timeouts/streaming/uploads,
// PTY shells, libssh2_sftp_* SFTP, multiplexed -L/-R/-D forwarding, and staged connection tests.
// Replaces all formerly spawned /usr/bin/ssh paths.
#include "ServerDockSSHCore.h"

#include <libssh2.h>
#include <libssh2_sftp.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netdb.h>
#include <netinet/in.h>
#include <time.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/wait.h>

extern char **environ;

// Utilities.
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

// Standard unpadded base64 for OpenSSH fingerprints. dst needs at least ((len+2)/3)*4 + 1 bytes.
static void b64_nopad(const unsigned char *src, size_t len, char *dst) {
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8) | src[i + 2];
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];  dst[o++] = B64[v & 63];
        i += 3;
    }
    if (len - i == 1) {
        unsigned v = src[i] << 16;
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
    } else if (len - i == 2) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8);
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];
    }
    dst[o] = '\0';
}

// Standard padded base64 for known_hosts lines. dst needs at least ((len+2)/3)*4 + 1 bytes.
static void b64_pad(const unsigned char *src, size_t len, char *dst, size_t dstcap) {
    size_t need = ((len + 2) / 3) * 4;
    if (dstcap < need + 1) { if (dstcap) dst[0] = '\0'; return; }
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8) | src[i + 2];
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];  dst[o++] = B64[v & 63];
        i += 3;
    }
    size_t rem = len - i;
    if (rem == 1) {
        unsigned v = src[i] << 16;
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = '='; dst[o++] = '=';
    } else if (rem == 2) {
        unsigned v = (src[i] << 16) | (src[i + 1] << 8);
        dst[o++] = B64[(v >> 18) & 63]; dst[o++] = B64[(v >> 12) & 63];
        dst[o++] = B64[(v >> 6) & 63];  dst[o++] = '=';
    }
    dst[o] = '\0';
}

// After handshake, write SHA256:base64 and colon-separated MD5 fingerprints to sha/md5 buffers.
static void fill_fingerprints(LIBSSH2_SESSION *session, char *sha, size_t shacap, char *md5, size_t md5cap) {
    if (sha && shacap) {
        const char *h = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
        if (h) { char b64[64]; b64_nopad((const unsigned char *)h, 32, b64); snprintf(sha, shacap, "SHA256:%s", b64); }
        else sha[0] = '\0';
    }
    if (md5 && md5cap) {
        const char *h = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_MD5);
        if (h) { char *p = md5; for (int i = 0; i < 16; i++) p += snprintf(p, 4, i ? ":%02x" : "%02x", (unsigned char)h[i]); }
        else md5[0] = '\0';
    }
}

static const char *hostkey_typename(int keytype) {
    switch (keytype) {
        case LIBSSH2_HOSTKEY_TYPE_RSA:       return "ssh-rsa";
        case LIBSSH2_HOSTKEY_TYPE_DSS:       return "ssh-dss";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return "ecdsa-sha2-nistp256";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return "ecdsa-sha2-nistp384";
        case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return "ecdsa-sha2-nistp521";
        case LIBSSH2_HOSTKEY_TYPE_ED25519:   return "ssh-ed25519";
        default: return NULL;
    }
}

// Compare the session host key against known_hosts; return 0=match, 1=unknown, 2=mismatch.
// If line_out is set, produce a standard trust line. Treat missing keys/parse failures as unknown, never falsely as mismatches.
static int hostkey_check(LIBSSH2_SESSION *session, const char *host, int port,
                         const char *real_file, const char *session_file,
                         char *line_out, size_t line_cap) {
    if (line_out && line_cap) line_out[0] = '\0';
    size_t keylen = 0; int keytype = 0;
    const char *key = libssh2_session_hostkey(session, &keylen, &keytype);
    if (!key) return 1;

    if (line_out && line_cap) {
        const char *tn = hostkey_typename(keytype);
        if (tn) {
            char spec[300];
            if (port == 22) snprintf(spec, sizeof(spec), "%s", host);
            else snprintf(spec, sizeof(spec), "[%s]:%d", host, port);
            size_t cap = ((keylen + 2) / 3) * 4 + 1;
            char *b64 = malloc(cap);
            if (b64) { b64_pad((const unsigned char *)key, keylen, b64, cap);
                       snprintf(line_out, line_cap, "%s %s %s", spec, tn, b64); free(b64); }
        }
    }

    LIBSSH2_KNOWNHOSTS *nh = libssh2_knownhost_init(session);
    if (!nh) return 1;
    if (real_file && *real_file)    libssh2_knownhost_readfile(nh, real_file, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
    if (session_file && *session_file) libssh2_knownhost_readfile(nh, session_file, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
    struct libssh2_knownhost *kh = NULL;
    int check = libssh2_knownhost_checkp(nh, host, port, key, keylen,
                                         LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW, &kh);
    libssh2_knownhost_free(nh);
    if (check == LIBSSH2_KNOWNHOST_CHECK_MATCH)    return 0;
    if (check == LIBSSH2_KNOWNHOST_CHECK_MISMATCH) return 2;
    return 1;   // NOTFOUND / FAILURE means unknown; permit connection.
}

// Jump hosts (ProxyJump).
// Connect stdin/stdout of /usr/bin/ssh -W host:port <jump> to a socketpair,
// using the other fd as libssh2 transport, like ProxyCommand. Delegate jump authentication to ~/.ssh/config/keys/agent.
static void *reap_thread(void *arg) {
    pid_t pid = (pid_t)(intptr_t)arg;
    int st; waitpid(pid, &st, 0);
    return NULL;
}

static int jump_connect(const char *jump, const char *host, int port, char *err, size_t errlen) {
    // Prevent argument injection: allowlisted characters, no leading '-'.
    if (!jump || !*jump || jump[0] == '-') { snprintf(err, errlen, "Invalid jump host"); return -1; }
    for (const char *p = jump; *p; p++) {
        if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') ||
              strchr("._@:[]%,-", *p))) { snprintf(err, errlen, "Invalid jump host"); return -1; }
    }
    char *j = strdup(jump);
    char *last = strrchr(j, ',');
    char *dest = last ? last + 1 : j;          // Last hop is ssh's destination; earlier hops form the -J chain.
    if (last) *last = '\0';
    if (!*dest || dest[0] == '-') { free(j); snprintf(err, errlen, "Invalid jump host"); return -1; }
    char target[300]; snprintf(target, sizeof(target), "%s:%d", host, port);

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { free(j); snprintf(err, errlen, "socketpair failed"); return -1; }
    int one = 1; setsockopt(sv[0], SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, sv[1], 0);
    posix_spawn_file_actions_adddup2(&fa, sv[1], 1);
    posix_spawn_file_actions_addclose(&fa, sv[0]);
    posix_spawn_file_actions_addclose(&fa, sv[1]);
    char *argv[16]; int n = 0;
    argv[n++] = "ssh"; argv[n++] = "-T"; argv[n++] = "-o"; argv[n++] = "BatchMode=yes";
    argv[n++] = "-o"; argv[n++] = "ConnectTimeout=10";
    if (last) { argv[n++] = "-J"; argv[n++] = j; }
    argv[n++] = "-W"; argv[n++] = target; argv[n++] = dest; argv[n] = NULL;
    pid_t pid;
    int rc = posix_spawn(&pid, "/usr/bin/ssh", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(sv[1]); free(j);
    if (rc != 0) { close(sv[0]); snprintf(err, errlen, "Failed to launch ssh for jump host"); return -1; }
    pthread_t th; pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, reap_thread, (void *)(intptr_t)pid) != 0) { /* Only a potential zombie remains. */ }
    pthread_attr_destroy(&at);
    return sv[0];
}

static int tcp_connect_via(const char *host, int port, int timeout_sec, const char *jump, char *err, size_t errlen);
// Nonblocking connect with select timeout in seconds; return a connected blocking socket fd or -1 on failure.
static int tcp_connect(const char *host, int port, int timeout_sec, char *err, size_t errlen) {
    return tcp_connect_via(host, port, timeout_sec, NULL, err, errlen);
}

static int tcp_connect_via(const char *host, int port, int timeout_sec, const char *jump, char *err, size_t errlen) {
    if (jump && *jump) return jump_connect(jump, host, port, err, errlen);
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(host, portstr, &hints, &res);
    if (gai != 0) {
        snprintf(err, errlen, "Failed to resolve host: %s", gai_strerror(gai));
        return -1;
    }
    int sock = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) { fcntl(sock, F_SETFL, flags); break; }   // Connected immediately.
        if (errno == EINPROGRESS) {
            fd_set wf; FD_ZERO(&wf); FD_SET(sock, &wf);
            struct timeval tv = { timeout_sec, 0 };
            rc = select(sock + 1, NULL, &wf, NULL, &tv);
            if (rc > 0) {
                int soerr = 0; socklen_t l = sizeof(soerr);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &l);
                if (soerr == 0) { fcntl(sock, F_SETFL, flags); break; }  // Connected.
            }
        }
        close(sock); sock = -1;   // This address failed; try the next.
    }
    freeaddrinfo(res);
    if (sock < 0) snprintf(err, errlen, "Connection to %s:%d failed or timed out", host, port);
    return sock;
}

// Persistent sessions.
struct ServerDockSSHSession {
    int sock;
    LIBSSH2_SESSION *session;
    char fp_sha256[80];
    char fp_md5[64];
    volatile int cancel;   // Streaming cancellation flag set by another thread.
};

/// key_path="agent:<socket>" selects libssh2 agent auth for 1Password/Secretive/ssh-agent.
/// Empty socket uses SSH_AUTH_SOCK; try all agent keys without importing private material into the app.
static int agent_auth(LIBSSH2_SESSION *session, const char *user, const char *spec,
                      char *err, size_t errlen) {
    LIBSSH2_AGENT *agent = libssh2_agent_init(session);
    if (!agent) { snprintf(err, errlen, "SSH agent initialization failed"); return -1; }
    const char *sock = spec + 6;
    if (*sock) libssh2_agent_set_identity_path(agent, sock);
    int rc = libssh2_agent_connect(agent);
    if (rc) {
        snprintf(err, errlen, "Could not connect to the SSH agent (%s). Check that it is running and its SSH agent option is enabled", *sock ? sock : "SSH_AUTH_SOCK");
        libssh2_agent_free(agent); return -1;
    }
    rc = libssh2_agent_list_identities(agent);
    if (rc) {
        snprintf(err, errlen, "Could not list the SSH agent's keys (%d); it may be locked", rc);
        libssh2_agent_disconnect(agent); libssh2_agent_free(agent); return -1;
    }
    struct libssh2_agent_publickey *id = NULL, *prev = NULL;
    int n = 0, authed = -1;
    while (libssh2_agent_get_identity(agent, &id, prev) == 0) {
        n++;
        if (libssh2_agent_userauth(agent, user ? user : "", id) == 0) { authed = 0; break; }
        prev = id;
    }
    if (authed != 0)
        snprintf(err, errlen, n ? "None of the SSH agent's %d keys was accepted by the server" : "The SSH agent has no keys loaded", n);
    libssh2_agent_disconnect(agent);
    libssh2_agent_free(agent);
    return authed;
}


ServerDockSSHSession *serverdock_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                const char *jump, char *err, int errlen) {
    libssh2_init(0);   // Reference-counted and safe to call repeatedly.
    int sock = tcp_connect_via(host ? host : "", port, 10, jump, err, (size_t)errlen);
    if (sock < 0) return NULL;

    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) {
        snprintf(err, (size_t)errlen, "libssh2_session_init failed");
        close(sock);
        return NULL;
    }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 15000);

    int rc = libssh2_session_handshake(session, sock);
    if (rc) {
        char *msg = NULL; libssh2_session_last_error(session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Handshake failed (%d): %s", rc, msg ? msg : "");
        goto fail;
    }

    // Verify keys before authentication; reject explicit mismatches/possible MITM so passwords never reach an impersonating server.
    if ((real_known_hosts && *real_known_hosts) || (session_known_hosts && *session_known_hosts)) {
        if (hostkey_check(session, host ? host : "", port,
                          real_known_hosts, session_known_hosts, NULL, 0) == 2) {
            snprintf(err, (size_t)errlen, "HOSTKEY_MISMATCH Host key does not match the known record (possible man-in-the-middle attack); connection refused");
            goto fail;
        }
    }

    if (key_path && strncmp(key_path, "agent:", 6) == 0) {
        char aerr[200] = {0};
        rc = agent_auth(session, user, key_path, aerr, sizeof(aerr));
        if (rc) { snprintf(err, (size_t)errlen, "Authentication failed (%d): %s", rc, aerr); goto fail; }
    } else if (key_path && *key_path) {
        rc = libssh2_userauth_publickey_fromfile(session, user ? user : "", NULL,
                                                 key_path, key_passphrase ? key_passphrase : "");
    } else {
        rc = libssh2_userauth_password(session, user ? user : "", password ? password : "");
    }
    if (rc) {
        char *msg = NULL; libssh2_session_last_error(session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Authentication failed (%d): %s", rc, msg ? msg : "");
        goto fail;
    }

    ServerDockSSHSession *s = calloc(1, sizeof(*s));
    if (!s) { snprintf(err, (size_t)errlen, "Allocation failed"); goto fail; }
    s->sock = sock;
    s->session = session;
    const char *sha = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if (sha) {
        char b64[64];
        b64_nopad((const unsigned char *)sha, 32, b64);
        snprintf(s->fp_sha256, sizeof(s->fp_sha256), "SHA256:%s", b64);
    }
    const char *md5 = libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_MD5);
    if (md5) {
        char *p = s->fp_md5;
        for (int i = 0; i < 16; i++)
            p += snprintf(p, 4, i ? ":%02x" : "%02x", (unsigned char)md5[i]);
    }
    return s;

fail:
    libssh2_session_disconnect(session, "open failed");
    libssh2_session_free(session);
    close(sock);
    return NULL;
}

const char *serverdock_ssh_session_sha256(ServerDockSSHSession *s) { return s ? s->fp_sha256 : ""; }
const char *serverdock_ssh_session_md5(ServerDockSSHSession *s) { return s ? s->fp_md5 : ""; }

void serverdock_ssh_test(const char *host, int port, const char *user,
                    const char *password, const char *key_path, const char *key_passphrase,
                    const char *jump,
                    ServerDockSSHStageCallback on_stage, void *ud) {
    if (!on_stage) return;
    #define STAGE(n, ok, msg) on_stage(ud, (n), (ok), (msg))
    libssh2_init(0);
    int sock = -1;

    // Jump hosts delegate DNS/TCP to ssh -W; success proceeds to stage 3.
    if (jump && *jump) {
        STAGE(1, 1, NULL);
        char je[160] = {0};
        sock = jump_connect(jump, host ? host : "", port, je, sizeof(je));
        if (sock < 0) { STAGE(2, 0, je[0] ? je : "Failed to connect through the jump host"); return; }
        STAGE(2, 1, NULL);
        goto handshake;
    }

    // 1. Resolve host addresses.
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    int gai = getaddrinfo(host ? host : "", portstr, &hints, &res);
    if (gai != 0 || !res) {
        char m[160]; snprintf(m, sizeof(m), "Failed to resolve host: %s", gai_strerror(gai));
        STAGE(1, 0, m); return;
    }
    STAGE(1, 1, NULL);

    // 2. Connect TCP, trying addresses with nonblocking connect and select timeout.
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) { fcntl(sock, F_SETFL, flags); break; }
        if (errno == EINPROGRESS) {
            fd_set wf; FD_ZERO(&wf); FD_SET(sock, &wf);
            struct timeval tv = { 10, 0 };
            if (select(sock + 1, NULL, &wf, NULL, &tv) > 0) {
                int soerr = 0; socklen_t l = sizeof(soerr);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &soerr, &l);
                if (soerr == 0) { fcntl(sock, F_SETFL, flags); break; }
            }
        }
        close(sock); sock = -1;
    }
    freeaddrinfo(res);
    if (sock < 0) { STAGE(2, 0, "Could not establish a TCP connection (port unreachable, refused, or blocked by local network permission)"); return; }
    STAGE(2, 1, NULL);

    // 3. SSH handshake.
handshake:;
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { STAGE(3, 0, "libssh2 initialization failed"); close(sock); return; }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 15000);
    int rc = libssh2_session_handshake(session, sock);
    if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        char m[220]; snprintf(m, sizeof(m), "SSH handshake failed (%d): %s", rc, e ? e : "");
        STAGE(3, 0, m);
        libssh2_session_free(session); close(sock); return;
    }
    STAGE(3, 1, NULL);

    // 4. Authenticate.
    char aerr[200] = {0};
    if (key_path && strncmp(key_path, "agent:", 6) == 0) {
        rc = agent_auth(session, user, key_path, aerr, sizeof(aerr));
        if (rc) { char m[260]; snprintf(m, sizeof(m), "Authentication failed (%d): %s", rc, aerr);
                  STAGE(4, 0, m);
                  libssh2_session_disconnect(session, "auth failed"); libssh2_session_free(session); close(sock); return; }
    } else if (key_path && *key_path)
        rc = libssh2_userauth_publickey_fromfile(session, user ? user : "", NULL,
                                                 key_path, key_passphrase ? key_passphrase : "");
    else
        rc = libssh2_userauth_password(session, user ? user : "", password ? password : "");
    if (rc) {
        char *e = NULL; libssh2_session_last_error(session, &e, NULL, 0);
        char m[220]; snprintf(m, sizeof(m), "Authentication failed (%d): %s", rc, e ? e : "");
        STAGE(4, 0, m);
        libssh2_session_disconnect(session, "auth failed"); libssh2_session_free(session); close(sock); return;
    }
    STAGE(4, 1, NULL);

    // 5. Complete.
    STAGE(5, 1, NULL);
    libssh2_session_disconnect(session, "test done");
    libssh2_session_free(session);
    close(sock);
    #undef STAGE
}

void serverdock_ssh_scan_hostkey(const char *host, int port,
                            const char *real_known_hosts, const char *session_known_hosts,
                            ServerDockHostKeyScan *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->status = -1;
    libssh2_init(0);
    char errbuf[128];
    int sock = tcp_connect(host ? host : "", port, 8, errbuf, sizeof(errbuf));
    if (sock < 0) return;
    LIBSSH2_SESSION *session = libssh2_session_init();
    if (!session) { close(sock); return; }
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 8000);
    if (libssh2_session_handshake(session, sock) == 0) {     // Handshake only, without authentication.
        fill_fingerprints(session, out->sha256, sizeof(out->sha256), out->md5, sizeof(out->md5));
        out->status = hostkey_check(session, host ? host : "", port,
                                    real_known_hosts, session_known_hosts,
                                    out->line, sizeof(out->line));
    }
    libssh2_session_disconnect(session, "scan done");
    libssh2_session_free(session);
    close(sock);
}

// Read a channel stream into a buffer, truncating at cap-1; stream_id 0=stdout, SSH_EXTENDED_DATA_STDERR=stderr.
static void drain_stream(LIBSSH2_CHANNEL *ch, int stream_id, char *buf, int cap) {
    if (!buf || cap <= 0) return;
    size_t off = 0;
    for (;;) {
        ssize_t n = libssh2_channel_read_ex(ch, stream_id, buf + off, (size_t)cap - 1 - off);
        if (n > 0) { off += (size_t)n; if (off >= (size_t)cap - 1) break; }
        else break;   // 0=EOF, negative=error; blocking mode has no EAGAIN.
    }
    buf[off] = '\0';
}

int serverdock_ssh_exec(ServerDockSSHSession *s, const char *command,
                   char *out, int out_cap, char *errout, int errout_cap,
                   int *exit_code, char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "Invalid session"); return -1; }
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Failed to open channel: %s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec failed: %s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }
    drain_stream(ch, 0, out, out_cap);                          // stdout
    drain_stream(ch, SSH_EXTENDED_DATA_STDERR, errout, errout_cap);  // stderr
    libssh2_channel_close(ch);
    if (exit_code) *exit_code = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);
    return 0;
}

static long serverdock_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int serverdock_ssh_exec2(ServerDockSSHSession *s, const char *command,
                    const char *stdin_bytes, int stdin_len,
                    char *out, int out_cap, int *out_len,
                    char *errout, int errout_cap, int *err_len,
                    int *exit_code, int timeout_ms, char *err, int errlen) {
    if (out_len) *out_len = 0;
    if (err_len) *err_len = 0;
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "Invalid session"); return -1; }
    if (s->cancel) return 2;                       // Canceled before borrowing.
    if (timeout_ms <= 0) timeout_ms = 20000;

    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Failed to open channel: %s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec failed: %s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }

    libssh2_session_set_timeout(s->session, 200);   // Poll at 200ms so blocking calls periodically check deadline/cancel.
    long deadline = serverdock_now_ms() + timeout_ms;
    int result = 0;                                 // 0=complete, 1=timeout, 2=canceled, -1=error.

    // Write optional stdin then send_eof. These file-writing commands produce little stdout, so writing before reading avoids bidirectional deadlock here.
    if (stdin_bytes && stdin_len > 0) {
        size_t woff = 0;
        while (woff < (size_t)stdin_len) {
            if (s->cancel) { result = 2; break; }
            if (serverdock_now_ms() > deadline) { result = 1; break; }
            ssize_t w = libssh2_channel_write(ch, stdin_bytes + woff, (size_t)stdin_len - woff);
            if (w > 0) woff += (size_t)w;
            else if (w == LIBSSH2_ERROR_TIMEOUT || w == LIBSSH2_ERROR_EAGAIN) continue;
            else { snprintf(err, (size_t)errlen, "Failed to write stdin (%ld)", (long)w); result = -1; break; }
        }
    }
    if (result == 0) libssh2_channel_send_eof(ch);

    // Read stdout/stderr until EOF/timeout/cancel. Truncate beyond cap but keep draining to avoid blocking the remote writer forever.
    char tmp[8192];
    size_t ooff = 0, eoff = 0;
    while (result == 0) {
        if (s->cancel) { result = 2; break; }
        if (serverdock_now_ms() > deadline) { result = 1; break; }
        int got = 0;
        ssize_t n = libssh2_channel_read_ex(ch, 0, tmp, sizeof(tmp));
        if (n > 0) {
            got = 1;
            if (out && ooff < (size_t)out_cap) {
                size_t cp = (size_t)n; if (cp > (size_t)out_cap - ooff) cp = (size_t)out_cap - ooff;
                memcpy(out + ooff, tmp, cp); ooff += cp;
            }
        } else if (n < 0 && n != LIBSSH2_ERROR_TIMEOUT) {
            snprintf(err, (size_t)errlen, "Read error (%ld)", (long)n); result = -1; break;
        }
        ssize_t m = libssh2_channel_read_ex(ch, SSH_EXTENDED_DATA_STDERR, tmp, sizeof(tmp));
        if (m > 0) {
            got = 1;
            if (errout && eoff < (size_t)errout_cap) {
                size_t cp = (size_t)m; if (cp > (size_t)errout_cap - eoff) cp = (size_t)errout_cap - eoff;
                memcpy(errout + eoff, tmp, cp); eoff += cp;
            }
        }
        if (!got && libssh2_channel_eof(ch)) break;   // No new data and remote EOF means complete.
    }

    if (out_len) *out_len = (int)ooff;
    if (err_len) *err_len = (int)eoff;
    libssh2_session_set_timeout(s->session, 15000);
    libssh2_channel_close(ch);
    if (exit_code) *exit_code = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);
    return result;
}

int serverdock_ssh_exec_upload(ServerDockSSHSession *s, const char *command,
                          ServerDockSSHPullCallback pull, void *ud,
                          int *exit_code, char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "Invalid session"); return -1; }
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Failed to open channel: %s", msg ? msg : "");
        return -1;
    }
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec failed: %s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }

    char buf[65536];
    int result = 0;                          // 0=complete, 1=canceled, -1=error.
    for (;;) {
        int n = pull ? pull(ud, buf, (int)sizeof(buf)) : 0;
        if (n < 0) { result = 1; break; }    // On cancel/pause, omit send_eof and preserve remote partial .part for resume.
        if (n == 0) { libssh2_channel_send_eof(ch); break; }
        size_t off = 0;
        while (off < (size_t)n) {
            ssize_t w = libssh2_channel_write(ch, buf + off, (size_t)n - off);
            if (w > 0) off += (size_t)w;
            else if (w == LIBSSH2_ERROR_TIMEOUT || w == LIBSSH2_ERROR_EAGAIN) continue;
            else { snprintf(err, (size_t)errlen, "Write failed (%ld)", (long)w); result = -1; break; }
        }
        if (result == -1) break;
    }
    if (result == 0) {                       // Drain the small remote output; cat normally produces none.
        char tmp[4096];
        while (libssh2_channel_read(ch, tmp, sizeof(tmp)) > 0) {}
    }
    libssh2_channel_close(ch);
    if (exit_code) *exit_code = libssh2_channel_get_exit_status(ch);
    libssh2_channel_free(ch);
    return result;
}

int serverdock_ssh_exec_stream(ServerDockSSHSession *s, const char *command,
                          ServerDockSSHDataCallback on_data, void *userdata,
                          int *exit_code, char *err, int errlen) {
    if (exit_code) *exit_code = -1;
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "Invalid session"); return -1; }
    // Do not reset s->cancel: sessions run one stream then close. A superseded/canceled session must exit immediately,
    // or an orphaned stream could become unstoppable. open's calloc initially sets cancel to zero.
    if (s->cancel) return 0;
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Failed to open channel: %s", msg ? msg : "");
        return -1;
    }
    // Merge stderr into stdout so remote shell/script errors, e.g. command not found or device Invalid input, reach the caller.
    libssh2_channel_handle_extended_data2(ch, LIBSSH2_CHANNEL_EXTENDED_DATA_MERGE);
    if (libssh2_channel_exec(ch, command ? command : "") != 0) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "exec failed: %s", msg ? msg : "");
        libssh2_channel_free(ch);
        return -1;
    }
    libssh2_session_set_timeout(s->session, 300);   // 300ms timeout lets blocking reads periodically check cancel.
    char buf[8192];
    int rc = 0;
    while (!s->cancel) {
        ssize_t n = libssh2_channel_read(ch, buf, sizeof(buf));
        if (n > 0) { if (on_data) on_data(userdata, buf, (int)n); }
        else if (n == LIBSSH2_ERROR_TIMEOUT) { continue; }       // No data; loop and check cancel.
        else if (n == 0) { if (libssh2_channel_eof(ch)) break; } // EOF: remote process exited.
        else { rc = -1; snprintf(err, (size_t)errlen, "Read error (%ld)", (long)n); break; }
    }
    libssh2_session_set_timeout(s->session, 15000);
    int cancelled = s->cancel;
    libssh2_channel_close(ch);
    if (!cancelled && rc == 0 && exit_code) {
        libssh2_channel_wait_closed(ch);
        *exit_code = libssh2_channel_get_exit_status(ch);
    }
    libssh2_channel_free(ch);
    return rc;
}

void serverdock_ssh_cancel(ServerDockSSHSession *s) {
    if (s) s->cancel = 1;
}

void serverdock_ssh_close(ServerDockSSHSession *s) {
    if (!s) return;
    if (s->session) {
        libssh2_session_disconnect(s->session, "serverdock close");
        libssh2_session_free(s->session);
    }
    if (s->sock >= 0) close(s->sock);
    free(s);
}

// Interactive PTY shell.
struct ServerDockSSHShell {
    ServerDockSSHSession *s;
    LIBSSH2_CHANNEL *ch;
    pthread_t thread;
    int thread_started;
    pthread_mutex_t lock;
    char *wbuf; size_t wlen, wcap;        // Pending write buffer, queued by main and drained by pump.
    int wake[2];                          // Self-pipe: [0] reads, [1] writes to wake pump select.
    volatile int cols, rows, resize_pending;
    volatile int stop;
    ServerDockSSHDataCallback on_data;
    ServerDockSSHClosedCallback on_closed;
    void *ud;
};

static void shell_wake(ServerDockSSHShell *sh) {
    char x = 'x';
    ssize_t r = write(sh->wake[1], &x, 1);   // Nonblocking; a full pipe is fine because a wakeup is already pending.
    (void)r;
}

static void *shell_pump(void *arg) {
    ServerDockSSHShell *sh = (ServerDockSSHShell *)arg;
    LIBSSH2_SESSION *session = sh->s->session;
    int sock = sh->s->sock;
    libssh2_session_set_blocking(session, 0);
    char rbuf[16384];
    int errored = 0;

    while (!sh->stop) {
        int progressed = 0;

        if (sh->resize_pending) {
            sh->resize_pending = 0;
            libssh2_channel_request_pty_size(sh->ch, sh->cols, sh->rows);   // best-effort
        }

        ssize_t n = libssh2_channel_read(sh->ch, rbuf, sizeof(rbuf));
        if (n > 0) {
            if (sh->on_data) sh->on_data(sh->ud, rbuf, (int)n);
            progressed = 1;
        } else if (n == LIBSSH2_ERROR_EAGAIN) {
            // No data yet.
        } else if (n == 0) {
            if (libssh2_channel_eof(sh->ch)) break;        // Remote shell exited explicitly.
        } else {
            errored = 1; break;                            // Connection error/disconnection.
        }

        pthread_mutex_lock(&sh->lock);
        while (sh->wlen > 0) {
            ssize_t w = libssh2_channel_write(sh->ch, sh->wbuf, sh->wlen);
            if (w > 0) {
                memmove(sh->wbuf, sh->wbuf + w, sh->wlen - (size_t)w);
                sh->wlen -= (size_t)w;
                progressed = 1;
            } else break;                                  // EAGAIN/error: retry next iteration.
        }
        pthread_mutex_unlock(&sh->lock);

        if (progressed) continue;                          // More work remains; run another iteration immediately.

        // Without progress, select waits for socket readiness or wake-pipe input instead of busy-waiting.
        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_ZERO(&wfds);
        FD_SET(sock, &rfds);
        FD_SET(sh->wake[0], &rfds);
        if (libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND) FD_SET(sock, &wfds);
        int maxfd = sock > sh->wake[0] ? sock : sh->wake[0];
        struct timeval tv = { 0, 100000 };                 // 100ms fallback.
        select(maxfd + 1, &rfds, &wfds, NULL, &tv);
        if (FD_ISSET(sh->wake[0], &rfds)) {
            char drain[64];
            while (read(sh->wake[0], drain, sizeof(drain)) > 0) {}   // Drain nonblockingly.
        }
    }

    int exit_code = errored ? 255 : libssh2_channel_get_exit_status(sh->ch);
    if (sh->on_closed) sh->on_closed(sh->ud, exit_code);
    return NULL;
}

ServerDockSSHShell *serverdock_ssh_shell_open(ServerDockSSHSession *s, int cols, int rows,
                                    ServerDockSSHDataCallback on_data,
                                    ServerDockSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "Invalid session"); return NULL; }
    libssh2_session_set_blocking(s->session, 1);
    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->session);
    if (!ch) {
        char *msg = NULL; libssh2_session_last_error(s->session, &msg, NULL, 0);
        snprintf(err, (size_t)errlen, "Failed to open channel: %s", msg ? msg : "");
        return NULL;
    }
    if (libssh2_channel_request_pty_ex(ch, "xterm-256color", 14, NULL, 0,
                                       cols > 0 ? cols : 80, rows > 0 ? rows : 24, 0, 0)) {
        snprintf(err, (size_t)errlen, "request pty failed");
        libssh2_channel_free(ch); return NULL;
    }
    if (libssh2_channel_shell(ch)) {
        snprintf(err, (size_t)errlen, "Failed to start shell");
        libssh2_channel_free(ch); return NULL;
    }
    ServerDockSSHShell *sh = calloc(1, sizeof(*sh));
    if (!sh) { snprintf(err, (size_t)errlen, "Allocation failed"); libssh2_channel_free(ch); return NULL; }
    sh->s = s; sh->ch = ch;
    sh->cols = cols; sh->rows = rows;
    sh->on_data = on_data; sh->on_closed = on_closed; sh->ud = userdata;
    pthread_mutex_init(&sh->lock, NULL);
    if (pipe(sh->wake) != 0) {
        snprintf(err, (size_t)errlen, "Failed to create wake pipe");
        pthread_mutex_destroy(&sh->lock); libssh2_channel_free(ch); free(sh); return NULL;
    }
    fcntl(sh->wake[0], F_SETFL, O_NONBLOCK);
    fcntl(sh->wake[1], F_SETFL, O_NONBLOCK);
    if (pthread_create(&sh->thread, NULL, shell_pump, sh) != 0) {
        snprintf(err, (size_t)errlen, "Failed to create pump thread");
        close(sh->wake[0]); close(sh->wake[1]);
        pthread_mutex_destroy(&sh->lock); libssh2_channel_free(ch); free(sh); return NULL;
    }
    sh->thread_started = 1;
    return sh;
}

long serverdock_ssh_shell_write(ServerDockSSHShell *sh, const char *buf, int len) {
    if (!sh || !buf || len <= 0) return 0;
    pthread_mutex_lock(&sh->lock);
    if (sh->wlen + (size_t)len > sh->wcap) {
        size_t ncap = sh->wcap ? sh->wcap : 4096;
        while (ncap < sh->wlen + (size_t)len) ncap *= 2;
        char *nb = realloc(sh->wbuf, ncap);
        if (!nb) { pthread_mutex_unlock(&sh->lock); return -1; }
        sh->wbuf = nb; sh->wcap = ncap;
    }
    memcpy(sh->wbuf + sh->wlen, buf, (size_t)len);
    sh->wlen += (size_t)len;
    pthread_mutex_unlock(&sh->lock);
    shell_wake(sh);
    return len;
}

int serverdock_ssh_shell_resize(ServerDockSSHShell *sh, int cols, int rows) {
    if (!sh) return -1;
    sh->cols = cols; sh->rows = rows; sh->resize_pending = 1;
    shell_wake(sh);
    return 0;
}

void serverdock_ssh_shell_close(ServerDockSSHShell *sh) {
    if (!sh) return;
    sh->stop = 1;
    shell_wake(sh);
    if (sh->thread_started) pthread_join(sh->thread, NULL);
    if (sh->ch) {
        libssh2_session_set_blocking(sh->s->session, 1);
        libssh2_channel_close(sh->ch);
        libssh2_channel_free(sh->ch);
    }
    close(sh->wake[0]); close(sh->wake[1]);
    pthread_mutex_destroy(&sh->lock);
    free(sh->wbuf);
    free(sh);
}

// Port forwarding (-L / -R / -D).
#define FWD_MAX_CONN 128
#define FWD_BUF 16384

typedef struct {
    int in_use;
    int local_fd;
    LIBSSH2_CHANNEL *ch;
    char l2s[FWD_BUF]; size_t l2s_len;   // Pending local-to-SSH writes.
    char s2l[FWD_BUF]; size_t s2l_len;   // Pending SSH-to-local writes.
    int local_eof, ssh_eof, sent_eof;
} ForwardConn;

struct ServerDockSSHForward {
    ServerDockSSHSession *s;
    int kind;                            // 0 local 1 remote 2 dynamic
    char dest_host[256];
    int dest_port;
    int listen_fd;                       // Local listener for -L/-D; -1 for -R.
    LIBSSH2_LISTENER *rlistener;         // Remote -R listener.
    pthread_t thread;
    int thread_started;
    int wake[2];
    volatile int stop;
    ServerDockSSHForwardStateCallback on_state;
    void *ud;
    ForwardConn conns[FWD_MAX_CONN];
};

static void fwd_wake(ServerDockSSHForward *f) { char x = 'x'; ssize_t r = write(f->wake[1], &x, 1); (void)r; }

static void set_nonblock(int fd) { int fl = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, fl | O_NONBLOCK); }

// Create a local listening socket; set *eaddrinuse=1 for a port conflict. Return -1 on failure.
static int make_listen_socket(const char *bind_addr, int port, int *eaddrinuse) {
    *eaddrinuse = 0;
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
    const char *node = (bind_addr && *bind_addr) ? bind_addr : NULL;
    if (getaddrinfo(node, portstr, &hints, &res) != 0 || !res) return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        if (bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && listen(fd, 16) == 0) break;
        if (errno == EADDRINUSE) *eaddrinuse = 1;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// Blocking connection to the local -R destination; return -1 on failure.
static int connect_blocking(const char *host, int port) {
    char portstr[16]; snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

// Temporarily open direct_tcpip in blocking mode, briefly pausing the pump during setup for simpler code.
static LIBSSH2_CHANNEL *open_direct(LIBSSH2_SESSION *session, const char *host, int port) {
    libssh2_session_set_blocking(session, 1);
    libssh2_session_set_timeout(session, 8000);
    LIBSSH2_CHANNEL *ch = libssh2_channel_direct_tcpip_ex(session, host, port, "127.0.0.1", 0);
    libssh2_session_set_timeout(session, 0);
    libssh2_session_set_blocking(session, 0);
    return ch;
}

static int recv_n(int fd, unsigned char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = recv(fd, buf + off, n - off, 0);
        if (r > 0) off += (size_t)r;
        else if (r < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}
static int send_all(int fd, const unsigned char *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = send(fd, buf + off, n - off, 0);
        if (w > 0) off += (size_t)w;
        else if (w < 0 && errno == EINTR) continue;
        else return -1;
    }
    return 0;
}

// Blocking SOCKS5 negotiation with receive timeout; write dhost/dport and return 0 on success, -1 on failure.
static int socks5_negotiate(int fd, char *dhost, size_t dhost_cap, int *dport) {
    struct timeval tv = { 10, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    unsigned char b[300];
    if (recv_n(fd, b, 2) || b[0] != 0x05) return -1;       // VER NMETHODS
    int nm = b[1];
    if (nm > 0 && recv_n(fd, b, (size_t)nm)) return -1;     // Ignore the method list.
    unsigned char rep[2] = { 0x05, 0x00 };                  // Select no authentication.
    if (send_all(fd, rep, 2)) return -1;
    if (recv_n(fd, b, 4) || b[0] != 0x05 || b[1] != 0x01) return -1;   // VER CMD(CONNECT) RSV ATYP
    int atyp = b[3];
    if (atyp == 0x01) {
        unsigned char a[4]; if (recv_n(fd, a, 4)) return -1;
        snprintf(dhost, dhost_cap, "%d.%d.%d.%d", a[0], a[1], a[2], a[3]);
    } else if (atyp == 0x03) {
        unsigned char len; if (recv_n(fd, &len, 1)) return -1;
        if ((size_t)len >= dhost_cap) return -1;
        if (recv_n(fd, (unsigned char *)dhost, len)) return -1;
        dhost[len] = '\0';
    } else if (atyp == 0x04) {
        unsigned char a[16]; if (recv_n(fd, a, 16)) return -1;
        snprintf(dhost, dhost_cap, "%x:%x:%x:%x:%x:%x:%x:%x",
                 (a[0]<<8)|a[1], (a[2]<<8)|a[3], (a[4]<<8)|a[5], (a[6]<<8)|a[7],
                 (a[8]<<8)|a[9], (a[10]<<8)|a[11], (a[12]<<8)|a[13], (a[14]<<8)|a[15]);
    } else return -1;
    unsigned char pb[2]; if (recv_n(fd, pb, 2)) return -1;
    *dport = (pb[0] << 8) | pb[1];
    tv.tv_sec = 0; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));   // Clear the timeout.
    return 0;
}
static void socks5_reply(int fd, int rep) {
    unsigned char r[10] = { 0x05, (unsigned char)rep, 0x00, 0x01, 0,0,0,0, 0,0 };
    send_all(fd, r, sizeof(r));
}

static ForwardConn *fwd_alloc(ServerDockSSHForward *f) {
    for (int i = 0; i < FWD_MAX_CONN; i++) if (!f->conns[i].in_use) return &f->conns[i];
    return NULL;
}
static void conn_close(ForwardConn *c) {
    if (c->ch) { libssh2_channel_free(c->ch); }
    if (c->local_fd >= 0) close(c->local_fd);
    memset(c, 0, sizeof(*c));
}

// Attach a connection with an already-open channel and set local_fd nonblocking; clean up both resources on failure.
static void fwd_add(ServerDockSSHForward *f, int local_fd, LIBSSH2_CHANNEL *ch) {
    ForwardConn *c = fwd_alloc(f);
    if (!c) { close(local_fd); if (ch) libssh2_channel_free(ch); return; }
    set_nonblock(local_fd);
    c->in_use = 1; c->local_fd = local_fd; c->ch = ch;
}

// Nonblocking bidirectional pump for one connection; -1 requests closure.
static int conn_pump(ForwardConn *c) {
    // local → ssh
    if (!c->local_eof && c->l2s_len < FWD_BUF) {
        ssize_t n = recv(c->local_fd, c->l2s + c->l2s_len, FWD_BUF - c->l2s_len, 0);
        if (n > 0) c->l2s_len += (size_t)n;
        else if (n == 0) c->local_eof = 1;
        else if (errno != EAGAIN && errno != EWOULDBLOCK) c->local_eof = 1;
    }
    while (c->l2s_len > 0) {
        ssize_t w = libssh2_channel_write(c->ch, c->l2s, c->l2s_len);
        if (w > 0) { memmove(c->l2s, c->l2s + w, c->l2s_len - (size_t)w); c->l2s_len -= (size_t)w; }
        else break;                                  // EAGAIN/error: retry next iteration.
    }
    if (c->local_eof && c->l2s_len == 0 && !c->sent_eof) { libssh2_channel_send_eof(c->ch); c->sent_eof = 1; }

    // ssh → local
    if (c->s2l_len < FWD_BUF) {
        ssize_t n = libssh2_channel_read(c->ch, c->s2l + c->s2l_len, FWD_BUF - c->s2l_len);
        if (n > 0) c->s2l_len += (size_t)n;
        else if (n == 0) c->ssh_eof = 1;             // EOF
        else if (n != LIBSSH2_ERROR_EAGAIN) c->ssh_eof = 1;
    }
    while (c->s2l_len > 0) {
        ssize_t w = send(c->local_fd, c->s2l, c->s2l_len, 0);
        if (w > 0) { memmove(c->s2l, c->s2l + w, c->s2l_len - (size_t)w); c->s2l_len -= (size_t)w; }
        else if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        else { return -1; }                          // Close on local write error.
    }
    // Close the whole connection after either side reaches EOF and its buffered output is flushed.
    if ((c->ssh_eof && c->s2l_len == 0) || (c->local_eof && c->l2s_len == 0 && c->ssh_eof)) return -1;
    return 0;
}

static void *forward_pump(void *arg) {
    ServerDockSSHForward *f = (ServerDockSSHForward *)arg;
    LIBSSH2_SESSION *session = f->s->session;
    int sock = f->s->sock;
    libssh2_session_set_blocking(session, 0);
    libssh2_keepalive_config(session, 0, 30);
    int ticks = 0;
    int dead = 0;
    char deadmsg[128] = "Disconnected";

    while (!f->stop) {
        fd_set rfds, wfds;
        FD_ZERO(&rfds); FD_ZERO(&wfds);
        int maxfd = 0;
        FD_SET(f->wake[0], &rfds); if (f->wake[0] > maxfd) maxfd = f->wake[0];
        FD_SET(sock, &rfds);       if (sock > maxfd) maxfd = sock;
        if (f->listen_fd >= 0) { FD_SET(f->listen_fd, &rfds); if (f->listen_fd > maxfd) maxfd = f->listen_fd; }
        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = &f->conns[i];
            if (!c->in_use) continue;
            if (!c->local_eof && c->l2s_len < FWD_BUF) { FD_SET(c->local_fd, &rfds); if (c->local_fd > maxfd) maxfd = c->local_fd; }
            if (c->s2l_len > 0) { FD_SET(c->local_fd, &wfds); if (c->local_fd > maxfd) maxfd = c->local_fd; }
        }
        struct timeval tv = { 0, 100000 };
        select(maxfd + 1, &rfds, &wfds, NULL, &tv);
        if (FD_ISSET(f->wake[0], &rfds)) { char d[64]; while (read(f->wake[0], d, sizeof(d)) > 0) {} }

        // -L/-D: accept new local connections.
        if (f->listen_fd >= 0 && FD_ISSET(f->listen_fd, &rfds)) {
            int cfd = accept(f->listen_fd, NULL, NULL);
            if (cfd >= 0) {
                if (f->kind == 2) {                  // Dynamic SOCKS5.
                    char dhost[256]; int dport = 0;
                    if (socks5_negotiate(cfd, dhost, sizeof(dhost), &dport) == 0) {
                        LIBSSH2_CHANNEL *ch = open_direct(session, dhost, dport);
                        if (ch) { socks5_reply(cfd, 0x00); fwd_add(f, cfd, ch); }
                        else { socks5_reply(cfd, 0x05); close(cfd); }   // 0x05 means connection refused.
                    } else close(cfd);
                } else {                             // Local -L.
                    LIBSSH2_CHANNEL *ch = open_direct(session, f->dest_host, f->dest_port);
                    if (ch) fwd_add(f, cfd, ch); else close(cfd);
                }
            }
        }

        // -R: accept the server-forwarded connection, then connect to local dest.
        if (f->kind == 1 && f->rlistener) {
            for (;;) {
                LIBSSH2_CHANNEL *ch = libssh2_channel_forward_accept(f->rlistener);
                if (!ch) break;                       // No more connections; EAGAIN.
                int lfd = connect_blocking(f->dest_host, f->dest_port);
                if (lfd >= 0) fwd_add(f, lfd, ch); else libssh2_channel_free(ch);
            }
        }

        // Forward every active connection.
        for (int i = 0; i < FWD_MAX_CONN; i++) {
            ForwardConn *c = &f->conns[i];
            if (!c->in_use) continue;
            if (conn_pump(c) < 0) conn_close(c);
        }

        // Periodic keepalive also detects broken sessions.
        if (++ticks >= 100) {                          // ~10s
            ticks = 0;
            int next = 0;
            int rc = libssh2_keepalive_send(session, &next);
            if (rc < 0 && rc != LIBSSH2_ERROR_EAGAIN) { dead = 1; break; }
        }
    }

    for (int i = 0; i < FWD_MAX_CONN; i++) if (f->conns[i].in_use) conn_close(&f->conns[i]);
    if (dead && f->on_state) f->on_state(f->ud, 0, deadmsg);
    return NULL;
}

ServerDockSSHForward *serverdock_ssh_forward_open(ServerDockSSHSession *s, int kind,
                                        const char *bind_addr, int listen_port,
                                        const char *dest_host, int dest_port,
                                        ServerDockSSHForwardStateCallback on_state, void *ud,
                                        char *err, int errlen) {
    if (!s || !s->session) { snprintf(err, (size_t)errlen, "Invalid session"); return NULL; }
    ServerDockSSHForward *f = calloc(1, sizeof(*f));
    if (!f) { snprintf(err, (size_t)errlen, "Allocation failed"); return NULL; }
    f->s = s; f->kind = kind; f->listen_fd = -1;
    f->dest_port = dest_port;
    snprintf(f->dest_host, sizeof(f->dest_host), "%s", dest_host ? dest_host : "");
    f->on_state = on_state; f->ud = ud;

    if (kind == 1) {                                   // -R remote listener.
        libssh2_session_set_blocking(s->session, 1);
        int bound = 0;
        f->rlistener = libssh2_channel_forward_listen_ex(s->session,
                        (bind_addr && *bind_addr) ? (char *)bind_addr : NULL,
                        listen_port, &bound, 16);
        if (!f->rlistener) { snprintf(err, (size_t)errlen, "Forwarding request rejected"); free(f); return NULL; }
    } else {                                           // -L/-D local listener.
        int eaddr = 0;
        f->listen_fd = make_listen_socket(bind_addr, listen_port, &eaddr);
        if (f->listen_fd < 0) {
            snprintf(err, (size_t)errlen, "%s", eaddr ? "Local port already in use" : "Could not listen on local port");
            free(f); return NULL;
        }
        set_nonblock(f->listen_fd);
    }

    if (pipe(f->wake) != 0) { snprintf(err, (size_t)errlen, "Failed to create wake pipe"); goto fail; }
    set_nonblock(f->wake[0]); set_nonblock(f->wake[1]);
    if (pthread_create(&f->thread, NULL, forward_pump, f) != 0) {
        snprintf(err, (size_t)errlen, "Failed to create pump thread");
        close(f->wake[0]); close(f->wake[1]); goto fail;
    }
    f->thread_started = 1;
    return f;

fail:
    if (f->listen_fd >= 0) close(f->listen_fd);
    if (f->rlistener) { libssh2_session_set_blocking(s->session, 1); libssh2_channel_forward_cancel(f->rlistener); }
    free(f);
    return NULL;
}

void serverdock_ssh_forward_close(ServerDockSSHForward *f) {
    if (!f) return;
    f->stop = 1;
    fwd_wake(f);
    if (f->thread_started) pthread_join(f->thread, NULL);
    libssh2_session_set_blocking(f->s->session, 1);
    if (f->rlistener) libssh2_channel_forward_cancel(f->rlistener);
    if (f->listen_fd >= 0) close(f->listen_fd);
    close(f->wake[0]); close(f->wake[1]);
    free(f);
}

// SFTP subsystem (libssh2_sftp_*).

// Map libssh2 results to 0=success, positive=SFTP status, 0xF000=transport error.
static int sftp_map(LIBSSH2_SFTP *sftp, int rc) {
    if (rc == 0) return 0;
    if (rc == LIBSSH2_ERROR_SFTP_PROTOCOL) return (int)libssh2_sftp_last_error(sftp);
    return 0xF000;
}

static void attrs_fill(ServerDockSFTPAttrs *out, const LIBSSH2_SFTP_ATTRIBUTES *a) {
    if (!out) return;
    out->has_size = (a->flags & LIBSSH2_SFTP_ATTR_SIZE) ? 1 : 0;
    out->has_perm = (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) ? 1 : 0;
    out->has_mtime = (a->flags & LIBSSH2_SFTP_ATTR_ACMODTIME) ? 1 : 0;
    out->size = (unsigned long long)a->filesize;
    out->permissions = (unsigned int)a->permissions;
    out->mtime = (unsigned int)a->mtime;
}

void *serverdock_sftp_init(ServerDockSSHSession *s) {
    if (!s || !s->session) return NULL;
    return libssh2_sftp_init(s->session);
}

void serverdock_sftp_shutdown(void *sftp) {
    if (sftp) libssh2_sftp_shutdown((LIBSSH2_SFTP *)sftp);
}

int serverdock_sftp_last_errno(void *sftp) {
    return sftp ? (int)libssh2_sftp_last_error((LIBSSH2_SFTP *)sftp) : 0;
}

int serverdock_sftp_stat(ServerDockSSHSession *s, void *sftp, const char *path, int follow, ServerDockSFTPAttrs *out) {
    if (!s || !sftp) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    int rc = libssh2_sftp_stat_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                  follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &a);
    if (rc == 0) attrs_fill(out, &a);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int serverdock_sftp_setstat_perm(ServerDockSSHSession *s, void *sftp, const char *path, unsigned int mode) {
    if (!s || !sftp) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    a.flags = LIBSSH2_SFTP_ATTR_PERMISSIONS;
    a.permissions = mode & 07777;
    int rc = libssh2_sftp_stat_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                  LIBSSH2_SFTP_SETSTAT, &a);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int serverdock_sftp_mkdir(ServerDockSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return 0xF000;
    int rc = libssh2_sftp_mkdir_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path), 0755);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int serverdock_sftp_rmdir(ServerDockSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return 0xF000;
    int rc = libssh2_sftp_rmdir_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path));
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int serverdock_sftp_unlink(ServerDockSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return 0xF000;
    int rc = libssh2_sftp_unlink_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path));
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int serverdock_sftp_rename(ServerDockSSHSession *s, void *sftp, const char *from, const char *to, int overwrite) {
    if (!s || !sftp) return 0xF000;
    long flags = overwrite ? (LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC |
                              LIBSSH2_SFTP_RENAME_NATIVE) : 0;
    int rc = libssh2_sftp_rename_ex((LIBSSH2_SFTP *)sftp, from, (unsigned)strlen(from),
                                    to, (unsigned)strlen(to), flags);
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

int serverdock_sftp_realpath(ServerDockSSHSession *s, void *sftp, const char *path, char *out, int out_cap) {
    if (!s || !sftp || !out || out_cap <= 0) return 0xF000;
    int rc = libssh2_sftp_realpath((LIBSSH2_SFTP *)sftp, path, out, (unsigned)out_cap - 1);
    if (rc >= 0) { out[rc < out_cap ? rc : out_cap - 1] = '\0'; return 0; }
    return sftp_map((LIBSSH2_SFTP *)sftp, rc);
}

void *serverdock_sftp_open(ServerDockSSHSession *s, void *sftp, const char *path, unsigned int pflags) {
    if (!s || !sftp) return NULL;
    // mode applies only to newly created files with CREAT; default to 0644 and inherit original permissions through setstat after finalization.
    return libssh2_sftp_open_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                pflags, 0644, LIBSSH2_SFTP_OPENFILE);
}

void *serverdock_sftp_opendir(ServerDockSSHSession *s, void *sftp, const char *path) {
    if (!s || !sftp) return NULL;
    return libssh2_sftp_open_ex((LIBSSH2_SFTP *)sftp, path, (unsigned)strlen(path),
                                0, 0, LIBSSH2_SFTP_OPENDIR);
}

int serverdock_sftp_fstat(void *handle, ServerDockSFTPAttrs *out) {
    if (!handle) return 0xF000;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    int rc = libssh2_sftp_fstat_ex((LIBSSH2_SFTP_HANDLE *)handle, &a, 0);
    if (rc == 0) { attrs_fill(out, &a); return 0; }
    return 0xF000;
}

long serverdock_sftp_read(void *handle, unsigned long long offset, char *buf, int len) {
    if (!handle || !buf || len <= 0) return -1;
    libssh2_sftp_seek64((LIBSSH2_SFTP_HANDLE *)handle, offset);
    ssize_t n = libssh2_sftp_read((LIBSSH2_SFTP_HANDLE *)handle, buf, (size_t)len);
    return (long)n;   // Positive=bytes, 0=EOF, negative=error.
}

long serverdock_sftp_write(void *handle, unsigned long long offset, const char *buf, int len) {
    if (!handle || !buf || len < 0) return -1;
    libssh2_sftp_seek64((LIBSSH2_SFTP_HANDLE *)handle, offset);
    size_t off = 0;
    while (off < (size_t)len) {
        ssize_t w = libssh2_sftp_write((LIBSSH2_SFTP_HANDLE *)handle, buf + off, (size_t)len - off);
        if (w < 0) return (long)w;     // Error.
        off += (size_t)w;              // libssh2_sftp_write may write partially; loop until complete.
    }
    return (long)off;
}

int serverdock_sftp_readdir(void *handle, char *name_buf, int name_cap, ServerDockSFTPAttrs *out) {
    if (!handle || !name_buf || name_cap <= 0) return -1;
    LIBSSH2_SFTP_ATTRIBUTES a;
    memset(&a, 0, sizeof(a));
    int rc = libssh2_sftp_readdir_ex((LIBSSH2_SFTP_HANDLE *)handle, name_buf, (size_t)name_cap - 1,
                                     NULL, 0, &a);
    if (rc > 0) {
        name_buf[rc < name_cap ? rc : name_cap - 1] = '\0';
        attrs_fill(out, &a);
    }
    return rc;   // Positive=name length, 0=EOF, negative=error.
}

void serverdock_sftp_close(void *handle) {
    if (handle) libssh2_sftp_close_handle((LIBSSH2_SFTP_HANDLE *)handle);
}

