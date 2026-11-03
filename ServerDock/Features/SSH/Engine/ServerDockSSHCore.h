// C interface for the in-process libssh2 engine. SSH migration J1 starts with linkage checks and later expands into
// a full connection/authentication/exec/SFTP/PTY/forwarding engine replacing spawned /usr/bin/ssh.
//
// libssh2 is a pure C SSH library without Foundation/CoreFoundation type conflicts, unlike FreeRDP/WinPR,
// so include libssh2.h directly without a separate pure-C isolation translation unit.
#ifndef SERVERDOCK_SSH_CORE_H
#define SERVERDOCK_SSH_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Persistent sessions.
// One session is an authenticated libssh2 connection supporting repeated channels for exec and later SFTP/PTY/forwarding.
// Sessions are not thread-safe; the caller must serialize every operation on a handle using a serial queue.
typedef struct ServerDockSSHSession ServerDockSSHSession;

/// Connect, handshake, and authenticate; return a handle or NULL with err on failure. Nonempty key_path selects public-key authentication.
/// When real_known_hosts/session_known_hosts are set, verify the host key after handshake but before authentication. Reject only explicit
/// known-key mismatches (possible MITM), with err starting HOSTKEY_MISMATCH; permit unknown hosts/parse failures to avoid false rejection.
ServerDockSSHSession *serverdock_ssh_open(const char *host, int port,
                                const char *user, const char *password,
                                const char *key_path, const char *key_passphrase,
                                const char *real_known_hosts, const char *session_known_hosts,
                                const char *jump,   // Comma-separated ssh -J jump chain; NULL/empty connects directly.
                                char *err, int errlen);

// Host-key scanning: handshake only, without authentication; replaces ssh-keyscan + ssh-keygen.
/// Obtain the host public key/fingerprint through TCP and handshake, then compare known_hosts for the first-connection dialog.
typedef struct {
    int status;          // 0=known match, 1=unknown, 2=mismatch/possible MITM, -1=connection/handshake failure.
    char sha256[80];     // "SHA256:base64"
    char md5[64];        // "ab:cd:…"
    char line[1024];     // known_hosts trust line: "<host|[host]:port> <keytype> <base64key>".
} ServerDockHostKeyScan;

/// Scan the host:port key without authenticating/sending a password; write the result to *out.
void serverdock_ssh_scan_hostkey(const char *host, int port,
                            const char *real_known_hosts, const char *session_known_hosts,
                            ServerDockHostKeyScan *out);

// Staged connection test replacing spawned ssh -v; app-owned connections trigger local-network permission.
/// Stage callbacks: 1=resolve host, 2=TCP connection, 3=SSH handshake, 4=authentication, 5=complete.
/// ok=1 succeeds; ok=0 writes the reason to message and stops. Blocking; call in the background.
typedef void (*ServerDockSSHStageCallback)(void *userdata, int stage, int ok, const char *message);
void serverdock_ssh_test(const char *host, int port, const char *user,
                    const char *password, const char *key_path, const char *key_passphrase,
                    const char *jump,   // ssh -J jump host; NULL/empty connects directly.
                    ServerDockSSHStageCallback on_stage, void *userdata);

/// Host fingerprint, available after handshake; points into session-owned storage and must not be freed.
const char *serverdock_ssh_session_sha256(ServerDockSSHSession *s);
const char *serverdock_ssh_session_md5(ServerDockSSHSession *s);

/// Execute a command, writing stdout to out and stderr to errout, each truncated to cap-1 and NUL-terminated.
/// Write the exit status to *exit_code. Return 0 on success, -1 for a channel error with details in err.
int serverdock_ssh_exec(ServerDockSSHSession *s, const char *command,
                   char *out, int out_cap, char *errout, int errout_cap,
                   int *exit_code, char *err, int errlen);

/// Binary-safe exec with stdin, overall timeout, and cancellation, replacing RemoteFS.run's spawned ssh:
/// stdout goes to out with *out_len bytes; stderr to errout with *err_len bytes. Neither is NUL-terminated; use lengths.
/// Truncate output beyond cap but keep draining it to avoid blocking the remote writer forever. Write *exit_code.
/// Send nonempty stdin_bytes before send_eof. Treat timeout_ms <= 0 as 20000.
/// Return 0=complete, 1=timeout, 2=canceled by serverdock_ssh_cancel, -1=error with details in err.
int serverdock_ssh_exec2(ServerDockSSHSession *s, const char *command,
                    const char *stdin_bytes, int stdin_len,
                    char *out, int out_cap, int *out_len,
                    char *errout, int errout_cap, int *err_len,
                    int *exit_code, int timeout_ms, char *err, int errlen);

/// Streaming upload exec replacing spawned ssh + cat: repeatedly call pull(ud, buf, cap) for stdin data to send remotely.
/// pull returns positive bytes, 0=EOF with normal send_eof, or negative=cancel immediately without send_eof, preserving remote partial data for resume.
/// Return 0=complete, 1=canceled by pull, -1=error in err; write remote *exit_code. Blocking; call in the background.
typedef int (*ServerDockSSHPullCallback)(void *userdata, char *buf, int cap);
int serverdock_ssh_exec_upload(ServerDockSSHSession *s, const char *command,
                          ServerDockSSHPullCallback pull, void *userdata,
                          int *exit_code, char *err, int errlen);

/// Streaming exec for a long-running command; deliver incremental stdout through on_data until EOF/error/cancel.
/// Block until completion; another thread can safely interrupt through serverdock_ssh_cancel, which only sets a flag.
/// Merge stderr into on_data for diagnostics. Write remote exit_code, -1 if unknown/canceled; NULL is allowed.
/// Return 0 for normal/canceled termination, -1 for error with details in err.
typedef void (*ServerDockSSHDataCallback)(void *userdata, const char *bytes, int len);
int serverdock_ssh_exec_stream(ServerDockSSHSession *s, const char *command,
                          ServerDockSSHDataCallback on_data, void *userdata,
                          int *exit_code, char *err, int errlen);

/// Request interruption of a streaming read by setting a flag from any thread.
void serverdock_ssh_cancel(ServerDockSSHSession *s);

/// Disconnect and free the session.
void serverdock_ssh_close(ServerDockSSHSession *s);

// Interactive PTY shell replacing spawned /usr/bin/ssh and LocalProcessTerminalView subprocesses.
// Open a PTY/shell on a dedicated session; one pump thread performs all libssh2 reads/writes/resizes to prevent concurrency.
// A self-pipe wakes the pump immediately for input. on_data delivers incremental stdout on the pump thread; on_closed runs once on termination.
// exit_code is the remote shell status; disconnection returns 255, matching ssh to trigger reconnection.
typedef struct ServerDockSSHShell ServerDockSSHShell;
typedef void (*ServerDockSSHClosedCallback)(void *userdata, int exit_code);

/// Open xterm-256color PTY at cols by rows, open shell, and start the pump. Return handle or NULL with err.
ServerDockSSHShell *serverdock_ssh_shell_open(ServerDockSSHSession *s, int cols, int rows,
                                    ServerDockSSHDataCallback on_data,
                                    ServerDockSSHClosedCallback on_closed, void *userdata,
                                    char *err, int errlen);
/// Thread-safe PTY write: enqueue/wake the pump and return immediately with queued bytes or -1.
long serverdock_ssh_shell_write(ServerDockSSHShell *sh, const char *buf, int len);
/// Notify PTY size changes; thread-safe.
int  serverdock_ssh_shell_resize(ServerDockSSHShell *sh, int cols, int rows);
/// Stop the pump and free channel/handle; caller ensures idempotency. Leave the underlying session for the caller to close.
void serverdock_ssh_shell_close(ServerDockSSHShell *sh);

// Port forwarding (-L / -R / -D), replacing spawned ssh -N.
// Each tunnel owns a dedicated session and pump thread, multiplexing nonblocking data across concurrent channels.
// Setup briefly blocks for direct_tcpip, SOCKS5 negotiation, and -R local connections to keep complexity manageable.
typedef struct ServerDockSSHForward ServerDockSSHForward;
/// Asynchronous tunnel status: ok=0 means disconnected/fatal error, with message explaining why; caller reconnects or marks failed.
typedef void (*ServerDockSSHForwardStateCallback)(void *userdata, int ok, const char *message);

/// Start forwarding; kind 0=local (-L), 1=remote (-R), 2=dynamic SOCKS5 (-D).
/// -L/-D listen locally on bind_addr:listen_port. dest_* specifies the -L target; -D ignores it.
/// -R listens remotely on server bind_addr:listen_port and forwards accepted connections to local dest_host:dest_port.
/// Listener setup failure, e.g. port conflict/forwarding denial, immediately returns NULL with details in err.
ServerDockSSHForward *serverdock_ssh_forward_open(ServerDockSSHSession *s, int kind,
                                        const char *bind_addr, int listen_port,
                                        const char *dest_host, int dest_port,
                                        ServerDockSSHForwardStateCallback on_state, void *userdata,
                                        char *err, int errlen);
/// Stop the pump and close listeners/active connections, leaving the underlying session for the caller to close.
void serverdock_ssh_forward_close(ServerDockSSHForward *f);

// SFTP subsystem using libssh2_sftp_* instead of handwritten FXP.
// Not thread-safe; call on the dedicated SFTP session's serial queue.
// Integer return convention: 0=success; positive values below 0xF000 are LIBSSH2_FX_* status codes, e.g. 2=file missing.
// Values >=0xF000 denote transport/native errors such as disconnection/protocol failure. open/opendir/init return NULL; inspect last_errno.

/// SFTP attributes used by this client; has_* indicates whether each field is valid.
typedef struct {
    int has_size, has_perm, has_mtime;
    unsigned long long size;
    unsigned int permissions;
    unsigned int mtime;
} ServerDockSFTPAttrs;

/// Initialize SFTP on an authenticated session; return LIBSSH2_SFTP* as void*, or NULL.
void *serverdock_sftp_init(ServerDockSSHSession *s);
/// Close the SFTP subsystem, not its underlying session.
void  serverdock_sftp_shutdown(void *sftp);
/// Get the last SFTP operation's LIBSSH2_FX_* protocol status.
int   serverdock_sftp_last_errno(void *sftp);

/// stat: follow=1 follows symlinks; 0 uses lstat.
int   serverdock_sftp_stat(ServerDockSSHSession *s, void *sftp, const char *path, int follow, ServerDockSFTPAttrs *out);
/// Set permission bits from mode & 07777.
int   serverdock_sftp_setstat_perm(ServerDockSSHSession *s, void *sftp, const char *path, unsigned int mode);
int   serverdock_sftp_mkdir(ServerDockSSHSession *s, void *sftp, const char *path);
int   serverdock_sftp_rmdir(ServerDockSSHSession *s, void *sftp, const char *path);
int   serverdock_sftp_unlink(ServerDockSSHSession *s, void *sftp, const char *path);
/// Rename: overwrite=1 uses OVERWRITE|ATOMIC|NATIVE for atomic posix-rename replacement; 0 refuses overwriting.
int   serverdock_sftp_rename(ServerDockSSHSession *s, void *sftp, const char *from, const char *to, int overwrite);
/// Resolve an absolute path into out, truncated to out_cap-1 and NUL-terminated.
int   serverdock_sftp_realpath(ServerDockSSHSession *s, void *sftp, const char *path, char *out, int out_cap);

/// Open with pflags passed directly as LIBSSH2_FXF_* values, matching SFTPFlag. Return a void* handle or NULL.
void *serverdock_sftp_open(ServerDockSSHSession *s, void *sftp, const char *path, unsigned int pflags);
/// Open a directory; return its handle or NULL.
void *serverdock_sftp_opendir(ServerDockSSHSession *s, void *sftp, const char *path);
/// fstat on a handle.
int   serverdock_sftp_fstat(void *handle, ServerDockSFTPAttrs *out);
/// Read a block at offset using seek64/read; return bytes, 0=EOF, negative=error.
long  serverdock_sftp_read(void *handle, unsigned long long offset, char *buf, int len);
/// Write the entire block at offset using seek64 and a write loop; return bytes written or negative error.
long  serverdock_sftp_write(void *handle, unsigned long long offset, const char *buf, int len);
/// Read one directory entry into NUL-terminated name_buf; return name length, 0=EOF, negative=error.
int   serverdock_sftp_readdir(void *handle, char *name_buf, int name_cap, ServerDockSFTPAttrs *out);
/// Close a file/directory handle.
void  serverdock_sftp_close(void *handle);

// Key generation/import through OpenSSL and handwritten OpenSSH formats, replacing ssh-keygen.
/// Generate a pair: type 0=ed25519, 1=RSA-4096. Return private text in out_priv, public line in out_pub, SHA256 fingerprint in out_fp.
/// A nonempty passphrase encrypts the private key using OpenSSL PKCS#8 for RSA or OpenSSH/bcrypt for ed25519. Return 0/-1 with err.
int serverdock_key_generate(int type, const char *comment, const char *passphrase,
                       char *out_priv, int priv_cap, char *out_pub, int pub_cap,
                       char *out_fp, int fp_cap, char *err, int errlen);
/// Derive an uncommented public-key line from a private file; return 0=success, 1=encrypted PEM cannot derive, -1=error.
/// *out_type: 0=ed25519, 1=RSA; *out_encrypted=1 for encrypted private keys. Encrypted OpenSSH still allows public derivation, so rc=0 may accompany encrypted=1.
int serverdock_key_pubkey_from_private(const char *priv_path, const char *passphrase,
                                  char *out_pub, int pub_cap, int *out_type, int *out_encrypted);
/// Compute a SHA256 fingerprint from a public-key line; return 0/-1.
int serverdock_key_fingerprint(const char *pub_line, char *out_fp, int fp_cap);

/// Change a private-file passphrase without writing to disk; output new private text for the caller to save to the original path.
/// Empty old_passphrase means currently unencrypted; empty new_passphrase removes encryption.
/// Supports ed25519 OpenSSH containers and RSA/EC PEM through OpenSSL. Return 0 and new private text in out_priv,
/// or -1 with err, commonly for an incorrect passphrase/unsupported key.
int serverdock_key_change_passphrase(const char *priv_path,
                                const char *old_passphrase, const char *new_passphrase,
                                char *out_priv, int priv_cap, char *err, int errlen);

#ifdef __cplusplus
}
#endif

#endif /* SERVERDOCK_SSH_CORE_H */
