#import "ServerDockRDPSession.h"
#import "ServerDockRDPCore.h"   // Pure C layer; do not include FreeRDP headers here to avoid conflicting type definitions.

static void serverdock_bridge_on_state(void *userdata, ServerDockRDPState state, const char *message);
static void serverdock_bridge_on_frame(void *userdata, const uint8_t *pixels, int width, int height, int stride, int bpp);
static void serverdock_bridge_on_log(void *userdata, int level, const char *text);
static void serverdock_bridge_on_clipboard(void *userdata, const char *utf8_text);
static int serverdock_bridge_verify_certificate(void *userdata, const char *host, int port,
                                           const char *common_name, const char *subject,
                                           const char *issuer, const char *fingerprint, int changed,
                                           const char *old_subject, const char *old_issuer,
                                           const char *old_fingerprint);

@implementation ServerDockRDPSession {
    NSString *_host;
    int _port;
    NSString *_username;
    NSString *_password;
    NSString *_domain;
    int _width;
    int _height;
    ServerDockRDPHandle *_handle;
    // Certificate checking synchronizes across threads: background waits on _certSem; the main-thread delegate resolves the decision and wakes it.
    NSLock *_certLock;
    dispatch_semaphore_t _certSem;   // Non-nil while awaiting a certificate decision.
    NSInteger _certDecision;
}

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                    password:(NSString *)password
                      domain:(NSString *)domain
                       width:(int)width
                      height:(int)height {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _username = [username copy];
        _password = [password copy];
        _domain = [domain copy];
        _width = width;
        _height = height;
        _certLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)connect {
    if (_handle) return;
    ServerDockRDPCallbacks cb = { 0 };
    cb.userdata = (__bridge void *)self;   // Unretained: dealloc calls serverdock_rdp_free and joins the thread before this object is destroyed.
    cb.on_state = serverdock_bridge_on_state;
    cb.on_frame = serverdock_bridge_on_frame;
    cb.on_log = serverdock_bridge_on_log;
    cb.on_clipboard = serverdock_bridge_on_clipboard;
    cb.verify_certificate = serverdock_bridge_verify_certificate;
    _handle = serverdock_rdp_create(cb);
    int rc = serverdock_rdp_connect(_handle, _host.UTF8String, _port,
                               _username.UTF8String, _password.UTF8String,
                               _domain.UTF8String, _width, _height);
    if (rc != 0 && [self.delegate respondsToSelector:@selector(rdpSession:didChangeState:message:)]) {
        [self.delegate rdpSession:self
                   didChangeState:ServerDockRDPStateFailed
                          message:[NSString stringWithFormat:@"Failed to start connection (%d)", rc]];
    }
}

- (void)disconnect {
    [self resolveCertificate:0];   // Reject a pending certificate prompt to unblock the background thread for clean exit.
    if (_handle) serverdock_rdp_disconnect(_handle);
}

- (void)shutdown {
    [self resolveCertificate:0];   // Resolve the certificate wait first or the following join would deadlock.
    if (_handle) {
        serverdock_rdp_free(_handle);   // Abort, join, and free synchronously; after return, no worker threads/callbacks remain.
        _handle = NULL;            // Clear the handle to prevent dealloc freeing it twice.
    }
}

// MARK: - Cross-thread certificate synchronization

// The background event-loop thread requests a main-thread dialog and blocks for the decision (0/1/2).
- (NSInteger)waitForCertificateDecisionHost:(NSString *)host port:(int)port
                                 commonName:(NSString *)commonName subject:(NSString *)subject
                                     issuer:(NSString *)issuer fingerprint:(NSString *)fingerprint
                                    changed:(BOOL)changed oldSubject:(NSString *)oldSubject
                                  oldIssuer:(NSString *)oldIssuer oldFingerprint:(NSString *)oldFingerprint {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [_certLock lock];
    _certSem = sem;
    _certDecision = 0;   // Default to reject if disconnected/freed before a decision.
    [_certLock unlock];

    __weak ServerDockRDPSession *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ServerDockRDPSession *s = weakSelf;
        if (!s) return;   // If the object is gone, dealloc has already resolved the wait, so the worker cannot remain blocked.
        id<ServerDockRDPSessionDelegate> d = s.delegate;
        SEL sel = @selector(rdpSession:verifyCertificateForHost:port:commonName:subject:issuer:fingerprint:changed:oldSubject:oldIssuer:oldFingerprint:completion:);
        if (![d respondsToSelector:sel]) {
            [s resolveCertificate:2];   // If unimplemented, accept once by default, preserving existing behavior without blocking the connection.
            return;
        }
        [d rdpSession:s verifyCertificateForHost:host port:port commonName:commonName
              subject:subject issuer:issuer fingerprint:fingerprint changed:changed
           oldSubject:oldSubject oldIssuer:oldIssuer oldFingerprint:oldFingerprint
           completion:^(NSInteger decision) { [s resolveCertificate:decision]; }];
    });

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    [_certLock lock];
    NSInteger decision = _certDecision;
    [_certLock unlock];
    return decision;
}

// Store the decision and wake the worker; nil _certSem marks completion and prevents duplicate signaling.
- (void)resolveCertificate:(NSInteger)decision {
    [_certLock lock];
    dispatch_semaphore_t sem = _certSem;
    if (sem) {
        _certDecision = decision;
        _certSem = nil;
        dispatch_semaphore_signal(sem);
    }
    [_certLock unlock];
}

- (void)sendMouseMoveX:(int)x y:(int)y {
    if (_handle) serverdock_rdp_mouse_move(_handle, x, y);
}
- (void)sendMouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y {
    if (_handle) serverdock_rdp_mouse_button(_handle, button, down ? 1 : 0, x, y);
}
- (void)sendMouseWheel:(int)delta x:(int)x y:(int)y {
    if (_handle) serverdock_rdp_mouse_wheel(_handle, delta, x, y);
}
- (void)sendKey:(int)keyCode down:(BOOL)down {
    if (_handle) serverdock_rdp_key(_handle, keyCode, down ? 1 : 0);
}
- (void)sendModifiers:(int)mask {
    if (_handle) serverdock_rdp_modifiers(_handle, mask);
}
- (void)offerClipboardText:(NSString *)text {
    if (_handle) serverdock_rdp_clipboard_offer_text(_handle, text.UTF8String);
}
- (void)resizeToWidth:(int)width height:(int)height {
    if (_handle) serverdock_rdp_resize(_handle, width, height);
}

- (void)dealloc {
    [self resolveCertificate:0];   // Unblock any certificate wait before joining the background thread to avoid deadlock.
    if (_handle) {
        serverdock_rdp_free(_handle);   // Join the worker so no further callbacks can arrive.
        _handle = NULL;
    }
}

+ (NSString *)freerdpVersion {
    return [NSString stringWithUTF8String:serverdock_rdp_freerdp_version()];
}

@end

// C callback trampolines to ObjC delegates on the main thread.
static void serverdock_bridge_on_state(void *userdata, ServerDockRDPState state, const char *message) {
    ServerDockRDPSession *session = (__bridge ServerDockRDPSession *)userdata;
    NSString *msg = message ? [NSString stringWithUTF8String:message] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didChangeState:message:)])
            [session.delegate rdpSession:session didChangeState:(NSInteger)state message:msg];
    });
}

static void serverdock_bridge_on_frame(void *userdata, const uint8_t *pixels, int width, int height, int stride, int bpp) {
    ServerDockRDPSession *session = (__bridge ServerDockRDPSession *)userdata;
    // Copy the full FreeRDP frame before the callback returns and its buffer changes, then dispatch to the main thread for rendering.
    NSData *data = [NSData dataWithBytes:pixels length:(NSUInteger)height * (NSUInteger)stride];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didReceiveFrame:width:height:stride:bpp:)])
            [session.delegate rdpSession:session didReceiveFrame:data width:width height:height stride:stride bpp:bpp];
    });
}

// Dispatch connection-log callbacks to the main-thread delegate.
static void serverdock_bridge_on_log(void *userdata, int level, const char *text) {
    if (!text) return;
    ServerDockRDPSession *session = (__bridge ServerDockRDPSession *)userdata;
    NSString *line = [NSString stringWithUTF8String:text];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didLog:level:)])
            [session.delegate rdpSession:session didLog:line level:(NSInteger)level];
    });
}

// Dispatch remote clipboard text to the main-thread delegate for local clipboard updates.
static void serverdock_bridge_on_clipboard(void *userdata, const char *utf8_text) {
    if (!utf8_text) return;
    ServerDockRDPSession *session = (__bridge ServerDockRDPSession *)userdata;
    NSString *text = [NSString stringWithUTF8String:utf8_text];
    if (!text) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([session.delegate respondsToSelector:@selector(rdpSession:didReceiveClipboardText:)])
            [session.delegate rdpSession:session didReceiveClipboardText:text];
    });
}

// Certificate callback trampoline: convert C strings to NSString, then synchronously await the ObjC/user decision on the background thread.
static int serverdock_bridge_verify_certificate(void *userdata, const char *host, int port,
                                           const char *common_name, const char *subject,
                                           const char *issuer, const char *fingerprint, int changed,
                                           const char *old_subject, const char *old_issuer,
                                           const char *old_fingerprint) {
    ServerDockRDPSession *session = (__bridge ServerDockRDPSession *)userdata;
#define TS(x) ((x) ? [NSString stringWithUTF8String:(x)] : nil)
    NSInteger decision = [session waitForCertificateDecisionHost:(TS(host) ?: @"")
                                                            port:port
                                                      commonName:TS(common_name)
                                                         subject:TS(subject)
                                                          issuer:TS(issuer)
                                                     fingerprint:TS(fingerprint)
                                                         changed:(changed != 0)
                                                      oldSubject:TS(old_subject)
                                                       oldIssuer:TS(old_issuer)
                                                  oldFingerprint:TS(old_fingerprint)];
#undef TS
    return (int)decision;
}
