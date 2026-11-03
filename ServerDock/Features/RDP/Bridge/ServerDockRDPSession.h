#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class ServerDockRDPSession;

/// RDP session events, already dispatched to the main thread.
/// state corresponds to ServerDockRDPCore's ServerDockRDPState: 0=connecting, 1=connected, 2=disconnected, 3=failed.
@protocol ServerDockRDPSessionDelegate <NSObject>
@optional
- (void)rdpSession:(ServerDockRDPSession *)session didChangeState:(NSInteger)state message:(nullable NSString *)message;
- (void)rdpSession:(ServerDockRDPSession *)session
    didReceiveFrame:(NSData *)pixels
              width:(int)width
             height:(int)height
             stride:(int)stride
                bpp:(int)bpp;

/// Main-thread connection logs for the live panel: 0=info, 1=warning, 2=error.
- (void)rdpSession:(ServerDockRDPSession *)session didLog:(NSString *)text level:(NSInteger)level;

/// Main-thread remote clipboard delivery; the caller updates the local clipboard.
- (void)rdpSession:(ServerDockRDPSession *)session didReceiveClipboardText:(NSString *)text;

/// Main-thread certificate check; changed=YES means a stored-fingerprint mismatch, with old* describing the previous certificate.
/// Call completion with 0=reject, 1=permanent trust, 2=accept once after the user's decision. Asynchronous completion is allowed;
/// the background thread waits. If this method is unimplemented, accept once by default.
- (void)rdpSession:(ServerDockRDPSession *)session
    verifyCertificateForHost:(NSString *)host
                        port:(int)port
                  commonName:(nullable NSString *)commonName
                     subject:(nullable NSString *)subject
                      issuer:(nullable NSString *)issuer
                 fingerprint:(nullable NSString *)fingerprint
                     changed:(BOOL)changed
                  oldSubject:(nullable NSString *)oldSubject
                   oldIssuer:(nullable NSString *)oldIssuer
              oldFingerprint:(nullable NSString *)oldFingerprint
                  completion:(void (^)(NSInteger decision))completion;
@end

/// ObjC FreeRDP bridge through ServerDockRDPCore's pure C connection/event/frame interface, exposing KVO/delegates to Swift.
@interface ServerDockRDPSession : NSObject

@property (nonatomic, weak) id<ServerDockRDPSessionDelegate> delegate;

- (instancetype)initWithHost:(NSString *)host
                        port:(int)port
                    username:(NSString *)username
                    password:(NSString *)password
                      domain:(NSString *)domain
                       width:(int)width
                      height:(int)height;

- (void)connect;
- (void)disconnect;
/// Close synchronously: resolve pending certificate waits, abort/join the event thread, then free. Call before app exit to leave no threads behind.
- (void)shutdown;

// Mouse input in remote-desktop pixel coordinates.
- (void)sendMouseMoveX:(int)x y:(int)y;
- (void)sendMouseButton:(int)button down:(BOOL)down x:(int)x y:(int)y;  // button: 0=left, 1=right, 2=middle.
- (void)sendMouseWheel:(int)delta x:(int)x y:(int)y;

// Keyboard input: keyCode is NSEvent.keyCode; mask uses ServerDockRDPModMask from ServerDockRDPCore.h.
- (void)sendKey:(int)keyCode down:(BOOL)down;
- (void)sendModifiers:(int)mask;

/// Announce local clipboard text over CLIPRDR; nil/empty means no shareable local text.
- (void)offerClipboardText:(nullable NSString *)text;

/// Request remote-desktop resolution width by height.
- (void)resizeToWidth:(int)width height:(int)height;

/// Linkage self-test returning the embedded FreeRDP version string.
+ (NSString *)freerdpVersion;

@end

NS_ASSUME_NONNULL_END
