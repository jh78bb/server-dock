// Pure C interface separating FreeRDP/WinPR types (GUID/IID, etc.) from ObjC/Foundation
// and the conflicting CFPlugInCOM/IOKit COM types. Expose only primitive C types, never FreeRDP types,
// so the ObjC bridge can safely import this header without conflicting type definitions in one translation unit.
// Implemented in ServerDockRDPCore.c, compiled as C without Foundation.
#ifndef SERVERDOCK_RDP_CORE_H
#define SERVERDOCK_RDP_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Connection state.
typedef enum {
    ServerDockRDPStateConnecting = 0,
    ServerDockRDPStateConnected = 1,
    ServerDockRDPStateDisconnected = 2,
    ServerDockRDPStateFailed = 3,
} ServerDockRDPState;

/// Callbacks run on the background event-loop thread; callers must dispatch UI work to the main thread.
typedef struct {
    void *userdata;
    /// Completed composite frame: pixels points to FreeRDP's full framebuffer, which may change after return; copy it if needed.
    /// bpp is bytes per pixel (2=RGB16, 4=BGRX32); select CGImage byte order/component depth accordingly, as in the official Mac/iOS clients.
    void (*on_frame)(void *userdata, const uint8_t *pixels, int width, int height, int stride, int bpp);
    /// State change; message may be NULL.
    void (*on_state)(void *userdata, ServerDockRDPState state, const char *message);
    /// Lifecycle connection log for the live-log panel: level 0=info, 1=warning, 2=error.
    void (*on_log)(void *userdata, int level, const char *text);
    /// Incoming remote clipboard text (UTF-8); dispatch from this background callback before updating the local clipboard.
    void (*on_clipboard)(void *userdata, const char *utf8_text);
    /// Synchronous certificate trust check on the background event-loop thread; may block while awaiting the user.
    /// changed=0 for a first-seen certificate, 1 for a mismatch with a stored fingerprint. old_* supplies previous certificate details or NULL.
    /// Return 0=reject, 1=accept/permanently trust, 2=accept once. A NULL callback defaults to 2.
    int (*verify_certificate)(void *userdata, const char *host, int port,
                              const char *common_name, const char *subject,
                              const char *issuer, const char *fingerprint, int changed,
                              const char *old_subject, const char *old_issuer,
                              const char *old_fingerprint);
} ServerDockRDPCallbacks;

/// Opaque session handle.
typedef struct ServerDockRDPHandle ServerDockRDPHandle;

/// Embedded FreeRDP version, e.g. "3.9.0"; points to static storage and must not be freed.
const char *serverdock_rdp_freerdp_version(void);

/// Create a session without connecting yet.
ServerDockRDPHandle *serverdock_rdp_create(ServerDockRDPCallbacks callbacks);

/// Connect asynchronously: launch freerdp_connect and the event loop on a background thread. Return 0 immediately, nonzero for invalid arguments.
int serverdock_rdp_connect(ServerDockRDPHandle *handle, const char *host, int port,
                      const char *username, const char *password,
                      const char *domain, int width, int height);

/// Pointer movement in remote-desktop pixel coordinates.
void serverdock_rdp_mouse_move(ServerDockRDPHandle *handle, int x, int y);
/// Mouse button: 0=left, 1=right, 2=middle; down=1 pressed, 0 released.
void serverdock_rdp_mouse_button(ServerDockRDPHandle *handle, int button, int down, int x, int y);
/// Wheel delta: positive scrolls up, negative down, about 120 per notch.
void serverdock_rdp_mouse_wheel(ServerDockRDPHandle *handle, int delta, int x, int y);

/// Abstract modifier bits independent of NSEvent, translated by the caller. The engine compares previous state and sends only changes.
typedef enum {
    ServerDockRDPModShift    = 1 << 0,
    ServerDockRDPModControl  = 1 << 1,
    ServerDockRDPModAlt      = 1 << 2,   // Option maps to remote Alt.
    ServerDockRDPModCommand  = 1 << 3,   // Command maps to remote left Windows key.
    ServerDockRDPModCapsLock = 1 << 4,   // Lock-toggle key.
} ServerDockRDPModMask;

/// Ordinary key: mac_keycode is an NSEvent.keyCode virtual key; down=1 pressed, 0 released.
/// WinPR maps Apple keycodes to Windows VKs and then RDP scan codes, including extended-key flags.
void serverdock_rdp_key(ServerDockRDPHandle *handle, int mac_keycode, int down);
/// Send the current OR-combined ServerDockRDPModMask; the engine diffs previous state and sends press/release changes.
void serverdock_rdp_modifiers(ServerDockRDPHandle *handle, int mod_mask);

/// Request width-by-height remote resolution through DisplayControl; ignore if the channel is not ready.
void serverdock_rdp_resize(ServerDockRDPHandle *handle, int width, int height);

/// Announce local UTF-8 clipboard text via CLIPRDR. NULL/empty clears it.
/// The server requests actual data as needed. Cache until the channel is ready and announce after MonitorReady.
void serverdock_rdp_clipboard_offer_text(ServerDockRDPHandle *handle, const char *utf8_text);

/// Request disconnection, allowing the event loop/thread to exit naturally.
void serverdock_rdp_disconnect(ServerDockRDPHandle *handle);

/// Disconnect and free, joining the background thread.
void serverdock_rdp_free(ServerDockRDPHandle *handle);

#ifdef __cplusplus
}
#endif

#endif /* SERVERDOCK_RDP_CORE_H */
