// FreeRDP calling layer, compiled as pure C without Foundation/CoreFoundation/IOKit.
// Keep all FreeRDP/WinPR types and calls inside this translation unit, exposing only primitive C types through ServerDockRDPCore.h,
// avoiding GUID/IID/REFIID conflicts with CoreFoundation CFPlugInCOM/IOKit COM types.
//
// Connect through low-level freerdp_new/freerdp_context_new, not freerdp_client_context_new.
// The high-level client API automatically loads dynamic channels such as rdpsnd/rdpgfx/echo/ainput; a statically embedded build
// has no dylib plugins to dlopen, causing pre_connect failure. Basic remote desktop uses legacy GDI without those channels.
#include "ServerDockRDPCore.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>        // RDP_SCANCODE_* modifier scan codes.
#include <winpr/input.h>             // GetVirtualKeyCodeFromKeycode / GetVirtualScanCodeFromVirtualKeyCode
#include <freerdp/event.h>
#include <freerdp/version.h>
#include <freerdp/settings.h>
#include <freerdp/addin.h>            // FREERDP_ADDIN_CHANNEL_STATIC / ENTRYEX
#include <freerdp/client/cmdline.h>   // freerdp_client_add_dynamic_channel
#include <freerdp/client/channels.h>  // freerdp_channels_load_static_addin_entry
#include <freerdp/channels/channels.h>// freerdp_channels_client_load_ex
#include <freerdp/client/disp.h>      // DispClientContext / SendMonitorLayout for dynamic resolution.
#include <freerdp/channels/disp.h>    // DISP_DVC_CHANNEL_NAME / DISPLAY_CONTROL_MONITOR_LAYOUT
#include <freerdp/client/cliprdr.h>   // CliprdrClientContext for clipboard synchronization.
#include <freerdp/channels/cliprdr.h> // CLIPRDR_* PDUs, CB_* constants, and CLIPRDR_SVC_CHANNEL_NAME.
#include <freerdp/client/rdpgfx.h>    // RdpgfxClientContext for full-color graphics pipeline.
#include <freerdp/channels/rdpgfx.h>  // RDPGFX_DVC_CHANNEL_NAME
#include <freerdp/gdi/gfx.h>          // gdi_graphics_pipeline_init/uninit
#include <winpr/user.h>               // CF_UNICODETEXT
#include <winpr/string.h>             // ConvertUtf8ToWCharAlloc / ConvertWCharNToUtf8Alloc
#include <winpr/synch.h>

#include <openssl/provider.h>        // OSSL_PROVIDER_add_builtin / OSSL_PROVIDER_load

// OpenSSL legacy provider for NTLM MD4 / RC4 / DES.
// OpenSSL 3 moved MD4/RC4/DES into the legacy provider. Static OpenSSL embedding
// does not load it automatically, leaving WinPR NTLM without MD4 (no md4 support / SEC_E_INTERNAL_ERROR),
// causing NLA authentication failure/disconnection. Register the liblegacy.a provider entry as builtin
// and explicitly load it, plus default as a fallback, before any NTLM crypto/freerdp_connect.
extern OSSL_provider_init_fn ossl_legacy_provider_init;   // Exported by static liblegacy.a.

static void serverdock_openssl_register_legacy(void) {
    OSSL_PROVIDER_add_builtin(NULL, "legacy", ossl_legacy_provider_init);
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");
}

static void serverdock_ensure_openssl_legacy(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, serverdock_openssl_register_legacy);
}

// Custom context must place rdpContext first so callbacks can cast context to ServerDockContext* and recover owner.
typedef struct {
    rdpContext context;
    ServerDockRDPHandle *owner;
} ServerDockContext;

struct ServerDockRDPHandle {
    freerdp *instance;
    rdpContext *context;
    ServerDockRDPCallbacks cb;
    pthread_t thread;
    int thread_started;
    DispClientContext *disp;   // Set when DisplayControl connects, for dynamic resolution.
    int dynresize_ready;       // Set to 1 only after DisplayControlCaps; the server ignores earlier SendMonitorLayout calls.
    UINT32 want_w, want_h;     // Latest requested size, cached until channel readiness to remove connection-time races.
    int mod_state;             // Previously reported ServerDockRDPModMask for sending only changes.
    CliprdrClientContext *cliprdr;  // Set when CLIPRDR connects, for clipboard synchronization.
    WCHAR *clip_local;         // Cached local UTF-16 clipboard text including trailing NUL, used to answer server data requests.
    UINT32 clip_local_bytes;   // clip_local byte count, including the two-byte NUL terminator.
    RdpgfxClientContext *gfx;  // Set after full-color RDPGFX connects; unsupported servers leave NULL and use legacy GDI.
};

static void serverdock_emit_state(ServerDockRDPHandle *h, ServerDockRDPState s, const char *msg) {
    if (h && h->cb.on_state) h->cb.on_state(h->cb.userdata, s, msg);
}

// Forward logs to the live connection panel; level 0=info, 1=warning, 2=error.
static void serverdock_log(ServerDockRDPHandle *h, int level, const char *text) {
    if (h && h->cb.on_log && text) h->cb.on_log(h->cb.userdata, level, text);
}

// Recover owner from a freerdp instance for callbacks.
static ServerDockRDPHandle *serverdock_owner(freerdp *instance) {
    return (instance && instance->context) ? ((ServerDockContext *)instance->context)->owner : NULL;
}

// Paint callbacks.
// BeginPaint clears invalid-region flags and starts accumulating this frame's dirty area.
static BOOL serverdock_begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd &&
        gdi->primary->hdc->hwnd->invalid)
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

// EndPaint passes the primary GDI buffer, dimensions, stride, and bytes per pixel for copying/rendering.
// Report bpp on each frame because servers may downgrade to RGB16 (two bytes/pixel); select CGImage byte order accordingly
// instead of assuming 32bpp and producing misaligned/torn rows.
static BOOL serverdock_end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary_buffer) return TRUE;
    ServerDockRDPHandle *h = ((ServerDockContext *)context)->owner;
    if (h && h->cb.on_frame)
        h->cb.on_frame(h->cb.userdata, gdi->primary_buffer, gdi->width, gdi->height,
                       (int)gdi->stride, (int)FreeRDPGetBytesPerPixel(gdi->dstFormat));
    return TRUE;
}

// DesktopResize runs after server resolution confirmation and recreates the GDI primary buffer, completing dynamic resizing.
static BOOL serverdock_desktop_resize(rdpContext *context) {
    rdpSettings *s = context->settings;
    return gdi_resize(context->gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight));
}

// DisplayControl for dynamic resolution.
// Send a single-primary-monitor layout requesting width by height; return SendMonitorLayout's result.
static UINT serverdock_disp_send_layout(ServerDockRDPHandle *h, UINT32 width, UINT32 height) {
    if (!h || !h->disp || !h->disp->SendMonitorLayout) return 0xFFFF;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    memset(&layout, 0, sizeof(layout));
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = width;
    layout.Height = height;
    layout.PhysicalWidth = width;       // Physical dimensions equal logical dimensions, equivalent to 100% DPI, matching official clients.
    layout.PhysicalHeight = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor = 100;
    return h->disp->SendMonitorLayout(h->disp, 1, &layout);
}

// DisplayControlCaps signals that dynamic resolution is supported; earlier layouts are ignored.
// Resend any cached connection-time size to avoid losing resize requests made before the channel was ready.
static UINT serverdock_disp_caps(DispClientContext *disp, UINT32 maxNumMonitors,
                            UINT32 maxMonitorAreaFactorA, UINT32 maxMonitorAreaFactorB) {
    (void)maxNumMonitors; (void)maxMonitorAreaFactorA; (void)maxMonitorAreaFactorB;
    ServerDockRDPHandle *h = disp ? (ServerDockRDPHandle *)disp->custom : NULL;
    if (h) {
        h->dynresize_ready = 1;
        serverdock_log(h, 0, "Display control channel ready (dynamic resolution)");
        if (h->want_w && h->want_h) serverdock_disp_send_layout(h, h->want_w, h->want_h);
    }
    return CHANNEL_RC_OK;
}

// CLIPRDR clipboard synchronization.
// Send general client capabilities with long-format-name support.
static UINT serverdock_cliprdr_send_caps(CliprdrClientContext *c) {
    CLIPRDR_GENERAL_CAPABILITY_SET gen = { 0 };
    gen.capabilitySetType = CB_CAPSTYPE_GENERAL;
    gen.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    gen.version = CB_CAPS_VERSION_2;
    gen.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&gen;
    return c->ClientCapabilities(c, &caps);
}

// Announce CF_UNICODETEXT if local text is cached, otherwise an empty format list indicating nothing shareable.
static UINT serverdock_cliprdr_send_format_list(ServerDockRDPHandle *h) {
    CliprdrClientContext *c = h ? h->cliprdr : NULL;
    if (!c) return CHANNEL_RC_OK;
    CLIPRDR_FORMAT fmt = { 0 };
    fmt.formatId = CF_UNICODETEXT;
    fmt.formatName = NULL;
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = h->clip_local ? 1 : 0;
    list.formats = h->clip_local ? &fmt : NULL;
    return c->ClientFormatList(c, &list);
}

// On server readiness, send capabilities and the current local format list.
static UINT serverdock_cliprdr_monitor_ready(CliprdrClientContext *c, const CLIPRDR_MONITOR_READY *m) {
    (void)m;
    ServerDockRDPHandle *h = c ? (ServerDockRDPHandle *)c->custom : NULL;
    serverdock_cliprdr_send_caps(c);
    serverdock_cliprdr_send_format_list(h);
    return CHANNEL_RC_OK;
}

// Acknowledge server clipboard changes and request UTF-16 data when text is offered.
static UINT serverdock_cliprdr_server_format_list(CliprdrClientContext *c, const CLIPRDR_FORMAT_LIST *list) {
    CLIPRDR_FORMAT_LIST_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_LIST_RESPONSE;
    resp.common.msgFlags = CB_RESPONSE_OK;
    c->ClientFormatListResponse(c, &resp);
    int has_text = 0;
    for (UINT32 i = 0; list && i < list->numFormats; i++)
        if (list->formats[i].formatId == CF_UNICODETEXT) { has_text = 1; break; }
    if (has_text) {
        CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
        req.common.msgType = CB_FORMAT_DATA_REQUEST;
        req.requestedFormatId = CF_UNICODETEXT;
        c->ClientFormatDataRequest(c, &req);
    }
    return CHANNEL_RC_OK;
}

static UINT serverdock_cliprdr_server_format_list_response(CliprdrClientContext *c,
                                                      const CLIPRDR_FORMAT_LIST_RESPONSE *r) {
    (void)c; (void)r; return CHANNEL_RC_OK;
}

// Answer server requests with cached local UTF-16 text, or FAIL if unavailable.
static UINT serverdock_cliprdr_server_format_data_request(CliprdrClientContext *c,
                                                     const CLIPRDR_FORMAT_DATA_REQUEST *req) {
    ServerDockRDPHandle *h = c ? (ServerDockRDPHandle *)c->custom : NULL;
    CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
    if (h && h->clip_local && req && req->requestedFormatId == CF_UNICODETEXT) {
        resp.common.msgFlags = CB_RESPONSE_OK;
        resp.common.dataLen = h->clip_local_bytes;
        resp.requestedFormatData = (const BYTE *)h->clip_local;
    } else {
        resp.common.msgFlags = CB_RESPONSE_FAIL;
    }
    return c->ClientFormatDataResponse(c, &resp);
}

// Convert received UTF-16 data to UTF-8 and notify the caller to update the local clipboard.
static UINT serverdock_cliprdr_server_format_data_response(CliprdrClientContext *c,
                                                      const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    ServerDockRDPHandle *h = c ? (ServerDockRDPHandle *)c->custom : NULL;
    if (!h || !resp || !(resp->common.msgFlags & CB_RESPONSE_OK)) return CHANNEL_RC_OK;
    const WCHAR *w = (const WCHAR *)resp->requestedFormatData;
    size_t wlen = resp->common.dataLen / sizeof(WCHAR);
    if (!w || wlen == 0) return CHANNEL_RC_OK;
    char *utf8 = ConvertWCharNToUtf8Alloc(w, wlen, NULL);   // Truncate at the first NUL.
    if (utf8) {
        if (h->cb.on_clipboard) h->cb.on_clipboard(h->cb.userdata, utf8);
        free(utf8);
    }
    return CHANNEL_RC_OK;
}

// Capture connected channel contexts by name: disp for resolution, cliprdr for clipboard.
static void serverdock_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    if (!e || !e->name) return;
    ServerDockRDPHandle *h = ((ServerDockContext *)context)->owner;
    if (!h) return;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext *disp = (DispClientContext *)e->pInterface;
        if (!disp) return;
        disp->custom = h;
        disp->DisplayControlCaps = serverdock_disp_caps;
        h->disp = disp;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        CliprdrClientContext *c = (CliprdrClientContext *)e->pInterface;
        if (!c) return;
        c->custom = h;
        c->MonitorReady = serverdock_cliprdr_monitor_ready;
        c->ServerFormatList = serverdock_cliprdr_server_format_list;
        c->ServerFormatListResponse = serverdock_cliprdr_server_format_list_response;
        c->ServerFormatDataRequest = serverdock_cliprdr_server_format_data_request;
        c->ServerFormatDataResponse = serverdock_cliprdr_server_format_data_response;
        h->cliprdr = c;
    } else if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // After full-color graphics negotiation, attach gfx to GDI so Progressive/RFX surface commands render into
        // the 32-bit BGRX primary_buffer, preserving EndPaint callbacks. If unsupported, retain legacy RGB16 GDI.
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
        rdpGdi *gdi = h->context ? h->context->gdi : NULL;
        if (gfx && gdi && gdi_graphics_pipeline_init(gdi, gfx)) {
            h->gfx = gfx;
            serverdock_log(h, 0, "Graphics pipeline enabled (full color)");
        }
    }
}

// Uninitialize gfx on ChannelDisconnected using the event's still-valid context; waiting until post_disconnect causes double-free.
static void serverdock_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    if (!e || !e->name) return;
    ServerDockRDPHandle *h = ((ServerDockContext *)context)->owner;
    if (!h) return;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        rdpGdi *gdi = h->context ? h->context->gdi : NULL;
        if (gdi && e->pInterface)
            gdi_graphics_pipeline_uninit(gdi, (RdpgfxClientContext *)e->pInterface);
        h->gfx = NULL;
    }
}

// Channel-loading callback, the key integration point for dynamic resolution.
// After PreConnect, utils_reload_channels frees old channels and creates an empty collection,
// then calls instance->LoadChannels to refill it before freerdp_channels_pre_connect initializes static channels.
// Load channels here; PreConnect loading would be discarded by reload, preventing drdynvc/disp connection.
static BOOL serverdock_load_channels(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;

    // Register a static-table global addin provider; otherwise loading disp through
    // freerdp_load_channel_addin_entry attempts nonexistent libdisp-client.dylib and fails in the static build.
    // After registration, CLIENT_DVCPluginEntry_TABLE, including disp_DVCPluginEntry, is searched first without dlopen.
    // The high-level API does this in freerdp_client_common_new; the low-level path must do it explicitly.
    freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0);

    // Load only the drdynvc transport manually. disp is added to the dynamic channel list during connection,
    // then instantiated from the static table after drdynvc negotiation.
    // Do not call freerdp_client_load_addins; it also requests channels such as rdpdr without registered static entry points and falls back to failing dlopen.
    PVIRTUALCHANNELENTRY ex = freerdp_channels_load_static_addin_entry(
        "drdynvc", NULL, NULL,
        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (ex) freerdp_channels_client_load_ex(context->channels, s, (PVIRTUALCHANNELENTRYEX)ex, NULL);

    // cliprdr also uses a static VC entry; ChannelConnected captures its CliprdrClientContext.
    PVIRTUALCHANNELENTRY clip = freerdp_channels_load_static_addin_entry(
        "cliprdr", NULL, NULL,
        FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX);
    if (clip) freerdp_channels_client_load_ex(context->channels, s, (PVIRTUALCHANNELENTRYEX)clip, NULL);
    return TRUE;
}

// Connection lifecycle callbacks.
static BOOL serverdock_pre_connect(freerdp *instance) {
    rdpContext *context = instance->context;
    rdpSettings *s = context->settings;
    serverdock_log(serverdock_owner(instance), 0, "Initializing connection parameters…");
    if (!freerdp_settings_set_bool(s, FreeRDP_CertificateCallbackPreferPEM, TRUE)) return FALSE;
    PubSub_SubscribeChannelConnected(context->pubSub, serverdock_on_channel_connected);
    PubSub_SubscribeChannelDisconnected(context->pubSub, serverdock_on_channel_disconnected);
    return TRUE;
}

static BOOL serverdock_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRX32)) return FALSE;  // BGRX32: 32bpp without alpha, matching the official Mac client.
    rdpContext *context = instance->context;
    context->update->BeginPaint = serverdock_begin_paint;
    context->update->EndPaint = serverdock_end_paint;
    context->update->DesktopResize = serverdock_desktop_resize;
    ServerDockRDPHandle *h = ((ServerDockContext *)context)->owner;
    serverdock_log(h, 0, "Graphics subsystem ready, connected");
    serverdock_emit_state(h, ServerDockRDPStateConnected, NULL);
    return TRUE;
}

static void serverdock_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context) return;
    ServerDockRDPHandle *h = ((ServerDockContext *)instance->context)->owner;
    // Uninitialize gfx in ChannelDisconnected while its channel/context is still valid,
    // not post_disconnect after rdpgfx has been freed, which causes double-free/dangling rfx_context_free crashes.
    gdi_free(instance);
    serverdock_log(h, 0, "Disconnected");
    serverdock_emit_state(h, ServerDockRDPStateDisconnected, NULL);
}

// Delegate certificate trust to the caller's dialog/store. This callback may block on the background event-loop thread
// while main-thread UI awaits a decision. With no callback, accept once by returning 2.
// Never write FreeRDP known_hosts; RDPCertTrustStore persists permanent trust and the upper layer answers each check,
// keeping one controlled trust source and avoiding later changed-certificate rejection paths.
static DWORD serverdock_verify_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                         const char *common_name, const char *subject,
                                         const char *issuer, const char *fingerprint, DWORD flags) {
    (void)flags;
    ServerDockRDPHandle *h = ((ServerDockContext *)instance->context)->owner;
    serverdock_log(h, 0, "Verifying server certificate…");
    if (h && h->cb.verify_certificate)
        return (DWORD)h->cb.verify_certificate(h->cb.userdata, host, (int)port, common_name,
                                               subject, issuer, fingerprint, 0, NULL, NULL, NULL);
    return 2;
}

// This callback handles stored-fingerprint mismatches from server rebuilds, certificate rotation, or NAT port reuse.
// Normally FreeRDP's changed path is unused because this project compares fingerprints in the upper layer instead of writing its known_hosts;
// register it defensively and forward old_* so changed certificates still receive a stronger warning.
static DWORD serverdock_verify_changed_certificate_ex(freerdp *instance, const char *host, UINT16 port,
                                                 const char *common_name, const char *subject,
                                                 const char *issuer, const char *fingerprint,
                                                 const char *old_subject, const char *old_issuer,
                                                 const char *old_fingerprint, DWORD flags) {
    (void)flags;
    ServerDockRDPHandle *h = ((ServerDockContext *)instance->context)->owner;
    if (h && h->cb.verify_certificate)
        return (DWORD)h->cb.verify_certificate(h->cb.userdata, host, (int)port, common_name,
                                               subject, issuer, fingerprint, 1,
                                               old_subject, old_issuer, old_fingerprint);
    return 2;
}

// Event-loop thread, following tf_freerdp.c tf_client_thread_proc.
static void *serverdock_thread_proc(void *arg) {
    ServerDockRDPHandle *h = (ServerDockRDPHandle *)arg;
    freerdp *instance = h->instance;

    serverdock_log(h, 0, "Negotiating security layer and connecting…");
    if (!freerdp_connect(instance)) {
        serverdock_log(h, 2, "Connection failed (authentication failed or server unreachable)");
        serverdock_emit_state(h, ServerDockRDPStateFailed, "Connection failed");
        return NULL;
    }

    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
    while (!freerdp_shall_disconnect_context(h->context)) {
        DWORD nCount = freerdp_get_event_handles(h->context, handles, ARRAYSIZE(handles));
        if (nCount == 0) break;
        DWORD status = WaitForMultipleObjects(nCount, handles, FALSE, 100);
        if (status == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(h->context)) break;
    }

    freerdp_disconnect(instance);
    return NULL;  // serverdock_post_disconnect emits disconnected state.
}

// Public API.
const char *serverdock_rdp_freerdp_version(void) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "%d.%d.%d",
             FREERDP_VERSION_MAJOR, FREERDP_VERSION_MINOR, FREERDP_VERSION_REVISION);
    return buf;
}

ServerDockRDPHandle *serverdock_rdp_create(ServerDockRDPCallbacks callbacks) {
    ServerDockRDPHandle *h = calloc(1, sizeof(*h));
    if (h) h->cb = callbacks;
    return h;
}

int serverdock_rdp_connect(ServerDockRDPHandle *h, const char *host, int port,
                      const char *username, const char *password,
                      const char *domain, int width, int height) {
    if (!h || !host || h->instance) return 1;

    serverdock_ensure_openssl_legacy();   // Load the legacy provider before NLA/NTLM needs MD4.

    freerdp *instance = freerdp_new();
    if (!instance) return 2;
    instance->ContextSize = sizeof(ServerDockContext);
    instance->PreConnect = serverdock_pre_connect;
    instance->LoadChannels = serverdock_load_channels;   // The only opportunity to restore drdynvc/disp channels after core reload.
    instance->PostConnect = serverdock_post_connect;
    instance->PostDisconnect = serverdock_post_disconnect;
    instance->VerifyCertificateEx = serverdock_verify_certificate_ex;
    instance->VerifyChangedCertificateEx = serverdock_verify_changed_certificate_ex;

    if (!freerdp_context_new(instance)) {
        freerdp_free(instance);
        return 3;
    }
    h->instance = instance;
    h->context = instance->context;
    ((ServerDockContext *)instance->context)->owner = h;

    rdpSettings *s = instance->context->settings;
    freerdp_settings_set_string(s, FreeRDP_ServerHostname, host);
    freerdp_settings_set_uint32(s, FreeRDP_ServerPort, (UINT32)port);
    if (username) freerdp_settings_set_string(s, FreeRDP_Username, username);
    if (password) freerdp_settings_set_string(s, FreeRDP_Password, password);
    if (domain) freerdp_settings_set_string(s, FreeRDP_Domain, domain);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, (UINT32)width);
    freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, (UINT32)height);
    freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32);
    // Dynamic resolution requires DVC transport, DisplayControl support, and resolution updates; omitting any prevents disp negotiation.
    freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE);
    // Disable audio playback/capture because those channels were excluded from the build and requesting them would dlopen missing plugins.
    freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_AudioCapture, FALSE);
    // Keep NetworkAutoDetect enabled: some servers, including the RainYun test server, actively send RTT requests,
    // which cause STATE_RUN_FAILED disconnection if unsupported. The messageChannelId mismatch is benign; retain the default.

    // RDPGFX enables full 32-bit color using royalty-free Progressive/RemoteFX; H264/FFmpeg are disabled in the build.
    // Negotiate gfx through drdynvc. Unsupported servers such as XP fall back to legacy GDI without breaking the connection.
    freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_RemoteFxCodec, TRUE);
    freerdp_settings_set_bool(s, FreeRDP_GfxH264, FALSE);       // No H264 decoder: explicitly omit AVC advertisement so the server uses Progressive/RFX.
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, FALSE);
    freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, FALSE);

    // Add disp/rdpgfx to the dynamic list so drdynvc starts DisplayControl/graphics subchannels after negotiation.
    const char *disp_args[] = { "disp" };
    freerdp_client_add_dynamic_channel(s, 1, disp_args);
    const char *gfx_args[] = { "rdpgfx" };
    freerdp_client_add_dynamic_channel(s, 1, gfx_args);

    char line[192];
    snprintf(line, sizeof(line), "Connecting %s@%s:%d", (username && *username) ? username : "(none)", host, port);
    serverdock_log(h, 0, line);
    serverdock_emit_state(h, ServerDockRDPStateConnecting, NULL);
    if (pthread_create(&h->thread, NULL, serverdock_thread_proc, h) != 0) return 4;
    h->thread_started = 1;
    return 0;
}

// Mouse input from the main thread, low-frequency user events; currently unlocked, with thread safety planned for stage F.
static rdpInput *serverdock_input(ServerDockRDPHandle *h) {
    return (h && h->context) ? h->context->input : NULL;
}

void serverdock_rdp_mouse_move(ServerDockRDPHandle *h, int x, int y) {
    rdpInput *in = serverdock_input(h);
    if (in) freerdp_input_send_mouse_event(in, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
}

void serverdock_rdp_mouse_button(ServerDockRDPHandle *h, int button, int down, int x, int y) {
    rdpInput *in = serverdock_input(h);
    if (!in) return;
    UINT16 flags;
    switch (button) {
        case 0: flags = PTR_FLAGS_BUTTON1; break;  // Left.
        case 1: flags = PTR_FLAGS_BUTTON2; break;  // Right.
        case 2: flags = PTR_FLAGS_BUTTON3; break;  // Middle.
        default: return;
    }
    if (down) flags |= PTR_FLAGS_DOWN;
    freerdp_input_send_mouse_event(in, flags, (UINT16)x, (UINT16)y);
}

void serverdock_rdp_mouse_wheel(ServerDockRDPHandle *h, int delta, int x, int y) {
    rdpInput *in = serverdock_input(h);
    if (!in) return;
    UINT16 flags = PTR_FLAGS_WHEEL;
    int amount = delta;
    if (amount < 0) { flags |= PTR_FLAGS_WHEEL_NEGATIVE; amount = -amount; }
    if (amount > 0xFF) amount = 0xFF;
    flags |= (UINT16)(amount & 0xFF);
    freerdp_input_send_mouse_event(in, flags, (UINT16)x, (UINT16)y);
}

// Main-thread keyboard input, mapping based on the official client/Mac implementation.
// Send an RDP scan-code press/release, including KBDEXT extended bits.
static void serverdock_send_scancode(rdpInput *in, UINT32 rdp_scancode, int down) {
    UINT16 flags = (rdp_scancode & KBDEXT) ? KBD_FLAGS_EXTENDED : 0;
    flags |= down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    freerdp_input_send_keyboard_event(in, flags, (UINT8)(rdp_scancode & 0xFF));
}

void serverdock_rdp_key(ServerDockRDPHandle *h, int mac_keycode, int down) {
    rdpInput *in = serverdock_input(h);
    if (!in) return;
    // Map Apple virtual keycode to Windows VK to RDP scan code; keyboard type 4 is IBM enhanced 101/102-key.
    DWORD vk = GetVirtualKeyCodeFromKeycode((DWORD)mac_keycode, WINPR_KEYCODE_TYPE_APPLE);
    DWORD sc = GetVirtualScanCodeFromVirtualKeyCode(vk, WINPR_KBD_TYPE_IBM_ENHANCED);
    if ((sc & 0xFF) == 0) return;   // No mapping.
    serverdock_send_scancode(in, sc, down);
}

void serverdock_rdp_modifiers(ServerDockRDPHandle *h, int mask) {
    rdpInput *in = serverdock_input(h);
    if (!in) return;
    static const struct { int bit; UINT32 sc; int toggle; } mods[] = {
        { ServerDockRDPModShift,    RDP_SCANCODE_LSHIFT,   0 },
        { ServerDockRDPModControl,  RDP_SCANCODE_LCONTROL, 0 },
        { ServerDockRDPModAlt,      RDP_SCANCODE_LMENU,    0 },
        { ServerDockRDPModCommand,  RDP_SCANCODE_LWIN,     0 },
        { ServerDockRDPModCapsLock, RDP_SCANCODE_CAPSLOCK, 1 },   // Toggle key: send one tap when state changes.
    };
    int changed = mask ^ h->mod_state;
    for (size_t i = 0; i < sizeof(mods) / sizeof(mods[0]); i++) {
        if (!(changed & mods[i].bit)) continue;
        if (mods[i].toggle) {
            serverdock_send_scancode(in, mods[i].sc, 1);
            serverdock_send_scancode(in, mods[i].sc, 0);
        } else {
            serverdock_send_scancode(in, mods[i].sc, (mask & mods[i].bit) ? 1 : 0);
        }
    }
    h->mod_state = mask;
}

void serverdock_rdp_resize(ServerDockRDPHandle *h, int width, int height) {
    if (!h || width < 1 || height < 1) return;
    // Always retain the target size. Send when the channel/capability is ready; otherwise serverdock_disp_caps resends after DisplayControlCaps.
    h->want_w = (UINT32)width;
    h->want_h = (UINT32)height;
    if (h->dynresize_ready && h->disp)
        serverdock_disp_send_layout(h, (UINT32)width, (UINT32)height);
}

void serverdock_rdp_clipboard_offer_text(ServerDockRDPHandle *h, const char *utf8) {
    if (!h) return;
    free(h->clip_local);
    h->clip_local = NULL;
    h->clip_local_bytes = 0;
    if (utf8 && *utf8) {
        size_t wlen = 0;   // wcslen excludes the trailing NUL.
        WCHAR *w = ConvertUtf8ToWCharAlloc(utf8, &wlen);
        if (w) {
            h->clip_local = w;
            h->clip_local_bytes = (UINT32)((wlen + 1) * sizeof(WCHAR));   // CF_UNICODETEXT includes the trailing NUL.
        }
    }
    serverdock_cliprdr_send_format_list(h);   // No-op before channel readiness; MonitorReady sends again.
}

void serverdock_rdp_disconnect(ServerDockRDPHandle *h) {
    if (h && h->context) freerdp_abort_connect_context(h->context);
}

void serverdock_rdp_free(ServerDockRDPHandle *h) {
    if (!h) return;
    if (h->instance) {
        if (h->context) freerdp_abort_connect_context(h->context);
        if (h->thread_started) { pthread_join(h->thread, NULL); h->thread_started = 0; }
        freerdp_context_free(h->instance);
        freerdp_free(h->instance);
        h->instance = NULL;
        h->context = NULL;
    }
    free(h->clip_local);
    free(h);
}
