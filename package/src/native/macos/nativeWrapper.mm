/*
 * =============================================================================
 * 1. IMPORTS
 * =============================================================================
 */

#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <Cocoa/Cocoa.h>
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Contacts/Contacts.h>
#import <EventKit/EventKit.h>
#import <Photos/Photos.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <Speech/Speech.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <dlfcn.h>
#include <math.h>
#include "dawn/webgpu.h"

static bool wgpuDebugEnabled() {
    static int cached = -1;
    if (cached >= 0) return cached == 1;
    const char* val = getenv("ELECTROBUN_WGPU_DEBUG");
    cached = (val && strcmp(val, "1") == 0) ? 1 : 0;
    return cached == 1;
}
#import <UserNotifications/UserNotifications.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Vision/Vision.h>
#import <CoreImage/CoreImage.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <signal.h>
#include <atomic>
#include <mutex>
#include "../shared/pending_resize_queue.h"

// CEF includes
#include "include/base/cef_ref_counted.h"
#include "include/base/cef_logging.h"
#include "include/cef_base.h"
#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/cef_browser.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_helpers.h"
#include "include/cef_request_handler.h" 
#include "include/cef_scheme.h"
#include "include/cef_resource_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_permission_handler.h"
#include "include/cef_dialog_handler.h"
#include "include/cef_download_handler.h"
#include <algorithm>
#include <string>
#include <vector>
#include <list>
#include <cstdint>
#include <chrono>
#include <map>
#include <mutex>
#include <atomic>
#include <string.h>
#include <stdlib.h>

// Shared cross-platform utilities
#include "../shared/glob_match.h"
#include "../shared/callbacks.h"
#include "../shared/permissions.h"
#include "../shared/permissions_cef.h"
#include "../shared/partition_context.h"
#include "../shared/mime_types.h"
#include "../shared/asar.h"
#include "../shared/config.h"
#include "../shared/preload_script.h"
#include "../shared/webview_storage.h"
#include "../shared/navigation_rules.h"
#include "../shared/content_blocker.h"
#include "../shared/thread_safe_map.h"
#include "../shared/shutdown_guard.h"
#include "../shared/ffi_helpers.h"
#include "../shared/download_event.h"
#include "../shared/app_paths.h"
#include "../shared/accelerator_parser.h"
#include "../shared/chromium_flags.h"
#include "../shared/cache_migration.h"

using namespace electrobun;

/*
 * =============================================================================
 * 2. CONSTANTS, GLOBAL VARIABLES, FORWARD DECLARATIONS & TYPE DEFINITIONS
 * =============================================================================
 */

// Global ASAR archive handle (lazy-loaded) with thread-safe initialization
// ASAR C FFI declarations are in shared/asar.h
static AsarArchive* g_asarArchive = nullptr;
static std::once_flag g_asarArchiveInitFlag;

CGFloat OFFSCREEN_OFFSET = -20000;
BOOL useCEF = false;
std::string g_electrobunChannel = "";
std::string g_electrobunIdentifier = "";
std::string g_acceptLanguage = "";

static BOOL isMovingWindow = NO;
static NSWindow *targetWindow = nil;
static CGFloat offsetX = 0.0;
static CGFloat offsetY = 0.0;
static id mouseDraggedMonitor = nil;
static id mouseUpMonitor = nil;

static int g_remoteDebugPort = 9222;

// Menu role to selector mapping
// This maps Electrobun role strings to their corresponding Objective-C selectors.
// Roles are grouped by category for easier maintenance.
static NSDictionary<NSString*, NSString*>* getMenuRoleToSelectorMap() {
    static NSDictionary<NSString*, NSString*>* map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            // Application roles
            @"about": @"orderFrontStandardAboutPanel:",
            @"quit": @"terminate:",
            @"hide": @"hide:",
            @"hideOthers": @"hideOtherApplications:",
            @"showAll": @"unhideAllApplications:",

            // Window roles
            @"minimize": @"performMiniaturize:",
            @"zoom": @"performZoom:",
            @"close": @"performClose:",
            @"bringAllToFront": @"arrangeInFront:",
            @"cycleThroughWindows": @"selectNextKeyView:",
            @"enterFullScreen": @"enterFullScreen:",
            @"exitFullScreen": @"exitFullScreen:",
            @"toggleFullScreen": @"toggleFullScreen:",

            // Standard edit roles
            @"undo": @"undo:",
            @"redo": @"redo:",
            @"cut": @"cut:",
            @"copy": @"copy:",
            @"paste": @"paste:",
            @"pasteAndMatchStyle": @"pasteAsPlainText:",
            @"delete": @"delete:",
            @"selectAll": @"selectAll:",

            // Speech roles
            @"startSpeaking": @"startSpeaking:",
            @"stopSpeaking": @"stopSpeaking:",

            // Help
            @"showHelp": @"showHelp:",

            // Movement - basic
            @"moveForward": @"moveForward:",
            @"moveBackward": @"moveBackward:",
            @"moveLeft": @"moveLeft:",
            @"moveRight": @"moveRight:",
            @"moveUp": @"moveUp:",
            @"moveDown": @"moveDown:",

            // Movement - by word
            @"moveWordForward": @"moveWordForward:",
            @"moveWordBackward": @"moveWordBackward:",
            @"moveWordLeft": @"moveWordLeft:",
            @"moveWordRight": @"moveWordRight:",

            // Movement - by line
            @"moveToBeginningOfLine": @"moveToBeginningOfLine:",
            @"moveToEndOfLine": @"moveToEndOfLine:",
            @"moveToLeftEndOfLine": @"moveToLeftEndOfLine:",
            @"moveToRightEndOfLine": @"moveToRightEndOfLine:",

            // Movement - by paragraph
            @"moveToBeginningOfParagraph": @"moveToBeginningOfParagraph:",
            @"moveToEndOfParagraph": @"moveToEndOfParagraph:",
            @"moveParagraphForward": @"moveParagraphForward:",
            @"moveParagraphBackward": @"moveParagraphBackward:",

            // Movement - by document
            @"moveToBeginningOfDocument": @"moveToBeginningOfDocument:",
            @"moveToEndOfDocument": @"moveToEndOfDocument:",

            // Movement with selection - basic
            @"moveForwardAndModifySelection": @"moveForwardAndModifySelection:",
            @"moveBackwardAndModifySelection": @"moveBackwardAndModifySelection:",
            @"moveLeftAndModifySelection": @"moveLeftAndModifySelection:",
            @"moveRightAndModifySelection": @"moveRightAndModifySelection:",
            @"moveUpAndModifySelection": @"moveUpAndModifySelection:",
            @"moveDownAndModifySelection": @"moveDownAndModifySelection:",

            // Movement with selection - by word
            @"moveWordForwardAndModifySelection": @"moveWordForwardAndModifySelection:",
            @"moveWordBackwardAndModifySelection": @"moveWordBackwardAndModifySelection:",
            @"moveWordLeftAndModifySelection": @"moveWordLeftAndModifySelection:",
            @"moveWordRightAndModifySelection": @"moveWordRightAndModifySelection:",

            // Movement with selection - by line
            @"moveToBeginningOfLineAndModifySelection": @"moveToBeginningOfLineAndModifySelection:",
            @"moveToEndOfLineAndModifySelection": @"moveToEndOfLineAndModifySelection:",
            @"moveToLeftEndOfLineAndModifySelection": @"moveToLeftEndOfLineAndModifySelection:",
            @"moveToRightEndOfLineAndModifySelection": @"moveToRightEndOfLineAndModifySelection:",

            // Movement with selection - by paragraph
            @"moveToBeginningOfParagraphAndModifySelection": @"moveToBeginningOfParagraphAndModifySelection:",
            @"moveToEndOfParagraphAndModifySelection": @"moveToEndOfParagraphAndModifySelection:",
            @"moveParagraphForwardAndModifySelection": @"moveParagraphForwardAndModifySelection:",
            @"moveParagraphBackwardAndModifySelection": @"moveParagraphBackwardAndModifySelection:",

            // Movement with selection - by document
            @"moveToBeginningOfDocumentAndModifySelection": @"moveToBeginningOfDocumentAndModifySelection:",
            @"moveToEndOfDocumentAndModifySelection": @"moveToEndOfDocumentAndModifySelection:",

            // Page movement
            @"pageUp": @"pageUp:",
            @"pageDown": @"pageDown:",
            @"pageUpAndModifySelection": @"pageUpAndModifySelection:",
            @"pageDownAndModifySelection": @"pageDownAndModifySelection:",

            // Scrolling
            @"scrollLineUp": @"scrollLineUp:",
            @"scrollLineDown": @"scrollLineDown:",
            @"scrollPageUp": @"scrollPageUp:",
            @"scrollPageDown": @"scrollPageDown:",
            @"scrollToBeginningOfDocument": @"scrollToBeginningOfDocument:",
            @"scrollToEndOfDocument": @"scrollToEndOfDocument:",
            @"centerSelectionInVisibleArea": @"centerSelectionInVisibleArea:",

            // Deletion - character
            @"deleteBackward": @"deleteBackward:",
            @"deleteForward": @"deleteForward:",
            @"deleteBackwardByDecomposingPreviousCharacter": @"deleteBackwardByDecomposingPreviousCharacter:",

            // Deletion - word
            @"deleteWordBackward": @"deleteWordBackward:",
            @"deleteWordForward": @"deleteWordForward:",

            // Deletion - line
            @"deleteToBeginningOfLine": @"deleteToBeginningOfLine:",
            @"deleteToEndOfLine": @"deleteToEndOfLine:",

            // Deletion - paragraph
            @"deleteToBeginningOfParagraph": @"deleteToBeginningOfParagraph:",
            @"deleteToEndOfParagraph": @"deleteToEndOfParagraph:",

            // Selection
            @"selectWord": @"selectWord:",
            @"selectLine": @"selectLine:",
            @"selectParagraph": @"selectParagraph:",
            @"selectToMark": @"selectToMark:",
            @"setMark": @"setMark:",
            @"swapWithMark": @"swapWithMark:",
            @"deleteToMark": @"deleteToMark:",

            // Text transformation
            @"capitalizeWord": @"capitalizeWord:",
            @"uppercaseWord": @"uppercaseWord:",
            @"lowercaseWord": @"lowercaseWord:",
            @"transpose": @"transpose:",
            @"transposeWords": @"transposeWords:",

            // Insertion
            @"insertNewline": @"insertNewline:",
            @"insertLineBreak": @"insertLineBreak:",
            @"insertParagraphSeparator": @"insertParagraphSeparator:",
            @"insertTab": @"insertTab:",
            @"insertBacktab": @"insertBacktab:",
            @"insertTabIgnoringFieldEditor": @"insertTabIgnoringFieldEditor:",
            @"insertNewlineIgnoringFieldEditor": @"insertNewlineIgnoringFieldEditor:",

            // Kill ring (Emacs-style)
            @"yank": @"yank:",
            @"yankAndSelect": @"yankAndSelect:",

            // Completion
            @"complete": @"complete:",
            @"cancelOperation": @"cancelOperation:",

            // Indentation
            @"indent": @"indent:",
        };
    });
    return map;
}

static bool IsPortAvailable(int port) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        return false;
    }

    int opt = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons((uint16_t)port);

    int result = bind(sock, (struct sockaddr*)&addr, sizeof(addr));
    close(sock);
    return result == 0;
}

static int FindAvailableRemoteDebugPort(int startPort, int endPort) {
    for (int port = startPort; port <= endPort; ++port) {
        if (IsPortAvailable(port)) {
            return port;
        }
    }
    return 0;
}


// Forward declare the CEF classes
class CefApp;
class CefClient;
class CefLifeSpanHandler;
class CefBrowser;
class ElectrobunSchemeHandler;
class ElectrobunSchemeHandlerFactory;
class ElectrobunClient;

typedef void (*RemoteDevToolsClosedCallback)(void* ctx, int target_id);
void RemoteDevToolsClosed(void* ctx, int target_id);

class RemoteDevToolsClient : public CefClient, public CefLifeSpanHandler {
public:
    RemoteDevToolsClient(RemoteDevToolsClosedCallback callback, void* ctx, int target_id)
        : callback_(callback), ctx_(ctx), target_id_(target_id) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return this;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        if (callback_) {
            RemoteDevToolsClosedCallback cb = callback_;
            void* ctx = ctx_;
            int target_id = target_id_;
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(ctx, target_id);
            });
        }
    }

private:
    RemoteDevToolsClosedCallback callback_ = nullptr;
    void* ctx_ = nullptr;
    int target_id_ = 0;

    IMPLEMENT_REFCOUNTING(RemoteDevToolsClient);
};

@interface RemoteDevToolsWindowDelegate : NSObject <NSWindowDelegate> {
@public
    RemoteDevToolsClosedCallback callback;
    void* ctx;
    int target_id;
}
@end

@implementation RemoteDevToolsWindowDelegate
- (BOOL)windowShouldClose:(id)sender {
    if (callback) {
        callback(ctx, target_id);
    }
    // Prevent NSWindow from actually closing to avoid CEF teardown crashes.
    return NO;
}
@end

// Type definitions
// Core callback types are defined in shared/callbacks.h
// Platform-specific aliases for Objective-C compatibility
typedef BOOL (*HandlePostMessageObjC)(uint32_t webviewId, const char* message);
typedef void (*callAsyncJavascriptCompletionHandler)(const char *messageId, uint32_t webviewId, uint32_t hostWebviewId, const char *responseJSON);

static dispatch_queue_t jsWorkerQueue = NULL;

// Webview content storage (replaces JSCallback approach)
static NSMutableDictionary<NSNumber*, NSString*> *webviewHTMLContent = nil;
static NSLock *webviewHTMLLock = nil;

// Forward declarations for HTML content management
extern "C" const char* getWebviewHTMLContent(uint32_t webviewId);
extern "C" void setWebviewHTMLContent(uint32_t webviewId, const char* htmlContent);

// MIME type detection function is in shared/mime_types.h

// Deadlock prevention for callJsCallbackFromMainSync
static BOOL isInSyncCallback = NO;
static NSMutableArray *queuedCallbacks = nil;

// this lets you call non-threadsafe JSCallbacks on the bun worker thread, from the main thread
// and wait for the response. 
// use it like:
// REMOVED: jsUtils.getHTMLForWebviewSync callback (now using webviewHTMLContent map)
// });
// 
// DEADLOCK PREVENTION: If called recursively (e.g., during URL scheme handling), 
// queues the callback for later execution to prevent deadlocks.
static const char* callJsCallbackFromMainSync(const char* (^callback)(void)) {
    NSLog(@"callJSCallbackFromMainSync 1");
    if (!jsWorkerQueue) {
        NSLog(@"Error: JS worker queue not initialized");
        return NULL;
    }
    
    // Initialize queue if needed
    if (!queuedCallbacks) {
        NSLog(@"callJSCallbackFromMainSync 2");
        queuedCallbacks = [[NSMutableArray alloc] init];
    }

    NSLog(@"callJSCallbackFromMainSync 3");
    
    // Prevent recursive calls that can cause deadlocks
    if (isInSyncCallback) {
        NSLog(@"callJSCallbackFromMainSync 4");
        NSLog(@"callJsCallbackFromMainSync: Preventing deadlock - queueing callback for later execution");
        // For queued callbacks, we can't return a meaningful result since they're async
        // This is fine since recursive calls are typically RPC sends that don't need return values
        [queuedCallbacks addObject:[callback copy]];
        NSLog(@"callJSCallbackFromMainSync 5");
        return NULL;
    }
    NSLog(@"callJSCallbackFromMainSync 6");
    
    isInSyncCallback = YES;
    
    __block const char* result = NULL;
    __block char* resultCopy = NULL;
    NSLog(@"callJSCallbackFromMainSync 7");
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSLog(@"callJSCallbackFromMainSync 8");
    dispatch_async(jsWorkerQueue, ^{
        NSLog(@"callJSCallbackFromMainSync 9");
        
        @try {
            // Call the provided block (which executes the JS callback)
            result = callback();
            NSLog(@"callJSCallbackFromMainSync 10");
        } @catch (NSException *exception) {
            NSLog(@"callJSCallbackFromMainSync: Exception caught during callback execution: %@", exception);
            result = NULL;
        } @catch (...) {
            NSLog(@"callJSCallbackFromMainSync: Unknown exception caught during callback execution");
            result = NULL;
        }
        
        // Duplicate the result so it won't be garbage collected.
        if (result != NULL) {
            NSLog(@"callJSCallbackFromMainSync 11");
            resultCopy = strdup(result);
        }
        NSLog(@"callJSCallbackFromMainSync 12");
        
        dispatch_semaphore_signal(semaphore);
        NSLog(@"callJSCallbackFromMainSync 13");
    });
    
    // Add timeout to prevent indefinite blocking during process failures
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC); // 5 second timeout
    long result_wait = dispatch_semaphore_wait(semaphore, timeout);
    
    if (result_wait != 0) {
        NSLog(@"callJSCallbackFromMainSync: Timeout waiting for callback completion - possible process failure");
        isInSyncCallback = NO;
        return NULL;
    }
    
    NSLog(@"callJSCallbackFromMainSync 14");
    
    // Process any queued callbacks (these are typically fire-and-forget RPC calls)
    while (queuedCallbacks.count > 0) {
        NSLog(@"callJSCallbackFromMainSync 15");
        NSLog(@"callJsCallbackFromMainSync: Processing %lu queued callback(s)", (unsigned long)queuedCallbacks.count);
        const char* (^queuedCallback)(void) = queuedCallbacks[0];
        [queuedCallbacks removeObjectAtIndex:0];
        NSLog(@"callJSCallbackFromMainSync 16");
        // Execute queued callback asynchronously (these don't need return values)
        dispatch_async(jsWorkerQueue, ^{
            NSLog(@"callJSCallbackFromMainSync 17");
            @try {
                queuedCallback();
            } @catch (NSException *exception) {
                NSLog(@"callJSCallbackFromMainSync: Exception in queued callback: %@", exception);
            } @catch (...) {
                NSLog(@"callJSCallbackFromMainSync: Unknown exception in queued callback");
            }
            NSLog(@"callJSCallbackFromMainSync 18");
        });
    }
    
    isInSyncCallback = NO;
    NSLog(@"callJSCallbackFromMainSync 19");
    return resultCopy; // Caller is responsible for freeing this memory.
}

typedef struct {
    NSRect frame;
    uint32_t styleMask;
    const char *titleBarStyle;
    bool toolbar;
    double trafficLightOffsetX;
    double trafficLightOffsetY;
    double cornerRadius;
} createNSWindowWithFrameAndStyleParams;

static NSString *g_appAppearanceName = nil;

static const void *kTrafficLightOffsetXKey = &kTrafficLightOffsetXKey;
static const void *kTrafficLightOffsetYKey = &kTrafficLightOffsetYKey;
static const void *kTrafficLightAppliedOffsetXKey = &kTrafficLightAppliedOffsetXKey;
static const void *kTrafficLightAppliedOffsetYKey = &kTrafficLightAppliedOffsetYKey;

static const void *kTrafficLightTitleBarStyleKey = &kTrafficLightTitleBarStyleKey;
static const void *kWindowCornerRadiusKey = &kWindowCornerRadiusKey;

static void applyContinuousCornerRadiusToView(NSView *view, CGFloat radius) {
    if (!view) return;
    view.wantsLayer = YES;
    view.layer.cornerRadius = MAX(radius, 0);
    if (radius > 0) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.layer.masksToBounds = YES;
    } else {
        view.layer.masksToBounds = NO;
    }
}

static void applyWindowCornerRadius(NSWindow *window, double cornerRadius) {
    if (!window) return;
    CGFloat radius = (CGFloat)cornerRadius;
    NSView *contentView = window.contentView;
    applyContinuousCornerRadiusToView(contentView.superview, radius);
    applyContinuousCornerRadiusToView(contentView, radius);
}

static void setConfiguredWindowCornerRadius(NSWindow *window, double cornerRadius) {
    if (!window) return;
    objc_setAssociatedObject(window, kWindowCornerRadiusKey, @(cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    applyWindowCornerRadius(window, cornerRadius);
}

static double getConfiguredWindowCornerRadius(NSWindow *window) {
    NSNumber *radius = objc_getAssociatedObject(window, kWindowCornerRadiusKey);
    return radius ? radius.doubleValue : 0;
}

static bool shouldManageTrafficLights(NSWindow *window) {
    if (!window) {
        return false;
    }

    NSString *titleBarStyle = objc_getAssociatedObject(window, kTrafficLightTitleBarStyleKey);
    return [titleBarStyle isEqualToString:@"hiddenInset"];
}

static void applyTrafficLightOffset(NSWindow *window) {
    if (!shouldManageTrafficLights(window)) {
        return;
    }

    NSNumber *offsetXValue = objc_getAssociatedObject(window, kTrafficLightOffsetXKey);
    NSNumber *offsetYValue = objc_getAssociatedObject(window, kTrafficLightOffsetYKey);
    const double offsetX = offsetXValue ? offsetXValue.doubleValue : 0;
    const double offsetY = offsetYValue ? offsetYValue.doubleValue : 0;

    if (offsetX == 0 && offsetY == 0) {
        return;
    }

    NSNumber *appliedOffsetXValue = objc_getAssociatedObject(window, kTrafficLightAppliedOffsetXKey);
    NSNumber *appliedOffsetYValue = objc_getAssociatedObject(window, kTrafficLightAppliedOffsetYKey);
    const double appliedOffsetX = appliedOffsetXValue ? appliedOffsetXValue.doubleValue : 0;
    const double appliedOffsetY = appliedOffsetYValue ? appliedOffsetYValue.doubleValue : 0;

    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    NSButton *minimizeButton = [window standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomButton = [window standardWindowButton:NSWindowZoomButton];

    for (NSButton *button in @[closeButton, minimizeButton, zoomButton]) {
        if (button == nil) {
            continue;
        }

        NSPoint origin = button.frame.origin;
        NSView *superview = button.superview;
        origin.x = origin.x - appliedOffsetX + offsetX;
        origin.y = origin.y + appliedOffsetY - offsetY;

        if (superview != nil) {
            CGFloat maxX = NSWidth(superview.bounds) - NSWidth(button.frame);
            CGFloat maxY = NSHeight(superview.bounds) - NSHeight(button.frame);
            origin.x = MAX(0, MIN(origin.x, maxX));
            origin.y = MAX(0, MIN(origin.y, maxY));
        }

        [button setFrameOrigin:origin];
    }

    objc_setAssociatedObject(window, kTrafficLightAppliedOffsetXKey, @(offsetX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kTrafficLightAppliedOffsetYKey, @(offsetY), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void applyTrafficLightOffsetFromDefault(NSWindow *window) {
    objc_setAssociatedObject(window, kTrafficLightAppliedOffsetXKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kTrafficLightAppliedOffsetYKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    applyTrafficLightOffset(window);
}

static void applyWindowButtonPosition(NSWindow *window, double x, double y) {
    NSButton *closeBtn = [window standardWindowButton:NSWindowCloseButton];
    NSButton *minimizeBtn = [window standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomBtn = [window standardWindowButton:NSWindowZoomButton];

    if (!closeBtn || !minimizeBtn || !zoomBtn) return;

    NSView *titlebarView = [closeBtn superview];
    if (!titlebarView) return;

    NSView *titlebarContainerView = [titlebarView superview];
    if (!titlebarContainerView) return;

    CGFloat buttonSpacing = 20.0;
    CGFloat buttonHeight = closeBtn.frame.size.height;
    CGFloat requiredHeight = y + buttonHeight;

    NSRect containerFrame = titlebarContainerView.frame;
    containerFrame.size.height = requiredHeight;
    containerFrame.origin.y = NSHeight(window.frame) - requiredHeight;
    [titlebarContainerView setFrame:containerFrame];

    NSRect titlebarFrame = titlebarView.frame;
    titlebarFrame.size.height = requiredHeight;
    titlebarFrame.origin.y = 0;
    [titlebarView setFrame:titlebarFrame];

    CGFloat adjustedY = requiredHeight - y - buttonHeight;
    [closeBtn setFrameOrigin:NSMakePoint(x, adjustedY)];
    [minimizeBtn setFrameOrigin:NSMakePoint(x + buttonSpacing, adjustedY)];
    [zoomBtn setFrameOrigin:NSMakePoint(x + 2 * buttonSpacing, adjustedY)];
}

// Window, tray, menu, and snapshot callbacks are defined in shared/callbacks.h
// Platform-specific aliases
typedef SnapshotCallback zigSnapshotCallback;
typedef StatusItemHandler ZigStatusItemHandler;
static URLOpenHandler g_urlOpenHandler = nullptr;
// Buffer for URLs received before the handler is registered (cold-launch race).
// The NSApp delegate fires on the main thread as soon as the event loop starts,
// but the Bun Worker thread may not have registered its handler yet.
// NOTE: This buffering fixes a pre-existing race in URL handling (not just file handling).
static std::vector<std::string> g_pendingUrlOpenPaths;
static std::mutex g_urlOpenMutex;
static AppReopenHandler g_appReopenHandler = nullptr;
static QuitRequestedHandler g_quitRequestedHandler = nullptr;
static std::atomic<bool> g_shutdownComplete{false};
static std::atomic<bool> g_eventLoopStopping{false};

typedef struct {
} MenuItemConfig;

// Permission cache types and functions are defined in shared/permissions.h

/*
 * =============================================================================
 * 3. UTILITY FUNCTIONS
 * =============================================================================
 */


bool isCEFAvailable() {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *frameworkPath = [mainBundle.privateFrameworksPath 
                              stringByAppendingPathComponent:@"Chromium Embedded Framework.framework/Chromium Embedded Framework"];
    return [[NSFileManager defaultManager] fileExistsAtPath:frameworkPath];
}

extern "C" uint32_t getWindowStyle(
    bool Borderless,
    bool Titled,
    bool Closable,
    bool Miniaturizable,
    bool Resizable,
    bool UnifiedTitleAndToolbar,
    bool FullScreen,
    bool FullSizeContentView,
    bool UtilityWindow,
    bool DocModalWindow,
    bool NonactivatingPanel,
    bool HUDWindow
) {
    uint32_t mask = 0;
    if (Borderless) mask |= NSWindowStyleMaskBorderless;
    if (Titled) mask |= NSWindowStyleMaskTitled;
    if (Closable) mask |= NSWindowStyleMaskClosable;
    if (Miniaturizable) mask |= NSWindowStyleMaskMiniaturizable;
    if (Resizable) mask |= NSWindowStyleMaskResizable;
    if (UnifiedTitleAndToolbar) mask |= NSWindowStyleMaskUnifiedTitleAndToolbar;
    if (FullScreen) mask |= NSWindowStyleMaskFullScreen;
    if (FullSizeContentView) mask |= NSWindowStyleMaskFullSizeContentView;
    if (UtilityWindow) mask |= NSWindowStyleMaskUtilityWindow;
    if (DocModalWindow) mask |= NSWindowStyleMaskDocModalWindow;
    if (NonactivatingPanel) mask |= NSWindowStyleMaskNonactivatingPanel;
    if (HUDWindow) mask |= NSWindowStyleMaskHUDWindow;
    return mask;
}

std::string GetScriptExecutionUrl(const std::string& frameUrl) {
    // List of URL schemes that should use about:blank for script execution
    static const std::vector<std::string> specialSchemes = {
        "data:",
        "blob:",
        "file:"
        // Add other schemes as needed
    };
    
    for (const auto& scheme : specialSchemes) {
        if (frameUrl.substr(0, scheme.length()) == scheme) {
            return "data://___preload.js";
        }
    }
    
    return frameUrl;
}

static bool isTrustedAppShellURL(NSString *urlString) {
    if (!urlString || [urlString length] == 0) {
        return false;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    NSString *scheme = [[components scheme] lowercaseString];
    if ([scheme isEqualToString:@"views"]) {
        return true;
    }

    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return false;
    }

    NSString *host = [[components host] lowercaseString];
    NSNumber *port = [components port];
    BOOL isLocalDevHost =
        [host isEqualToString:@"localhost"] ||
        [host isEqualToString:@"127.0.0.1"] ||
        [host isEqualToString:@"::1"];
    if (!isLocalDevHost || !port || [port intValue] != 5173) {
        return false;
    }

    for (NSURLQueryItem *item in [components queryItems]) {
        if ([[item name] isEqualToString:@"cachyWindow"] && [[item value] isEqualToString:@"launcher"]) {
            return true;
        }
    }

    return false;
}

static bool isTrustedAppShellURL(const std::string& urlString) {
    if (urlString.empty()) {
        return false;
    }
    NSString *nsUrlString = [NSString stringWithUTF8String:urlString.c_str()];
    return isTrustedAppShellURL(nsUrlString);
}

NSUUID *UUIDFromString(NSString *string) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(string.UTF8String, (CC_LONG)string.length, hash);
    uuid_t uuid;
    memcpy(uuid, hash, sizeof(uuid));
    return [[NSUUID alloc] initWithUUIDBytes:uuid];
}

static NSMutableDictionary<NSUUID*, WKWebsiteDataStore*> *dataStoreCache = nil;

WKWebsiteDataStore* createDataStoreForPartition(const char* partitionIdentifier) {
    NSString *identifier = [NSString stringWithUTF8String:partitionIdentifier];
    if ([identifier hasPrefix:@"persist:"]) {
        identifier = [identifier substringFromIndex:8];
        NSUUID *uuid = UUIDFromString(identifier);
        if (uuid) {
            if (@available(macOS 14.0, *)) {
                if (!dataStoreCache) dataStoreCache = [NSMutableDictionary dictionary];
                WKWebsiteDataStore *store = dataStoreCache[uuid];
                if (!store) {
                    store = [WKWebsiteDataStore dataStoreForIdentifier:uuid];
                    dataStoreCache[uuid] = store;
                }
                return store;
            } else {
                NSLog(@"[Session] Partition-specific data stores require macOS 14.0+, using default store");
                return [WKWebsiteDataStore defaultDataStore];
            }
        } else {
            NSLog(@"Invalid UUID for identifier: %@", identifier);
            return [WKWebsiteDataStore defaultDataStore];
        }
    } else {
        return [WKWebsiteDataStore nonPersistentDataStore];
    }
}

static NSString* normalizeViewsRelativePath(NSString *urlString) {
    if (!urlString || ![urlString hasPrefix:@"views://"]) {
        return nil;
    }

    NSString *relativePath = [urlString substringFromIndex:8];
    while ([relativePath hasPrefix:@"/"]) {
        relativePath = [relativePath substringFromIndex:1];
    }
    NSUInteger trimIndex = [relativePath length];
    NSRange queryRange = [relativePath rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        trimIndex = MIN(trimIndex, queryRange.location);
    }
    NSRange fragmentRange = [relativePath rangeOfString:@"#"];
    if (fragmentRange.location != NSNotFound) {
        trimIndex = MIN(trimIndex, fragmentRange.location);
    }
    relativePath = [relativePath substringToIndex:trimIndex];
    // Strip trailing slashes - WebView may normalize URLs without folder components
    while ([relativePath hasSuffix:@"/"] && [relativePath length] > 0) {
        relativePath = [relativePath substringToIndex:[relativePath length] - 1];
    }

    return relativePath;
}

NSData* readViewsFile(const char* viewsUrl) {
    if (!viewsUrl) return nil;

    NSString *urlString = [NSString stringWithUTF8String:viewsUrl];
    NSString *relativePath = normalizeViewsRelativePath(urlString);
    if (!relativePath) {
        return nil;
    }

    // Get the current working directory and Resources path
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString *resourcesDir = [cwd stringByAppendingPathComponent:@"../Resources"];
    NSString *asarPath = [resourcesDir stringByAppendingPathComponent:@"app.asar"];

    // Check if ASAR archive exists
    if ([[NSFileManager defaultManager] fileExistsAtPath:asarPath]) {
        // Thread-safe lazy-load ASAR archive on first use
        std::call_once(g_asarArchiveInitFlag, [asarPath]() {
            const char* asarPathCStr = [asarPath UTF8String];
            g_asarArchive = asar_open(asarPathCStr);
            if (!g_asarArchive) {
                NSLog(@"ERROR readViewsFile: Failed to open ASAR archive at %@", asarPath);
            }
        });

        // If ASAR archive is loaded, try to read from it
        if (g_asarArchive) {
            // The ASAR contains the entire app directory, so prepend "views/" to the relativePath
            NSString *asarFilePath = [NSString stringWithFormat:@"views/%@", relativePath];
            const char* asarFilePathCStr = [asarFilePath UTF8String];

            size_t fileSize = 0;
            const uint8_t* fileData = asar_read_file(g_asarArchive, asarFilePathCStr, &fileSize);

            if (fileData && fileSize > 0) {
                // Create NSData that copies the buffer (we'll free it after)
                NSData *data = [NSData dataWithBytes:fileData length:fileSize];
                // Free the ASAR buffer
                asar_free_buffer(fileData, fileSize);
                return data;
            }
        }
    }

    // Fallback: Read from flat file system (for non-ASAR builds or missing files)
    NSString *viewsDir = [resourcesDir stringByAppendingPathComponent:@"app/views"];
    NSString *filePath = [viewsDir stringByAppendingPathComponent:relativePath];

    // Read the file
    return [NSData dataWithContentsOfFile:filePath];
}

NSData* readViewsFileWithRoot(const char* viewsUrl, NSString *viewsRoot) {
    if (!viewsRoot || viewsRoot.length == 0) {
        return readViewsFile(viewsUrl);
    }

    if (!viewsUrl) return nil;

    NSString *urlString = [NSString stringWithUTF8String:viewsUrl];
    NSString *relativePath = normalizeViewsRelativePath(urlString);
    if (!relativePath) {
        return nil;
    }

    NSString *normalizedRoot = [viewsRoot stringByStandardizingPath];
    NSString *candidatePath =
        [[viewsRoot stringByAppendingPathComponent:relativePath] stringByStandardizingPath];

    if (![candidatePath isEqualToString:normalizedRoot] &&
        ![candidatePath hasPrefix:[normalizedRoot stringByAppendingString:@"/"]]) {
        NSLog(@"ERROR readViewsFileWithRoot: path escapes root %@ -> %@", normalizedRoot, candidatePath);
        return nil;
    }

    return [NSData dataWithContentsOfFile:candidatePath];
}


// Convenience functions for manual memory management
void retainObjCObject(id objcObject) {
    CFRetain((__bridge CFTypeRef)objcObject);
}
void releaseObjCObject(id objcObject) {
    CFRelease((__bridge CFTypeRef)objcObject);
}

/*
 * =============================================================================
 * 4. OBJECTIVE-C @INTERFACES
 * =============================================================================
 */

// ----------------------- Abstract Base Classes -----------------------

@interface AbstractView : NSObject
    @property (nonatomic, assign) uint32_t webviewId;
    @property (nonatomic, assign) NSView * nsView;
    @property (nonatomic, assign) BOOL isMousePassthroughEnabled;
    @property (nonatomic, assign) BOOL mirrorModeEnabled;
    @property (nonatomic, assign) BOOL fullSize;
    @property (nonatomic, assign) BOOL isRemoved;
    @property (nonatomic, assign) BOOL isInFullscreen;
    @property (nonatomic, assign) BOOL isSandboxed;  // When true, only eventBridge is active (no RPC)
    @property (nonatomic, assign) BOOL pendingStartTransparent;
    @property (nonatomic, assign) BOOL pendingStartPassthrough;
    @property (nonatomic, strong) CALayer *storedLayerMask;
    @property (nonatomic, strong) NSArray<NSString *> *navigationRules;
    @property (atomic, assign) uint32_t resizeGeneration;
    @property (nonatomic, assign) BOOL contentBlockerEnabled;

    - (void)loadURL:(const char *)urlString;
    - (void)loadHTML:(const char *)htmlString;
    - (void)goBack;
    - (void)goForward;
    - (void)reload;
    - (void)remove;

    - (void)setTransparent:(BOOL)transparent;
    - (void)setPassthrough:(BOOL)enable;
    - (void)setHidden:(BOOL)hidden;

    - (BOOL)canGoBack;
    - (BOOL)canGoForward;

    - (void)evaluateJavaScriptWithNoCompletion:(const char*)jsString;
    - (const char*)evaluateJavaScriptSync:(const char*)jsString;
    - (void)callAsyncJavascript:(const char*)messageId 
                       jsString:(const char*)jsString 
                      webviewId:(uint32_t)webviewId 
                  hostWebviewId:(uint32_t)hostWebviewId 
              completionHandler:(callAsyncJavascriptCompletionHandler)completionHandler;
    - (void)addPreloadScriptToWebView:(const char*)jsString;
    - (void)updateCustomPreloadScript:(const char*)jsString;

    - (void)resize:(NSRect)frame withMasksJSON:(const char *)masksJson;
    - (void)resizeWithFrame:(NSRect)frame parsedMasks:(NSArray *)parsedMasks;

    - (void)setNavigationRulesFromJSON:(const char*)rulesJson;
    - (BOOL)shouldAllowNavigationToURL:(NSString *)url;

    - (void)findInPage:(const char*)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase;
    - (void)stopFindInPage;

    // Developer tools methods
    - (void)openDevTools;
    - (void)closeDevTools;
    - (void)toggleDevTools;
@end

@interface AbstractView () {
@public
    std::mutex pendingResizeMutex;
    std::atomic<uint64_t> pendingResizeGeneration;
    uint64_t appliedResizeGeneration;
    BOOL hasPendingResize;
    NSRect pendingResizeFrame;
    NSArray *pendingResizeMasks;
}
- (void)storePendingResize:(NSRect)frame parsedMasks:(NSArray *)parsedMasks;
- (void)applyPendingResizeIfNeeded;
@end

// Global map to track all AbstractView instances by their webviewId
static NSMutableDictionary<NSNumber *, AbstractView *> *globalAbstractViews = nil;

// OSR (Off-Screen Rendering) View for transparent CEF windows
@interface CEFOSRView : NSView {
    @private
    NSLock *_bufferLock;
    void *_pixelBuffer;
    void *_renderBuffer;  // Double buffer for thread safety
    size_t _pixelBufferSize;
    int _bufferWidth;
    int _bufferHeight;
    BOOL _hasNewFrame;
}
@property (nonatomic, assign) void* cefBrowser;  // CefRefPtr<CefBrowser> stored as void*
@property (nonatomic, strong) NSTrackingArea *trackingArea;

- (void)updateBuffer:(const void*)buffer width:(int)width height:(int)height;
- (void)setCefBrowser:(void*)browser;
@end

@interface ContainerView : NSView
    /// An reverse ordered array of abstractViews (newest first)
    @property (nonatomic, strong) NSMutableArray<AbstractView *> *abstractViews;
    - (void)addAbstractView:(AbstractView *)webview;
    - (void)removeAbstractViewWithId:(uint32_t)webviewId;
    - (void)updateActiveWebviewForMousePosition:(NSPoint)mouseLocation;
@end

// ----------------------- Find Bar -----------------------

@interface FindBarView : NSView <NSSearchFieldDelegate>
    @property (nonatomic, strong) NSSearchField *searchField;
    @property (nonatomic, strong) NSButton *prevButton;
    @property (nonatomic, strong) NSButton *nextButton;
    @property (nonatomic, strong) NSButton *closeButton;
    @property (nonatomic, weak) NSWindow *parentWindow;
    - (void)showInWindow:(NSWindow *)window;
    - (void)dismiss;
    - (void)findNext;
    - (void)findPrevious;
@end

// ----------------------- URL Scheme & Navigation -----------------------

@interface MyURLSchemeHandler : NSObject <WKURLSchemeHandler>    
    @property (nonatomic, assign) uint32_t webviewId;
    @property (nonatomic, copy) NSString *viewsRoot;
@end

@interface MyNavigationDelegate : NSObject <WKNavigationDelegate, WKDownloadDelegate>
    @property (nonatomic, assign) DecideNavigationCallback zigCallback;
    @property (nonatomic, assign) WebviewEventHandler zigEventHandler;
    @property (nonatomic, assign) uint32_t webviewId;
    @property (nonatomic, strong) NSMutableDictionary<NSValue *, NSString *> *downloadPaths;
    @property (nonatomic, strong) NSMutableSet<WKDownload *> *observedDownloads;
    - (void)detectAndApplyThemeColor:(WKWebView *)webView;
@end

@interface MyWebViewUIDelegate : NSObject <WKUIDelegate>
    @property (nonatomic, assign) WebviewEventHandler zigEventHandler;
    @property (nonatomic, assign) uint32_t webviewId;
@end

@interface MyScriptMessageHandler : NSObject <WKScriptMessageHandler>
    @property (nonatomic, assign) HandlePostMessage zigCallback;
    @property (nonatomic, assign) uint32_t webviewId;
@end

@interface MyScriptMessageHandlerWithReply : NSObject <WKScriptMessageHandlerWithReply>
    @property (nonatomic, assign) HandlePostMessageWithReply zigCallback;
    @property (nonatomic, assign) uint32_t webviewId;
@end

// ----------------------- Webview Implementations -----------------------
@interface WKWebViewImpl : AbstractView
    @property (nonatomic, strong) WKWebView *webView;
    @property (nonatomic, assign) WebviewEventHandler zigEventHandler;

    - (instancetype)initWithWebviewId:(uint32_t)webviewId
                            window:(NSWindow *)window
                            url:(const char *)url
                                frame:(NSRect)frame
                        autoResize:(bool)autoResize
                partitionIdentifier:(const char *)partitionIdentifier
                navigationCallback:(DecideNavigationCallback)navigationCallback
                webviewEventHandler:(WebviewEventHandler)webviewEventHandler
                eventBridgeHandler:(HandlePostMessage)eventBridgeHandler
                bunBridgeHandler:(HandlePostMessage)bunBridgeHandler
                internalBridgeHandler:(HandlePostMessage)internalBridgeHandler
                electrobunPreloadScript:(const char *)electrobunPreloadScript
                customPreloadScript:(const char *)customPreloadScript
                viewsRoot:(const char *)viewsRoot
                transparent:(bool)transparent
                sandbox:(bool)sandbox;
@end

@interface WGPUViewImpl : AbstractView
    - (instancetype)initWithWebviewId:(uint32_t)webviewId
                            window:(NSWindow *)window
                            frame:(NSRect)frame
                        autoResize:(bool)autoResize;
@end



// ----------------------- Application & Window Delegates -----------------------

@interface ElectrobunNSApplication : NSApplication <CefAppProtocol> {
    @private
    BOOL handlingSendEvent_;
    }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@interface WindowDelegate : NSObject <NSWindowDelegate>
    @property (nonatomic, assign) WindowCloseHandler closeHandler;
    @property (nonatomic, assign) WindowMoveHandler moveHandler;
    @property (nonatomic, assign) WindowResizeHandler resizeHandler;
    @property (nonatomic, assign) WindowFocusHandler focusHandler;
    @property (nonatomic, assign) WindowBlurHandler blurHandler;
    @property (nonatomic, assign) WindowKeyHandler keyHandler;
    @property (nonatomic, assign) uint32_t windowId;
    @property (nonatomic, strong) NSWindow *window;
    @property (nonatomic, assign) BOOL hasCustomButtonPosition;
    @property (nonatomic, assign) double buttonPositionX;
    @property (nonatomic, assign) double buttonPositionY;
@end

// ----------------------- Navigation Toolbar -----------------------

static NSToolbarItemIdentifier const NavigationBackItemIdentifier = @"NavigationBackItem";
static NSToolbarItemIdentifier const NavigationForwardItemIdentifier = @"NavigationForwardItem";

@interface NavigationToolbarDelegate : NSObject <NSToolbarDelegate, NSToolbarItemValidation>
@end

@interface StatusItemTarget : NSObject
    @property (nonatomic, assign) NSStatusItem *statusItem;
    @property (nonatomic, assign) ZigStatusItemHandler zigHandler;
    @property (nonatomic, assign) uint32_t trayId;
    - (void)statusItemClicked:(id)sender;
    - (void)menuItemClicked:(id)sender;
@end

// Convert a key name string to an NSMenuItem key equivalent string.
// For single characters this is just the character itself. For special keys
// (arrows, function keys, etc.) it returns the appropriate Unicode character
// that NSMenuItem expects.
static NSString *keyEquivalentFromString(NSString *key) {
    if ([key length] == 1) {
        return key;
    }

    static NSDictionary *specialKeys = nil;
    if (!specialKeys) {
        specialKeys = @{
            @"return":   @"\r",
            @"enter":    @"\r",
            @"tab":      @"\t",
            @"escape":   [NSString stringWithFormat:@"%C", (unichar)0x1B],
            @"esc":      [NSString stringWithFormat:@"%C", (unichar)0x1B],
            @"space":    @" ",
            @"backspace": [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter],
            @"delete":   [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter],
            @"up":       [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey],
            @"down":     [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey],
            @"left":     [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey],
            @"right":    [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey],
            @"home":     [NSString stringWithFormat:@"%C", (unichar)NSHomeFunctionKey],
            @"end":      [NSString stringWithFormat:@"%C", (unichar)NSEndFunctionKey],
            @"pageup":   [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey],
            @"pagedown": [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey],
            @"f1":  [NSString stringWithFormat:@"%C", (unichar)NSF1FunctionKey],
            @"f2":  [NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey],
            @"f3":  [NSString stringWithFormat:@"%C", (unichar)NSF3FunctionKey],
            @"f4":  [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey],
            @"f5":  [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey],
            @"f6":  [NSString stringWithFormat:@"%C", (unichar)NSF6FunctionKey],
            @"f7":  [NSString stringWithFormat:@"%C", (unichar)NSF7FunctionKey],
            @"f8":  [NSString stringWithFormat:@"%C", (unichar)NSF8FunctionKey],
            @"f9":  [NSString stringWithFormat:@"%C", (unichar)NSF9FunctionKey],
            @"f10": [NSString stringWithFormat:@"%C", (unichar)NSF10FunctionKey],
            @"f11": [NSString stringWithFormat:@"%C", (unichar)NSF11FunctionKey],
            @"f12": [NSString stringWithFormat:@"%C", (unichar)NSF12FunctionKey],
            @"f13": [NSString stringWithFormat:@"%C", (unichar)NSF13FunctionKey],
            @"f14": [NSString stringWithFormat:@"%C", (unichar)NSF14FunctionKey],
            @"f15": [NSString stringWithFormat:@"%C", (unichar)NSF15FunctionKey],
            @"f16": [NSString stringWithFormat:@"%C", (unichar)NSF16FunctionKey],
            @"f17": [NSString stringWithFormat:@"%C", (unichar)NSF17FunctionKey],
            @"f18": [NSString stringWithFormat:@"%C", (unichar)NSF18FunctionKey],
            @"f19": [NSString stringWithFormat:@"%C", (unichar)NSF19FunctionKey],
            @"f20": [NSString stringWithFormat:@"%C", (unichar)NSF20FunctionKey],
            @"plus": @"+",
            @"minus": @"-",
        };
    }

    NSString *equivalent = specialKeys[key];
    return equivalent ?: key;
}

// Convert shared AcceleratorParts to macOS NSEventModifierFlags.
// On macOS, CommandOrControl and Command both map to the Command key.
static NSEventModifierFlags modifierFlagsFromAccelerator(const electrobun::AcceleratorParts& parts) {
    NSEventModifierFlags flags = 0;
    if (parts.commandOrControl || parts.command) flags |= NSEventModifierFlagCommand;
    if (parts.control)                           flags |= NSEventModifierFlagControl;
    if (parts.alt)                               flags |= NSEventModifierFlagOption;
    if (parts.shift)                             flags |= NSEventModifierFlagShift;
    return flags;
}

// Parse an Electron-style accelerator string into an NSMenuItem key equivalent
// and modifier mask. When the accelerator is a bare key with no modifiers
// (e.g. "s"), Command is used as the default modifier to match macOS conventions.
static void parseMenuAccelerator(NSString *accelerator,
                                 NSString **outKeyEquivalent,
                                 NSEventModifierFlags *outModifiers) {
    auto parts = electrobun::parseAccelerator([accelerator UTF8String]);

    *outModifiers = modifierFlagsFromAccelerator(parts);

    // Bare key like "s" with no modifier prefix — default to Command
    if (parts.isBareKey) {
        *outModifiers = NSEventModifierFlagCommand;
    }

    *outKeyEquivalent = keyEquivalentFromString(
        [NSString stringWithUTF8String:parts.key.c_str()]);
}

NSMenu *createMenuFromConfig(NSArray *menuConfig, StatusItemTarget *target) {
    NSMenu *menu = [[NSMenu alloc] init];
    [menu setAutoenablesItems:NO];

    for (NSDictionary *itemData in menuConfig) {
        NSString *type = itemData[@"type"];
        NSString *label = itemData[@"label"];
        NSString *action = itemData[@"action"];
        NSArray *submenuConfig = itemData[@"submenu"];
        NSString *role = itemData[@"role"];
        NSString *accelerator = itemData[@"accelerator"];
        NSNumber *modifierMask = itemData[@"modifierMask"];

        BOOL enabled = [itemData[@"enabled"] boolValue];
        BOOL checked = [itemData[@"checked"] boolValue];
        BOOL hidden = [itemData[@"hidden"] boolValue];
        NSString *tooltip = itemData[@"tooltip"];

        NSMenuItem *menuItem;
        if ([type isEqualToString:@"divider"]) {
            menuItem = [NSMenuItem separatorItem];
        } else {
            menuItem = [[NSMenuItem alloc] initWithTitle:label ?: @""
                                                  action:@selector(menuItemClicked:)
                                           keyEquivalent:@""];
            menuItem.representedObject = action;
            if (role) {
                // Look up the selector from the role map
                NSDictionary<NSString*, NSString*>* roleMap = getMenuRoleToSelectorMap();
                NSString *selectorName = roleMap[role];
                if (selectorName) {
                    menuItem.action = NSSelectorFromString(selectorName);
                }
                if (!accelerator) {
                    if ([role isEqualToString:@"undo"]) {
                        menuItem.keyEquivalent = @"z";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
                    } else if ([role isEqualToString:@"redo"]) {
                        menuItem.keyEquivalent = @"Z";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
                    } else if ([role isEqualToString:@"cut"]) {
                        menuItem.keyEquivalent = @"x";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
                    } else if ([role isEqualToString:@"copy"]) {
                        menuItem.keyEquivalent = @"c";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
                    } else if ([role isEqualToString:@"paste"]) {
                        menuItem.keyEquivalent = @"v";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
                    } else if ([role isEqualToString:@"pasteAndMatchStyle"]) {
                        menuItem.keyEquivalent = @"V";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
                    } else if ([role isEqualToString:@"delete"]) {
                        menuItem.keyEquivalent = [NSString stringWithFormat:@"%c",(char)NSDeleteCharacter];
                        menuItem.keyEquivalentModifierMask = 0;
                    } else if ([role isEqualToString:@"selectAll"]) {
                        menuItem.keyEquivalent = @"a";
                        menuItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
                    }
                }
            } else {
                menuItem.target = target;
            }
            if (accelerator) {
                if (modifierMask) {
                    // Explicit modifierMask from JSON takes precedence
                    menuItem.keyEquivalent = [accelerator lowercaseString];
                    menuItem.keyEquivalentModifierMask = [modifierMask unsignedIntegerValue];
                } else {
                    // Parse Electron-style accelerator (e.g. "CommandOrControl+T")
                    NSString *keyEq = nil;
                    NSEventModifierFlags modFlags = 0;
                    parseMenuAccelerator(accelerator, &keyEq, &modFlags);
                    menuItem.keyEquivalent = keyEq;
                    menuItem.keyEquivalentModifierMask = modFlags;
                }
            }
            menuItem.enabled = enabled;
            menuItem.state = checked ? NSControlStateValueOn : NSControlStateValueOff;
            menuItem.hidden = hidden;
            menuItem.toolTip = tooltip;
            if (submenuConfig) {
                NSMenu *submenu = createMenuFromConfig(submenuConfig, target);
                [menu setSubmenu:submenu forItem:menuItem];
            }
        }
        [menu addItem:menuItem];
    }
    return menu;
}

/*
 * =============================================================================
 * 5. OBJECTIVE-C @IMPLEMENTATIONS
 * =============================================================================
 */

// ----------------------- AbstractView & ContainerView -----------------------
// Todo: incorporate into AbstractView
NSArray<NSValue *> *addOverlapRects(NSArray<NSDictionary *> *rectsArray, CGFloat containerHeight) {
    NSMutableArray<NSValue *> *resultingRects = [NSMutableArray array];
    for (NSDictionary *rectDict in rectsArray) {
        CGFloat x = [rectDict[@"x"] floatValue];
        CGFloat y = [rectDict[@"y"] floatValue];
        CGFloat w = [rectDict[@"width"] floatValue];
        CGFloat h = [rectDict[@"height"] floatValue];
                
        // Note: CEF does not flip the view geometry so the measured y from the dom (origin top)
        // needs to be inverted to work with MacOs default (y origin bottom) 
        if (containerHeight > 0) {
            y = containerHeight - h - y;
        }

        NSRect newRect = NSMakeRect(x, y, w, h);

        NSMutableArray<NSValue *> *overlapRects = [NSMutableArray array];
        for (NSValue *existingRectValue in resultingRects) {
            NSRect existingRect = [existingRectValue rectValue];
            if (NSIntersectsRect(existingRect, newRect)) {
                NSRect overlapRect = NSIntersectionRect(existingRect, newRect);
                if (!NSIsEmptyRect(overlapRect)) {
                    [overlapRects addObject:[NSValue valueWithRect:overlapRect]];
                }
            }
        }
        [resultingRects addObject:[NSValue valueWithRect:newRect]];
        [resultingRects addObjectsFromArray:overlapRects];
    }
    return resultingRects;
}

@implementation AbstractView

    - (instancetype)init {
        self = [super init];
        if (self) {
            self.isRemoved = NO;
            pendingResizeGeneration = 0;
            appliedResizeGeneration = 0;
            hasPendingResize = NO;
            pendingResizeFrame = NSZeroRect;
            pendingResizeMasks = nil;
        }
        return self;
    }

    - (void)loadURL:(const char *)urlString { [self doesNotRecognizeSelector:_cmd]; }
    - (void)loadHTML:(const char *)htmlString { [self doesNotRecognizeSelector:_cmd]; }
    - (void)goBack { [self doesNotRecognizeSelector:_cmd]; }
    - (void)goForward { [self doesNotRecognizeSelector:_cmd]; }
    - (void)reload { [self doesNotRecognizeSelector:_cmd]; }
    - (void)remove { [self doesNotRecognizeSelector:_cmd]; }


    - (BOOL)canGoBack { [self doesNotRecognizeSelector:_cmd]; return NO; }
    - (BOOL)canGoForward { [self doesNotRecognizeSelector:_cmd]; return NO; }

    - (void)evaluateJavaScriptWithNoCompletion:(const char*)jsString { [self doesNotRecognizeSelector:_cmd]; }
    - (const char*)evaluateJavaScriptSync:(const char*)jsString { return NULL; }
    - (void)callAsyncJavascript:(const char*)messageId jsString:(const char*)jsString webviewId:(uint32_t)webviewId hostWebviewId:(uint32_t)hostWebviewId completionHandler:(callAsyncJavascriptCompletionHandler)completionHandler { [self doesNotRecognizeSelector:_cmd]; }
    // todo: we don't need this to be public since it's only used to set the internal electrobun preview script
    - (void)addPreloadScriptToWebView:(const char*)jsString { [self doesNotRecognizeSelector:_cmd]; }
    - (void)updateCustomPreloadScript:(const char*)jsString { [self doesNotRecognizeSelector:_cmd]; }

    // todo: rename to toggleOffscreen / isOffscreen
    // then create isInteractive that returns !isOffscreen && isPassthrough


    - (void)setHidden:(BOOL)hidden {
        [self.nsView setHidden:hidden];
    }

    - (void)setPassthrough:(BOOL)enable {    
        self.isMousePassthroughEnabled = enable;
        // Re-evaluate active view immediately so passthrough takes effect without mouse movement
        if (self.nsView && self.nsView.window && [self.nsView.superview isKindOfClass:[ContainerView class]]) {
            ContainerView *containerView = (ContainerView *)self.nsView.superview;
            NSPoint currentMousePosition = [self.nsView.window mouseLocationOutsideOfEventStream];
            [containerView updateActiveWebviewForMousePosition:currentMousePosition];
        }
    }

    - (void)setTransparent:(BOOL)transparent {
        if (self.nsView) {
            [self.nsView setWantsLayer:YES];
            self.nsView.layer.opacity = transparent ? 0 : 1;
        }
    }


    - (void)toggleMirrorMode:(BOOL)enable {
        NSView *subview = self.nsView;

        if (self.mirrorModeEnabled == enable) {
            return;
        }
        BOOL isLeftMouseButtonDown = ([NSEvent pressedMouseButtons] & (1 << 0)) != 0;
        if (isLeftMouseButtonDown) {
            return;
        }
        self.mirrorModeEnabled = enable;

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        if (enable) {
            CGFloat positionX = subview.frame.origin.x;
            CGFloat positionY = subview.frame.origin.y;
            subview.frame = CGRectOffset(subview.frame, OFFSCREEN_OFFSET, OFFSCREEN_OFFSET);
            subview.layer.position = CGPointMake(positionX, positionY);
        } else {
            subview.frame = CGRectMake(subview.layer.position.x,
                                    subview.layer.position.y,
                                    subview.frame.size.width,
                                    subview.frame.size.height);
        }
        [CATransaction commit];
    }


    // Internal callers (e.g. fullSize resize on window resize) use this entry point
    - (void)resize:(NSRect)frame withMasksJSON:(const char *)masksJson {
        NSArray *parsedMasks = nil;
        if (masksJson && strlen(masksJson) > 0) {
            NSString *jsonString = [NSString stringWithUTF8String:masksJson ?: ""];
            NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
            if (jsonData) {
                NSError *error = nil;
                parsedMasks = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
                if (error) parsedMasks = nil;
            }
        }
        [self resizeWithFrame:frame parsedMasks:parsedMasks];
    }

    // Optimized resize — accepts pre-parsed masks (JSON parsing done off main thread)
    - (void)resizeWithFrame:(NSRect)frame parsedMasks:(NSArray *)parsedMasks {
        NSView *subview = self.nsView;
        if (!subview) {
            return;
        }

        CGFloat adjustedX = floor(frame.origin.x);
        CGFloat adjustedWidth = ceilf(frame.size.width);
        CGFloat adjustedHeight = ceilf(frame.size.height);
        CGFloat adjustedY = floor(subview.superview.bounds.size.height - ceilf(frame.origin.y) - adjustedHeight);

        [CATransaction begin];
        [CATransaction setDisableActions:YES];

        if (self.mirrorModeEnabled) {
            subview.frame = NSMakeRect(OFFSCREEN_OFFSET, OFFSCREEN_OFFSET, adjustedWidth, adjustedHeight);
            subview.layer.position = CGPointMake(adjustedX, adjustedY);
        } else {
            subview.frame = NSMakeRect(adjustedX, adjustedY, adjustedWidth, adjustedHeight);
        }

        CAShapeLayer *maskLayer = nil;
        if (parsedMasks && parsedMasks.count > 0) {
            CGFloat heightToAdjust = self.nsView.layer.geometryFlipped ? 0 : adjustedHeight;
            NSArray<NSValue *> *processedRects = addOverlapRects(parsedMasks, heightToAdjust);

            maskLayer = [CAShapeLayer layer];
            maskLayer.frame = self.nsView.layer.bounds;
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddRect(path, NULL, maskLayer.bounds);
            for (NSValue *rectValue in processedRects) {
                NSRect rect = [rectValue rectValue];
                CGPathAddRect(path, NULL, rect);
            }
            maskLayer.fillRule = kCAFillRuleEvenOdd;
            maskLayer.path = path;
            CGPathRelease(path);
        }
        self.nsView.layer.mask = maskLayer;

        [CATransaction commit];

        if (self.nsView && [self.nsView.layer isKindOfClass:[CAMetalLayer class]]) {
            CAMetalLayer *layer = (CAMetalLayer *)self.nsView.layer;
            CGFloat scale = self.nsView.window.backingScaleFactor;
            layer.contentsScale = scale;
            CGSize size = self.nsView.bounds.size;
            layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
            if (wgpuDebugEnabled()) {
                NSLog(@"WGPUView resize: bounds=%.1fx%.1f scale=%.2f drawable=%.1fx%.1f",
                      size.width, size.height, scale, layer.drawableSize.width, layer.drawableSize.height);
            }
        }

        NSPoint currentMousePosition = [self.nsView.window mouseLocationOutsideOfEventStream];
        ContainerView *containerView = (ContainerView *)self.nsView.superview;
        [containerView updateActiveWebviewForMousePosition:currentMousePosition];
    }

    - (void)setNavigationRulesFromJSON:(const char*)rulesJson {
        if (!rulesJson || strlen(rulesJson) == 0) {
            self.navigationRules = @[];
            return;
        }

        NSString *jsonString = [NSString stringWithUTF8String:rulesJson];
        NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
        if (!jsonData) {
            self.navigationRules = @[];
            return;
        }

        NSError *error = nil;
        NSArray *rulesArray = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        if (error || ![rulesArray isKindOfClass:[NSArray class]]) {
            NSLog(@"Failed to parse navigation rules JSON: %@", error);
            self.navigationRules = @[];
            return;
        }

        self.navigationRules = rulesArray;
    }

    - (BOOL)shouldAllowNavigationToURL:(NSString *)url {
        if (!self.navigationRules || self.navigationRules.count == 0) {
            return YES; // Default allow if no rules
        }

        BOOL allowed = YES; // Default allow if no rules match
        std::string urlStr = [url UTF8String] ?: "";

        for (NSString *rule in self.navigationRules) {
            BOOL isBlockRule = [rule hasPrefix:@"^"];
            NSString *pattern = isBlockRule ? [rule substringFromIndex:1] : rule;
            std::string patternStr = [pattern UTF8String] ?: "";

            if (electrobun::globMatch(patternStr, urlStr)) {
                allowed = !isBlockRule; // Last match wins
            }
        }

        return allowed;
    }

    - (void)findInPage:(const char*)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase {
        [self doesNotRecognizeSelector:_cmd];
    }

    - (void)stopFindInPage {
        [self doesNotRecognizeSelector:_cmd];
    }

    - (void)openDevTools {
        [self doesNotRecognizeSelector:_cmd];
    }

    - (void)closeDevTools {
        [self doesNotRecognizeSelector:_cmd];
    }

    - (void)toggleDevTools {
        [self doesNotRecognizeSelector:_cmd];
    }

    - (void)storePendingResize:(NSRect)frame parsedMasks:(NSArray *)parsedMasks {
        std::lock_guard<std::mutex> lock(pendingResizeMutex);
        pendingResizeFrame = frame;
        pendingResizeMasks = parsedMasks;
        hasPendingResize = YES;
        pendingResizeGeneration++;
    }

    - (void)applyPendingResizeIfNeeded {
        NSRect frame = NSZeroRect;
        NSArray *masks = nil;
        uint64_t gen = 0;
        {
            std::lock_guard<std::mutex> lock(pendingResizeMutex);
            if (!hasPendingResize) {
                return;
            }
            gen = pendingResizeGeneration.load();
            if (gen == appliedResizeGeneration) {
                return;
            }
            frame = pendingResizeFrame;
            masks = pendingResizeMasks;
            appliedResizeGeneration = gen;
            hasPendingResize = NO;
        }
        [self resizeWithFrame:frame parsedMasks:masks];
    }
@end

// Pending resize queue (cross-thread)
static PendingResizeQueue g_pendingResizeQueue;
static std::atomic<bool> g_pendingResizeScheduled{false};
static CFRunLoopSourceRef g_pendingResizeSource = nullptr;

static void drainPendingResizes() {
    g_pendingResizeScheduled.store(false);
    auto items = g_pendingResizeQueue.drain();
    for (void* item : items) {
        AbstractView *view = (__bridge AbstractView *)item;
        if (!view || view.isRemoved) continue;
        [view applyPendingResizeIfNeeded];
    }
}

static void pendingResizeSourcePerform(void *info) {
    (void)info;
    drainPendingResizes();
}

static void ensurePendingResizeSource() {
    if (g_pendingResizeSource) return;
    CFRunLoopSourceContext ctx = {};
    ctx.perform = pendingResizeSourcePerform;
    g_pendingResizeSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_pendingResizeSource, kCFRunLoopCommonModes);
}

static void schedulePendingResizeDrain() {
    if (g_pendingResizeScheduled.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ensurePendingResizeSource();
        CFRunLoopSourceSignal(g_pendingResizeSource);
        CFRunLoopWakeUp(CFRunLoopGetMain());
    });
}


@implementation ContainerView
    - (instancetype)initWithFrame:(NSRect)frameRect {
        self = [super initWithFrame:frameRect];
        if (self) {
            self.abstractViews = [NSMutableArray array]; 
            [self updateTrackingAreas];
        }
        return self;
    }

    - (void)updateTrackingAreas {    
        for (NSTrackingArea *area in self.trackingAreas) {
            [self removeTrackingArea:area];
        }
        NSTrackingArea *mouseTrackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
            options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow
            owner:self
            userInfo:nil];
        [self addTrackingArea:mouseTrackingArea];
    }

    - (void)mouseMoved:(NSEvent *)event {    
        NSPoint mouseLocation = [self convertPoint:[event locationInWindow] fromView:nil];
        [self updateActiveWebviewForMousePosition:mouseLocation];
    }

    // This function tries to figure out which "abstractView" should be interactive
    // vs mirrored, based on mouse position and layering.
    - (void)updateActiveWebviewForMousePosition:(NSPoint)mouseLocation {    
        BOOL stillSearching = YES;    

        for (AbstractView * abstractView in self.abstractViews) {           

            if (abstractView.isMousePassthroughEnabled) {
                [abstractView toggleMirrorMode:YES];
                continue;
            }
            
            NSView *subview = abstractView.nsView;

            if (stillSearching) {
                NSRect subviewRenderLayerFrame = subview.layer.frame;
                if (NSPointInRect(mouseLocation, subviewRenderLayerFrame)){// && !subview.hidden) {
                    CAShapeLayer *maskLayer = (CAShapeLayer *)subview.layer.mask;
                    CGPathRef maskPath = maskLayer ? maskLayer.path : NULL;
                    if (maskPath) {                    
                        CGFloat mouseXInWebview = mouseLocation.x - subviewRenderLayerFrame.origin.x;
                        CGFloat mouseYInWebview = mouseLocation.y - subviewRenderLayerFrame.origin.y;
                        
                        // Note: WKWebkit uses geometryFlipped so the y coordinate is from the top not the bottom
                        // (the default on osx is from the bottom). The mouse y coordinate is from the bottom
                        // so we need to invert it to match the layer geometry
                        if (subview.layer.geometryFlipped) {                                                
                            mouseYInWebview = subviewRenderLayerFrame.size.height - (mouseLocation.y - subviewRenderLayerFrame.origin.y);                        
                        }

                        CGPoint mousePositionInMaskPath = CGPointMake(mouseXInWebview, mouseYInWebview);

                        if (!CGPathContainsPoint(maskPath, NULL, mousePositionInMaskPath, true)) {                        
                            [abstractView toggleMirrorMode:YES];                                                
                            continue;
                        }
                    }
                    
                    [abstractView toggleMirrorMode:NO];
                    stillSearching = NO;
                    continue;
                }
            }        
            [abstractView toggleMirrorMode:YES];
        }    
    }


    - (void)addAbstractView:(AbstractView *)abstractView {
        // Add to front of array so it's top-most first
        [self.abstractViews insertObject:abstractView atIndex:0];
    }

    - (void)removeAbstractViewWithId:(uint32_t)webviewId {
        for (NSInteger i = 0; i < self.abstractViews.count; i++) {
            AbstractView * candidate = self.abstractViews[i];
            if (candidate.webviewId == webviewId) {
                g_pendingResizeQueue.remove((__bridge void *)candidate);
                [self.abstractViews removeObjectAtIndex:i];
                break;
            }
        }
    }

    - (void)dealloc {
        for (AbstractView *view in self.abstractViews) {
            g_pendingResizeQueue.remove((__bridge void *)view);
        }
    }
@end

// ----------------------- Find Bar Implementation -----------------------

static NSString * const FindBarAssociatedKey = @"ElectrobunFindBar";

@implementation FindBarView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;

        NSVisualEffectView *bgView = [[NSVisualEffectView alloc] initWithFrame:self.bounds];
        bgView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        bgView.material = NSVisualEffectMaterialHeaderView;
        bgView.blendingMode = NSVisualEffectBlendingModeWithinWindow;
        bgView.state = NSVisualEffectStateActive;
        [self addSubview:bgView];

        NSView *bottomBorder = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frameRect.size.width, 1)];
        bottomBorder.wantsLayer = YES;
        bottomBorder.layer.backgroundColor = [[NSColor separatorColor] CGColor];
        bottomBorder.autoresizingMask = NSViewWidthSizable;
        [self addSubview:bottomBorder];

        CGFloat h = frameRect.size.height;
        CGFloat btnSize = 24;
        CGFloat pad = 6;
        CGFloat y = (h - btnSize) / 2;

        self.closeButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close"]
                                              target:self action:@selector(closeTapped:)];
        self.closeButton.bezelStyle = NSBezelStyleAccessoryBarAction;
        self.closeButton.bordered = NO;
        self.closeButton.frame = NSMakeRect(pad, y, btnSize, btnSize);
        [self addSubview:self.closeButton];

        CGFloat fieldX = pad + btnSize + pad;
        CGFloat fieldW = 220;
        CGFloat fieldH = 22;
        CGFloat fieldY = (h - fieldH) / 2;
        self.searchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(fieldX, fieldY, fieldW, fieldH)];
        self.searchField.placeholderString = @"Find on page";
        self.searchField.delegate = self;
        self.searchField.controlSize = NSControlSizeSmall;
        [self.searchField.cell setScrollable:YES];
        [self addSubview:self.searchField];

        CGFloat bx = fieldX + fieldW + pad;
        self.prevButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:@"Previous"]
                                             target:self action:@selector(prevTapped:)];
        self.prevButton.bezelStyle = NSBezelStyleAccessoryBarAction;
        self.prevButton.bordered = NO;
        self.prevButton.frame = NSMakeRect(bx, y, btnSize, btnSize);
        [self addSubview:self.prevButton];

        bx += btnSize + 2;
        self.nextButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Next"]
                                             target:self action:@selector(nextTapped:)];
        self.nextButton.bezelStyle = NSBezelStyleAccessoryBarAction;
        self.nextButton.bordered = NO;
        self.nextButton.frame = NSMakeRect(bx, y, btnSize, btnSize);
        [self addSubview:self.nextButton];

        self.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    }
    return self;
}

- (AbstractView *)activeWebview {
    if (!self.parentWindow) return nil;
    if (![self.parentWindow.contentView isKindOfClass:[ContainerView class]]) return nil;
    ContainerView *container = (ContainerView *)self.parentWindow.contentView;
    return container.abstractViews.lastObject;
}

- (void)showInWindow:(NSWindow *)window {
    self.parentWindow = window;
    if (![window.contentView isKindOfClass:[ContainerView class]]) return;
    ContainerView *container = (ContainerView *)window.contentView;

    CGFloat barHeight = 32;
    NSRect bounds = container.bounds;
    self.frame = NSMakeRect(0, bounds.size.height - barHeight, bounds.size.width, barHeight);

    if (self.superview != container) {
        [container addSubview:self positioned:NSWindowAbove relativeTo:nil];
    }
    self.hidden = NO;
    [window makeFirstResponder:self.searchField];
    [self.searchField selectText:nil];
}

- (void)dismiss {
    AbstractView *view = [self activeWebview];
    if (view) [view stopFindInPage];
    self.hidden = YES;
    [self removeFromSuperview];
    if (self.parentWindow) {
        objc_setAssociatedObject(self.parentWindow, FindBarAssociatedKey.UTF8String, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)findNext {
    NSString *query = self.searchField.stringValue;
    if (query.length == 0) return;
    AbstractView *view = [self activeWebview];
    if (view) [view findInPage:query.UTF8String forward:YES matchCase:NO];
}

- (void)findPrevious {
    NSString *query = self.searchField.stringValue;
    if (query.length == 0) return;
    AbstractView *view = [self activeWebview];
    if (view) [view findInPage:query.UTF8String forward:NO matchCase:NO];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    NSString *query = self.searchField.stringValue;
    AbstractView *view = [self activeWebview];
    if (!view) return;
    if (query.length == 0) {
        [view stopFindInPage];
    } else {
        [view findInPage:query.UTF8String forward:YES matchCase:NO];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (commandSelector == @selector(insertNewline:)) {
        NSEvent *event = [NSApp currentEvent];
        if (event.modifierFlags & NSEventModifierFlagShift) {
            [self findPrevious];
        } else {
            [self findNext];
        }
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self dismiss];
        return YES;
    }
    return NO;
}

- (void)closeTapped:(id)sender { [self dismiss]; }
- (void)prevTapped:(id)sender { [self findPrevious]; }
- (void)nextTapped:(id)sender { [self findNext]; }

@end

// ----------------------- CEF OSR View Implementation -----------------------

@implementation CEFOSRView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor clearColor] CGColor];
        self.layer.opaque = NO;

        _bufferLock = [[NSLock alloc] init];
        _pixelBuffer = NULL;
        _renderBuffer = NULL;
        _pixelBufferSize = 0;
        _bufferWidth = 0;
        _bufferHeight = 0;
        _hasNewFrame = NO;

        // Set up tracking area for mouse events
        [self updateTrackingAreas];
    }
    return self;
}

- (void)dealloc {
    [_bufferLock lock];
    if (_pixelBuffer) {
        free(_pixelBuffer);
        _pixelBuffer = NULL;
    }
    if (_renderBuffer) {
        free(_renderBuffer);
        _renderBuffer = NULL;
    }
    [_bufferLock unlock];

    // Clean up the heap-allocated browser pointer
    if (_cefBrowser) {
        CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)_cefBrowser;
        delete browserPtr;
        _cefBrowser = NULL;
    }
}

- (void)updateTrackingAreas {
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
        owner:self
        userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (BOOL)isFlipped {
    return YES;  // CEF uses top-left origin
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return YES;
}

- (void)setCefBrowser:(void*)browser {
    _cefBrowser = browser;  // Use backing ivar directly to avoid recursive setter call
}

- (void)updateBuffer:(const void*)buffer width:(int)width height:(int)height {
    NSLog(@"DEBUG OSR updateBuffer: Enter, buffer=%p, width=%d, height=%d", buffer, width, height);

    if (!buffer || width <= 0 || height <= 0) {
        NSLog(@"DEBUG OSR updateBuffer: Invalid params, returning");
        return;
    }

    // Sanity check for reasonable buffer sizes (max 8K resolution)
    if (width > 8192 || height > 8192) {
        NSLog(@"DEBUG OSR updateBuffer: Size too large, returning");
        return;
    }

    size_t requiredSize = (size_t)width * (size_t)height * 4;  // BGRA

    // Sanity check for allocation size (max 256MB)
    if (requiredSize > 256 * 1024 * 1024) {
        NSLog(@"DEBUG OSR updateBuffer: Required size too large, returning");
        return;
    }

    NSLog(@"DEBUG OSR updateBuffer: About to lock, _bufferLock=%p", _bufferLock);
    [_bufferLock lock];
    NSLog(@"DEBUG OSR updateBuffer: Lock acquired");

    // Reallocate buffer if needed
    if (_pixelBufferSize < requiredSize) {
        NSLog(@"DEBUG OSR updateBuffer: Reallocating buffer from %zu to %zu", _pixelBufferSize, requiredSize);
        if (_pixelBuffer) {
            free(_pixelBuffer);
            _pixelBuffer = NULL;
        }
        _pixelBuffer = malloc(requiredSize);
        if (_pixelBuffer) {
            _pixelBufferSize = requiredSize;
            NSLog(@"DEBUG OSR updateBuffer: Buffer allocated at %p", _pixelBuffer);
        } else {
            _pixelBufferSize = 0;
            NSLog(@"DEBUG OSR updateBuffer: Buffer allocation failed!");
            [_bufferLock unlock];
            return;
        }
    }

    NSLog(@"DEBUG OSR updateBuffer: About to memcpy %zu bytes", requiredSize);
    memcpy(_pixelBuffer, buffer, requiredSize);
    _bufferWidth = width;
    _bufferHeight = height;
    _hasNewFrame = YES;

    [_bufferLock unlock];
    NSLog(@"DEBUG OSR updateBuffer: Lock released, requesting redraw");

    // Request redraw on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay:YES];
    });
    NSLog(@"DEBUG OSR updateBuffer: Exit");
}

- (void)drawRect:(NSRect)dirtyRect {
    NSLog(@"DEBUG OSR drawRect: Enter");
    [_bufferLock lock];

    if (!_pixelBuffer || _bufferWidth == 0 || _bufferHeight == 0) {
        [_bufferLock unlock];
        NSLog(@"DEBUG OSR drawRect: No buffer, returning");
        return;
    }

    // Copy to render buffer to minimize lock time
    size_t bufferSize = (size_t)_bufferWidth * (size_t)_bufferHeight * 4;
    if (!_renderBuffer || _hasNewFrame) {
        if (_renderBuffer) free(_renderBuffer);
        _renderBuffer = malloc(bufferSize);
        if (_renderBuffer) {
            memcpy(_renderBuffer, _pixelBuffer, bufferSize);
        }
        _hasNewFrame = NO;
    }

    int width = _bufferWidth;
    int height = _bufferHeight;
    void *renderData = _renderBuffer;

    [_bufferLock unlock];

    if (!renderData) {
        NSLog(@"DEBUG OSR drawRect: No render data, returning");
        return;
    }

    CGContextRef context = [[NSGraphicsContext currentContext] CGContext];
    if (!context) {
        NSLog(@"DEBUG OSR drawRect: No context, returning");
        return;
    }

    NSLog(@"DEBUG OSR drawRect: Creating bitmap context %dx%d", width, height);

    // Create a CGImage from the pixel buffer (BGRA format)
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapContext = CGBitmapContextCreate(
        renderData,
        width,
        height,
        8,  // bits per component
        width * 4,  // bytes per row
        colorSpace,
        (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little  // BGRA
    );

    if (bitmapContext) {
        CGImageRef image = CGBitmapContextCreateImage(bitmapContext);
        if (image) {
            // CGContextDrawImage draws with origin at bottom-left, but CEF renders with origin at top-left
            // We need to flip the context to draw correctly
            CGContextSaveGState(context);

            // Flip the context: translate to bottom and scale y by -1
            CGContextTranslateCTM(context, 0, self.bounds.size.height);
            CGContextScaleCTM(context, 1.0, -1.0);

            CGRect drawRect = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height);
            CGContextDrawImage(context, drawRect, image);

            CGContextRestoreGState(context);
            CGImageRelease(image);
        }
        CGContextRelease(bitmapContext);
    }
    CGColorSpaceRelease(colorSpace);
    NSLog(@"DEBUG OSR drawRect: Exit");
}

// Mouse event handling - forward to CEF
- (void)sendMouseEvent:(NSEvent*)event type:(int)type {
    if (!self.cefBrowser) return;

    CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
    if (!browserPtr || !(*browserPtr)) return;

    CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
    if (!host) return;

    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    CefMouseEvent cefEvent;
    cefEvent.x = (int)point.x;
    cefEvent.y = (int)point.y;
    cefEvent.modifiers = 0;

    if ([event modifierFlags] & NSEventModifierFlagShift) cefEvent.modifiers |= EVENTFLAG_SHIFT_DOWN;
    if ([event modifierFlags] & NSEventModifierFlagControl) cefEvent.modifiers |= EVENTFLAG_CONTROL_DOWN;
    if ([event modifierFlags] & NSEventModifierFlagOption) cefEvent.modifiers |= EVENTFLAG_ALT_DOWN;
    if ([event modifierFlags] & NSEventModifierFlagCommand) cefEvent.modifiers |= EVENTFLAG_COMMAND_DOWN;

    CefBrowserHost::MouseButtonType buttonType = MBT_LEFT;
    if ([event type] == NSEventTypeRightMouseDown || [event type] == NSEventTypeRightMouseUp) {
        buttonType = MBT_RIGHT;
    } else if ([event type] == NSEventTypeOtherMouseDown || [event type] == NSEventTypeOtherMouseUp) {
        buttonType = MBT_MIDDLE;
    }

    if (type == 0) {  // Move
        host->SendMouseMoveEvent(cefEvent, false);
    } else if (type == 1) {  // Down
        host->SendMouseClickEvent(cefEvent, buttonType, false, 1);
    } else if (type == 2) {  // Up
        host->SendMouseClickEvent(cefEvent, buttonType, true, 1);
    }
}

- (void)mouseDown:(NSEvent*)event { [self sendMouseEvent:event type:1]; }
- (void)mouseUp:(NSEvent*)event { [self sendMouseEvent:event type:2]; }
- (void)mouseMoved:(NSEvent*)event { [self sendMouseEvent:event type:0]; }
- (void)mouseDragged:(NSEvent*)event { [self sendMouseEvent:event type:0]; }
- (void)rightMouseDown:(NSEvent*)event { [self sendMouseEvent:event type:1]; }
- (void)rightMouseUp:(NSEvent*)event { [self sendMouseEvent:event type:2]; }
- (void)rightMouseDragged:(NSEvent*)event { [self sendMouseEvent:event type:0]; }

- (void)scrollWheel:(NSEvent*)event {
    if (!self.cefBrowser) return;

    CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
    if (!browserPtr || !(*browserPtr)) return;

    CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
    if (!host) return;

    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];

    CefMouseEvent cefEvent;
    cefEvent.x = (int)point.x;
    cefEvent.y = (int)point.y;
    cefEvent.modifiers = 0;

    int deltaX = (int)([event scrollingDeltaX] * 10);
    int deltaY = (int)([event scrollingDeltaY] * 10);

    host->SendMouseWheelEvent(cefEvent, deltaX, deltaY);
}

// Keyboard event handling
- (void)keyDown:(NSEvent*)event {
    if (!self.cefBrowser) return;

    CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
    if (!browserPtr || !(*browserPtr)) return;

    CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
    if (!host) return;

    CefKeyEvent cefEvent;
    cefEvent.type = KEYEVENT_RAWKEYDOWN;
    cefEvent.native_key_code = [event keyCode];
    cefEvent.windows_key_code = [event keyCode];
    cefEvent.modifiers = 0;

    if ([event modifierFlags] & NSEventModifierFlagShift) cefEvent.modifiers |= EVENTFLAG_SHIFT_DOWN;
    if ([event modifierFlags] & NSEventModifierFlagControl) cefEvent.modifiers |= EVENTFLAG_CONTROL_DOWN;
    if ([event modifierFlags] & NSEventModifierFlagOption) cefEvent.modifiers |= EVENTFLAG_ALT_DOWN;
    if ([event modifierFlags] & NSEventModifierFlagCommand) cefEvent.modifiers |= EVENTFLAG_COMMAND_DOWN;

    host->SendKeyEvent(cefEvent);

    // Also send char event for text input
    NSString *chars = [event characters];
    if ([chars length] > 0) {
        cefEvent.type = KEYEVENT_CHAR;
        cefEvent.character = [chars characterAtIndex:0];
        cefEvent.unmodified_character = cefEvent.character;
        host->SendKeyEvent(cefEvent);
    }
}

- (void)keyUp:(NSEvent*)event {
    if (!self.cefBrowser) return;

    CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
    if (!browserPtr || !(*browserPtr)) return;

    CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
    if (!host) return;

    CefKeyEvent cefEvent;
    cefEvent.type = KEYEVENT_KEYUP;
    cefEvent.native_key_code = [event keyCode];
    cefEvent.windows_key_code = [event keyCode];
    cefEvent.modifiers = 0;

    host->SendKeyEvent(cefEvent);
}

- (void)flagsChanged:(NSEvent*)event {
    // Handle modifier key changes if needed
}

- (BOOL)becomeFirstResponder {
    BOOL result = [super becomeFirstResponder];
    if (result && self.cefBrowser) {
        CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
        if (browserPtr && *browserPtr) {
            CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
            if (host) {
                host->SetFocus(true);
            }
        }
    }
    return result;
}

- (BOOL)resignFirstResponder {
    if (self.cefBrowser) {
        CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
        if (browserPtr && *browserPtr) {
            CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
            if (host) {
                host->SetFocus(false);
            }
        }
    }
    return [super resignFirstResponder];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        // Request focus when added to window
        [self.window makeFirstResponder:self];
    }
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];

    // Notify CEF of size change
    if (self.cefBrowser) {
        CefRefPtr<CefBrowser>* browserPtr = (CefRefPtr<CefBrowser>*)self.cefBrowser;
        if (browserPtr && *browserPtr) {
            CefRefPtr<CefBrowserHost> host = (*browserPtr)->GetHost();
            if (host) {
                host->WasResized();
            }
        }
    }
}

@end

// ----------------------- URL Scheme & Navigation Delegates -----------------------

@implementation MyURLSchemeHandler
    - (void)webView:(WKWebView *)webView
    startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
        NSURL *url = urlSchemeTask.request.URL;
        NSData *bodyData = urlSchemeTask.request.HTTPBody;
        NSString *bodyString = bodyData ? [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] : @"";
        
        NSData *data = nil;
        size_t contentLength = 0;
        const char *contentPtr = NULL;
        
        NSString *urlString = url.absoluteString;
        
        if ([urlString hasPrefix:@"views://"]) {
            NSString *relativePath = normalizeViewsRelativePath(urlString);

            if ([relativePath isEqualToString:@"internal/index.html"]) {
                // For internal content, call the native HTML resolver.
                // Use stored HTML content instead of JSCallback
                contentPtr = getWebviewHTMLContent(self.webviewId);
                if (!contentPtr) {
                    // Fallback to default if no content set
                    contentPtr = strdup("<html><body>No content set</body></html>");
                }
                if (contentPtr) {
                    contentLength = strlen(contentPtr);
                    data = [NSData dataWithBytes:contentPtr length:contentLength];
                } else {
                    // Handle NULL content gracefully
                    NSError *error = [NSError errorWithDomain:@"MyURLSchemeHandler" 
                                                         code:404 
                                                     userInfo:@{NSLocalizedDescriptionKey: @"Failed to load internal content"}];
                    [urlSchemeTask didFailWithError:error];
                    return;
                }
            } else {
                data = readViewsFileWithRoot(urlString.UTF8String, self.viewsRoot);
                
                if (data) {
                    contentPtr = (const char *)data.bytes;
                    contentLength = data.length;
                }
            } 
        } else {
            NSLog(@"Unknown URL format: %@", urlString);
        }
        
        if (contentPtr && contentLength > 0) {
            // Determine MIME type using shared function
            std::string urlStr = [urlString UTF8String];
            std::string detectedMimeType = getMimeTypeFromUrl(urlStr);
            const char *mimeTypePtr = strdup(detectedMimeType.c_str());
            
            NSString *rawMimeType = mimeTypePtr ? [NSString stringWithUTF8String:mimeTypePtr] : @"application/octet-stream";

            NSString *mimeType;
            NSString *encodingName = nil;
            if ([rawMimeType hasPrefix:@"text/html"]) {
                mimeType = @"text/html";
                encodingName = @"UTF-8";  // Set encoding explicitly
            } else {
                // For non-text content or text content that doesn't need explicit encoding
                mimeType = rawMimeType;
            }
            
            NSURLResponse *response = [[NSURLResponse alloc] initWithURL:url
                                                    MIMEType:mimeType
                                        expectedContentLength:contentLength
                                            textEncodingName:encodingName];
            [urlSchemeTask didReceiveResponse:response];
            [urlSchemeTask didReceiveData:data];
            [urlSchemeTask didFinish];
            
            // Clean up memory
            if (mimeTypePtr) {
                free((void*)mimeTypePtr);
            }
        } else {
            NSLog(@"============== ERROR ========== empty response for URL: %@", urlString);         
            // Notify failure properly to prevent crashes
            NSError *error = [NSError errorWithDomain:@"MyURLSchemeHandler" 
                                                 code:404 
                                             userInfo:@{NSLocalizedDescriptionKey: @"Resource not found"}];
            [urlSchemeTask didFailWithError:error];
        }
       
    }
    - (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    }
@end

static BOOL isGoogleDomain(NSString *host) {
    if (!host) return NO;
    return [host hasSuffix:@".google.com"] || [host isEqualToString:@"google.com"]
        || [host hasSuffix:@".google.se"]  || [host isEqualToString:@"google.se"]
        || [host hasSuffix:@".googleapis.com"]
        || [host hasSuffix:@".gstatic.com"]
        || [host containsString:@".google."];
}

static NSMutableURLRequest *addChromeClientHints(NSURLRequest *original) {
    NSMutableURLRequest *req = [original mutableCopy];
    [req setValue:@"\"Chromium\";v=\"134\", \"Not:A-Brand\";v=\"24\", \"Google Chrome\";v=\"134\"" forHTTPHeaderField:@"Sec-CH-UA"];
    [req setValue:@"?0" forHTTPHeaderField:@"Sec-CH-UA-Mobile"];
    [req setValue:@"\"macOS\"" forHTTPHeaderField:@"Sec-CH-UA-Platform"];
    return req;
}

static NSString *jsonStringFromObject(id object) {
    if (!object || ![NSJSONSerialization isValidJSONObject:object]) {
        return @"{}";
    }

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (error || !data) {
        NSLog(@"[Nav] failed to serialize event payload: %@", error);
        return @"{}";
    }

    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return json ?: @"{}";
}

static char *copyCString(NSString *string) {
    const char *utf8 = string.UTF8String ?: "";
    return strdup(utf8);
}

static void sendWebviewEvent(WebviewEventHandler handler, uint32_t webviewId, const char *eventName, NSString *detail) {
    if (!handler || !eventName) {
        return;
    }

    char *eventNameCopy = strdup(eventName);
    char *detailCopy = copyCString(detail ?: @"");
    if (!eventNameCopy || !detailCopy) {
        free(eventNameCopy);
        free(detailCopy);
        return;
    }

    handler(webviewId, eventNameCopy, detailCopy);
}

static void dispatchWebviewEvent(WebviewEventHandler handler, uint32_t webviewId, const char *eventName, NSString *detail) {
    if (!handler || !eventName) {
        return;
    }

    NSString *detailCopy = [detail copy] ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        sendWebviewEvent(handler, webviewId, eventName, detailCopy);
    });
}

@implementation MyNavigationDelegate
    - (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
        NSURL *newURL = navigationAction.request.URL;
        NSString *urlString = newURL.absoluteString ?: @"";

        // Check if cmd key is held - if so, fire event and block navigation
        BOOL isCmdClick = (navigationAction.modifierFlags & NSEventModifierFlagCommand) != 0;

        if (isCmdClick && navigationAction.navigationType == WKNavigationTypeLinkActivated) {
            decisionHandler(WKNavigationActionPolicyCancel);
            NSString *eventData = jsonStringFromObject(@{
                @"url": urlString,
                @"isCmdClick": @YES,
                @"modifierFlags": @((unsigned long)navigationAction.modifierFlags)
            });
            dispatchWebviewEvent(self.zigEventHandler, self.webviewId, "new-window-open", eventData);
            return;
        }

        // For main-frame navigations that haven't been processed yet,
        // cancel, inject stored cookies, and re-issue the request.
        // The custom header prevents re-entry.
        if (navigationAction.targetFrame.isMainFrame
            && ![navigationAction.request valueForHTTPHeaderField:@"X-EB-CI"]) {

            BOOL isGoogle = isGoogleDomain(newURL.host);
            if (isGoogle) {
                webView.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15";
            }

            decisionHandler(WKNavigationActionPolicyCancel);

            WKHTTPCookieStore *cookieStore = webView.configuration.websiteDataStore.httpCookieStore;
            NSURLRequest *origRequest = navigationAction.request;

            [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
                NSMutableURLRequest *req = [origRequest mutableCopy];

                // Inject matching cookies
                NSURL *url = req.URL;
                NSMutableArray *matchingCookies = [NSMutableArray array];
                for (NSHTTPCookie *cookie in cookies) {
                    NSString *domain = cookie.domain;
                    NSString *host = url.host;
                    BOOL domainMatch = NO;
                    if ([domain hasPrefix:@"."]) {
                        domainMatch = [host hasSuffix:domain] || [host isEqualToString:[domain substringFromIndex:1]];
                    } else {
                        domainMatch = [host isEqualToString:domain];
                    }
                    if (domainMatch) {
                        NSString *cookiePath = cookie.path ?: @"/";
                        NSString *urlPath = url.path.length > 0 ? url.path : @"/";
                        if ([urlPath hasPrefix:cookiePath]) {
                            [matchingCookies addObject:cookie];
                        }
                    }
                }
                if (matchingCookies.count > 0) {
                    NSDictionary *headers = [NSHTTPCookie requestHeaderFieldsWithCookies:matchingCookies];
                    for (NSString *key in headers) {
                        [req setValue:headers[key] forHTTPHeaderField:key];
                    }
                }

                [req setValue:@"1" forHTTPHeaderField:@"X-EB-CI"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [webView loadRequest:req];
                });
            }];
            return;
        }

        // Check navigation rules synchronously from native-stored rules
        AbstractView *abstractView = [globalAbstractViews objectForKey:@(self.webviewId)];
        BOOL shouldAllow = abstractView ? [abstractView shouldAllowNavigationToURL:urlString] : YES;

        WKNavigationActionPolicy policy;
        if (navigationAction.shouldPerformDownload) {
            policy = WKNavigationActionPolicyDownload;
        } else {
            policy = shouldAllow ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel;
        }
        decisionHandler(policy);

        NSString *eventData = jsonStringFromObject(@{
            @"url": urlString,
            @"allowed": @(shouldAllow)
        });
        dispatchWebviewEvent(self.zigEventHandler, self.webviewId, "will-navigate", eventData);
    }

    - (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
        // If the response cannot be shown (e.g., binary file, attachment), trigger download
        if (!navigationResponse.canShowMIMEType) {
            NSLog(@"DEBUG WKWebView Download: Cannot show MIME type, triggering download for %@", navigationResponse.response.URL.absoluteString);
            decisionHandler(WKNavigationResponsePolicyDownload);
        } else {
            decisionHandler(WKNavigationResponsePolicyAllow);
        }
    }

    - (void)detectAndApplyThemeColor:(WKWebView *)webView {
        NSWindow *window = webView.window;
        NSNumber *adaptiveTheme = objc_getAssociatedObject(window, "adaptiveTheme");
        if (!adaptiveTheme || !adaptiveTheme.boolValue) return;

        WKSnapshotConfiguration *config = [[WKSnapshotConfiguration alloc] init];
        config.rect = CGRectMake(0, 0, webView.bounds.size.width, 5);
        config.snapshotWidth = @(200);

        [webView takeSnapshotWithConfiguration:config completionHandler:^(NSImage *image, NSError *error) {
            if (error || !image) return;

            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithData:[image TIFFRepresentation]];
            if (!bitmap) return;

            NSCountedSet *colorCounts = [[NSCountedSet alloc] init];
            NSInteger width = bitmap.pixelsWide;
            NSInteger height = bitmap.pixelsHigh;

            for (NSInteger y = 0; y < height; y++) {
                for (NSInteger x = 0; x < width; x++) {
                    NSColor *pixel = [bitmap colorAtX:x y:y];
                    NSColor *rgb = [pixel colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
                    if (!rgb) continue;
                    NSInteger qr = ((NSInteger)(rgb.redComponent * 255)) / 16 * 16;
                    NSInteger qg = ((NSInteger)(rgb.greenComponent * 255)) / 16 * 16;
                    NSInteger qb = ((NSInteger)(rgb.blueComponent * 255)) / 16 * 16;
                    NSString *key = [NSString stringWithFormat:@"%ld,%ld,%ld", (long)qr, (long)qg, (long)qb];
                    [colorCounts addObject:key];
                }
            }

            NSString *mostFrequent = nil;
            NSUInteger maxCount = 0;
            for (NSString *key in colorCounts) {
                NSUInteger count = [colorCounts countForObject:key];
                if (count > maxCount) {
                    maxCount = count;
                    mostFrequent = key;
                }
            }

            if (!mostFrequent) return;
            NSArray *parts = [mostFrequent componentsSeparatedByString:@","];
            CGFloat r = [parts[0] floatValue] / 255.0;
            CGFloat g = [parts[1] floatValue] / 255.0;
            CGFloat b = [parts[2] floatValue] / 255.0;
            NSColor *color = [NSColor colorWithRed:r green:g blue:b alpha:1.0];

            dispatch_async(dispatch_get_main_queue(), ^{
                window.backgroundColor = color;
                CGFloat luminance = 0.299 * r + 0.587 * g + 0.114 * b;
                window.appearance = [NSAppearance appearanceNamed:
                    (luminance > 0.5) ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
            });
        }];
    }

    - (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
        NSString *urlString = webView.URL.absoluteString ?: @"";
        NSLog(@"[Nav] webview %u didFinishNavigation: %@", self.webviewId, urlString);
        if (urlString.length > 0) {
            sendWebviewEvent(self.zigEventHandler, self.webviewId, "did-navigate", urlString);
        }
        [self detectAndApplyThemeColor:webView];

        if (self.zigEventHandler) {
            uint32_t wid = self.webviewId;
            WebviewEventHandler handler = self.zigEventHandler;
            [webView evaluateJavaScript:
                @"(function(){"
                 "var l=document.querySelectorAll('link[rel~=\"icon\"],link[rel=\"shortcut icon\"]');"
                 "return l.length?l[l.length-1].href:'';"
                 "})()"
                completionHandler:^(id result, NSError *error) {
                    if (!error && result && [result isKindOfClass:[NSString class]] && [result length] > 0) {
                        sendWebviewEvent(handler, wid, "favicon-updated", result);
                    }
                }];
        }
    }

    - (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
        NSString *urlString = webView.URL.absoluteString ?: @"";
        NSLog(@"[Nav] webview %u didCommitNavigation: %@", self.webviewId, urlString);
        if (urlString.length > 0) {
            sendWebviewEvent(self.zigEventHandler, self.webviewId, "did-commit-navigation", urlString);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
            dispatch_get_main_queue(), ^{
                [self detectAndApplyThemeColor:webView];
            });
    }

    - (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
        NSLog(@"[Nav] webview %u didFailNavigation: %@ (code %ld)", self.webviewId, error.localizedDescription, (long)error.code);
    }

    - (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
        NSLog(@"[Nav] webview %u didFailProvisionalNavigation: %@ (code %ld)", self.webviewId, error.localizedDescription, (long)error.code);
    }

    - (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
        NSLog(@"[Nav] webview %u WEB CONTENT PROCESS TERMINATED", self.webviewId);
    }

    - (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
        NSLog(@"[Nav] webview %u didStartProvisionalNavigation: %@", self.webviewId, webView.URL.absoluteString);
    }

    // Called when navigationAction policy returns .download
    - (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)navigationAction didBecomeDownload:(WKDownload *)download API_AVAILABLE(macos(11.3)) {
        NSLog(@"DEBUG WKWebView Download: Navigation action became download");
        download.delegate = self;
    }

    // Called when navigationResponse policy returns .download
    - (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)navigationResponse didBecomeDownload:(WKDownload *)download API_AVAILABLE(macos(11.3)) {
        NSLog(@"DEBUG WKWebView Download: Navigation response became download");
        download.delegate = self;
    }

    // WKDownloadDelegate methods
    - (void)download:(WKDownload *)download
    decideDestinationUsingResponse:(NSURLResponse *)response
    suggestedFilename:(NSString *)suggestedFilename
    completionHandler:(void (^)(NSURL * _Nullable destination))completionHandler API_AVAILABLE(macos(11.3)) {
        NSLog(@"DEBUG WKWebView Download: Deciding destination for %@", suggestedFilename);

        // Get the Downloads folder
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES);
        NSString *downloadsDirectory = [paths firstObject];

        if (downloadsDirectory) {
            NSString *destinationPath = [downloadsDirectory stringByAppendingPathComponent:suggestedFilename];

            // Handle duplicate filenames by appending a number
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSString *basePath = [destinationPath stringByDeletingPathExtension];
            NSString *extension = [destinationPath pathExtension];
            int counter = 1;

            while ([fileManager fileExistsAtPath:destinationPath]) {
                if (extension.length > 0) {
                    destinationPath = [NSString stringWithFormat:@"%@ (%d).%@", basePath, counter, extension];
                } else {
                    destinationPath = [NSString stringWithFormat:@"%@ (%d)", basePath, counter];
                }
                counter++;
            }

            NSURL *destinationURL = [NSURL fileURLWithPath:destinationPath];
            NSLog(@"DEBUG WKWebView Download: Saving to %@", destinationPath);

            // Store the path for this download so we can reference it in completion handlers
            if (!self.downloadPaths) {
                self.downloadPaths = [NSMutableDictionary dictionary];
            }
            [self.downloadPaths setObject:destinationPath forKey:[NSValue valueWithNonretainedObject:download]];

            // Observe download progress via KVO
            if (!self.observedDownloads) {
                self.observedDownloads = [NSMutableSet set];
            }
            [self.observedDownloads addObject:download];
            [download.progress addObserver:self
                                forKeyPath:@"fractionCompleted"
                                   options:NSKeyValueObservingOptionNew
                                   context:NULL];

            // Send download-started event
            if (self.zigEventHandler) {
                // Use NSJSONSerialization for proper escaping
                NSDictionary *eventDict = @{@"filename": suggestedFilename, @"path": destinationPath};
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:eventDict options:0 error:nil];
                NSString *eventData = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                self.zigEventHandler(self.webviewId, strdup("download-started"), strdup([eventData UTF8String]));
            }

            completionHandler(destinationURL);
        } else {
            NSLog(@"ERROR WKWebView Download: Could not find Downloads directory");
            completionHandler(nil);
        }
    }

    - (void)downloadDidFinish:(WKDownload *)download API_AVAILABLE(macos(11.3)) {
        NSLog(@"DEBUG WKWebView Download: Download finished successfully");

        // Remove KVO observer
        if ([self.observedDownloads containsObject:download]) {
            [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            [self.observedDownloads removeObject:download];
        }

        // Send download-completed event
        if (self.zigEventHandler) {
            NSString *path = [self.downloadPaths objectForKey:[NSValue valueWithNonretainedObject:download]];
            NSString *filename = [path lastPathComponent] ?: @"";
            // Use NSJSONSerialization for proper escaping
            NSDictionary *eventDict = @{@"filename": filename, @"path": path ?: @""};
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:eventDict options:0 error:nil];
            NSString *eventData = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            self.zigEventHandler(self.webviewId, strdup("download-completed"), strdup([eventData UTF8String]));

            // Clean up
            [self.downloadPaths removeObjectForKey:[NSValue valueWithNonretainedObject:download]];
        }
    }

    - (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData API_AVAILABLE(macos(11.3)) {
        NSLog(@"ERROR WKWebView Download: Download failed with error: %@", error.localizedDescription);

        // Remove KVO observer
        if ([self.observedDownloads containsObject:download]) {
            [download.progress removeObserver:self forKeyPath:@"fractionCompleted"];
            [self.observedDownloads removeObject:download];
        }

        // Send download-failed event
        if (self.zigEventHandler) {
            NSString *path = [self.downloadPaths objectForKey:[NSValue valueWithNonretainedObject:download]];
            NSString *filename = [path lastPathComponent] ?: @"";
            // Use NSJSONSerialization for proper escaping
            NSDictionary *eventDict = @{@"filename": filename, @"path": path ?: @"", @"error": error.localizedDescription};
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:eventDict options:0 error:nil];
            NSString *eventData = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            self.zigEventHandler(self.webviewId, strdup("download-failed"), strdup([eventData UTF8String]));

            // Clean up
            [self.downloadPaths removeObjectForKey:[NSValue valueWithNonretainedObject:download]];
        }
    }

    // KVO observer for download progress
    - (void)observeValueForKeyPath:(NSString *)keyPath
                          ofObject:(id)object
                            change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                           context:(void *)context {
        if ([keyPath isEqualToString:@"fractionCompleted"]) {
            NSProgress *progress = (NSProgress *)object;
            int percent = (int)(progress.fractionCompleted * 100);

            // Send download-progress event
            if (self.zigEventHandler) {
                NSString *eventData = [NSString stringWithFormat:@"{\"progress\":%d}", percent];
                self.zigEventHandler(self.webviewId, strdup("download-progress"), strdup([eventData UTF8String]));
            }
        }
    }
@end

@implementation MyWebViewUIDelegate
    - (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
        forNavigationAction:(WKNavigationAction *)navigationAction
            windowFeatures:(WKWindowFeatures *)windowFeatures {
        
        // Check if this is a cmd+click or a traditional popup window request
        BOOL isCmdClick = (navigationAction.modifierFlags & NSEventModifierFlagCommand) != 0;
        BOOL isNewWindow = !navigationAction.targetFrame.isMainFrame || isCmdClick;        
        
        if (isNewWindow) {
            NSString *eventData = [NSString stringWithFormat:@"{\"url\":\"%@\",\"isCmdClick\":%@,\"modifierFlags\":%lu}", 
                                 navigationAction.request.URL.absoluteString, 
                                 isCmdClick ? @"true" : @"false",
                                 (unsigned long)navigationAction.modifierFlags];            
            
            if (self.zigEventHandler) {                
                // Use strdup to create a persistent copy of the string for the FFI callback
                char* eventDataCopy = strdup([eventData UTF8String]);
                self.zigEventHandler(self.webviewId, strdup("new-window-open"), eventDataCopy);                
            } else {
                NSLog(@"[NEW_WINDOW] ERROR: zigEventHandler is NULL!");
            }
        }
        return nil;
    }
    
    // Handle file input elements (<input type="file">)
    - (void)webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
  initiatedByFrame:(WKFrameInfo *)frame
 completionHandler:(void (^)(NSArray<NSURL *> * _Nullable URLs))completionHandler {
        
        NSOpenPanel *openPanel = [NSOpenPanel openPanel];
        
        // Configure the panel based on parameters
        [openPanel setAllowsMultipleSelection:parameters.allowsMultipleSelection];
        [openPanel setCanChooseDirectories:parameters.allowsDirectories];
        [openPanel setCanChooseFiles:YES];
        
        // Note: WKOpenPanelParameters doesn't expose acceptedMIMETypes in older versions
        // The file filtering will be handled by the web page's input element accept attribute
        // For now, we'll keep the dialog open to all file types and let the web page handle filtering
        
        // Run the panel synchronously to avoid block capture issues
        NSInteger response = [openPanel runModal];
        if (response == NSModalResponseOK) {
            completionHandler(openPanel.URLs);
        } else {
            completionHandler(nil);
        }
    }
    
    - (void)webView:(WKWebView *)webView
    requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    type:(WKMediaCaptureType)type
    decisionHandler:(void (^)(WKPermissionDecision decision))decisionHandler {
        
        NSString *originString = [NSString stringWithFormat:@"%@://%@", origin.protocol, origin.host];
        std::string originStd = [originString UTF8String];

        NSLog(@"WKWebView: Media capture permission requested for %@ (type: %ld)", originString, (long)type);

        NSString *requestURLString = frame.request.URL.absoluteString ?: webView.URL.absoluteString;

        // The app shell is fully trusted. In production this is views://; in dev
        // the launcher is served from localhost with cachyWindow=launcher.
        if ([origin.protocol isEqualToString:@"views"] || isTrustedAppShellURL(requestURLString)) {
            decisionHandler(WKPermissionDecisionGrant);
            return;
        }

        // Check cache first
        PermissionStatus cachedStatus = getPermissionFromCache(originStd, PermissionType::USER_MEDIA);
        
        if (cachedStatus == PermissionStatus::ALLOWED) {
            NSLog(@"WKWebView: Using cached permission: User previously allowed media access for %@", originString);
            decisionHandler(WKPermissionDecisionGrant);
            return;
        } else if (cachedStatus == PermissionStatus::DENIED) {
            NSLog(@"WKWebView: Using cached permission: User previously blocked media access for %@", originString);
            decisionHandler(WKPermissionDecisionDeny);
            return;
        }
        
        // No cached permission, show dialog
        NSLog(@"WKWebView: No cached permission found for %@, showing dialog", originString);
        
        NSString *message;
        NSString *title;
        
        switch (type) {
            case WKMediaCaptureTypeCamera:
                message = @"This page wants to access your camera.\n\nDo you want to allow this?";
                title = @"Camera Access";
                break;
            case WKMediaCaptureTypeMicrophone:
                message = @"This page wants to access your microphone.\n\nDo you want to allow this?";
                title = @"Microphone Access";
                break;
            case WKMediaCaptureTypeCameraAndMicrophone:
                message = @"This page wants to access your camera and microphone.\n\nDo you want to allow this?";
                title = @"Camera & Microphone Access";
                break;
            default:
                message = @"This page wants to access your media devices.\n\nDo you want to allow this?";
                title = @"Media Access";
                break;
        }
        
        // Show macOS native alert
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:title];
        [alert setInformativeText:message];
        [alert addButtonWithTitle:@"Allow"];
        [alert addButtonWithTitle:@"Block"];
        [alert setAlertStyle:NSAlertStyleInformational];
        
        NSModalResponse response = [alert runModal];
        
        // Handle response and cache the decision
        if (response == NSAlertFirstButtonReturn) { // Allow
            decisionHandler(WKPermissionDecisionGrant);
            cachePermission(originStd, PermissionType::USER_MEDIA, PermissionStatus::ALLOWED);
            NSLog(@"WKWebView: User allowed media access for %@ (cached)", originString);
        } else { // Block
            decisionHandler(WKPermissionDecisionDeny);
            cachePermission(originStd, PermissionType::USER_MEDIA, PermissionStatus::DENIED);
            NSLog(@"WKWebView: User blocked media access for %@ (cached)", originString);
        }
    }
    
    - (void)webView:(WKWebView *)webView
    requestGeolocationPermissionForOrigin:(WKSecurityOrigin *)origin
    initiatedByFrame:(WKFrameInfo *)frame
    decisionHandler:(void (^)(WKPermissionDecision decision))decisionHandler {
        
        NSString *originString = [NSString stringWithFormat:@"%@://%@", origin.protocol, origin.host];
        std::string originStd = [originString UTF8String];

        NSLog(@"WKWebView: Geolocation permission requested for %@", originString);

        // views:// is the app's own bundled-asset shell — always trusted, never prompt.
        if ([origin.protocol isEqualToString:@"views"]) {
            decisionHandler(WKPermissionDecisionGrant);
            return;
        }

        // Check cache first
        PermissionStatus cachedStatus = getPermissionFromCache(originStd, PermissionType::GEOLOCATION);
        
        if (cachedStatus == PermissionStatus::ALLOWED) {
            NSLog(@"WKWebView: Using cached permission: User previously allowed location access for %@", originString);
            decisionHandler(WKPermissionDecisionGrant);
            return;
        } else if (cachedStatus == PermissionStatus::DENIED) {
            NSLog(@"WKWebView: Using cached permission: User previously blocked location access for %@", originString);
            decisionHandler(WKPermissionDecisionDeny);
            return;
        }
        
        // No cached permission, show dialog
        NSLog(@"WKWebView: No cached permission found for %@, showing dialog", originString);
        
        NSString *message = @"This page wants to access your location.\n\nDo you want to allow this?";
        NSString *title = @"Location Access";
        
        // Show macOS native alert
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:title];
        [alert setInformativeText:message];
        [alert addButtonWithTitle:@"Allow"];
        [alert addButtonWithTitle:@"Block"];
        [alert setAlertStyle:NSAlertStyleInformational];
        
        NSModalResponse response = [alert runModal];
        
        // Handle response and cache the decision
        if (response == NSAlertFirstButtonReturn) { // Allow
            decisionHandler(WKPermissionDecisionGrant);
            cachePermission(originStd, PermissionType::GEOLOCATION, PermissionStatus::ALLOWED);
            NSLog(@"WKWebView: User allowed location access for %@ (cached)", originString);
        } else { // Block
            decisionHandler(WKPermissionDecisionDeny);
            cachePermission(originStd, PermissionType::GEOLOCATION, PermissionStatus::DENIED);
            NSLog(@"WKWebView: User blocked location access for %@ (cached)", originString);
        }
    }
@end

@implementation MyScriptMessageHandlerWithReply
    - (void)userContentController:(WKUserContentController *)userContentController
        didReceiveScriptMessage:(WKScriptMessage *)message
                    replyHandler:(void (^)(id _Nullable, NSString * _Nullable))replyHandler {
        NSString *body = message.body;
        const char *response = self.zigCallback(self.webviewId, body.UTF8String);
        NSString *responseNSString = response ? [NSString stringWithUTF8String:response] : @"";
        replyHandler(responseNSString, nil);
    }
@end

@implementation MyScriptMessageHandler
    - (void)userContentController:(WKUserContentController *)userContentController
        didReceiveScriptMessage:(WKScriptMessage *)message {
        NSString *body = message.body;
        const char *bodyCStr = strdup(body.UTF8String);
        self.zigCallback(self.webviewId, bodyCStr); 

        // Note: threadsafe JSCallbacks are invoked on the js worker thread, When called frequently they
        // can build up and take longer. Meanwhile objc GC auto free's the message body and the callback
        // ends up getting garbage.

        // So we duplicate it and give it plenty of time to execute (1 second delay vs. 0.1ms execution per invocation)
        // before freeing the memory
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            free((void*)bodyCStr);
        });              
    }
@end

// ----------------------- WKWebViewImpl -----------------------


@implementation WKWebViewImpl

    - (instancetype)initWithWebviewId:(uint32_t)webviewId
                            window:(NSWindow *)window
                            url:(const char *)url
                                frame:(NSRect)frame
                        autoResize:(bool)autoResize
                partitionIdentifier:(const char *)partitionIdentifier
                navigationCallback:(DecideNavigationCallback)navigationCallback
                webviewEventHandler:(WebviewEventHandler)webviewEventHandler
                eventBridgeHandler:(HandlePostMessage)eventBridgeHandler
                bunBridgeHandler:(HandlePostMessage)bunBridgeHandler
                internalBridgeHandler:(HandlePostMessage)internalBridgeHandler
                electrobunPreloadScript:(const char *)electrobunPreloadScript
                customPreloadScript:(const char *)customPreloadScript
                viewsRoot:(const char *)viewsRoot
                transparent:(bool)transparent
                sandbox:(bool)sandbox
    {
        self = [super init];
        if (self) {
            self.webviewId = webviewId;
            self.isSandboxed = sandbox;
            self.zigEventHandler = webviewEventHandler;
            NSString *viewsRootString =
                (viewsRoot && strlen(viewsRoot) > 0)
                    ? [NSString stringWithUTF8String:viewsRoot]
                    : nil;

            // TODO: rewrite this so we can return a reference to the AbstractRenderer and then call
            // init from zig after the handle is added to the webviewMap then we don't need this async stuff
            dispatch_async(dispatch_get_main_queue(), ^{
                
                // configuration
                WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
                
                configuration.websiteDataStore = createDataStoreForPartition(partitionIdentifier);
                
                [configuration.preferences setValue:@YES forKey:@"developerExtrasEnabled"];        
                [configuration.preferences setValue:@YES forKey:@"elementFullscreenEnabled"];                                
                [configuration.preferences setValue:@YES forKey:@"allowsPictureInPictureMediaPlayback"];                
                
                // Add scheme handler
                MyURLSchemeHandler *assetSchemeHandler = [[MyURLSchemeHandler alloc] init];
                // TODO: Consider storing views handler globally and not on each AbstractView                
                assetSchemeHandler.webviewId = webviewId;
                assetSchemeHandler.viewsRoot = viewsRootString;
                [configuration setURLSchemeHandler:assetSchemeHandler forURLScheme:@"views"];
                
                // create WKWebView
                self.webView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];

                // Only transparent windows should make the page canvas transparent.
                // Normal site/app windows need WebKit's opaque background so pages
                // that do not paint their own body background do not show native
                // dark window chrome through the document.
                if (autoResize && transparent) {
                    [self.webView setValue:@NO forKey:@"drawsBackground"];
                    self.webView.layer.backgroundColor = [[NSColor clearColor] CGColor];
                    self.webView.layer.opaque = NO;
                }

                self.webView.autoresizingMask = NSViewNotSizable;
                
                [self.webView addObserver:self forKeyPath:@"fullscreenState" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];
                [self.webView addObserver:self forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:nil];

                if (autoResize) {
                    self.fullSize = YES;
                } else {                
                    self.fullSize = NO;
                }
                
                // retainObjCObject(self.webView);

                // delegates
                MyNavigationDelegate *navigationDelegate = [[MyNavigationDelegate alloc] init];
                navigationDelegate.zigCallback = navigationCallback;                
                navigationDelegate.zigEventHandler = webviewEventHandler;
                navigationDelegate.webviewId = webviewId;
                self.webView.navigationDelegate = navigationDelegate;
                objc_setAssociatedObject(self.webView, "NavigationDelegate", navigationDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                MyWebViewUIDelegate *uiDelegate = [[MyWebViewUIDelegate alloc] init];
                uiDelegate.zigEventHandler = webviewEventHandler;
                uiDelegate.webviewId = webviewId;
                self.webView.UIDelegate = uiDelegate;
                objc_setAssociatedObject(self.webView, "UIDelegate", uiDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);                                    

                // postmessage handlers

                // eventBridge - event-only bridge (always set up for all webviews, including sandboxed)
                MyScriptMessageHandler *eventHandler = [[MyScriptMessageHandler alloc] init];
                eventHandler.zigCallback = eventBridgeHandler;
                eventHandler.webviewId = webviewId;
                [self.webView.configuration.userContentController addScriptMessageHandler:eventHandler
                                                                                name:[NSString stringWithUTF8String:"eventBridge"]];
                objc_setAssociatedObject(self.webView, "eventBridgeHandler", eventHandler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                // bunBridge and internalBridge - RPC bridges (only for non-sandboxed webviews)
                if (!sandbox) {
                    // bunBridge - user RPC bridge
                    MyScriptMessageHandler *bunHandler = [[MyScriptMessageHandler alloc] init];
                    bunHandler.zigCallback = bunBridgeHandler;
                    bunHandler.webviewId = webviewId;
                    [self.webView.configuration.userContentController addScriptMessageHandler:bunHandler
                                                                                    name:[NSString stringWithUTF8String:"bunBridge"]];
                    objc_setAssociatedObject(self.webView, "bunBridgeHandler", bunHandler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

                    // internalBridge - internal RPC bridge (for webview tags, drag regions, etc.)
                    MyScriptMessageHandler *webviewTagHandler = [[MyScriptMessageHandler alloc] init];
                    webviewTagHandler.zigCallback = internalBridgeHandler;
                    webviewTagHandler.webviewId = webviewId;
                    [self.webView.configuration.userContentController addScriptMessageHandler:webviewTagHandler
                                                                                    name:[NSString stringWithUTF8String:"internalBridge"]];
                    objc_setAssociatedObject(self.webView, "webviewTagHandler", webviewTagHandler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }

                // add subview
                [window.contentView addSubview:self.webView positioned:NSWindowAbove relativeTo:nil];
                // For fullSize webviews, use the content view's bounds (excludes title bar)
                // instead of the passed frame which may include the window chrome dimensions.
                NSRect webviewFrame = autoResize ? window.contentView.bounds : frame;
                if (!autoResize) {
                    CGFloat adjustedY = window.contentView.bounds.size.height - frame.origin.y - frame.size.height;
                    webviewFrame = NSMakeRect(frame.origin.x, adjustedY, frame.size.width, frame.size.height);
                }
                self.webView.frame = webviewFrame;

                // Ensure the webview is properly layer-backed and visible
                self.webView.wantsLayer = YES;
                self.webView.hidden = NO;

                // For child webviews (non-autoResize), ensure they appear on top
                if (!autoResize) {
                    // Bring child webview to front of the view hierarchy
                    [self.webView removeFromSuperview];
                    [window.contentView addSubview:self.webView positioned:NSWindowAbove relativeTo:nil];
                    self.webView.layer.zPosition = 1000;
                }

                ContainerView *containerView = (ContainerView *)window.contentView;
                [containerView addAbstractView:self];
                // self.webView.abstractView = self;
                
                
                
                // Note: in WkWebkit the webview is an NSView
                self.nsView = self.webView;

                // Apply deferred initial transparent/passthrough state now that nsView is set
                if (self.pendingStartTransparent) {
                    [self setTransparent:YES];
                }
                if (self.pendingStartPassthrough) {
                    [self setPassthrough:YES];
                }

                // Polyfill navigator.userAgentData so sites like Google
                // recognise WKWebView as a Chromium-based browser.
                static NSString *uaDataPolyfill = @"(function(){"
                    "if(navigator.userAgentData)return;"
                    "var b=[{brand:'Chromium',version:'134'},{brand:'Not:A-Brand',version:'24'},{brand:'Google Chrome',version:'134'}];"
                    "Object.defineProperty(navigator,'userAgentData',{get:function(){return{"
                        "brands:b,mobile:false,platform:'macOS',"
                        "getHighEntropyValues:function(){return Promise.resolve({"
                            "brands:b,mobile:false,platform:'macOS',platformVersion:'15.3.0',"
                            "architecture:'arm',model:'',uaFullVersion:'134.0.0.0',"
                            "fullVersionList:[{brand:'Chromium',version:'134.0.0.0'},{brand:'Not:A-Brand',version:'24.0.0.0'},{brand:'Google Chrome',version:'134.0.0.0'}]"
                        "})},"
                        "toJSON:function(){return{brands:this.brands,mobile:this.mobile,platform:this.platform}}"
                    "}},configurable:true,enumerable:true});"
                "})();";
                WKUserScript *uaDataScript = [[WKUserScript alloc] initWithSource:uaDataPolyfill
                                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                forMainFrameOnly:false];
                [self.webView.configuration.userContentController addUserScript:uaDataScript];

                [self addPreloadScriptToWebView:electrobunPreloadScript];
                
                // Note: For custom preload scripts we support either inline js or a views:// style
                // url to a js file in the bundled views folder.
                if (strncmp(customPreloadScript, "views://", 8) == 0) {                    
                    NSData *scriptData = readViewsFileWithRoot(customPreloadScript, viewsRootString);
                    if (scriptData) {                        
                        NSString *scriptString = [[NSString alloc] initWithData:scriptData encoding:NSUTF8StringEncoding];                        
                        const char *scriptCString = [scriptString UTF8String];
                        [self updateCustomPreloadScript:scriptCString];
                    }
                } else {
                    [self updateCustomPreloadScript:customPreloadScript];
                }

                // Only load URL if it's provided and no HTML content exists
                if (url && strlen(url) > 0) {                                   
                    [self loadURL:url];
                } 
                
                // associate
                objc_setAssociatedObject(self.webView, "WKWebViewImpl", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            });
        }
        
        // Add to global tracking map
        if (globalAbstractViews) {
            globalAbstractViews[@(self.webviewId)] = self;
        }
        
        return self;
    }

    - (void)loadURL:(const char *)urlString {
        // Copy the string since we're dispatching async
        NSString *urlNSString = (urlString ? [NSString stringWithUTF8String:urlString] : @"");

        // Ensure URL loading happens on the main queue (WKWebView requirement)
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.webView) {
                NSLog(@"ERROR: WKWebView loadURL called but webview is nil for webview ID: %u", self.webviewId);
                return;
            }

            NSURL *url = [NSURL URLWithString:urlNSString];
            if (!url) {
                NSLog(@"ERROR: WKWebView loadURL invalid URL for webview ID: %u", self.webviewId);
                return;
            }
            if (url.isFileURL) {
                NSURL *readAccessURL = [url URLByDeletingLastPathComponent];
                if (!readAccessURL) {
                    readAccessURL = url;
                }
                [self.webView loadFileURL:url allowingReadAccessToURL:readAccessURL];
            } else {
                BOOL isGoogle = isGoogleDomain(url.host);
                if (isGoogle) {
                    self.webView.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15";
                }
                NSURLRequest *base = [NSURLRequest requestWithURL:url];
                NSURLRequest *request = base;

                WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
                [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
                    NSMutableArray *matchingCookies = [NSMutableArray array];
                    for (NSHTTPCookie *cookie in cookies) {
                        NSString *domain = cookie.domain;
                        NSString *host = url.host;
                        BOOL domainMatch = NO;
                        if ([domain hasPrefix:@"."]) {
                            domainMatch = [host hasSuffix:domain] || [host isEqualToString:[domain substringFromIndex:1]];
                        } else {
                            domainMatch = [host isEqualToString:domain];
                        }
                        if (domainMatch) {
                            NSString *cookiePath = cookie.path ?: @"/";
                            NSString *urlPath = url.path.length > 0 ? url.path : @"/";
                            if ([urlPath hasPrefix:cookiePath]) {
                                [matchingCookies addObject:cookie];
                            }
                        }
                    }
                    if (matchingCookies.count > 0) {
                        NSDictionary *headers = [NSHTTPCookie requestHeaderFieldsWithCookies:matchingCookies];
                        NSMutableURLRequest *mutableRequest = [request mutableCopy];
                        for (NSString *key in headers) {
                            [mutableRequest setValue:headers[key] forHTTPHeaderField:key];
                        }
                        NSLog(@"[cookies] Injected %lu cookies into request for %@", (unsigned long)matchingCookies.count, url.host);
                        [self.webView loadRequest:mutableRequest];
                    } else {
                        [self.webView loadRequest:request];
                    }
                }];
            }
        });
    }

    - (void)loadHTML:(const char *)htmlString {
        // Ensure the HTML loading happens on the main queue after webview is initialized
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.webView) {
                NSLog(@"ERROR: WKWebView loadHTML called but webview is nil for webview ID: %u", self.webviewId);
                return;
            }
            
            NSString *htmlNSString = (htmlString ? [NSString stringWithUTF8String:htmlString] : @"");
            NSLog(@"DEBUG WKWebView: Loading HTML content for webview %u: %.50s...", self.webviewId, htmlString);
            [self.webView loadHTMLString:htmlNSString baseURL:nil];
            NSLog(@"DEBUG WKWebView: loadHTMLString completed for webview ID: %u", self.webviewId);
        });
    }

    - (void)goBack {        
            [self.webView goBack];        
    }
    - (void)goForward {
        [self.webView goForward];
    }
    - (void)reload {
        [self.webView reload];
    }

    - (void)remove {
        if (!self.webView) {
            return;
        }

        uint32_t webviewIdForLogging = self.webviewId;
        WKWebView *webViewToClean = self.webView;

        // Keep native tracking consistent even if this remove path is called
        // directly instead of going through webviewRemove().
        if (globalAbstractViews) {
            [globalAbstractViews removeObjectForKey:@(self.webviewId)];
        }

        // Dispatch all cleanup to main queue since WKWebView operations require it
        dispatch_async(dispatch_get_main_queue(), ^{
            // Stop any HTML5 media first. WKWebView's about:blank navigation below
            // would normally tear down media, but MSE-based players (YouTube etc.)
            // can keep an audio session alive in the WebContent process for a moment
            // after the WKWebView is dismissed — explicitly pausing every <video>/<audio>
            // and clearing their sources forces the audio HAL to release samples
            // immediately, so closing the window also stops the sound.
            @try {
                [webViewToClean evaluateJavaScript:@"(function(){try{document.querySelectorAll('video,audio').forEach(function(m){try{m.pause();m.muted=true;m.removeAttribute('src');m.srcObject=null;m.load();}catch(e){}});}catch(e){}})()"
                                           inFrame:nil
                                    inContentWorld:[WKContentWorld pageWorld]
                                 completionHandler:nil];
            } @catch (NSException *e) {}

            [webViewToClean stopLoading];

            // Remove KVO observer
            @try {
                [webViewToClean removeObserver:self forKeyPath:@"fullscreenState"];
                [webViewToClean removeObserver:self forKeyPath:@"title"];
            } @catch (NSException *exception) {
                // Observer may not be registered yet if remove is called during init
            }

            // Remove script message handlers — WKUserContentController strongly retains
            // these handlers, preventing WKWebView deallocation
            WKUserContentController *ucc = webViewToClean.configuration.userContentController;
            @try { [ucc removeScriptMessageHandlerForName:@"eventBridge"]; } @catch (NSException *e) {}
            @try { [ucc removeScriptMessageHandlerForName:@"bunBridge"]; } @catch (NSException *e) {}
            @try { [ucc removeScriptMessageHandlerForName:@"internalBridge"]; } @catch (NSException *e) {}
            // Remove all user scripts as well
            [ucc removeAllUserScripts];

            // Nil delegates
            webViewToClean.navigationDelegate = nil;
            webViewToClean.UIDelegate = nil;

            // Remove from ContainerView tracking
            if (webViewToClean.superview && [webViewToClean.superview isKindOfClass:[ContainerView class]]) {
                ContainerView *containerView = (ContainerView *)webViewToClean.superview;
                [containerView removeAbstractViewWithId:webviewIdForLogging];
            }

            // Remove from view hierarchy immediately
            [webViewToClean removeFromSuperview];

            // Load about:blank to force WebKit to release the WebContent process
            [webViewToClean loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"about:blank"]]];
        });

        // Release our strong reference immediately so the main queue block
        // holds the last reference and deallocation happens after cleanup
        self.webView = nil;
        self.nsView = nil;
    }



    - (BOOL)canGoBack {
        return [self.webView canGoBack];
    }
    - (BOOL)canGoForward {
        return [self.webView canGoForward];
    }

    - (void)evaluateJavaScriptWithNoCompletion:(const char*)jsString {
        // Copy the string before dispatch_async since the JS-side buffer may be GC'd
        NSString *code = (jsString ? [NSString stringWithUTF8String:jsString] : @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.webView) return;
            WKContentWorld *isolatedWorld = [WKContentWorld pageWorld];
            [self.webView evaluateJavaScript:code
                                    inFrame:nil
                            inContentWorld:isolatedWorld
                        completionHandler:nil];
        });
    }

    - (const char*)evaluateJavaScriptSync:(const char*)jsString {
        NSString *code = (jsString ? [NSString stringWithUTF8String:jsString] : @"");
        __block const char* result = NULL;
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.webView) {
                dispatch_semaphore_signal(sema);
                return;
            }
            [self.webView evaluateJavaScript:code
                                    inFrame:nil
                            inContentWorld:[WKContentWorld pageWorld]
                        completionHandler:^(id _result, NSError *error) {
                if (!error && _result && [_result isKindOfClass:[NSString class]]) {
                    result = strdup([_result UTF8String]);
                }
                dispatch_semaphore_signal(sema);
            }];
        });
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
        return result;
    }

    - (void)callAsyncJavascript:(const char*)messageId jsString:(const char*)jsString webviewId:(uint32_t)webviewId hostWebviewId:(uint32_t)hostWebviewId completionHandler:(callAsyncJavascriptCompletionHandler)completionHandler {
        NSString *javaScript = [NSString stringWithUTF8String:jsString ?: ""];
        NSDictionary *arguments = @{};
        [self.webView callAsyncJavaScript:javaScript
                        arguments:arguments
                            inFrame:nil
                    inContentWorld:WKContentWorld.pageWorld
                completionHandler:^(id result, NSError *error) {
            NSError *jsonError;
            NSData *jsonData;
            if (error) {
                jsonData = [NSJSONSerialization dataWithJSONObject:@{@"error": error.localizedDescription}
                                                        options:0
                                                            error:&jsonError];
            } else {
                if (result == nil) {
                    jsonData = [NSJSONSerialization dataWithJSONObject:@{@"result": [NSNull null]}
                                                            options:0
                                                                error:&jsonError];
                } else if ([NSJSONSerialization isValidJSONObject:result]) {
                    jsonData = [NSJSONSerialization dataWithJSONObject:result
                                                            options:0
                                                                error:&jsonError];
                } else {
                    jsonData = [NSJSONSerialization dataWithJSONObject:@{@"result": [result description]}
                                                            options:0
                                                                error:&jsonError];
                }
                if (jsonError) {
                    jsonData = [NSJSONSerialization dataWithJSONObject:@{@"error": jsonError.localizedDescription}
                                                            options:0
                                                                error:&jsonError];
                }
            }
            NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
            completionHandler(messageId, webviewId, hostWebviewId, jsonString.UTF8String);
        }];
    }


    - (void)addPreloadScriptToWebView:(const char*)jsString {
        NSString *code = (jsString ? [NSString stringWithUTF8String:jsString] : @"");
        WKUserScript *script = [[WKUserScript alloc] initWithSource:code
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                forMainFrameOnly:false];
        [self.webView.configuration.userContentController addUserScript:script];    
    }

    - (void)updateCustomPreloadScript:(const char*)jsString {    
        WKUserContentController *contentController = self.webView.configuration.userContentController;
        NSString *identifierComment = [NSString stringWithFormat:@"// %@\n", [NSString stringWithUTF8String:"electrobun_custom_preload_script"]];
        NSString *newScriptSource = [identifierComment stringByAppendingString:[NSString stringWithUTF8String:jsString ?: ""]];
        NSMutableArray *newScripts = [NSMutableArray array];
        for (WKUserScript *userScript in contentController.userScripts) {
            if (![userScript.source containsString:identifierComment]) {
                [newScripts addObject:userScript];
            }
        }
        [contentController removeAllUserScripts];
        for (WKUserScript *userScript in newScripts) {
            [contentController addUserScript:userScript];
        }
        WKUserScript *newUserScript = [[WKUserScript alloc] initWithSource:newScriptSource
                                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                        forMainFrameOnly:true];
        [contentController addUserScript:newUserScript];
    }

    // KVO observer method to track fullscreen and other webview state changes
    - (void)observeValueForKeyPath:(NSString *)keyPath
                          ofObject:(id)object
                            change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                           context:(void *)context {        
        
        if (object == self.webView) {
            if ([keyPath isEqualToString:@"title"]) {
                NSString *title = self.webView.title;
                if (title && title.length > 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.webView.window) {
                            [self.webView.window setTitle:title];
                        }
                    });
                    if (self.zigEventHandler) {
                        self.zigEventHandler(self.webviewId, strdup("page-title-updated"), strdup(title.UTF8String));
                    }
                }
            } else if ([keyPath isEqualToString:@"fullscreenState"]) {                
                id newValue = change[NSKeyValueChangeNewKey];                                                
                NSInteger stateValue = 0;
                if (newValue) {
                    stateValue = [newValue integerValue];                
                }                
                
                // FULLSCREEN FIX: Handle fullscreen transitions with mask store/restore
                if (stateValue == 1) { // Entering Fullscreen
                    self.isInFullscreen = YES;
                    
                    // Store the current mask before clearing it
                    self.storedLayerMask = self.webView.layer.mask;
                    self.webView.layer.mask = nil;                                                            
                } else if (stateValue == 0 || stateValue == 3) { // Not in fullscreen or exiting
                    if (self.isInFullscreen) {
                        self.isInFullscreen = NO;
                        
                        // Restore the stored mask when exiting fullscreen
                        self.webView.layer.mask = self.storedLayerMask;
                        self.storedLayerMask = nil; // Clear the stored reference                                                
                    }                    
                }                 
            } 
        } else {
            // Call super for non-webview objects
            [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        }
    }

    // Cleanup KVO observers when the webview is deallocated
    - (void)dealloc {
        @try {
            [self.webView removeObserver:self forKeyPath:@"fullscreenState"];
            [self.webView removeObserver:self forKeyPath:@"title"];
        } @catch (NSException *exception) {
            // Observer already removed in -remove
        }
    }

    - (void)findInPage:(const char*)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase {
        if (!searchText || strlen(searchText) == 0) {
            [self stopFindInPage];
            return;
        }

        NSString *text = [NSString stringWithUTF8String:searchText];
        if (@available(macOS 11.0, *)) {
            WKFindConfiguration *config = [[WKFindConfiguration alloc] init];
            config.backwards = !forward;
            config.caseSensitive = matchCase;
            config.wraps = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.webView findString:text withConfiguration:config completionHandler:nil];
            });
        } else {
            NSString *escapedText = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
            escapedText = [escapedText stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
            escapedText = [escapedText stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
            escapedText = [escapedText stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
            NSString *js = [NSString stringWithFormat:
                @"window.find('%@', %@, %@, true, false, false, false)",
                escapedText,
                matchCase ? @"true" : @"false",
                forward ? @"false" : @"true"];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.webView evaluateJavaScript:js completionHandler:nil];
            });
        }
    }

    - (void)stopFindInPage {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (@available(macOS 12.0, *)) {
                [self.webView findString:@"" withConfiguration:nil completionHandler:nil];
            }
            [self.webView evaluateJavaScript:@"window.getSelection().removeAllRanges();" completionHandler:nil];
        });
    }

    - (void)openDevTools {
        dispatch_async(dispatch_get_main_queue(), ^{
            // WKWebView doesn't have public DevTools API, but we can use private API if available
            if ([self.webView respondsToSelector:@selector(_inspector)]) {
                id inspector = [self.webView performSelector:@selector(_inspector)];
                if ([inspector respondsToSelector:@selector(show)]) {
                    [inspector performSelector:@selector(show)];
                }
            }
        });
    }

    - (void)closeDevTools {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.webView respondsToSelector:@selector(_inspector)]) {
                id inspector = [self.webView performSelector:@selector(_inspector)];
                if ([inspector respondsToSelector:@selector(close)]) {
                    [inspector performSelector:@selector(close)];
                }
            }
        });
    }

    - (void)toggleDevTools {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.webView respondsToSelector:@selector(_inspector)]) {
                id inspector = [self.webView performSelector:@selector(_inspector)];
                if ([inspector respondsToSelector:@selector(isVisible)]) {
                    BOOL isVisible = [[inspector performSelector:@selector(isVisible)] boolValue];
                    if (isVisible) {
                        [self closeDevTools];
                    } else {
                        [self openDevTools];
                    }
                } else {
                    // Fallback: just try to open
                    [self openDevTools];
                }
            }
        });
    }

@end

// ----------------------- WGPUViewImpl -----------------------
@interface WGPUInputView : NSView
@end

@implementation WGPUInputView
    - (uint32_t)modifierMaskFromEvent:(NSEvent*)event {
        uint32_t mods = 0;
        if ([event modifierFlags] & NSEventModifierFlagShift) mods |= 1 << 0;
        if ([event modifierFlags] & NSEventModifierFlagControl) mods |= 1 << 1;
        if ([event modifierFlags] & NSEventModifierFlagOption) mods |= 1 << 2;
        if ([event modifierFlags] & NSEventModifierFlagCommand) mods |= 1 << 3;
        return mods;
    }
    - (void)flagsChanged:(NSEvent*)event {
        WindowDelegate *delegate = (WindowDelegate *)self.window.delegate;
        if (!delegate || !delegate.keyHandler) return;
        const NSUInteger flags = [event modifierFlags];
        uint32_t isDown = 0;
        switch ([event keyCode]) {
            case 0x38: // left shift
            case 0x3C: // right shift
                isDown = (flags & NSEventModifierFlagShift) ? 1 : 0;
                break;
            case 0x3B: // left control
            case 0x3E: // right control
                isDown = (flags & NSEventModifierFlagControl) ? 1 : 0;
                break;
            case 0x3A: // left option
            case 0x3D: // right option
                isDown = (flags & NSEventModifierFlagOption) ? 1 : 0;
                break;
            case 0x37: // left command
            case 0x36: // right command
                isDown = (flags & NSEventModifierFlagCommand) ? 1 : 0;
                break;
            default:
                return;
        }
        delegate.keyHandler(delegate.windowId,
                            (uint32_t)[event keyCode],
                            [self modifierMaskFromEvent:event],
                            isDown,
                            0);
    }
    - (BOOL)acceptsFirstResponder {
        return YES;
    }
    - (BOOL)becomeFirstResponder {
        return YES;
    }
    - (void)keyDown:(NSEvent*)event {
        WindowDelegate *delegate = (WindowDelegate *)self.window.delegate;
        if (delegate && delegate.keyHandler) {
            delegate.keyHandler(delegate.windowId,
                                (uint32_t)[event keyCode],
                                [self modifierMaskFromEvent:event],
                                1,
                                [event isARepeat] ? 1 : 0);
        }
    }
    - (void)keyUp:(NSEvent*)event {
        WindowDelegate *delegate = (WindowDelegate *)self.window.delegate;
        if (delegate && delegate.keyHandler) {
            delegate.keyHandler(delegate.windowId,
                                (uint32_t)[event keyCode],
                                [self modifierMaskFromEvent:event],
                                0,
                                0);
        }
    }
@end

@implementation WGPUViewImpl

    - (instancetype)initWithWebviewId:(uint32_t)webviewId
                            window:(NSWindow *)window
                            frame:(NSRect)frame
                        autoResize:(bool)autoResize {
        self = [super init];
        if (self) {
            self.webviewId = webviewId;

            dispatch_async(dispatch_get_main_queue(), ^{
                id<MTLDevice> device = MTLCreateSystemDefaultDevice();
                NSView *view = [[WGPUInputView alloc] initWithFrame:frame];
                view.wantsLayer = YES;
                view.layer.backgroundColor = [[NSColor clearColor] CGColor];

                CAMetalLayer *metalLayer = [CAMetalLayer layer];
                metalLayer.device = device;
                metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
                metalLayer.framebufferOnly = NO;
                metalLayer.opaque = NO;
                metalLayer.backgroundColor = [[NSColor clearColor] CGColor];
                metalLayer.presentsWithTransaction = YES;
                metalLayer.allowsNextDrawableTimeout = NO;
                CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
                metalLayer.colorspace = cs;
                CGColorSpaceRelease(cs);
                CGFloat scale = window.backingScaleFactor;
                metalLayer.contentsScale = scale;
                metalLayer.drawableSize = CGSizeMake(frame.size.width * scale, frame.size.height * scale);
                view.layer = metalLayer;

                if (wgpuDebugEnabled()) {
                    NSLog(@"WGPUViewImpl init: frame=%.1fx%.1f scale=%.2f drawable=%.1fx%.1f",
                          frame.size.width, frame.size.height, scale,
                          metalLayer.drawableSize.width, metalLayer.drawableSize.height);
                }

                view.autoresizingMask = NSViewNotSizable;

                if (autoResize) {
                    self.fullSize = YES;
                } else {
                    self.fullSize = NO;
                }

                [window.contentView addSubview:view positioned:NSWindowAbove relativeTo:nil];
                CGFloat adjustedY = window.contentView.bounds.size.height - frame.origin.y - frame.size.height;
                view.frame = NSMakeRect(frame.origin.x, adjustedY, frame.size.width, frame.size.height);
                [window makeFirstResponder:view];

                if (self.pendingStartTransparent) {
                    window.opaque = NO;
                    window.backgroundColor = [NSColor clearColor];
                }

                ContainerView *containerView = (ContainerView *)window.contentView;
                [containerView addAbstractView:self];

                self.nsView = view;

                if (self.pendingStartTransparent) {
                    [self setTransparent:YES];
                }
                if (self.pendingStartPassthrough) {
                    [self setPassthrough:YES];
                }
            });
        }

        if (globalAbstractViews) {
            globalAbstractViews[@(self.webviewId)] = self;
        }

        return self;
    }

    - (void)loadURL:(const char *)urlString {}
    - (void)loadHTML:(const char *)htmlString {}
    - (void)goBack {}
    - (void)goForward {}
    - (void)reload {}
    - (void)evaluateJavaScriptWithNoCompletion:(const char*)jsString {}
    - (const char*)evaluateJavaScriptSync:(const char*)jsString { return NULL; }
    - (void)callAsyncJavascript:(const char*)messageId jsString:(const char*)jsString webviewId:(uint32_t)webviewId hostWebviewId:(uint32_t)hostWebviewId completionHandler:(callAsyncJavascriptCompletionHandler)completionHandler {}
    - (void)addPreloadScriptToWebView:(const char*)jsString {}
    - (void)updateCustomPreloadScript:(const char*)jsString {}

    - (void)findInPage:(const char*)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase {}
    - (void)stopFindInPage {}
    - (void)openDevTools {}
    - (void)closeDevTools {}
    - (void)toggleDevTools {}

    - (void)setTransparent:(BOOL)transparent {
        if (!self.nsView) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.nsView setWantsLayer:YES];
            self.nsView.layer.opacity = transparent ? 0 : 1;
            self.nsView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            self.nsView.layer.opaque = !transparent ? YES : NO;
            if ([self.nsView.layer isKindOfClass:[CAMetalLayer class]]) {
                CAMetalLayer *metalLayer = (CAMetalLayer *)self.nsView.layer;
                metalLayer.opaque = !transparent ? YES : NO;
                metalLayer.backgroundColor = [[NSColor clearColor] CGColor];
            }
        });
    }

    - (void)remove {
        if (!self.nsView) {
            return;
        }

        uint32_t webviewIdForLogging = self.webviewId;
        NSView *viewToRemove = self.nsView;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (viewToRemove.superview && [viewToRemove.superview isKindOfClass:[ContainerView class]]) {
                ContainerView *containerView = (ContainerView *)viewToRemove.superview;
                [containerView removeAbstractViewWithId:webviewIdForLogging];
            }
            [viewToRemove removeFromSuperview];
        });

        if (globalAbstractViews) {
            [globalAbstractViews removeObjectForKey:@(self.webviewId)];
        }
    }
@end

// ----------------------- WGPU Main-Thread Shims -----------------------

typedef void* (*PFN_wgpuInstanceCreateSurface)(void* instance, const void* descriptor);
typedef void (*PFN_wgpuSurfaceConfigure)(void* surface, const void* config);
typedef void (*PFN_wgpuSurfaceGetCurrentTexture)(void* surface, void* surfaceTexture);
typedef int32_t (*PFN_wgpuSurfacePresent)(void* surface);
typedef WGPUFuture (*PFN_wgpuQueueOnSubmittedWorkDone)(WGPUQueue queue, WGPUQueueWorkDoneCallbackInfo callbackInfo);
typedef WGPUFuture (*PFN_wgpuBufferMapAsync)(WGPUBuffer buffer, WGPUMapMode mode, size_t offset, size_t size, WGPUBufferMapCallbackInfo callbackInfo);
typedef WGPUWaitStatus (*PFN_wgpuInstanceWaitAny)(WGPUInstance instance, size_t futureCount, WGPUFutureWaitInfo* futures, uint64_t timeoutNS);
typedef void* (*PFN_wgpuBufferGetMappedRange)(WGPUBuffer buffer, size_t offset, size_t size);
typedef void* (*PFN_wgpuBufferGetConstMappedRange)(WGPUBuffer buffer, size_t offset, size_t size);
typedef void (*PFN_wgpuBufferUnmap)(WGPUBuffer buffer);

static void* wgpuLibHandle = nullptr;
static PFN_wgpuInstanceCreateSurface p_wgpuInstanceCreateSurface = nullptr;
static PFN_wgpuSurfaceConfigure p_wgpuSurfaceConfigure = nullptr;
static PFN_wgpuSurfaceGetCurrentTexture p_wgpuSurfaceGetCurrentTexture = nullptr;
static PFN_wgpuSurfacePresent p_wgpuSurfacePresent = nullptr;
static PFN_wgpuQueueOnSubmittedWorkDone p_wgpuQueueOnSubmittedWorkDone = nullptr;
static PFN_wgpuBufferMapAsync p_wgpuBufferMapAsync = nullptr;
static PFN_wgpuInstanceWaitAny p_wgpuInstanceWaitAny = nullptr;
static PFN_wgpuBufferGetMappedRange p_wgpuBufferGetMappedRange = nullptr;
static PFN_wgpuBufferGetConstMappedRange p_wgpuBufferGetConstMappedRange = nullptr;
static PFN_wgpuBufferUnmap p_wgpuBufferUnmap = nullptr;

static void* loadWgpuLibrary() {
    if (wgpuLibHandle) return wgpuLibHandle;
    NSString* execDir = [[[NSBundle mainBundle] executableURL] URLByDeletingLastPathComponent].path;
    NSString* bundlePath = [execDir stringByAppendingPathComponent:@"libwebgpu_dawn.dylib"];
    wgpuLibHandle = dlopen(bundlePath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!wgpuLibHandle) {
        wgpuLibHandle = dlopen("libwebgpu_dawn.dylib", RTLD_NOW | RTLD_LOCAL);
    }
    if (!wgpuLibHandle) {
        NSLog(@"WGPU: failed to load libwebgpu_dawn.dylib: %s", dlerror());
    }
    return wgpuLibHandle;
}

static bool ensureWgpuSymbols() {
    if (p_wgpuInstanceCreateSurface && p_wgpuSurfaceConfigure && p_wgpuSurfaceGetCurrentTexture && p_wgpuSurfacePresent
        && p_wgpuQueueOnSubmittedWorkDone && p_wgpuBufferMapAsync && p_wgpuInstanceWaitAny
        && p_wgpuBufferGetMappedRange && p_wgpuBufferUnmap) {
        return true;
    }
    void* handle = loadWgpuLibrary();
    if (!handle) return false;
    p_wgpuInstanceCreateSurface = (PFN_wgpuInstanceCreateSurface)dlsym(handle, "wgpuInstanceCreateSurface");
    p_wgpuSurfaceConfigure = (PFN_wgpuSurfaceConfigure)dlsym(handle, "wgpuSurfaceConfigure");
    p_wgpuSurfaceGetCurrentTexture = (PFN_wgpuSurfaceGetCurrentTexture)dlsym(handle, "wgpuSurfaceGetCurrentTexture");
    p_wgpuSurfacePresent = (PFN_wgpuSurfacePresent)dlsym(handle, "wgpuSurfacePresent");
    p_wgpuQueueOnSubmittedWorkDone = (PFN_wgpuQueueOnSubmittedWorkDone)dlsym(handle, "wgpuQueueOnSubmittedWorkDone");
    p_wgpuBufferMapAsync = (PFN_wgpuBufferMapAsync)dlsym(handle, "wgpuBufferMapAsync");
    p_wgpuInstanceWaitAny = (PFN_wgpuInstanceWaitAny)dlsym(handle, "wgpuInstanceWaitAny");
    p_wgpuBufferGetMappedRange = (PFN_wgpuBufferGetMappedRange)dlsym(handle, "wgpuBufferGetMappedRange");
    p_wgpuBufferGetConstMappedRange = (PFN_wgpuBufferGetConstMappedRange)dlsym(handle, "wgpuBufferGetConstMappedRange");
    p_wgpuBufferUnmap = (PFN_wgpuBufferUnmap)dlsym(handle, "wgpuBufferUnmap");
    if (!p_wgpuInstanceCreateSurface || !p_wgpuSurfaceConfigure || !p_wgpuSurfaceGetCurrentTexture || !p_wgpuSurfacePresent
        || !p_wgpuQueueOnSubmittedWorkDone || !p_wgpuBufferMapAsync || !p_wgpuInstanceWaitAny
        || !p_wgpuBufferGetMappedRange || !p_wgpuBufferUnmap) {
        NSLog(@"WGPU: missing symbols (create=%p configure=%p getTexture=%p present=%p)",
              p_wgpuInstanceCreateSurface, p_wgpuSurfaceConfigure, p_wgpuSurfaceGetCurrentTexture, p_wgpuSurfacePresent);
        return false;
    }
    return true;
}

static void* runOnMainThreadSyncPtr(void* (^block)(void)) {
    if ([NSThread isMainThread]) {
        return block();
    }
    __block void* result = nullptr;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = block();
    });
    return result;
}

static void runOnMainThreadSyncVoid(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        block();
    });
}

extern "C" void* wgpuInstanceCreateSurfaceMainThread(void* instance, void* descriptor) {
    if (!ensureWgpuSymbols()) return nullptr;
    return runOnMainThreadSyncPtr(^{
        return p_wgpuInstanceCreateSurface(instance, descriptor);
    });
}

extern "C" void* wgpuCreateSurfaceForView(void* wgpuInstance, AbstractView* abstractView) {
    if (!wgpuInstance || !abstractView) return nullptr;
    if (!ensureWgpuSymbols()) return nullptr;

    return (void*)runOnMainThreadSyncPtr(^{
        if (!abstractView.nsView) return (void*)nullptr;
        CALayer *layer = abstractView.nsView.layer;
        if (![layer isKindOfClass:[CAMetalLayer class]]) return (void*)nullptr;

        WGPUSurfaceSourceMetalLayer metalSource = {};
        metalSource.chain.sType = WGPUSType_SurfaceSourceMetalLayer;
        metalSource.layer = (__bridge void*)layer;

        WGPUSurfaceDescriptor surfaceDesc = {};
        surfaceDesc.nextInChain = reinterpret_cast<WGPUChainedStruct*>(&metalSource);
        return (void*)p_wgpuInstanceCreateSurface(wgpuInstance, &surfaceDesc);
    });
}

extern "C" void wgpuSurfaceConfigureMainThread(void* surface, void* config) {
    if (!ensureWgpuSymbols()) return;
    runOnMainThreadSyncVoid(^{
        p_wgpuSurfaceConfigure(surface, config);
    });
}

extern "C" void wgpuSurfaceGetCurrentTextureMainThread(void* surface, void* surfaceTexture) {
    if (!ensureWgpuSymbols()) return;
    runOnMainThreadSyncVoid(^{
        p_wgpuSurfaceGetCurrentTexture(surface, surfaceTexture);
    });
}

extern "C" int32_t wgpuSurfacePresentMainThread(void* surface) {
    if (!ensureWgpuSymbols()) return 0;
    return (int32_t)(intptr_t)runOnMainThreadSyncPtr(^{
        return (void*)(intptr_t)p_wgpuSurfacePresent(surface);
    });
}

extern "C" uint64_t wgpuQueueOnSubmittedWorkDoneShim(void* queue, void* callbackInfo) {
    if (!ensureWgpuSymbols()) return 0;
    if (!callbackInfo) return 0;
    WGPUQueueWorkDoneCallbackInfo info = *(WGPUQueueWorkDoneCallbackInfo*)callbackInfo;
    WGPUFuture future = p_wgpuQueueOnSubmittedWorkDone((WGPUQueue)queue, info);
    return future.id;
}

extern "C" uint64_t wgpuBufferMapAsyncShim(void* buffer, uint64_t mode, uint64_t offset, uint64_t size, void* callbackInfo) {
    if (!ensureWgpuSymbols()) return 0;
    if (!callbackInfo) return 0;
    WGPUBufferMapCallbackInfo info = *(WGPUBufferMapCallbackInfo*)callbackInfo;
    WGPUFuture future = p_wgpuBufferMapAsync((WGPUBuffer)buffer, (WGPUMapMode)mode, (size_t)offset, (size_t)size, info);
    return future.id;
}

extern "C" int32_t wgpuInstanceWaitAnyShim(void* instance, uint64_t futureId, uint64_t timeoutNS) {
    if (!ensureWgpuSymbols()) return 0;
    if (!instance || !futureId) return 0;
    WGPUFutureWaitInfo info;
    info.future.id = futureId;
    info.completed = WGPU_FALSE;
    WGPUWaitStatus status = p_wgpuInstanceWaitAny((WGPUInstance)instance, 1, &info, timeoutNS);
    if (status == WGPUWaitStatus_Success && info.completed) return 1;
    return 0;
}

extern "C" uint8_t* wgpuBufferReadSyncShim(
    void* instance,
    void* buffer,
    uint64_t offset,
    uint64_t size,
    uint64_t timeoutNS,
    uint64_t* outSize
) {
    if (!ensureWgpuSymbols()) return nullptr;
    if (!instance || !buffer || size == 0) return nullptr;

    WGPUBufferMapCallbackInfo mapInfo = {};
    mapInfo.mode = WGPUCallbackMode_AllowSpontaneous;
    mapInfo.callback = nullptr;
    mapInfo.userdata1 = nullptr;
    mapInfo.userdata2 = nullptr;

    WGPUFuture mapFuture = p_wgpuBufferMapAsync(
        (WGPUBuffer)buffer,
        WGPUMapMode_Read,
        (size_t)offset,
        (size_t)size,
        mapInfo
    );

    WGPUFutureWaitInfo waitInfo;
    waitInfo.future = mapFuture;
    waitInfo.completed = WGPU_FALSE;
    WGPUWaitStatus status = p_wgpuInstanceWaitAny(
        (WGPUInstance)instance,
        1,
        &waitInfo,
        timeoutNS
    );

    if (status != WGPUWaitStatus_Success || !waitInfo.completed) {
        return nullptr;
    }

    void* mapped = nullptr;
    if (p_wgpuBufferGetConstMappedRange) {
        mapped = p_wgpuBufferGetConstMappedRange((WGPUBuffer)buffer, (size_t)offset, (size_t)size);
    }
    if (!mapped) {
        mapped = p_wgpuBufferGetMappedRange((WGPUBuffer)buffer, (size_t)offset, (size_t)size);
    }
    if (!mapped) return nullptr;

    uint8_t* out = (uint8_t*)malloc((size_t)size);
    if (!out) return nullptr;
    memcpy(out, mapped, (size_t)size);
    p_wgpuBufferUnmap((WGPUBuffer)buffer);

    if (outSize) *outSize = size;
    return out;
}

extern "C" int32_t wgpuBufferReadSyncIntoShim(
    void* instance,
    void* buffer,
    uint64_t offset,
    uint64_t size,
    uint64_t timeoutNS,
    void* dst
) {
    if (!ensureWgpuSymbols()) return 0;
    if (!instance || !buffer || !dst || size == 0) return 0;
    __block int32_t result = 0;
    runOnMainThreadSyncVoid(^{
        WGPUBufferMapCallbackInfo mapInfo = {};
        mapInfo.mode = WGPUCallbackMode_AllowSpontaneous;
        mapInfo.callback = nullptr;
        mapInfo.userdata1 = nullptr;
        mapInfo.userdata2 = nullptr;

        WGPUFuture mapFuture = p_wgpuBufferMapAsync(
            (WGPUBuffer)buffer,
            WGPUMapMode_Read,
            (size_t)offset,
            (size_t)size,
            mapInfo
        );

        WGPUFutureWaitInfo waitInfo;
        waitInfo.future = mapFuture;
        waitInfo.completed = WGPU_FALSE;
        WGPUWaitStatus status = p_wgpuInstanceWaitAny(
            (WGPUInstance)instance,
            1,
            &waitInfo,
            timeoutNS
        );

        if (status != WGPUWaitStatus_Success || !waitInfo.completed) {
            result = 0;
            return;
        }

        void* mapped = nullptr;
        if (p_wgpuBufferGetConstMappedRange) {
            mapped = p_wgpuBufferGetConstMappedRange((WGPUBuffer)buffer, (size_t)offset, (size_t)size);
        }
        if (!mapped) {
            mapped = p_wgpuBufferGetMappedRange((WGPUBuffer)buffer, (size_t)offset, (size_t)size);
        }
        if (!mapped) {
            result = 0;
            return;
        }
        memcpy(dst, mapped, (size_t)size);
        p_wgpuBufferUnmap((WGPUBuffer)buffer);
        result = 1;
    });
    return result;
}

struct WGPUReadbackJob {
    std::atomic<int> done;
    std::atomic<int> ok;
    std::atomic<int> status;
    uint8_t* dst;
    size_t size;
    WGPUBuffer buffer;
    size_t offset;
};

static void wgpuReadbackCallback(
    WGPUMapAsyncStatus status,
    WGPUStringView /*message*/,
    void* userdata1,
    void* /*userdata2*/
) {
    WGPUReadbackJob* job = (WGPUReadbackJob*)userdata1;
    if (!job) return;
    if (status != WGPUMapAsyncStatus_Success) {
        job->ok.store(0);
        job->status.store(2);
        job->done.store(1);
        return;
    }
    void* mapped = nullptr;
    if (p_wgpuBufferGetConstMappedRange) {
        mapped = p_wgpuBufferGetConstMappedRange(job->buffer, job->offset, job->size);
    }
    if (!mapped) {
        mapped = p_wgpuBufferGetMappedRange(job->buffer, job->offset, job->size);
    }
    if (mapped && job->dst) {
        memcpy(job->dst, mapped, job->size);
        job->ok.store(1);
        job->status.store(1);
    } else {
        job->ok.store(0);
        job->status.store(3);
    }
    p_wgpuBufferUnmap(job->buffer);
    job->done.store(1);
}

extern "C" void* wgpuBufferReadbackBeginShim(
    void* buffer,
    uint64_t offset,
    uint64_t size,
    void* dst
) {
    if (!ensureWgpuSymbols()) return nullptr;
    if (!buffer || !dst || size == 0) return nullptr;

    WGPUReadbackJob* job = (WGPUReadbackJob*)malloc(sizeof(WGPUReadbackJob));
    if (!job) return nullptr;
    job->done.store(0);
    job->ok.store(0);
    job->status.store(0);
    job->dst = (uint8_t*)dst;
    job->size = (size_t)size;
    job->buffer = (WGPUBuffer)buffer;
    job->offset = (size_t)offset;

    WGPUBufferMapCallbackInfo mapInfo = {};
    mapInfo.mode = WGPUCallbackMode_AllowSpontaneous;
    mapInfo.callback = wgpuReadbackCallback;
    mapInfo.userdata1 = job;
    mapInfo.userdata2 = nullptr;

    p_wgpuBufferMapAsync(
        (WGPUBuffer)buffer,
        WGPUMapMode_Read,
        (size_t)offset,
        (size_t)size,
        mapInfo
    );

    return job;
}

extern "C" int32_t wgpuBufferReadbackStatusShim(void* jobPtr) {
    if (!jobPtr) return 2;
    WGPUReadbackJob* job = (WGPUReadbackJob*)jobPtr;
    if (job->done.load() == 0) return 0;
    return job->status.load();
}

extern "C" void wgpuBufferReadbackFreeShim(void* jobPtr) {
    if (!jobPtr) return;
    WGPUReadbackJob* job = (WGPUReadbackJob*)jobPtr;
    free(job);
}


// ----------------------- WGPU Native Test (macOS) -----------------------

typedef WGPUInstance (*PFN_wgpuCreateInstance)(WGPUInstanceDescriptor const* descriptor);
typedef WGPUFuture (*PFN_wgpuInstanceRequestAdapter)(WGPUInstance instance, WGPURequestAdapterOptions const* options, WGPURequestAdapterCallbackInfo callbackInfo);
typedef WGPUFuture (*PFN_wgpuAdapterRequestDevice)(WGPUAdapter adapter, WGPUDeviceDescriptor const* descriptor, WGPURequestDeviceCallbackInfo callbackInfo);
typedef WGPUQueue (*PFN_wgpuDeviceGetQueue)(WGPUDevice device);
typedef void (*PFN_wgpuSurfaceGetCapabilities)(WGPUSurface surface, WGPUAdapter adapter, WGPUSurfaceCapabilities* capabilities);
typedef void (*PFN_wgpuSurfaceCapabilitiesFreeMembers)(WGPUSurfaceCapabilities capabilities);
typedef WGPUShaderModule (*PFN_wgpuDeviceCreateShaderModule)(WGPUDevice device, WGPUShaderModuleDescriptor const* descriptor);
typedef WGPURenderPipeline (*PFN_wgpuDeviceCreateRenderPipeline)(WGPUDevice device, WGPURenderPipelineDescriptor const* descriptor);
typedef void (*PFN_wgpuDeviceSetLabel)(WGPUDevice device, WGPUStringView label);
typedef WGPUBuffer (*PFN_wgpuDeviceCreateBuffer)(WGPUDevice device, WGPUBufferDescriptor const* descriptor);
typedef void (*PFN_wgpuQueueWriteBuffer)(WGPUQueue queue, WGPUBuffer buffer, uint64_t bufferOffset, void const* data, size_t size);
typedef WGPUCommandEncoder (*PFN_wgpuDeviceCreateCommandEncoder)(WGPUDevice device, WGPUCommandEncoderDescriptor const* descriptor);
typedef WGPURenderPassEncoder (*PFN_wgpuCommandEncoderBeginRenderPass)(WGPUCommandEncoder encoder, WGPURenderPassDescriptor const* descriptor);
typedef void (*PFN_wgpuRenderPassEncoderSetPipeline)(WGPURenderPassEncoder pass, WGPURenderPipeline pipeline);
typedef void (*PFN_wgpuRenderPassEncoderSetVertexBuffer)(WGPURenderPassEncoder pass, uint32_t slot, WGPUBuffer buffer, uint64_t offset, uint64_t size);
typedef void (*PFN_wgpuRenderPassEncoderDraw)(WGPURenderPassEncoder pass, uint32_t vertexCount, uint32_t instanceCount, uint32_t firstVertex, uint32_t firstInstance);
typedef void (*PFN_wgpuRenderPassEncoderEnd)(WGPURenderPassEncoder pass);
typedef WGPUCommandBuffer (*PFN_wgpuCommandEncoderFinish)(WGPUCommandEncoder encoder, WGPUCommandBufferDescriptor const* descriptor);
typedef void (*PFN_wgpuQueueSubmit)(WGPUQueue queue, size_t commandCount, WGPUCommandBuffer const* commands);
typedef WGPUTextureView (*PFN_wgpuTextureCreateView)(WGPUTexture texture, WGPUTextureViewDescriptor const* descriptor);
typedef void (*PFN_wgpuTextureViewRelease)(WGPUTextureView view);
typedef void (*PFN_wgpuTextureRelease)(WGPUTexture texture);
typedef void (*PFN_wgpuCommandBufferRelease)(WGPUCommandBuffer buffer);
typedef void (*PFN_wgpuCommandEncoderRelease)(WGPUCommandEncoder encoder);

static PFN_wgpuCreateInstance p_wgpuCreateInstance = nullptr;
static PFN_wgpuInstanceRequestAdapter p_wgpuInstanceRequestAdapter = nullptr;
static PFN_wgpuAdapterRequestDevice p_wgpuAdapterRequestDevice = nullptr;
static PFN_wgpuDeviceGetQueue p_wgpuDeviceGetQueue = nullptr;
static PFN_wgpuSurfaceGetCapabilities p_wgpuSurfaceGetCapabilities = nullptr;
static PFN_wgpuSurfaceCapabilitiesFreeMembers p_wgpuSurfaceCapabilitiesFreeMembers = nullptr;
static PFN_wgpuDeviceCreateShaderModule p_wgpuDeviceCreateShaderModule = nullptr;
static PFN_wgpuDeviceCreateRenderPipeline p_wgpuDeviceCreateRenderPipeline = nullptr;
static PFN_wgpuDeviceSetLabel p_wgpuDeviceSetLabel = nullptr;
static PFN_wgpuDeviceCreateBuffer p_wgpuDeviceCreateBuffer = nullptr;
static PFN_wgpuQueueWriteBuffer p_wgpuQueueWriteBuffer = nullptr;
static PFN_wgpuDeviceCreateCommandEncoder p_wgpuDeviceCreateCommandEncoder = nullptr;
static PFN_wgpuCommandEncoderBeginRenderPass p_wgpuCommandEncoderBeginRenderPass = nullptr;
static PFN_wgpuRenderPassEncoderSetPipeline p_wgpuRenderPassEncoderSetPipeline = nullptr;
static PFN_wgpuRenderPassEncoderSetVertexBuffer p_wgpuRenderPassEncoderSetVertexBuffer = nullptr;
static PFN_wgpuRenderPassEncoderDraw p_wgpuRenderPassEncoderDraw = nullptr;
static PFN_wgpuRenderPassEncoderEnd p_wgpuRenderPassEncoderEnd = nullptr;
static PFN_wgpuCommandEncoderFinish p_wgpuCommandEncoderFinish = nullptr;
static PFN_wgpuQueueSubmit p_wgpuQueueSubmit = nullptr;
static PFN_wgpuTextureCreateView p_wgpuTextureCreateView = nullptr;
static PFN_wgpuTextureViewRelease p_wgpuTextureViewRelease = nullptr;
static PFN_wgpuTextureRelease p_wgpuTextureRelease = nullptr;
static PFN_wgpuCommandBufferRelease p_wgpuCommandBufferRelease = nullptr;
static PFN_wgpuCommandEncoderRelease p_wgpuCommandEncoderRelease = nullptr;

static void uncapturedErrorCallback(WGPUDevice const* device, WGPUErrorType type, WGPUStringView message, void* userdata1, void* userdata2);

static bool ensureWgpuTestSymbols() {
    if (!ensureWgpuSymbols()) return false;
    void* handle = loadWgpuLibrary();
    if (!handle) return false;
#define LOAD_SYM(name) \
    p_##name = (decltype(p_##name))dlsym(handle, #name); \
    if (!p_##name) { \
        NSLog(@"WGPU: missing symbol %s", #name); \
        return false; \
    }
    LOAD_SYM(wgpuCreateInstance);
    LOAD_SYM(wgpuInstanceRequestAdapter);
    LOAD_SYM(wgpuAdapterRequestDevice);
    LOAD_SYM(wgpuDeviceGetQueue);
    LOAD_SYM(wgpuSurfaceGetCapabilities);
    LOAD_SYM(wgpuSurfaceCapabilitiesFreeMembers);
    LOAD_SYM(wgpuDeviceCreateShaderModule);
    LOAD_SYM(wgpuDeviceCreateRenderPipeline);
    LOAD_SYM(wgpuDeviceSetLabel);
    LOAD_SYM(wgpuDeviceCreateBuffer);
    LOAD_SYM(wgpuQueueWriteBuffer);
    LOAD_SYM(wgpuDeviceCreateCommandEncoder);
    LOAD_SYM(wgpuCommandEncoderBeginRenderPass);
    LOAD_SYM(wgpuRenderPassEncoderSetPipeline);
    LOAD_SYM(wgpuRenderPassEncoderSetVertexBuffer);
    LOAD_SYM(wgpuRenderPassEncoderDraw);
    LOAD_SYM(wgpuRenderPassEncoderEnd);
    LOAD_SYM(wgpuCommandEncoderFinish);
    LOAD_SYM(wgpuQueueSubmit);
    LOAD_SYM(wgpuTextureCreateView);
    LOAD_SYM(wgpuTextureViewRelease);
    LOAD_SYM(wgpuTextureRelease);
    LOAD_SYM(wgpuCommandBufferRelease);
    LOAD_SYM(wgpuCommandEncoderRelease);
#undef LOAD_SYM
    return true;
}

extern "C" void wgpuCreateAdapterDeviceMainThread(void* instancePtr, void* surfacePtr, void* outAdapterDevice) {
    if (!ensureWgpuTestSymbols()) return;
    runOnMainThreadSyncVoid(^{
        WGPUInstance instance = (WGPUInstance)instancePtr;
        WGPUSurface surface = (WGPUSurface)surfacePtr;

        __block WGPUAdapter adapter = nullptr;
        __block WGPUDevice device = nullptr;

        dispatch_semaphore_t adapterSem = dispatch_semaphore_create(0);
        dispatch_semaphore_t deviceSem = dispatch_semaphore_create(0);

        WGPURequestAdapterOptions opts = {};
        opts.compatibleSurface = surface;
        WGPURequestAdapterCallbackInfo adapterInfo = {};
        adapterInfo.mode = WGPUCallbackMode_AllowSpontaneous;
        adapterInfo.callback = [](WGPURequestAdapterStatus status, WGPUAdapter cbAdapter, WGPUStringView message, void* userdata1, void* userdata2) {
            (void)message;
            (void)userdata2;
            struct {
                WGPUAdapter* adapter;
                dispatch_semaphore_t sem;
            }* ctx = (decltype(ctx))userdata1;
            if (status == WGPURequestAdapterStatus_Success) {
                *(ctx->adapter) = cbAdapter;
            }
            dispatch_semaphore_signal(ctx->sem);
        };
        struct {
            WGPUAdapter* adapter;
            dispatch_semaphore_t sem;
        } adapterCtx = { &adapter, adapterSem };
        adapterInfo.userdata1 = &adapterCtx;
        p_wgpuInstanceRequestAdapter(instance, &opts, adapterInfo);

        dispatch_semaphore_wait(adapterSem, DISPATCH_TIME_FOREVER);
        if (!adapter) {
            return;
        }

        WGPURequestDeviceCallbackInfo deviceInfo = {};
        deviceInfo.mode = WGPUCallbackMode_AllowSpontaneous;
        deviceInfo.callback = [](WGPURequestDeviceStatus status, WGPUDevice cbDevice, WGPUStringView message, void* userdata1, void* userdata2) {
            (void)message;
            (void)userdata2;
            struct {
                WGPUDevice* device;
                dispatch_semaphore_t sem;
            }* ctx = (decltype(ctx))userdata1;
            if (status == WGPURequestDeviceStatus_Success) {
                *(ctx->device) = cbDevice;
            }
            dispatch_semaphore_signal(ctx->sem);
        };
        struct {
            WGPUDevice* device;
            dispatch_semaphore_t sem;
        } deviceCtx = { &device, deviceSem };
        deviceInfo.userdata1 = &deviceCtx;
        WGPUDeviceDescriptor deviceDesc = {};
        deviceDesc.uncapturedErrorCallbackInfo.callback = uncapturedErrorCallback;
        deviceDesc.uncapturedErrorCallbackInfo.userdata1 = &deviceCtx;
        p_wgpuAdapterRequestDevice(adapter, &deviceDesc, deviceInfo);

        dispatch_semaphore_wait(deviceSem, DISPATCH_TIME_FOREVER);

        if (outAdapterDevice) {
            uint64_t* out = (uint64_t*)outAdapterDevice;
            out[0] = (uint64_t)adapter;
            out[1] = (uint64_t)device;
        }
    });
}

struct GPUTestState {
    WGPUInstance instance = nullptr;
    WGPUSurface surface = nullptr;
    WGPUAdapter adapter = nullptr;
    WGPUDevice device = nullptr;
    WGPUQueue queue = nullptr;
    WGPURenderPipeline pipeline = nullptr;
    WGPUBuffer vertexBuffer = nullptr;
    WGPUTextureFormat surfaceFormat = WGPUTextureFormat_BGRA8UnormSrgb;
    WGPUCompositeAlphaMode alphaMode = WGPUCompositeAlphaMode_Opaque;
    CAMetalLayer* layer = nil;
    dispatch_source_t timer = nullptr;
    float angle = 0.0f;
    CGSize lastDrawable = {0, 0};
    bool running = false;
};

static GPUTestState g_gpuTest;

static const float kCubeVertices[] = {
    // front
    -0.5f,-0.5f, 0.5f,  0.5f,-0.5f, 0.5f,  0.5f, 0.5f, 0.5f,
    -0.5f,-0.5f, 0.5f,  0.5f, 0.5f, 0.5f, -0.5f, 0.5f, 0.5f,
    // back
    -0.5f,-0.5f,-0.5f, -0.5f, 0.5f,-0.5f,  0.5f, 0.5f,-0.5f,
    -0.5f,-0.5f,-0.5f,  0.5f, 0.5f,-0.5f,  0.5f,-0.5f,-0.5f,
    // left
    -0.5f,-0.5f,-0.5f, -0.5f,-0.5f, 0.5f, -0.5f, 0.5f, 0.5f,
    -0.5f,-0.5f,-0.5f, -0.5f, 0.5f, 0.5f, -0.5f, 0.5f,-0.5f,
    // right
     0.5f,-0.5f,-0.5f,  0.5f, 0.5f,-0.5f,  0.5f, 0.5f, 0.5f,
     0.5f,-0.5f,-0.5f,  0.5f, 0.5f, 0.5f,  0.5f,-0.5f, 0.5f,
    // top
    -0.5f, 0.5f,-0.5f, -0.5f, 0.5f, 0.5f,  0.5f, 0.5f, 0.5f,
    -0.5f, 0.5f,-0.5f,  0.5f, 0.5f, 0.5f,  0.5f, 0.5f,-0.5f,
    // bottom
    -0.5f,-0.5f,-0.5f,  0.5f,-0.5f,-0.5f,  0.5f,-0.5f, 0.5f,
    -0.5f,-0.5f,-0.5f,  0.5f,-0.5f, 0.5f, -0.5f,-0.5f, 0.5f,
};

static void buildRotatedVertices(float angle, float* out, size_t count) {
    const float sinY = sinf(angle);
    const float cosY = cosf(angle);
    const float sinX = sinf(angle * 0.7f);
    const float cosX = cosf(angle * 0.7f);
    for (size_t i = 0; i < count; i += 3) {
        float x = kCubeVertices[i];
        float y = kCubeVertices[i + 1];
        float z = kCubeVertices[i + 2];
        float x1 = x * cosY + z * sinY;
        float z1 = -x * sinY + z * cosY;
        float y1 = y * cosX - z1 * sinX;
        float z2 = y * sinX + z1 * cosX;
        float depth = z2 + 2.5f;
        float proj = 1.2f / depth;
        out[i] = x1 * proj;
        out[i + 1] = y1 * proj;
        out[i + 2] = 0.0f;
    }
}

static void configureSurface(GPUTestState* state) {
    if (!state->surface || !state->device || !state->layer) return;
    WGPUSurfaceCapabilities caps = {};
    p_wgpuSurfaceGetCapabilities(state->surface, state->adapter, &caps);
    if (caps.formatCount > 0 && caps.formats) {
        state->surfaceFormat = caps.formats[0];
    }
    if (caps.alphaModeCount > 0 && caps.alphaModes) {
        state->alphaMode = caps.alphaModes[0];
    }
    p_wgpuSurfaceCapabilitiesFreeMembers(caps);

    CGSize drawable = state->layer.drawableSize;
    state->lastDrawable = drawable;

    WGPUSurfaceConfiguration config = {};
    config.device = state->device;
    config.format = state->surfaceFormat;
    config.usage = WGPUTextureUsage_RenderAttachment;
    config.width = (uint32_t)drawable.width;
    config.height = (uint32_t)drawable.height;
    config.presentMode = WGPUPresentMode_Fifo;
    config.alphaMode = state->alphaMode;
    p_wgpuSurfaceConfigure(state->surface, &config);
}

static void setupPipeline(GPUTestState* state) {
    if (!state->device) return;
    const char* shaderSrc = R"WGSL(
struct VSOut {
  @builtin(position) position : vec4<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>) -> VSOut {
  var out: VSOut;
  out.position = vec4<f32>(position, 1.0);
  return out;
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
  return vec4<f32>(0.1, 0.9, 0.4, 1.0);
}
)WGSL";

    WGPUShaderSourceWGSL wgsl = {};
    wgsl.chain.sType = WGPUSType_ShaderSourceWGSL;
    wgsl.code.data = shaderSrc;
    wgsl.code.length = WGPU_STRLEN;

    WGPUShaderModuleDescriptor shaderDesc = {};
    shaderDesc.nextInChain = reinterpret_cast<WGPUChainedStruct*>(&wgsl);

    WGPUShaderModule shader = p_wgpuDeviceCreateShaderModule(state->device, &shaderDesc);
    if (!shader) {
        NSLog(@"WGPU test: failed to create shader module");
    }

    WGPUStringView vsEntry = { "vs_main", WGPU_STRLEN };
    WGPUStringView fsEntry = { "fs_main", WGPU_STRLEN };

    WGPUVertexAttribute attr = {};
    attr.format = WGPUVertexFormat_Float32x3;
    attr.offset = 0;
    attr.shaderLocation = 0;

    WGPUVertexBufferLayout vbuf = {};
    vbuf.arrayStride = sizeof(float) * 3;
    vbuf.attributeCount = 1;
    vbuf.attributes = &attr;
    vbuf.stepMode = WGPUVertexStepMode_Vertex;

    WGPUVertexState vstate = {};
    vstate.module = shader;
    vstate.entryPoint = vsEntry;
    vstate.bufferCount = 1;
    vstate.buffers = &vbuf;

    WGPUColorTargetState colorTarget = {};
    colorTarget.format = state->surfaceFormat;
    colorTarget.writeMask = WGPUColorWriteMask_All;

    WGPUFragmentState fstate = {};
    fstate.module = shader;
    fstate.entryPoint = fsEntry;
    fstate.targetCount = 1;
    fstate.targets = &colorTarget;

    WGPUPrimitiveState prim = {};
    prim.topology = WGPUPrimitiveTopology_TriangleList;
    prim.stripIndexFormat = WGPUIndexFormat_Undefined;
    prim.frontFace = WGPUFrontFace_CCW;
    prim.cullMode = WGPUCullMode_None;
    prim.unclippedDepth = false;

    WGPUMultisampleState ms = {};
    ms.count = 1;
    ms.mask = 0xFFFFFFFF;
    ms.alphaToCoverageEnabled = false;

    WGPURenderPipelineDescriptor rpDesc = {};
    rpDesc.vertex = vstate;
    rpDesc.primitive = prim;
    rpDesc.multisample = ms;
    rpDesc.fragment = &fstate;

    state->pipeline = p_wgpuDeviceCreateRenderPipeline(state->device, &rpDesc);
    if (!state->pipeline) {
        NSLog(@"WGPU test: failed to create render pipeline");
    }

    WGPUBufferDescriptor bufDesc = {};
    bufDesc.usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst;
    bufDesc.size = sizeof(kCubeVertices);
    bufDesc.mappedAtCreation = false;
    state->vertexBuffer = p_wgpuDeviceCreateBuffer(state->device, &bufDesc);

    float initialVerts[sizeof(kCubeVertices) / sizeof(float)];
    buildRotatedVertices(0.0f, initialVerts, sizeof(kCubeVertices) / sizeof(float));
    p_wgpuQueueWriteBuffer(state->queue, state->vertexBuffer, 0, initialVerts, sizeof(initialVerts));
}

static void renderFrame(GPUTestState* state) {
    if (!state->device || !state->surface || !state->queue) return;
    if (!state->layer) return;
    if (!state->pipeline) return;

    CGSize drawable = state->layer.drawableSize;
    if (drawable.width <= 1 || drawable.height <= 1) return;
    if (drawable.width != state->lastDrawable.width || drawable.height != state->lastDrawable.height) {
        configureSurface(state);
    }

    state->angle += 0.02f;
    float verts[sizeof(kCubeVertices) / sizeof(float)];
    buildRotatedVertices(state->angle, verts, sizeof(kCubeVertices) / sizeof(float));
    p_wgpuQueueWriteBuffer(state->queue, state->vertexBuffer, 0, verts, sizeof(verts));

    static bool loggedDrawable = false;
    if (!loggedDrawable && wgpuDebugEnabled()) {
        id<CAMetalDrawable> drawable = [state->layer nextDrawable];
        if (drawable) {
            NSLog(@"WGPU test: CAMetalLayer nextDrawable OK");
        } else {
            NSLog(@"WGPU test: CAMetalLayer nextDrawable is NULL");
        }
        loggedDrawable = true;
    }

    WGPUSurfaceTexture surfaceTexture = {};
    p_wgpuSurfaceGetCurrentTexture(state->surface, &surfaceTexture);
    if (surfaceTexture.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal &&
        surfaceTexture.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
        return;
    }
    if (!surfaceTexture.texture) return;

    WGPUTextureView view = p_wgpuTextureCreateView(surfaceTexture.texture, nullptr);

    WGPURenderPassColorAttachment colorAtt = {};
    colorAtt.view = view;
    colorAtt.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
    colorAtt.loadOp = WGPULoadOp_Clear;
    colorAtt.storeOp = WGPUStoreOp_Store;
    colorAtt.clearValue = {0.05, 0.05, 0.1, 1.0};

    WGPURenderPassDescriptor passDesc = {};
    passDesc.colorAttachmentCount = 1;
    passDesc.colorAttachments = &colorAtt;

    WGPUCommandEncoder encoder = p_wgpuDeviceCreateCommandEncoder(state->device, nullptr);
    WGPURenderPassEncoder pass = p_wgpuCommandEncoderBeginRenderPass(encoder, &passDesc);
    p_wgpuRenderPassEncoderSetPipeline(pass, state->pipeline);
    p_wgpuRenderPassEncoderSetVertexBuffer(pass, 0, state->vertexBuffer, 0, sizeof(kCubeVertices));
    p_wgpuRenderPassEncoderDraw(pass, (uint32_t)(sizeof(kCubeVertices) / (sizeof(float) * 3)), 1, 0, 0);
    p_wgpuRenderPassEncoderEnd(pass);

    WGPUCommandBuffer cmd = p_wgpuCommandEncoderFinish(encoder, nullptr);
    p_wgpuQueueSubmit(state->queue, 1, &cmd);
    p_wgpuSurfacePresent(state->surface);

    p_wgpuTextureViewRelease(view);
    p_wgpuTextureRelease(surfaceTexture.texture);
    p_wgpuCommandBufferRelease(cmd);
    p_wgpuCommandEncoderRelease(encoder);
}

static void requestDeviceCallback(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message, void* userdata1, void* userdata2);

static void logStringView(const char* prefix, WGPUStringView view) {
    if (!view.data) {
        NSLog(@"%s (null)", prefix);
        return;
    }
    size_t len = view.length == WGPU_STRLEN ? strlen(view.data) : (size_t)view.length;
    std::string msg(view.data, view.data + len);
    NSLog(@"%s %s", prefix, msg.c_str());
}

static void uncapturedErrorCallback(WGPUDevice const* device, WGPUErrorType type, WGPUStringView message, void* userdata1, void* userdata2) {
    (void)device;
    (void)userdata1;
    (void)userdata2;
    char buf[64];
    snprintf(buf, sizeof(buf), "WGPU uncaptured error type=%d:", (int)type);
    logStringView(buf, message);
}

static void requestAdapterCallback(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView message, void* userdata1, void* userdata2) {
    if (status != WGPURequestAdapterStatus_Success) {
        logStringView("WGPU test: adapter error:", message);
    }
    (void)userdata2;
    GPUTestState* state = (GPUTestState*)userdata1;
    if (!state || status != WGPURequestAdapterStatus_Success || !adapter) {
        NSLog(@"WGPU test: adapter request failed (%d)", status);
        return;
    }
    state->adapter = adapter;
    WGPURequestDeviceCallbackInfo cbInfo = {};
    cbInfo.mode = WGPUCallbackMode_AllowSpontaneous;
    cbInfo.callback = requestDeviceCallback;
    cbInfo.userdata1 = state;
    WGPUDeviceDescriptor deviceDesc = {};
    deviceDesc.uncapturedErrorCallbackInfo.callback = uncapturedErrorCallback;
    deviceDesc.uncapturedErrorCallbackInfo.userdata1 = state;
    p_wgpuAdapterRequestDevice(adapter, &deviceDesc, cbInfo);
}

static void requestDeviceCallback(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView message, void* userdata1, void* userdata2) {
    if (status != WGPURequestDeviceStatus_Success) {
        logStringView("WGPU test: device error:", message);
    }
    (void)userdata2;
    GPUTestState* state = (GPUTestState*)userdata1;
    if (!state || status != WGPURequestDeviceStatus_Success || !device) {
        NSLog(@"WGPU test: device request failed (%d)", status);
        return;
    }
    state->device = device;
    if (p_wgpuDeviceSetLabel) {
        WGPUStringView label = { "Electrobun WGPU Device", WGPU_STRLEN };
        p_wgpuDeviceSetLabel(device, label);
    }
    state->queue = p_wgpuDeviceGetQueue(device);
    configureSurface(state);
    setupPipeline(state);

    if (state->timer) {
        dispatch_source_cancel(state->timer);
        state->timer = nullptr;
    }
    state->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(state->timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(16 * NSEC_PER_MSEC), (uint64_t)(1 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(state->timer, ^{
        renderFrame(state);
    });
    dispatch_resume(state->timer);
}

extern "C" void wgpuRunGPUTest(AbstractView* abstractView) {
    if (!abstractView) return;
    if (!ensureWgpuTestSymbols()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSView* nsView = [abstractView nsView];
        if (!nsView || ![nsView.layer isKindOfClass:[CAMetalLayer class]]) {
            NSLog(@"WGPU test: no CAMetalLayer found");
            return;
        }
        CAMetalLayer* layer = (CAMetalLayer*)nsView.layer;
        g_gpuTest.layer = layer;
        if (!g_gpuTest.instance) {
            g_gpuTest.instance = p_wgpuCreateInstance(nullptr);
        }
        if (!g_gpuTest.instance) {
            NSLog(@"WGPU test: failed to create instance");
            return;
        }
        WGPUSurfaceSourceMetalLayer metalSource = {};
        metalSource.chain.sType = WGPUSType_SurfaceSourceMetalLayer;
        metalSource.layer = (__bridge void*)layer;
        WGPUSurfaceDescriptor surfaceDesc = {};
        surfaceDesc.nextInChain = reinterpret_cast<WGPUChainedStruct*>(&metalSource);
        g_gpuTest.surface = (WGPUSurface)p_wgpuInstanceCreateSurface(g_gpuTest.instance, &surfaceDesc);
        if (!g_gpuTest.surface) {
            NSLog(@"WGPU test: failed to create surface");
            return;
        }
        WGPURequestAdapterOptions opts = {};
        opts.compatibleSurface = g_gpuTest.surface;
        WGPURequestAdapterCallbackInfo cbInfo = {};
        cbInfo.mode = WGPUCallbackMode_AllowSpontaneous;
        cbInfo.callback = requestAdapterCallback;
        cbInfo.userdata1 = &g_gpuTest;
        p_wgpuInstanceRequestAdapter(g_gpuTest.instance, &opts, cbInfo);
    });
}

// ----------------------- CEF and NSApplication Setup (C++ and ObjC) -----------------------

static BOOL isViewDescendantOfView(NSView *view, NSView *ancestor) {
    for (NSView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if (candidate == ancestor) return YES;
    }
    return NO;
}

static BOOL shouldSuppressNativeContextClick(NSEvent *event) {
    NSEventType type = event.type;
    BOOL isRightClick =
        type == NSEventTypeRightMouseDown ||
        type == NSEventTypeRightMouseUp;
    BOOL isControlClick =
        (type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseUp) &&
        ((event.modifierFlags & NSEventModifierFlagControl) != 0);

    if (!isRightClick && !isControlClick) return NO;
    if (!globalAbstractViews) return NO;

    NSWindow *window = event.window;
    NSView *contentView = window.contentView;
    if (!contentView) return NO;

    NSPoint pointInContent = [contentView convertPoint:event.locationInWindow fromView:nil];
    NSView *targetView = [contentView hitTest:pointInContent];
    if (!targetView) return NO;

    for (AbstractView *abstractView in [globalAbstractViews allValues]) {
        if (abstractView.isSandboxed) continue;
        NSView *webview = abstractView.nsView;
        if (webview && isViewDescendantOfView(targetView, webview)) {
            return YES;
        }
    }

    return NO;
}

@implementation ElectrobunNSApplication
    - (BOOL)isHandlingSendEvent {
        return handlingSendEvent_;
    }
    - (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
        handlingSendEvent_ = handlingSendEvent;
    }
    - (void)sendEvent:(NSEvent*)event {
        if (shouldSuppressNativeContextClick(event)) {
            return;
        }

        CefScopedSendingEvent sendingEventScoper;
        [super sendEvent:event];
    }
@end



@implementation StatusItemTarget
    - (void)statusItemClicked:(id)sender {
        if (self.zigHandler) {                    
            self.zigHandler(self.trayId, "");                        
        }
    }
    - (void)menuItemClicked:(id)sender {
        NSMenuItem *menuItem = (NSMenuItem *)sender;
        NSString *action = menuItem.representedObject;
        if (!action) {
            NSLog(@"No action found for menu item");
            return;
        }
        if (!self.zigHandler) {
            NSLog(@"No zig handler found for menu item");
            return;
        }
        self.zigHandler(self.trayId, [action UTF8String]);
    }
@end


// C++ classes for CEF:


class ElectrobunHandler : public CefClient,
                         public CefDisplayHandler,
                         public CefLifeSpanHandler,
                         public CefLoadHandler {
public:
    static ElectrobunHandler* GetInstance() {
        return g_instance;
    }
    ElectrobunHandler() {
        DCHECK(!g_instance);
        g_instance = this;
    }
    ~ElectrobunHandler() {
        g_instance = nullptr;
    }

    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        browser_list_.push_back(browser);
    }
    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        if (browser_list_.size() == 1) {
            is_closing_ = true;
        }
        return false;
    }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        CEF_REQUIRE_UI_THREAD();
        for (auto bit = browser_list_.begin(); bit != browser_list_.end(); ++bit) {
            if ((*bit)->IsSame(browser)) {
                browser_list_.erase(bit);
                break;
            }
        }
        if (browser_list_.empty()) {
            CefQuitMessageLoop();
        }
    }

private:
    static ElectrobunHandler* g_instance;
    typedef std::list<CefRefPtr<CefBrowser>> BrowserList;
    BrowserList browser_list_;
    bool is_closing_ = false;

    IMPLEMENT_REFCOUNTING(ElectrobunHandler);
    DISALLOW_COPY_AND_ASSIGN(ElectrobunHandler);
};

ElectrobunHandler* ElectrobunHandler::g_instance = nullptr;

electrobun::ChromiumFlagConfig g_userChromiumFlags;

class ElectrobunApp : public CefApp,
                     public CefBrowserProcessHandler,
                     public CefRenderProcessHandler {
public:
    ElectrobunApp() {
        
    }
    void OnBeforeCommandLineProcessing(const CefString& process_type, CefRefPtr<CefCommandLine> command_line) override {
        command_line->AppendSwitchWithValue("custom-scheme", "views");

        // macOS default flags — can be overridden via chromiumFlags in config
        static const std::vector<electrobun::DefaultFlag> defaults = {
            {"use-mock-keychain", ""},
            {"enable-features=PictureInPicture", ""},
            {"enable-fullscreen", ""},
            {"remote-allow-origins", "*"},
            {"allow-insecure-localhost", ""},
        };
        electrobun::applyDefaultFlags(defaults, g_userChromiumFlags.skip, command_line);

        // Apply user-defined chromium flags from build.json
        electrobun::applyChromiumFlags(g_userChromiumFlags, command_line);
    }
    void OnRegisterCustomSchemes(CefRawPtr<CefSchemeRegistrar> registrar) override {        
        registrar->AddCustomScheme("views", 
            CEF_SCHEME_OPTION_STANDARD | 
            CEF_SCHEME_OPTION_CORS_ENABLED |
            CEF_SCHEME_OPTION_SECURE | // treat it like https
            CEF_SCHEME_OPTION_CSP_BYPASSING | // allow things like crypto.subtle
            CEF_SCHEME_OPTION_FETCH_ENABLED);
            
    }
    
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {        
        return this;
    }
    virtual void OnBeforeChildProcessLaunch(CefRefPtr<CefCommandLine> command_line) override {        
        std::vector<CefString> args;
        command_line->GetArguments(args); 

        // Log the CEF process_helper path
        // NSLog(@"CEF helper process path: %s", command_line->GetProgram().ToString().c_str());
        
        // Prevent CEF helper processes from appearing in dock
        command_line->AppendSwitch("disable-background-mode");
        command_line->AppendSwitch("disable-backgrounding-occluded-windows");            
    }
    void OnContextInitialized() override {
        // Register the scheme handler factory after context is initialized
        CefRefPtr<CefCommandLine> command_line = CefCommandLine::GetGlobalCommandLine();
        // if (command_line.get() && command_line->HasSwitch("type")) {
        //     // Skip registration in non-browser processes
        //     return;
        // }
        
        // The actual factory registration will happen in getOrCreateRequestContext()
        // CefRegisterSchemeHandlerFactory("views", "", nullptr);
    }
    CefRefPtr<CefClient> GetDefaultClient() override {
        return ElectrobunHandler::GetInstance();
    }

private:
    IMPLEMENT_REFCOUNTING(ElectrobunApp);
    DISALLOW_COPY_AND_ASSIGN(ElectrobunApp);
};

// PreloadScript struct is now defined in shared/preload_script.h

class ElectrobunResponseFilter : public CefResponseFilter {
private:
    std::string buffer_;
    bool has_head_;
    bool injected_;
    PreloadScript electrobun_script_;
    PreloadScript custom_script_;

public:
    ElectrobunResponseFilter(const PreloadScript& electrobunScript, 
                           const PreloadScript& customScript)
        : has_head_(false), 
          injected_(false),
          electrobun_script_(electrobunScript),
          custom_script_(customScript) {}
    
    virtual FilterStatus Filter(void* data_in,
                               size_t data_in_size,
                               size_t& data_in_read,
                               void* data_out,
                               size_t data_out_size,
                               size_t& data_out_written) override {

        // Check if we have scripts to inject
        if (electrobun_script_.code.empty() && custom_script_.code.empty()) {
            // Nothing to inject, just copy the data
            size_t copy_size = std::min(data_in_size, data_out_size);
            memcpy(data_out, data_in, copy_size);
            data_in_read = copy_size;
            data_out_written = copy_size;
            return RESPONSE_FILTER_DONE;
        }

        
        // Append the new data to our buffer
        if (data_in_size > 0) {
            buffer_.append(static_cast<char*>(data_in), data_in_size);
            data_in_read = data_in_size;
        } else {
            data_in_read = 0;
        }
        
        // Check if we've already injected our scripts
        if (injected_) {
            // Just copy data from our buffer to the output
            size_t copy_size = std::min(buffer_.size(), data_out_size);
            memcpy(data_out, buffer_.c_str(), copy_size);
            buffer_.erase(0, copy_size);
            data_out_written = copy_size;
            
            return buffer_.empty() ? RESPONSE_FILTER_DONE : RESPONSE_FILTER_NEED_MORE_DATA;
        }
        
        // Look for <head> tag if we haven't found it yet
        if (!has_head_) {
            size_t head_pos = buffer_.find("<head>");
            if (head_pos != std::string::npos) {
                has_head_ = true;
                
                // Inject our scripts after the <head> tag
                std::string scripts = "<script>\n";
                scripts += electrobun_script_.code;
                scripts += "\n</script>\n";
                
                if (!custom_script_.code.empty()) {
                    scripts += "<script>\n";
                    scripts += custom_script_.code;
                    scripts += "\n</script>\n";
                }
                
                buffer_.insert(head_pos + 6, scripts);  // Insert after <head>
                injected_ = true;
            }
        }
        
        // If we still haven't found <head> but the buffer is getting large,
        // we should check for <html> or just inject at the beginning
        if (!has_head_ && buffer_.size() > 1024) {
            size_t html_pos = buffer_.find("<html>");
            if (html_pos != std::string::npos) {
                // Inject after <html> tag
                std::string scripts = "<head>\n<script>\n";
                scripts += electrobun_script_.code;
                scripts += "\n</script>\n";
                
                if (!custom_script_.code.empty() ) {
                    scripts += "<script>\n";
                    scripts += custom_script_.code;
                    scripts += "\n</script>\n";
                }
                
                scripts += "</head>\n";
                
                buffer_.insert(html_pos + 6, scripts);  // Insert after <html>
            } else {
                // As a last resort, inject at the beginning
                std::string scripts = "<script>\n";
                scripts += electrobun_script_.code;
                scripts += "\n</script>\n";
                
                if (!custom_script_.code.empty() ) {
                    scripts += "<script>\n";
                    scripts += custom_script_.code;
                    scripts += "\n</script>\n";
                }
                
                buffer_.insert(0, scripts);
            }
            
            injected_ = true;
        }

        // Copy data from our buffer to the output
        size_t copy_size = std::min(buffer_.size(), data_out_size);
        memcpy(data_out, buffer_.c_str(), copy_size);
        buffer_.erase(0, copy_size);
        data_out_written = copy_size;
        
        return buffer_.empty() ? RESPONSE_FILTER_DONE : RESPONSE_FILTER_NEED_MORE_DATA;
    }

    virtual bool InitFilter() override {
        // Initialize any resources needed for filtering
        buffer_.clear();
        has_head_ = false;
        injected_ = false;
        return true;
    }
    
    IMPLEMENT_REFCOUNTING(ElectrobunResponseFilter);
};

CefRefPtr<ElectrobunApp> g_app;

class ElectrobunClient : public CefClient,
                        public CefRenderHandler,
                        public CefLoadHandler,
                        public CefRequestHandler,
                        public CefContextMenuHandler,
                        public CefKeyboardHandler,
                        public CefResourceRequestHandler,
                        public CefPermissionHandler,
                        public CefDisplayHandler,
                        public CefLifeSpanHandler,
                        public CefDownloadHandler  {
private:
    uint32_t webview_id_;
    HandlePostMessage event_bridge_handler_;
    HandlePostMessage bun_bridge_handler_;
    HandlePostMessage webview_tag_handler_;
    WebviewEventHandler webview_event_handler_;
    DecideNavigationCallback navigation_callback_;
    bool is_sandboxed_;

    // OSR (Off-Screen Rendering) support
    CEFOSRView* osr_view_ = nullptr;
    int view_width_ = 800;
    int view_height_ = 600;
    bool osr_enabled_ = false;

    PreloadScript electrobun_script_;
    PreloadScript custom_script_;
    static const int MENU_ID_DEV_TOOLS = 1;

    // Track download paths by download ID
    std::map<uint32_t, std::string> download_paths_; 

    struct DevToolsHost {
        NSWindow* window = nil;
        CefRefPtr<CefBrowser> browser;
        CefRefPtr<RemoteDevToolsClient> client;
        RemoteDevToolsWindowDelegate* delegate = nil;
        bool is_open = false;
    };

    std::map<int, DevToolsHost> devtools_hosts_;
    std::string last_title_;

     // Helper function to escape JavaScript code for embedding in a string
    std::string EscapeJavaScriptString(const std::string& input) {
        std::string result;
        result.reserve(input.size() * 2);  // Reserve space to avoid multiple allocations
        
        for (char c : input) {
            switch (c) {
                case '\\': result += "\\\\"; break;
                case '\'': result += "\\\'"; break;
                case '\"': result += "\\\""; break;
                case '\n': result += "\\n"; break;
                case '\r': result += "\\r"; break;
                case '\t': result += "\\t"; break;
                case '\b': result += "\\b"; break;
                case '\f': result += "\\f"; break;
                default:
                    if (c < 32 || c > 126) {
                        // Convert non-printable characters to Unicode escape sequences
                        char buf[7];
                        snprintf(buf, sizeof(buf), "\\u%04x", (unsigned char)c);
                        result += buf;
                    } else {
                        result += c;
                    }
            }
        }
        
        return result;
    }

    std::vector<std::shared_ptr<const char>> messageStrings_;

    void ShowDevToolsWindow(CefRefPtr<CefBrowser> browser, const CefPoint& inspect_at) {
        if (!browser || !browser->GetHost()) {
            return;
        }

        CefWindowInfo windowInfo;
        CefBrowserSettings settings;
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

        CefWindowHandle parent = browser->GetHost()->GetWindowHandle();
        if (parent) {
            NSView* parentView = (__bridge NSView*)parent;
            NSRect bounds = [parentView bounds];
            CefRect devtools_rect(0, 0, (int)bounds.size.width, (int)bounds.size.height);
            windowInfo.SetAsChild(parent, devtools_rect);
        } else {
            CefRect devtools_rect(0, 0, 900, 700);
            windowInfo.SetAsChild(nullptr, devtools_rect);
        }

        browser->GetHost()->ShowDevTools(windowInfo, nullptr, settings, inspect_at);
    }

    void CreateRemoteDevToolsWindow(int target_id, const std::string& url) {
        DevToolsHost& host = devtools_hosts_[target_id];

        if (!host.window) {
            NSRect frame = NSMakeRect(120, 120, 1100, 800);
            NSWindowStyleMask style = NSWindowStyleMaskTitled |
                                      NSWindowStyleMaskClosable |
                                      NSWindowStyleMaskResizable |
                                      NSWindowStyleMaskMiniaturizable;
            host.window = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:style
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
            [host.window setTitle:@"DevTools"];

            host.delegate = [[RemoteDevToolsWindowDelegate alloc] init];
            host.delegate->callback = RemoteDevToolsClosed;
            host.delegate->ctx = this;
            host.delegate->target_id = target_id;
            [host.window setDelegate:host.delegate];
        }

        [host.window makeKeyAndOrderFront:nil];
        host.is_open = true;

        if (!host.client) {
            host.client = new RemoteDevToolsClient(RemoteDevToolsClosed, this, target_id);
        }

        if (host.browser) {
            host.browser->GetMainFrame()->LoadURL(CefString(url));
            return;
        }

        NSView* contentView = [host.window contentView];
        NSRect bounds = [contentView bounds];
        CefRect devtools_rect(0, 0, (int)bounds.size.width, (int)bounds.size.height);

        CefWindowInfo windowInfo;
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        windowInfo.SetAsChild((__bridge void*)contentView, devtools_rect);

        CefBrowserSettings settings;
        host.browser = CefBrowserHost::CreateBrowserSync(
            windowInfo,
            host.client,
            CefString(url),
            settings,
            nullptr,
            nullptr);
        host.is_open = true;
    }

    void OpenRemoteDevToolsFrontend(CefRefPtr<CefBrowser> browser) {
        int target_id = static_cast<int>(webview_id_);
        std::string targetUrl;
        if (browser && browser->GetMainFrame()) {
            targetUrl = browser->GetMainFrame()->GetURL().ToString();
        }

        NSString* targetUrlNs = targetUrl.empty() ? nil : [NSString stringWithUTF8String:targetUrl.c_str()];

        NSString* baseUrl = [NSString stringWithFormat:@"http://127.0.0.1:%d", g_remoteDebugPort];
        NSURL* url = [NSURL URLWithString:[baseUrl stringByAppendingString:@"/json"]];
        NSURLSessionDataTask* task = [[NSURLSession sharedSession]
            dataTaskWithURL:url
          completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
            if (error || !data) {
                NSLog(@"[CEF] Remote DevTools: failed to fetch JSON: %@", error);
                return;
            }

            NSError* jsonError = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError || ![json isKindOfClass:[NSArray class]]) {
                NSLog(@"[CEF] Remote DevTools: invalid JSON");
                return;
            }

            NSArray* items = (NSArray*)json;
            if ([items count] == 0) {
                NSLog(@"[CEF] Remote DevTools: no targets");
                return;
            }

            NSDictionary* selected = nil;
            NSString* targetTitleNs = nil;
            if (!last_title_.empty()) {
                targetTitleNs = [NSString stringWithUTF8String:last_title_.c_str()];
            }

            if (targetUrlNs || targetTitleNs) {
                for (NSDictionary* item in items) {
                    NSString* itemUrl = item[@"url"];
                    NSString* itemTitle = item[@"title"];

                    bool urlMatch = false;
                    bool titleMatch = false;
                    if (targetUrlNs && [itemUrl isKindOfClass:[NSString class]] &&
                        [itemUrl isEqualToString:targetUrlNs]) {
                        urlMatch = true;
                    }
                    if (targetTitleNs && [itemTitle isKindOfClass:[NSString class]] &&
                        [itemTitle isEqualToString:targetTitleNs]) {
                        titleMatch = true;
                    }

                    if ((targetUrlNs && targetTitleNs && urlMatch && titleMatch) ||
                        (targetUrlNs && urlMatch) ||
                        (targetTitleNs && titleMatch)) {
                        selected = item;
                        break;
                    }
                }
            }
            if (!selected) {
                selected = [items objectAtIndex:0];
            }

            NSString* wsUrl = selected[@"webSocketDebuggerUrl"];
            if (![wsUrl isKindOfClass:[NSString class]]) {
                NSLog(@"[CEF] Remote DevTools: missing webSocketDebuggerUrl");
                return;
            }

            // Build a local DevTools frontend URL to avoid cross-origin rejection.
            // Example: http://127.0.0.1:9222/devtools/inspector.html?ws=127.0.0.1:9222/devtools/page/<id>
            NSString* wsParam = [wsUrl stringByReplacingOccurrencesOfString:@"ws://" withString:@""];
            NSString* finalUrl = [NSString stringWithFormat:@"%@/devtools/inspector.html?ws=%@&dockSide=undocked",
                                  baseUrl, wsParam];

            dispatch_async(dispatch_get_main_queue(), ^{
                this->CreateRemoteDevToolsWindow(target_id, [finalUrl UTF8String]);
            });
        }];

        [task resume];
    }

public:
    bool IsRemoteDevToolsOpen(int target_id) const {
        auto it = devtools_hosts_.find(target_id);
        return it != devtools_hosts_.end() && it->second.is_open;
    }

    void OpenRemoteDevTools(CefRefPtr<CefBrowser> browser) {
        OpenRemoteDevToolsFrontend(browser);
    }

    void CloseRemoteDevTools() {
        OnRemoteDevToolsClosed(static_cast<int>(webview_id_));
    }

    void ToggleRemoteDevTools(CefRefPtr<CefBrowser> browser) {
        int target_id = static_cast<int>(webview_id_);
        if (IsRemoteDevToolsOpen(target_id)) {
            OnRemoteDevToolsClosed(target_id);
        } else {
            OpenRemoteDevToolsFrontend(browser);
        }
    }

    void OnRemoteDevToolsClosed(int target_id) {
        auto it = devtools_hosts_.find(target_id);
        if (it == devtools_hosts_.end()) {
            return;
        }
        it->second.is_open = false;
        if (it->second.window) {
            [it->second.window orderOut:nil];
        }
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
        if (browser && browser->GetMainFrame()) {
            last_title_ = title.ToString();
            if (webview_event_handler_ && !last_title_.empty()) {
                webview_event_handler_(webview_id_, strdup("page-title-updated"), strdup(last_title_.c_str()));
            }
        }
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) override {
        if (webview_event_handler_ && !icon_urls.empty()) {
            std::string url = icon_urls[0].ToString();
            if (!url.empty()) {
                webview_event_handler_(webview_id_, strdup("favicon-updated"), strdup(url.c_str()));
            }
        }
    }

    ElectrobunClient(uint32_t webviewId,
                     HandlePostMessage eventBridgeHandler,
                     HandlePostMessage bunBridgeHandler,
                     HandlePostMessage internalBridgeHandler,
                     WebviewEventHandler webviewEventHandler,
                     DecideNavigationCallback navigationCallback,
                     bool sandbox)
        : webview_id_(webviewId)
        , event_bridge_handler_(eventBridgeHandler)
        , bun_bridge_handler_(bunBridgeHandler)
        , webview_tag_handler_(internalBridgeHandler)
        , webview_event_handler_(webviewEventHandler)
        , navigation_callback_(navigationCallback)
        , is_sandboxed_(sandbox) {}    

    void AddPreloadScript(const std::string& script, bool mainFrameOnly = false) {
        electrobun_script_ = {script, false};
    }

    void UpdateCustomPreloadScript(const std::string& script) {
        custom_script_ = {script, true};
    }

    // OSR configuration methods
    void SetOSRView(CEFOSRView* view) {
        osr_view_ = view;
        osr_enabled_ = (view != nullptr);
    }

    void SetViewSize(int width, int height) {
        view_width_ = width;
        view_height_ = height;
    }

    bool IsOSREnabled() const {
        return osr_enabled_;
    }

    virtual CefRefPtr<CefLoadHandler> GetLoadHandler() override { 
        return this; 
    }

    virtual CefRefPtr<CefRenderHandler> GetRenderHandler() override {
        return this;
    }

    virtual CefRefPtr<CefRequestHandler> GetRequestHandler() override { 
        return this; 
    }
    
    virtual CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
        return this;
    }
    
    virtual CefRefPtr<CefDisplayHandler> GetDisplayHandler() override {
        return this;
    }

    virtual CefRefPtr<CefDownloadHandler> GetDownloadHandler() override {
        return this;
    }

    // Commented out for now to prevent crashes - file dialogs will use default CEF behavior
    // virtual CefRefPtr<CefDialogHandler> GetDialogHandler() override {
    //     return this;
    // }

    // Required CefRenderHandler methods
    virtual void GetViewRect(CefRefPtr<CefBrowser> browser, CefRect& rect) override {
        rect.x = 0;
        rect.y = 0;
        // Always use stored dimensions (thread-safe)
        // These are set when the view is created and updated on resize
        rect.width = view_width_ > 0 ? view_width_ : 800;
        rect.height = view_height_ > 0 ? view_height_ : 600;
    }

    virtual void OnPaint(CefRefPtr<CefBrowser> browser,
                        PaintElementType type,
                        const RectList& dirtyRects,
                        const void* buffer,
                        int width,
                        int height) override {
        NSLog(@"DEBUG CEF OnPaint: osr_enabled=%d, osr_view=%p, buffer=%p, width=%d, height=%d",
              osr_enabled_, osr_view_, buffer, width, height);
        if (osr_enabled_ && osr_view_ && buffer && width > 0 && height > 0) {
            NSLog(@"DEBUG CEF OnPaint: Calling updateBuffer");
            [osr_view_ updateBuffer:buffer width:width height:height];
            NSLog(@"DEBUG CEF OnPaint: updateBuffer completed");
        }
    }

    // CefDownloadHandler methods
    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDownloadItem> download_item,
                          const CefString& suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        NSLog(@"DEBUG CEF Download: OnBeforeDownload for %s", suggested_name.ToString().c_str());

        // Get the Downloads folder
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES);
        NSString *downloadsDirectory = [paths firstObject];

        if (downloadsDirectory) {
            NSString *suggestedFilename = [NSString stringWithUTF8String:suggested_name.ToString().c_str()];
            NSString *destinationPath = [downloadsDirectory stringByAppendingPathComponent:suggestedFilename];

            // Handle duplicate filenames by appending a number
            NSFileManager *fileManager = [NSFileManager defaultManager];
            NSString *basePath = [destinationPath stringByDeletingPathExtension];
            NSString *extension = [destinationPath pathExtension];
            int counter = 1;

            while ([fileManager fileExistsAtPath:destinationPath]) {
                if (extension.length > 0) {
                    destinationPath = [NSString stringWithFormat:@"%@ (%d).%@", basePath, counter, extension];
                } else {
                    destinationPath = [NSString stringWithFormat:@"%@ (%d)", basePath, counter];
                }
                counter++;
            }

            NSLog(@"DEBUG CEF Download: Saving to %@", destinationPath);

            // Store the path for this download
            uint32_t downloadId = download_item->GetId();
            download_paths_[downloadId] = [destinationPath UTF8String];

            // Send download-started event
            if (webview_event_handler_) {
                std::string escapedFilename = EscapeJavaScriptString(suggested_name.ToString());
                std::string escapedPath = EscapeJavaScriptString(std::string([destinationPath UTF8String]));
                std::string eventData = "{\"filename\":\"" + escapedFilename +
                    "\",\"path\":\"" + escapedPath + "\"}";
                // Use strdup to create persistent copies for the FFI callback
                webview_event_handler_(webview_id_, strdup("download-started"), strdup(eventData.c_str()));
            }

            // Continue the download to the specified path without showing a dialog
            callback->Continue([destinationPath UTF8String], false);
        } else {
            NSLog(@"ERROR CEF Download: Could not find Downloads directory, using suggested name");
            callback->Continue("", false);  // Use default behavior
        }

        return true;  // We handled it
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefDownloadItem> download_item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        uint32_t downloadId = download_item->GetId();

        if (download_item->IsComplete()) {
            std::string fullPath = download_item->GetFullPath().ToString();
            NSLog(@"DEBUG CEF Download: Download complete - %s", fullPath.c_str());

            // Send download-completed event
            if (webview_event_handler_) {
                // Extract just the filename from the full path
                std::string filename = fullPath;
                size_t lastSlash = fullPath.find_last_of('/');
                if (lastSlash != std::string::npos) {
                    filename = fullPath.substr(lastSlash + 1);
                }
                std::string escapedFilename = EscapeJavaScriptString(filename);
                std::string escapedPath = EscapeJavaScriptString(fullPath);
                std::string eventData = "{\"filename\":\"" + escapedFilename +
                    "\",\"path\":\"" + escapedPath + "\"}";
                NSLog(@"DEBUG CEF Download: Sending event data - %s", eventData.c_str());
                // Use strdup to create persistent copies for the FFI callback
                webview_event_handler_(webview_id_, strdup("download-completed"), strdup(eventData.c_str()));
            }

            // Clean up
            download_paths_.erase(downloadId);
        } else if (download_item->IsCanceled()) {
            NSLog(@"DEBUG CEF Download: Download canceled");

            // Send download-failed event
            if (webview_event_handler_) {
                // Try to get path from stored paths or from download item
                std::string path = download_paths_[downloadId];
                if (path.empty()) {
                    path = download_item->GetFullPath().ToString();
                }
                std::string escapedPath = EscapeJavaScriptString(path);
                std::string eventData = "{\"filename\":\"\",\"path\":\"" + escapedPath +
                    "\",\"error\":\"Download canceled\"}";
                // Use strdup to create persistent copies for the FFI callback
                webview_event_handler_(webview_id_, strdup("download-failed"), strdup(eventData.c_str()));
            }

            // Clean up
            download_paths_.erase(downloadId);
        } else if (download_item->IsInProgress()) {
            int percent = download_item->GetPercentComplete();
            if (percent >= 0) {
                // Send download-progress event
                if (webview_event_handler_) {
                    std::string eventData = "{\"progress\":" + std::to_string(percent) + "}";
                    webview_event_handler_(webview_id_, strdup("download-progress"), strdup(eventData.c_str()));
                }
            }
        }
    }

    // Static timestamp for debouncing cmd+click across all webviews
    static NSTimeInterval lastCmdClickTime;

    // Handle all navigation requests
    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       CefRefPtr<CefRequest> request,
                       bool user_gesture,
                       bool is_redirect) override {
        std::string url = request->GetURL().ToString();

       
        // Check if cmd key is held - if so, fire new-window-open event and block navigation
        // Use NSEvent to get current modifier flags since CEF doesn't provide them in OnBeforeBrowse
        // Note: We don't check user_gesture because SPA frameworks may trigger navigations
        // programmatically after a click, causing user_gesture to be false
        NSEventModifierFlags modifierFlags = [NSEvent modifierFlags];
        bool isCmdClick = false;//(modifierFlags & NSEventModifierFlagCommand) != 0;

        // Skip Cmd+click handling for initial page loads (navigating away from about:blank)
        // This prevents keyboard shortcuts like Cmd+T from triggering double tab creation
        std::string currentUrl = frame->GetURL().ToString();
        bool isInitialLoad = (currentUrl == "about:blank" || currentUrl.empty());

        if (isCmdClick && !is_redirect && !isInitialLoad) {
            // Debounce: ignore cmd+click navigations within 500ms of the last one
            // This prevents cascading new tabs when cmd is held during page load
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if (now - lastCmdClickTime < 0.5) {
                // Allow navigation normally, don't fire event
            } else {
                lastCmdClickTime = now;

                // Escape special characters in URL for JSON
                std::string escapedUrl;
                for (char c : url) {
                    switch (c) {
                        case '"': escapedUrl += "\\\""; break;
                        case '\\': escapedUrl += "\\\\"; break;
                        case '\n': escapedUrl += "\\n"; break;
                        case '\r': escapedUrl += "\\r"; break;
                        case '\t': escapedUrl += "\\t"; break;
                        default: escapedUrl += c; break;
                    }
                }
                std::string eventData = "{\"url\":\"" + escapedUrl +
                                       "\",\"isCmdClick\":true,\"modifierFlags\":" +
                                       std::to_string((unsigned long)modifierFlags) + "}";
                if (webview_event_handler_) {
                    // Use strdup to create a persistent copy for the FFI callback
                    webview_event_handler_(webview_id_, strdup("new-window-open"), strdup(eventData.c_str()));
                }
                return true;  // Cancel the navigation
            }
        }

        // Check navigation rules synchronously from native-stored rules
        AbstractView *abstractView = [globalAbstractViews objectForKey:@(webview_id_)];
        bool shouldAllow = abstractView ? [abstractView shouldAllowNavigationToURL:[NSString stringWithUTF8String:url.c_str()]] : true;

        // Escape special characters in URL for JSON event
        std::string escapedUrl;
        for (char c : url) {
            switch (c) {
                case '"': escapedUrl += "\\\""; break;
                case '\\': escapedUrl += "\\\\"; break;
                case '\n': escapedUrl += "\\n"; break;
                case '\r': escapedUrl += "\\r"; break;
                case '\t': escapedUrl += "\\t"; break;
                default: escapedUrl += c; break;
            }
        }

        // Fire will-navigate event with allowed status
        if (webview_event_handler_) {
            std::string eventData = "{\"url\":\"" + escapedUrl + "\",\"allowed\":" +
                                   (shouldAllow ? "true" : "false") + "}";
            webview_event_handler_(webview_id_, strdup("will-navigate"), strdup(eventData.c_str()));
        }
        return !shouldAllow;  // Return true to cancel the navigation
    }

     virtual CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        CefRefPtr<CefRequest> request,
        bool is_navigation,
        bool is_download,
        const CefString& request_initiator,
        bool& disable_default_handling) override {
        // Return this object as the resource request handler
        return this;
    }
    
    // Response filter to modify HTML content
    CefRefPtr<CefResponseFilter> GetResourceResponseFilter(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        CefRefPtr<CefRequest> request,
        CefRefPtr<CefResponse> response) override {
        
        // Only filter main frame HTML responses
        if (frame->IsMain() && 
            response->GetMimeType().ToString().find("html") != std::string::npos) {
            NSLog(@"Creating response filter for HTML content");
            return new ElectrobunResponseFilter(electrobun_script_, custom_script_);
        }
        
        return nullptr;
    }

    virtual void OnLoadStart(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           TransitionType transition_type) override {    

        std::string frameUrl = frame->GetURL().ToString();
        std::string scriptUrl = GetScriptExecutionUrl(frameUrl);

        // NSLog(@"OnLoadStart %s", frameUrl.c_str());//, electrobun_script_.code.c_str());           
    }   

    void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                  CefRefPtr<CefFrame> frame,
                  int httpStatusCode) override {
        if (frame->IsMain() && webview_event_handler_) {
            // Create a persistent copy of the URL string using strdup
            // The callback is invoked asynchronously and the local std::string would be destroyed
            std::string url = frame->GetURL().ToString();
            char* urlCopy = strdup(url.c_str());
            webview_event_handler_(webview_id_, "did-navigate", urlCopy);

            // Free the memory after giving the callback time to execute
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                free((void*)urlCopy);
            });
        }
    }

   virtual bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefProcessId source_process,
                                     CefRefPtr<CefProcessMessage> message) override {
    
    std::string messageName = message->GetName().ToString();
    std::string messageContent = message->GetArgumentList()->GetString(0).ToString();
    
    char* contentCopy = strdup(messageContent.c_str());
    bool result = false;

    // eventBridge - event-only bridge (always process for all webviews, including sandboxed)
    if (messageName == "EventBridgeMessage") {
        event_bridge_handler_(webview_id_, contentCopy);
        result = true;
    }
    // bunBridge and internalBridge - RPC bridges (only for non-sandboxed webviews)
    else if (!is_sandboxed_) {
        if (messageName == "BunBridgeMessage") {
            bun_bridge_handler_(webview_id_, contentCopy);
            result = true;
        } else if (messageName == "internalMessage") {
            webview_tag_handler_(webview_id_, contentCopy);
            result = true;
        }
    }

    // Note: threadsafe JSCallbacks are invoked on the js worker thread, When called frequently they
    // can build up and take longer. Meanwhile objc GC auto free's the message body and the callback
    // ends up getting garbage.

    // So we duplicate it and give it plenty of time to execute (1 second delay vs. 0.1ms execution per invocation)
    // before freeing the memory
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        free((void*)contentCopy);
    });   
    
    return result;
}

    // Context Menu
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
        return this;
    }

    // Implement context menu callback
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            CefRefPtr<CefMenuModel> model) override {
        // Add "Inspect Element" to context menu
        if (model->GetCount() > 0) {
            model->AddSeparator();
        }
        model->AddItem(MENU_ID_DEV_TOOLS, "Inspect Element");
    }

    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefContextMenuParams> params,
                        int command_id,
                        EventFlags event_flags) override {
        if (command_id == MENU_ID_DEV_TOOLS) {
            OpenRemoteDevToolsFrontend(browser);

            CefPoint inspect_at(params->GetXCoord(), params->GetYCoord());
            CefRefPtr<ElectrobunClient> self(this);
            CefRefPtr<CefBrowser> browser_ref(browser);
            dispatch_async(dispatch_get_main_queue(), ^{
                // Disabled for now due to crash in CEF 144 on macOS.
                // self->ShowDevToolsWindow(browser_ref, inspect_at);
            });
            return true;
        }
        return false;
    }

    // Keyboard Shortcut
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override {
        return this;
    }

    // Life Span Handler
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override {
        return this;
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      int popup_id,
                      const CefString& target_url,
                      const CefString& target_frame_name,
                      CefLifeSpanHandler::WindowOpenDisposition target_disposition,
                      bool user_gesture,
                      const CefPopupFeatures& popupFeatures,
                      CefWindowInfo& windowInfo,
                      CefRefPtr<CefClient>& client,
                      CefBrowserSettings& settings,
                      CefRefPtr<CefDictionaryValue>& extra_info,
                      bool* no_javascript_access) override {
        CEF_REQUIRE_UI_THREAD();
        
        // Check if this is a new window request (cmd+click, target="_blank", window.open, etc.)
        bool isCmdClick = target_disposition == CEF_WOD_NEW_FOREGROUND_TAB || 
                         target_disposition == CEF_WOD_NEW_BACKGROUND_TAB ||
                         target_disposition == CEF_WOD_NEW_WINDOW;        
        
        // Create event data with more context
        std::string eventData = "{\"url\":\"" + target_url.ToString() + 
                               "\",\"isCmdClick\":" + (isCmdClick ? "true" : "false") +
                               ",\"targetDisposition\":" + std::to_string(target_disposition) +
                               ",\"userGesture\":" + (user_gesture ? "true" : "false") + "}";
                
        
        // Send the new window event
        if (webview_event_handler_) {            
            // Use strdup to create a persistent copy of the string for the FFI callback
            char* eventDataCopy = strdup(eventData.c_str());
            webview_event_handler_(webview_id_, strdup("new-window-open"), eventDataCopy);            
        } else {
            NSLog(@"[CEF_NEW_WINDOW] ERROR: webview_event_handler_ is NULL!");
        }
        
        // Prevent the popup from actually opening by returning true
        return true;
    }

    bool OnKeyEvent(CefRefPtr<CefBrowser> browser,
               const CefKeyEvent& event,
               CefEventHandle os_event) override {
       

        bool hasCommand = (event.modifiers & EVENTFLAG_COMMAND_DOWN) != 0;
        bool hasOption = (event.modifiers & EVENTFLAG_ALT_DOWN) != 0;                

                
        if (event.type == KEYEVENT_RAWKEYDOWN) {
            // Note: option changes the character for i, so we use the native_key_code
            // for the i key instead. cmd+option+i
            if (event.native_key_code == 34 &&
                (event.modifiers & EVENTFLAG_COMMAND_DOWN) &&
                (event.modifiers & EVENTFLAG_ALT_DOWN)) {
                CefPoint inspect_at(0, 0);
                CefRefPtr<ElectrobunClient> self(this);
                CefRefPtr<CefBrowser> browser_ref(browser);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->ShowDevToolsWindow(browser_ref, inspect_at);
                });
                return true;
            }
            
            // Handle ESC key to exit fullscreen (try both key codes)
            if (event.windows_key_code == 27 || event.native_key_code == 53) {
                browser->GetHost()->ExitFullscreen(false);
                return true;
            }                        
        }
        return false;
    }
    
    // Permission Handler methods for CEF
    virtual bool OnRequestMediaAccessPermission(
        CefRefPtr<CefBrowser> browser,
        CefRefPtr<CefFrame> frame,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefMediaAccessCallback> callback) override {
        
        std::string origin = requesting_origin.ToString();
        NSLog(@"CEF: Media access permission requested for %s (permissions: %u)", origin.c_str(), requested_permissions);

        std::string frameUrl;
        if (frame) {
            frameUrl = frame->GetURL().ToString();
        }

        // The app shell is fully trusted. In production this is views://; in dev
        // the launcher is served from localhost with cachyWindow=launcher.
        if (isTrustedAppShellURL(origin) || isTrustedAppShellURL(frameUrl)) {
            callback->Continue(requested_permissions);
            return true;
        }

        // Check cache first
        PermissionStatus cachedStatus = getPermissionFromCache(origin, PermissionType::USER_MEDIA);
        
        if (cachedStatus == PermissionStatus::ALLOWED) {
            NSLog(@"CEF: Using cached permission: User previously allowed media access for %s", origin.c_str());
            callback->Continue(requested_permissions); // Allow all requested permissions
            return true;
        } else if (cachedStatus == PermissionStatus::DENIED) {
            NSLog(@"CEF: Using cached permission: User previously blocked media access for %s", origin.c_str());
            callback->Cancel();
            return true;
        }
        
        // No cached permission, show dialog
        NSLog(@"CEF: No cached permission found for %s, showing dialog", origin.c_str());
        
        // Show macOS native alert
        NSString *message = @"This page wants to access your camera and/or microphone.\n\nDo you want to allow this?";
        NSString *title = @"Camera & Microphone Access";
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:title];
        [alert setInformativeText:message];
        [alert addButtonWithTitle:@"Allow"];
        [alert addButtonWithTitle:@"Block"];
        [alert setAlertStyle:NSAlertStyleInformational];
        
        NSModalResponse response = [alert runModal];
        
        // Handle response and cache the decision
        if (response == NSAlertFirstButtonReturn) { // Allow
            callback->Continue(requested_permissions); // Allow all requested permissions
            cachePermission(origin, PermissionType::USER_MEDIA, PermissionStatus::ALLOWED);
            NSLog(@"CEF: User allowed media access for %s (cached)", origin.c_str());
        } else { // Block
            callback->Cancel();
            cachePermission(origin, PermissionType::USER_MEDIA, PermissionStatus::DENIED);
            NSLog(@"CEF: User blocked media access for %s (cached)", origin.c_str());
        }
        
        return true; // We handled the permission request
    }
    
    virtual bool OnShowPermissionPrompt(
        CefRefPtr<CefBrowser> browser,
        uint64_t prompt_id,
        const CefString& requesting_origin,
        uint32_t requested_permissions,
        CefRefPtr<CefPermissionPromptCallback> callback) override {
        
        std::string origin = requesting_origin.ToString();
        NSLog(@"CEF: Permission prompt requested for %s (permissions: %u)", origin.c_str(), requested_permissions);

        std::string pageUrl;
        if (browser && browser->GetMainFrame()) {
            pageUrl = browser->GetMainFrame()->GetURL().ToString();
        }

        // The app shell is fully trusted. In production this is views://; in dev
        // the launcher is served from localhost with cachyWindow=launcher.
        if (isTrustedAppShellURL(origin) || isTrustedAppShellURL(pageUrl)) {
            callback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
            return true;
        }

        // Handle different permission types
        PermissionType permType = PermissionType::OTHER;
        NSString *message = nil;
        NSString *title = nil;

        // Check for specific permission types
        if (requested_permissions & CEF_PERMISSION_TYPE_CAMERA_STREAM ||
            requested_permissions & CEF_PERMISSION_TYPE_MIC_STREAM) {
            permType = PermissionType::USER_MEDIA;
            message = @"This page wants to access your camera and/or microphone.\n\nDo you want to allow this?";
            title = @"Camera & Microphone Access";
        } else if (requested_permissions & CEF_PERMISSION_TYPE_GEOLOCATION) {
            permType = PermissionType::GEOLOCATION;
            message = @"This page wants to access your location.\n\nDo you want to allow this?";
            title = @"Location Access";
        } else if (requested_permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) {
            permType = PermissionType::NOTIFICATIONS;
            message = @"This page wants to show notifications.\n\nDo you want to allow this?";
            title = @"Notification Permission";
        } else {
            // Unrecognized permission type — name what's being requested instead of
            // a generic "additional permissions" dialog so the user can decide.
            std::string names = electrobun::describeCefPermissions(requested_permissions);
            message = [NSString stringWithFormat:
                @"This page is requesting permission for: %s.\n\nDo you want to allow this?",
                names.c_str()];
            title = @"Permission Request";
        }

        // Check cache first
        PermissionStatus cachedStatus = getPermissionFromCache(origin, permType);
        
        if (cachedStatus == PermissionStatus::ALLOWED) {
            NSLog(@"CEF: Using cached permission: User previously allowed %@ for %s", title, origin.c_str());
            callback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
            return true;
        } else if (cachedStatus == PermissionStatus::DENIED) {
            NSLog(@"CEF: Using cached permission: User previously blocked %@ for %s", title, origin.c_str());
            callback->Continue(CEF_PERMISSION_RESULT_DENY);
            return true;
        }
        
        // No cached permission, show dialog
        NSLog(@"CEF: No cached permission found for %s, showing dialog", origin.c_str());
        
        // Show macOS native alert
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:title];
        [alert setInformativeText:message];
        [alert addButtonWithTitle:@"Allow"];
        [alert addButtonWithTitle:@"Block"];
        [alert setAlertStyle:NSAlertStyleInformational];
        
        NSModalResponse response = [alert runModal];
        
        // Handle response and cache the decision
        if (response == NSAlertFirstButtonReturn) { // Allow
            callback->Continue(CEF_PERMISSION_RESULT_ACCEPT);
            cachePermission(origin, permType, PermissionStatus::ALLOWED);
            NSLog(@"CEF: User allowed %@ for %s (cached)", title, origin.c_str());
        } else { // Block
            callback->Continue(CEF_PERMISSION_RESULT_DENY);
            cachePermission(origin, permType, PermissionStatus::DENIED);
            NSLog(@"CEF: User blocked %@ for %s (cached)", title, origin.c_str());
        }
        
        return true; // We handled the permission request
    }
    
    virtual void OnDismissPermissionPrompt(
        CefRefPtr<CefBrowser> browser,
        uint64_t prompt_id,
        cef_permission_request_result_t result) override {
        
        NSLog(@"CEF: Permission prompt %llu dismissed with result %d", prompt_id, result);
        // Optional: Handle prompt dismissal if needed
    }
    
    // CefDialogHandler methods - commented out for now to prevent crashes
    // TODO: Fix CEF reference counting issues in Objective-C blocks
    /*
    virtual bool OnFileDialog(CefRefPtr<CefBrowser> browser,
                            FileDialogMode mode,
                            const CefString& title,
                            const CefString& default_file_path,
                            const std::vector<CefString>& accept_filters,
                            CefRefPtr<CefFileDialogCallback> callback) override {
        // Implementation commented out - needs proper reference handling
        return false; // Let CEF handle with default behavior
    }
    */

    // Store original state for fullscreen
    NSRect storedFrame_;
    NSView* storedSuperview_;
    NSWindow* fullscreenWindow_;
    NSWindow* originalWindow_;
    CALayer* storedLayerMask_;
    id globalKeyMonitor_;
    
    // CefDisplayHandler methods
    virtual void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                       bool fullscreen) override {
        CEF_REQUIRE_UI_THREAD();
        
        NSLog(@"[CEF_FULLSCREEN] OnFullscreenModeChange called - fullscreen: %s for webview %u", 
              fullscreen ? "YES" : "NO", webview_id_);
        
        if (!browser || !browser->GetHost()) {
            return;
        }
        
        CefWindowHandle handle = browser->GetHost()->GetWindowHandle();
        if (!handle) {
            return;
        }
        
        NSView* cefView = (__bridge NSView*)handle;
        
        if (fullscreen) {
            NSLog(@"[CEF_FULLSCREEN] Entering fullscreen for webview %u", webview_id_);
            
            // Store original state
            storedFrame_ = cefView.frame;
            storedSuperview_ = cefView.superview;
            originalWindow_ = cefView.window;
            
            // Store and clear the layer mask (this was causing cropping in WKWebView too)
            storedLayerMask_ = cefView.layer.mask;
            cefView.layer.mask = nil;
            NSLog(@"[CEF_FULLSCREEN] Stored and cleared layer mask for webview %u", webview_id_);
            
            // Create a new fullscreen window
            NSScreen* screen = [NSScreen mainScreen];
            NSRect screenFrame = screen.frame;
            
            fullscreenWindow_ = [[NSWindow alloc] initWithContentRect:screenFrame
                                                            styleMask:NSWindowStyleMaskBorderless
                                                              backing:NSBackingStoreBuffered
                                                                defer:NO];
            
            fullscreenWindow_.level = NSScreenSaverWindowLevel;
            fullscreenWindow_.backgroundColor = [NSColor blackColor];
            fullscreenWindow_.opaque = YES;
            fullscreenWindow_.hasShadow = NO;
            
            // Remove CEF view from original location and add to fullscreen window
            [cefView removeFromSuperview];
            [fullscreenWindow_.contentView addSubview:cefView];
            
            // Make CEF view fill the fullscreen window
            cefView.frame = fullscreenWindow_.contentView.bounds;
            cefView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            
            // Show the fullscreen window
            [fullscreenWindow_ makeKeyAndOrderFront:nil];
            [fullscreenWindow_ setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
            [fullscreenWindow_ toggleFullScreen:nil];
            
            // Add local key monitor for ESC key (works even when our app has focus)
            globalKeyMonitor_ = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown 
                                handler:^NSEvent*(NSEvent *event) {
                if (event.keyCode == 53) { // ESC key code on macOS
                    NSLog(@"[CEF_FULLSCREEN] Local ESC key detected - exiting fullscreen for webview %u", webview_id_);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        browser->GetHost()->ExitFullscreen(false);
                    });
                    return nil; // Consume the event
                }
                return event; // Let other events through
            }];
            
            // Notify CEF of the size change
            browser->GetHost()->WasResized();
            
            NSLog(@"[CEF_FULLSCREEN] Created fullscreen window, CEF view size: %.0fx%.0f", 
                  cefView.frame.size.width, cefView.frame.size.height);
            
        } else {
            NSLog(@"[CEF_FULLSCREEN] Exiting fullscreen for webview %u", webview_id_);
            
            // Exit fullscreen on the fullscreen window
            if (fullscreenWindow_) {
                // Remove global key monitor
                if (globalKeyMonitor_) {
                    [NSEvent removeMonitor:globalKeyMonitor_];
                    globalKeyMonitor_ = nil;                    
                }
                
                // First exit fullscreen mode on temp window, then delay reparenting
                NSWindow* tempWindow = fullscreenWindow_;
                fullscreenWindow_ = nil; // Clear reference immediately
                
                if ((tempWindow.styleMask & NSWindowStyleMaskFullScreen) == NSWindowStyleMaskFullScreen) {                    
                    [tempWindow toggleFullScreen:nil];
                    
                    // Capture references before dispatch block
                    NSView* capturedCefView = cefView;
                    NSView* capturedSuperview = storedSuperview_;
                    NSRect capturedFrame = storedFrame_;
                    CALayer* capturedMask = storedLayerMask_;
                    NSWindow* capturedOriginalWindow = originalWindow_;
                    
                    // Clear instance variables to prevent double cleanup
                    storedSuperview_ = nil;
                    originalWindow_ = nil;
                    storedLayerMask_ = nil;
                    
                    // Wait for fullscreen exit animation before reparenting CEF view
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        // NSLog(@"[CEF_FULLSCREEN] Fullscreen exit complete - now reparenting CEF view");
                        
                        // Make temp window transparent first to reduce flicker
                        [tempWindow setAlphaValue:0.0];
                        
                        // NSLog(@"[CEF_FULLSCREEN] Hidden temp fullscreen window");
                        
                        // Now do the reparenting after temp window is hidden
                        if (capturedCefView && capturedSuperview) {
                            // Make original window key before reparenting to ensure smooth transition
                            if (capturedOriginalWindow) {
                                [capturedOriginalWindow makeKeyAndOrderFront:nil];
                                // NSLog(@"[CEF_FULLSCREEN] Restored original window as key");
                            }
                            
                            // NSLog(@"[CEF_FULLSCREEN] Removing CEF view from fullscreen window");
                            [capturedCefView removeFromSuperview];
                            
                            // NSLog(@"[CEF_FULLSCREEN] Restoring CEF view to original parent");
                            [capturedSuperview addSubview:capturedCefView];
                            capturedCefView.frame = capturedFrame;
                            capturedCefView.autoresizingMask = NSViewNotSizable;
                            
                            // Restore the layer mask
                            if (capturedMask) {
                                capturedCefView.layer.mask = capturedMask;
                                NSLog(@"[CEF_FULLSCREEN] Restored layer mask for webview %u", webview_id_);
                            }
                            
                            // Notify CEF of the size change after everything is in place
                            browser->GetHost()->WasResized();
                        } else {
                            NSLog(@"[CEF_FULLSCREEN] ERROR: capturedCefView or capturedSuperview is nil!");
                        }
                    });
                } else {
                    NSLog(@"[CEF_FULLSCREEN] Window not in fullscreen mode, reparenting immediately");
                    // Reparent immediately if not fullscreen
                    if (cefView && storedSuperview_) {
                        NSLog(@"[CEF_FULLSCREEN] Removing CEF view from fullscreen window");
                        [cefView removeFromSuperview];
                        
                        NSLog(@"[CEF_FULLSCREEN] Restoring CEF view to original parent");
                        [storedSuperview_ addSubview:cefView];
                        cefView.frame = storedFrame_;
                        cefView.autoresizingMask = NSViewNotSizable;
                        
                        // Restore the layer mask
                        if (storedLayerMask_) {
                            cefView.layer.mask = storedLayerMask_;
                            storedLayerMask_ = nil;
                            NSLog(@"[CEF_FULLSCREEN] Restored layer mask for webview %u", webview_id_);
                        }
                        
                        browser->GetHost()->WasResized();
                    }
                    
                    if (originalWindow_) {
                        [originalWindow_ makeKeyAndOrderFront:nil];
                        NSLog(@"[CEF_FULLSCREEN] Restored original window as key");
                    }
                    
                    [tempWindow orderOut:nil];
                }
            }
            
            // Note: storedSuperview_, originalWindow_, and storedLayerMask_ are cleared
            // either in the dispatch block above or in the immediate reparenting case
        }
    }

    IMPLEMENT_REFCOUNTING(ElectrobunClient);
    DISALLOW_COPY_AND_ASSIGN(ElectrobunClient);
};

// Initialize static debounce timestamp for cmd+click handling
NSTimeInterval ElectrobunClient::lastCmdClickTime = 0;

void RemoteDevToolsClosed(void* ctx, int target_id) {
    if (!ctx) {
        return;
    }
    static_cast<ElectrobunClient*>(ctx)->OnRemoteDevToolsClosed(target_id);
}

@interface CEFWebViewImpl : AbstractView
    // @property (nonatomic, strong) WKWebView *webView;

    @property (nonatomic, assign) CefRefPtr<CefBrowser> browser;
    @property (nonatomic, assign) CefRefPtr<ElectrobunClient> client;
    @property (nonatomic, strong) CEFOSRView *osrView;  // For transparent/OSR mode
    @property (nonatomic, assign) BOOL isOSRMode;


    - (instancetype)initWithWebviewId:(uint32_t)webviewId
                            window:(NSWindow *)window
                            url:(const char *)url
                                frame:(NSRect)frame
                        autoResize:(bool)autoResize
                partitionIdentifier:(const char *)partitionIdentifier
                navigationCallback:(DecideNavigationCallback)navigationCallback
                webviewEventHandler:(WebviewEventHandler)webviewEventHandler
                eventBridgeHandler:(HandlePostMessage)eventBridgeHandler
                bunBridgeHandler:(HandlePostMessage)bunBridgeHandler
                internalBridgeHandler:(HandlePostMessage)internalBridgeHandler
                electrobunPreloadScript:(const char *)electrobunPreloadScript
                customPreloadScript:(const char *)customPreloadScript
                viewsRoot:(const char *)viewsRoot
                transparent:(bool)transparent
                sandbox:(bool)sandbox;

@end

bool initializeCEF() {
    static bool initialized = false;
    if (initialized) return true;
    
    [ElectrobunNSApplication sharedApplication];
    if (![NSApp isKindOfClass:[ElectrobunNSApplication class]]) {        
        return false;
    }

    NSProcessInfo* processInfo = [NSProcessInfo processInfo];
    NSArray* arguments = [processInfo arguments];
    int argc = (int)[arguments count];
    char** argv = (char**)malloc(sizeof(char*) * argc);
    for (int i = 0; i < argc; i++) {
        argv[i] = strdup([[arguments objectAtIndex:i] UTF8String]);
    }
    
    CefMainArgs main_args(argc, argv);
    g_app = new ElectrobunApp();

    // Read user-defined chromium flags from build.json
    NSString* buildJsonPath = [[NSBundle mainBundle] pathForResource:@"build" ofType:@"json"];
    if (buildJsonPath) {
        std::string buildJsonContent = electrobun::readFileToString([buildJsonPath UTF8String]);
        g_userChromiumFlags = electrobun::parseChromiumFlags(buildJsonContent);
    }

    CefSettings settings;
    settings.no_sandbox = true;
    settings.multi_threaded_message_loop = false; // Use single threaded message loop on macOS
    settings.windowless_rendering_enabled = true; // Required for OSR/transparent windows
    // Remote DevTools port with simple scan for availability.
    int selectedPort = FindAvailableRemoteDebugPort(9222, 9232);
    if (selectedPort == 0) {
        selectedPort = 9222;
        NSLog(@"[CEF] Remote DevTools: no free port in 9222-9232, falling back to 9222");
    }
    g_remoteDebugPort = selectedPort;
    settings.remote_debugging_port = selectedPort;
    // settings.log_severity = LOGSEVERITY_VERBOSE;

    // Set explicit paths to avoid bundle lookup issues in newer CEF builds.
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    if (bundlePath) {
        CefString(&settings.main_bundle_path) = [bundlePath UTF8String];
    }

    NSString* frameworkPath = [[NSBundle mainBundle]
        pathForResource:@"Chromium Embedded Framework"
                 ofType:@"framework"
            inDirectory:@"Contents/Frameworks"];
    if (frameworkPath) {
        CefString(&settings.framework_dir_path) = [frameworkPath UTF8String];
    }

    // This prevents multiple apps from sharing the same helper.
    NSString* helperPath =
        [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"bun Helper.app/Contents/MacOS/bun Helper"];
    if (helperPath) {
        CefString(&settings.browser_subprocess_path) = [helperPath UTF8String];
        NSLog(@"[CEF] Using helper at: %@", helperPath);
    }
    
    // Add cache path to prevent warnings and potential issues
     // Use app-specific cache directory to allow multiple Electrobun apps to run simultaneously
    NSString* appSupportPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];

    // Build path with identifier/channel structure (consistent with CLI and updater)
    std::string cachePathStr = buildAppDataPath(
        [appSupportPath UTF8String],
        g_electrobunIdentifier,
        g_electrobunChannel,
        "CEF"
    );
    NSString* cachePath = [NSString stringWithUTF8String:cachePathStr.c_str()];
    NSLog(@"[CEF] Using path: %s", cachePathStr.c_str());

    // One-shot wipe if Electrobun's cache format version has been bumped
    // since the user's last launch. See cache_migration.h.
    electrobun::migrateCacheFolderIfNeeded(cachePathStr);

    CefString(&settings.root_cache_path) = [cachePath UTF8String];

    // Set log file path for debugging
    NSString* logPath = [cachePath stringByAppendingPathComponent:@"debug.log"];
    CefString(&settings.log_file) = [logPath UTF8String];    
    
    // Enable network service
    // settings.packaged_services = cef_services_t::CEF_SERVICE_ALL;
    
    CefString(&settings.accept_language_list) = g_acceptLanguage.empty() ? "en-US,en" : g_acceptLanguage;
    
    // Register custom scheme
    // CefRegisterSchemeHandlerFactory("views", "", new ElectrobunSchemeHandlerFactory(assetFileLoader, 0));
    
    // Make CEF aware of the custom scheme
    // CefCommandLine::GetGlobalCommandLine()->AppendSwitch("register-scheme-handler");
    // CefCommandLine::GetGlobalCommandLine()->AppendSwitchWithValue("custom-scheme", "views");
    
    // Enable file access and modern web APIs
    // Note: Some command line switches can cause CEF crashes, commenting out for now
    // CefRefPtr<CefCommandLine> commandLine = CefCommandLine::GetGlobalCommandLine();
    // commandLine->AppendSwitch("allow-file-access-from-files");
    // commandLine->AppendSwitch("allow-universal-access-from-files");
    // commandLine->AppendSwitch("disable-web-security");
    
    // Enable required packaged services
    // settings.packaged_services = cef_services_t::CEF_SERVICE_ALL;    
    bool result = CefInitialize(main_args, settings, g_app.get(), nullptr);

    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
    
    if (!result) {        
        return false;
    }
    
    initialized = true;
    return true;
}


// The main scheme handler class
class ElectrobunSchemeHandler : public CefResourceHandler {
public:
     ElectrobunSchemeHandler(uint32_t webviewId)
    : webviewId_(webviewId), hasResponse_(false), offset_(0) {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {

        std::string urlStr = request->GetURL().ToString();
        
        // CEF calls Open from a worker thread, so we need to handle this on the main thread
        // to avoid threading issues with Bun's JS runtime
        __block std::string responseDataBlock;
        __block std::string mimeTypeBlock;
        __block bool hasResponseBlock = false;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
            responseData_.clear();
            hasResponse_ = false;
            offset_ = 0;
            
            // If the URL starts with "views://"
            if (urlStr.find("views://") == 0) {
                NSLog(@"DEBUG CEF: Processing views:// URL: %s", urlStr.c_str());
                // Remove the prefix (8 characters for "views://") - FIXED VERSION v2
                std::string relativePath = urlStr.substr(8);
                size_t queryOrFragment = relativePath.find_first_of("?#");
                if (queryOrFragment != std::string::npos) {
                    relativePath.erase(queryOrFragment);
                }
                // Strip trailing slashes - WebView may normalize URLs without folder components
                while (!relativePath.empty() && (relativePath.back() == '/' || relativePath.back() == '\\')) {
                    relativePath.pop_back();
                }
                NSLog(@"DEBUG CEF FIXED: relativePath = '%s'", relativePath.c_str());
                
                // Check if this is the internal HTML request.
                NSLog(@"DEBUG CEF: Comparing relativePath '%s' with 'internal/index.html'", relativePath.c_str());
                if (relativePath == "internal/index.html") {
                    NSLog(@"DEBUG CEF: Handling views://internal/index.html for webview %u", webviewId_);
                    // Use stored HTML content instead of JSCallback
                    const char* htmlContent = getWebviewHTMLContent(webviewId_);
                    if (!htmlContent) {
                        // Fallback to default if no content set
                        NSLog(@"DEBUG CEF: No HTML content found for webview %u, using fallback", webviewId_);
                        htmlContent = strdup("<html><body>No content set</body></html>");
                    } else {
                        NSLog(@"DEBUG CEF: Retrieved HTML content for webview %u", webviewId_);
                    }
                    
                    if (htmlContent) {
                        size_t len = strlen(htmlContent);
                        NSLog(@"DEBUG CEF: HTML content length: %zu, content preview: %.100s", len, htmlContent);
                        mimeTypeBlock = "text/html";
                        responseDataBlock.assign(htmlContent, htmlContent + len);
                        hasResponseBlock = true;
                        free((void*)htmlContent); // Free the strdup'd memory
                    } else {
                        NSLog(@"DEBUG CEF: No HTML content to load");
                    }
                } else {
                    NSLog(@"DEBUG CEF: Attempting to read views file: %s", urlStr.c_str());
                    NSData *data = readViewsFile(urlStr.c_str());
                    if (data) {   
                        NSLog(@"DEBUG CEF: Successfully read views file, length: %lu", (unsigned long)data.length);
                        // Determine MIME type using shared function
                        std::string mimeType = getMimeTypeFromUrl(relativePath);
                        const char* mimeTypePtr = strdup(mimeType.c_str());
                        NSLog(@"DEBUG CEF: Set MIME type '%s' for file: %s", mimeType.c_str(), relativePath.c_str());
                        // REMOVED: jsUtils.getMimeType callback (now using file extension detection)
                        
                        if (mimeTypePtr) {
                            mimeTypeBlock = std::string(mimeTypePtr);
                            free((void*)mimeTypePtr); // Free the strdup'd memory
                        } else {
                            mimeTypeBlock = "text/html"; // Fallback
                        }

                        responseDataBlock.assign((const char*)data.bytes,
                                            (const char*)data.bytes + data.length);
                        hasResponseBlock = true;
                    } else {
                        NSLog(@"DEBUG CEF: Failed to read views file: %s", urlStr.c_str());
                    }
                }
            }
            else {
                NSLog(@"Unknown URL format: %s", urlStr.c_str());
            }
        });
        
        // Copy the results back to the member variables
        mimeType_ = mimeTypeBlock;
        responseData_.assign(responseDataBlock.begin(), responseDataBlock.end());
        hasResponse_ = hasResponseBlock;
        handle_request = true;

        return hasResponse_;
    }

    void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirectUrl) override {
        if (!hasResponse_) {
        response->SetStatus(404);
        response_length = 0;
        return;
        }

        response->SetMimeType(mimeType_);
        response->SetStatus(200);
        response_length = responseData_.size();

        CefResponse::HeaderMap headers;
        headers.insert(std::make_pair("Access-Control-Allow-Origin", "*"));
        response->SetHeaderMap(headers);
    }

    bool Read(void* data_out,
                int bytes_to_read,
                int& bytes_read,
                CefRefPtr<CefResourceReadCallback> callback) override {
        bytes_read = 0;
        if (!hasResponse_ || offset_ >= responseData_.size()) {
        return false;
        }
        size_t remaining = responseData_.size() - offset_;
        bytes_read = std::min(bytes_to_read, static_cast<int>(remaining));
        memcpy(data_out, responseData_.data() + offset_, bytes_read);
        offset_ += bytes_read;
        return true;
    }

    void Cancel() override {
        // Optionally log cancellation.
    }

    private:
    uint32_t webviewId_;
    std::string mimeType_;
    std::vector<char> responseData_;
    bool hasResponse_;
    size_t offset_;

    IMPLEMENT_REFCOUNTING(ElectrobunSchemeHandler);
    DISALLOW_COPY_AND_ASSIGN(ElectrobunSchemeHandler);
};


// Global map to track browser to webview ID mapping
static std::map<int, uint32_t> browserToWebviewMap;
static std::mutex browserMapMutex;

// The factory class that creates scheme handlers
class ElectrobunSchemeHandlerFactory : public CefSchemeHandlerFactory {
public:
  ElectrobunSchemeHandlerFactory() {}

  CefRefPtr<CefResourceHandler> Create(CefRefPtr<CefBrowser> browser,
                                         CefRefPtr<CefFrame> frame,
                                         const CefString& scheme_name,
                                         CefRefPtr<CefRequest> request) override {
    
    NSLog(@"DEBUG CEF Factory: Create called for URL: %s", request->GetURL().ToString().c_str());
    
    // Get webview ID from browser ID
    std::lock_guard<std::mutex> lock(browserMapMutex);
    int browserId = browser->GetIdentifier();
    auto it = browserToWebviewMap.find(browserId);
    uint32_t webviewId = (it != browserToWebviewMap.end()) ? it->second : 0;
    
    NSLog(@"DEBUG CEF Factory: Creating handler for browser %d -> webview %u", browserId, webviewId);
    
    // Debug: print all current mappings
    NSLog(@"DEBUG CEF Factory: Current browser-to-webview mappings:");
    for (const auto& pair : browserToWebviewMap) {
        NSLog(@"  Browser %d -> Webview %u", pair.first, pair.second);
    }
    
    return new ElectrobunSchemeHandler(webviewId);
  }
  
  IMPLEMENT_REFCOUNTING(ElectrobunSchemeHandlerFactory);
  DISALLOW_COPY_AND_ASSIGN(ElectrobunSchemeHandlerFactory);
};





// Utility function for WKWebsiteDataStore creation:



// Platform implementation for partition_context.h — builds the on-disk
// cache_path for a persistent partition under the macOS Application Support
// directory, ensuring the directory exists.
namespace electrobun {
std::string buildAndEnsurePartitionCachePath(const std::string& partitionName) {
    NSString* appSupportPath = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    if (!appSupportPath) return "";

    std::string cachePathStr = buildCEFPartitionPath(
        [appSupportPath UTF8String],
        g_electrobunIdentifier,
        g_electrobunChannel,
        "CEF",
        partitionName);

    NSString* cachePath = [NSString stringWithUTF8String:cachePathStr.c_str()];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:cachePath]) {
        [fileManager createDirectoryAtPath:cachePath
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];
    }
    return cachePathStr;
}
} // namespace electrobun

CefRefPtr<CefRequestContext> CreateRequestContextForPartition(const char* partitionIdentifier,
                                                               uint32_t webviewId) {
    static CefRefPtr<ElectrobunSchemeHandlerFactory> schemeFactory =
        new ElectrobunSchemeHandlerFactory();
    return electrobun::getOrCreateRequestContextForPartition(
        partitionIdentifier, webviewId, schemeFactory);
}

// ----------------------- CEFWebViewImpl -----------------------


@implementation CEFWebViewImpl {}

    - (instancetype)initWithWebviewId:(uint32_t)webviewId
                            window:(NSWindow *)window
                                url:(const char *)url
                            frame:(NSRect)frame
                        autoResize:(bool)autoResize
                partitionIdentifier:(const char *)partitionIdentifier
                navigationCallback:(DecideNavigationCallback)navigationCallback
                webviewEventHandler:(WebviewEventHandler)webviewEventHandler
                eventBridgeHandler:(HandlePostMessage)eventBridgeHandler
                bunBridgeHandler:(HandlePostMessage)bunBridgeHandler
            internalBridgeHandler:(HandlePostMessage)internalBridgeHandler
            electrobunPreloadScript:(const char *)electrobunPreloadScript
            customPreloadScript:(const char *)customPreloadScript
            viewsRoot:(const char *)viewsRoot
            transparent:(bool)transparent
            sandbox:(bool)sandbox
    {
        self = [super init];
        if (self) {
            self.webviewId = webviewId;
            self.isSandboxed = sandbox;

            if (autoResize) {
                self.fullSize = YES;
            } else {
                self.fullSize = NO;
            }

            void (^createCEFBrowser)(void) = ^{
                [window makeKeyAndOrderFront:nil];
                CefBrowserSettings browserSettings;

                // Set transparent background if requested
                if (transparent) {
                    // CEF uses ARGB format: 0x00000000 = fully transparent
                    browserSettings.background_color = 0;
                }

                CefWindowInfo window_info;
                window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

                NSView *contentView = window.contentView;

                CGFloat adjustedY = contentView.bounds.size.height - frame.origin.y - frame.size.height;
                CefRect cefBounds((int)frame.origin.x,
                                (int)adjustedY,
                                (int)frame.size.width,
                                (int)frame.size.height);

                // Use OSR (windowless) mode for transparent windows
                if (transparent) {
                    self.isOSRMode = YES;
                    // Create OSR view
                    NSRect osrFrame = NSMakeRect(frame.origin.x, adjustedY, frame.size.width, frame.size.height);
                    self.osrView = [[CEFOSRView alloc] initWithFrame:osrFrame];
                    [contentView addSubview:self.osrView];
                    self.nsView = self.osrView;

                    // Use windowless (off-screen) rendering for transparency
                    // Pass the window handle for context menu positioning, etc.
                    window_info.SetAsWindowless((__bridge void*)window);
                } else {
                    self.isOSRMode = NO;
                    window_info.SetAsChild((__bridge void*)contentView, cefBounds);
                }

                CefRefPtr<CefRequestContext> requestContext = CreateRequestContextForPartition(
                    partitionIdentifier,
                    webviewId
                );


                // Global scheme handler is already registered in getOrCreateRequestContext()

                self.client = new ElectrobunClient(
                    webviewId,
                    eventBridgeHandler,
                    bunBridgeHandler,
                    internalBridgeHandler,
                    webviewEventHandler,
                    navigationCallback,
                    sandbox
                );

                // Configure OSR if enabled
                if (transparent && self.osrView) {
                    self.client->SetOSRView(self.osrView);
                    self.client->SetViewSize((int)frame.size.width, (int)frame.size.height);
                }                

                // store the script values
                [self addPreloadScriptToWebView:electrobunPreloadScript];
                
                // Note: For custom preload scripts we support either inline js or a views:// style
                // url to a js file in the bundled views folder.
                if (strncmp(customPreloadScript, "views://", 8) == 0) {                    
                    NSData *scriptData = readViewsFile(customPreloadScript);
                    if (scriptData) {                        
                        NSString *scriptString = [[NSString alloc] initWithData:scriptData encoding:NSUTF8StringEncoding];                        
                        const char *scriptCString = [scriptString UTF8String];
                        [self updateCustomPreloadScript:scriptCString];
                    }
                } else {
                    [self updateCustomPreloadScript:customPreloadScript];
                }                            


                // Note: We must create a browser with about:blank first so that self.browser can be set
                // Otherwise we get a race condition where OOPIF events hit bun then get passed to the parent
                // webview which is still in the middle of a CreateBrowserSync and fails to call
                // self.browser->GetMainFrame()->ExecuteJavascript.
                NSLog(@"DEBUG CEF: Creating browser, OSR mode: %@, view size: %dx%d, sandbox: %@",
                      self.isOSRMode ? @"YES" : @"NO",
                      (int)frame.size.width, (int)frame.size.height,
                      sandbox ? @"YES" : @"NO");

                // Pass sandbox flag to renderer process via extra_info
                CefRefPtr<CefDictionaryValue> extra_info = CefDictionaryValue::Create();
                extra_info->SetBool("sandbox", sandbox);

                self.browser = CefBrowserHost::CreateBrowserSync(
                    window_info, self.client, CefString("about:blank"), browserSettings, extra_info, requestContext);
                NSLog(@"DEBUG CEF: Browser created successfully");

                if (self.browser) {
                    // Register browser-to-webview mapping for global scheme handler
                    int browserId = self.browser->GetIdentifier();
                    {
                        std::lock_guard<std::mutex> lock(browserMapMutex);
                        browserToWebviewMap[browserId] = self.webviewId;
                    }
                    NSLog(@"DEBUG CEF Mapping: Registered browser %d -> webview %u", browserId, self.webviewId);

                    if (self.isOSRMode) {
                        // In OSR mode, pass browser reference to the OSR view for event handling
                        // Allocate a CefRefPtr on heap that lives with this webview instance
                        CefRefPtr<CefBrowser>* browserPtr = new CefRefPtr<CefBrowser>(self.browser);
                        [self.osrView setCefBrowser:browserPtr];
                        NSLog(@"DEBUG CEF OSR: Browser created in OSR mode for transparent window");
                    } else {
                        // In windowed mode, get the native view handle
                        CefWindowHandle handle = self.browser->GetHost()->GetWindowHandle();
                        self.nsView = (__bridge NSView *)handle;
                        self.nsView.autoresizingMask = NSViewNotSizable;
                    }
                }


                ContainerView *containerView = (ContainerView *)window.contentView;
                [containerView addAbstractView:self];

                // Apply deferred initial transparent/passthrough state now that nsView is set
                if (self.pendingStartTransparent) {
                    [self setTransparent:YES];
                }
                if (self.pendingStartPassthrough) {
                    [self setPassthrough:YES];
                }

                if (self.browser && url && url[0] != '\0') {
                    self.browser->GetMainFrame()->LoadURL(CefString(url));
                } else if (!self.browser) {
                    NSLog(@"ERROR CEF: CreateBrowserSync returned null for webview %u (partition: %s) — initial URL not loaded",
                          webviewId, partitionIdentifier ? partitionIdentifier : "(default)");
                }
            };
            
            // TODO: revisit bug with 3+ CEF windows created in rapid succession - the 3rd window's
            // OOPIF fails to initialize/render. Windows 1 & 2 work fine. Separately opened windows
            // also work. Likely a race condition in concurrent browser creation.
            // Test: kitchen sink "Multi-window CEF OOPIF test" in interactive tests.
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            NSArray *notificationNames = @[ NSWindowDidUpdateNotification ];
            __block BOOL hasCreatedBrowser = NO;
            for (NSString *notificationName in notificationNames) {
                [center addObserverForName:notificationName
                                object:window
                                    queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *note) {
                    
                    if (!hasCreatedBrowser) {
                        hasCreatedBrowser = YES;                    
                        createCEFBrowser();
                        
                    }
                }];
            }
            [window makeKeyAndOrderFront:nil];

            // Force trigger window update to ensure CEF browser is created immediately
            dispatch_async(dispatch_get_main_queue(), ^{
                // Trigger a window update notification to ensure CEF browser creation
                // This prevents the delay that would otherwise wait for mouse movement
                [window display];
                [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidUpdateNotification
                                                                    object:window];
            });

    
            // dispatch_async(dispatch_get_main_queue(), ^{               
                // dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                //     createCEFBrowser();
                //     NSLog(@"-----------------> DISPATCH 1");
                // });
            // });

            
        }
        
        // Add to global tracking map
        if (globalAbstractViews) {
            globalAbstractViews[@(self.webviewId)] = self;
        } else {
            NSLog(@"CEFWebViewImpl: ERROR - globalAbstractViews is nil when trying to add webview %u", self.webviewId);
        }
        
        return self;
    }


    - (void)loadURL:(const char *)urlString {
        if (!self.browser)
            return;

        CefString cefUrl = urlString ? urlString : "";
        self.browser->GetMainFrame()->LoadURL(cefUrl);
    }

    - (void)loadHTML:(const char *)htmlString {
        if (!self.browser)
            return;

        NSLog(@"DEBUG CEF: Loading HTML content directly: %.50s...", htmlString);
        // Store HTML content in the global map for the scheme handler
        setWebviewHTMLContent(self.webviewId, htmlString);
        // Load the internal scheme URL which will trigger our scheme handler
        self.browser->GetMainFrame()->LoadURL(CefString("views://internal/index.html"));
    }

    - (void)goBack {   
        if (self.browser)
            self.browser->GoBack();
    }

    - (void)goForward {
        if (self.browser)
            self.browser->GoForward();
    }

    - (void)reload {
        if (self.browser)
            self.browser->Reload();
    }

    - (void)remove {
        
        // Stop loading, close the browser, remove from superview, etc.
        if (self.browser) {
            NSLog(@"CEFWebViewImpl remove: closing CEF browser for webview %u", self.webviewId);
            // Tells CEF to close the browser window
            self.browser->GetHost()->CloseBrowser(false);
            self.browser = nullptr;
            NSLog(@"CEFWebViewImpl remove: CEF browser closed and set to nullptr for webview %u", self.webviewId);
        } else {
            NSLog(@"CEFWebViewImpl remove: browser is already null for webview %u", self.webviewId);
        }
        
        if (self.nsView) {
            
            // Remove from ContainerView's tracking array first
            if (self.nsView.superview && [self.nsView.superview isKindOfClass:[ContainerView class]]) {
                ContainerView *containerView = (ContainerView *)self.nsView.superview;
                [containerView removeAbstractViewWithId:self.webviewId];
                NSLog(@"CEFWebViewImpl remove: removed from ContainerView tracking");
            } else {
                NSLog(@"CEFWebViewImpl remove: superview is not ContainerView or is nil");
            }
            
            // Keep a weak reference to the view for delayed removal
            NSView *viewToRemove = self.nsView;
            uint32_t webviewIdForLogging = self.webviewId;
            
            // Set nsView to nil immediately to prevent further operations
            NSLog(@"CEFWebViewImpl remove: setting nsView to nil for webview %u", self.webviewId);
            self.nsView = nil;
            
            // Check if the view is still in a superview before trying to remove it
            if (viewToRemove.superview != nil) {
                NSLog(@"CEFWebViewImpl remove: scheduling delayed removeFromSuperview for webview %u", webviewIdForLogging);
                
                // Delay the removeFromSuperview call to allow CEF to finish cleanup
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"CEFWebViewImpl remove: executing delayed removeFromSuperview for webview %u", webviewIdForLogging);
                    
                    @try {
                        // Double-check superview still exists at execution time
                        if (viewToRemove.superview != nil) {
                            [viewToRemove removeFromSuperview];
                            NSLog(@"CEFWebViewImpl remove: delayed removeFromSuperview completed for webview %u", webviewIdForLogging);
                        } else {
                            NSLog(@"CEFWebViewImpl remove: superview became nil before delayed removal for webview %u", webviewIdForLogging);
                        }
                    } @catch (NSException *exception) {
                        NSLog(@"CEFWebViewImpl remove: EXCEPTION during delayed removeFromSuperview for webview %u: %@", webviewIdForLogging, exception);
                    } @finally {
                        NSLog(@"CEFWebViewImpl remove: delayed removeFromSuperview attempt finished for webview %u", webviewIdForLogging);
                    }
                });
            } else {
                NSLog(@"CEFWebViewImpl remove: nsView has no superview, skipping removeFromSuperview");
            }
        } else {
            NSLog(@"CEFWebViewImpl remove: nsView is already nil for webview %u", self.webviewId);
        }
        
        NSLog(@"CEFWebViewImpl remove: COMPLETED cleanup for webview %u", self.webviewId);
    }


    - (BOOL)canGoBack {
        if (!self.browser) return NO;
        return self.browser->CanGoBack() ? YES : NO;
    }

    - (BOOL)canGoForward {
        if (!self.browser) return NO;
        return self.browser->CanGoForward() ? YES : NO;
    }

    - (void)evaluateJavaScriptWithNoCompletion:(const char*)jsString {    
        if (!jsString) return;
        
        CefRefPtr<CefFrame> mainFrame = self.browser->GetMainFrame();
        
        if (!mainFrame) {
            NSLog(@"[CEF] Failed to get main frame for JavaScript evaluation");
            return;
        }

        // Execute in the main context
        mainFrame->ExecuteJavaScript(
            CefString(jsString),
            mainFrame->GetURL(),
            0  // Line number for debugging
        );
    }

    - (const char*)evaluateJavaScriptSync:(const char*)jsString {
        return NULL;
    }

    - (void)callAsyncJavascript:(const char*)messageId 
                    jsString:(const char*)jsString 
                    webviewId:(uint32_t)webviewId 
                hostWebviewId:(uint32_t)hostWebviewId 
            completionHandler:(callAsyncJavascriptCompletionHandler)completionHandler {
        

        NSLog(@"TODO: Implement callAsyncJavascript for CEF when refactoring the entire RPC system");
        completionHandler(messageId, webviewId, hostWebviewId, "\"\"");   
    }

    - (void)addPreloadScriptToWebView:(const char*)jsString {
        if (!jsString) return;
        
        std::string script(jsString);
        self.client->AddPreloadScript(script);
    }

    - (void)updateCustomPreloadScript:(const char*)jsString {
        if (!jsString) return;

        std::string script(jsString);
        self.client->UpdateCustomPreloadScript(script);
    }

    - (void)findInPage:(const char*)searchText forward:(BOOL)forward matchCase:(BOOL)matchCase {
        if (!self.browser) return;

        CefRefPtr<CefBrowserHost> host = self.browser->GetHost();
        if (!host) return;

        if (!searchText || strlen(searchText) == 0) {
            // Stop find and clear highlights
            host->StopFinding(true);
            return;
        }

        // CEF Find flags
        bool findNext = false; // Will be set based on direction changes
        bool forwardDirection = forward ? true : false;
        bool caseSensitive = matchCase ? true : false;

        // Use CEF's native find functionality
        host->Find(CefString(searchText), forwardDirection, caseSensitive, findNext);
    }

    - (void)stopFindInPage {
        if (!self.browser) return;

        CefRefPtr<CefBrowserHost> host = self.browser->GetHost();
        if (host) {
            host->StopFinding(true); // true = clear selection
        }
    }

    - (void)openDevTools {
        // Use existing remote debugger approach for CEF
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.browser) {
                self.client->OpenRemoteDevTools(self.browser);
            }
        });
    }

    - (void)closeDevTools {
        // Close remote debugger window
        dispatch_async(dispatch_get_main_queue(), ^{
            self.client->CloseRemoteDevTools();
        });
    }

    - (void)toggleDevTools {
        // Toggle remote debugger window
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.browser) {
                self.client->ToggleRemoteDevTools(self.browser);
            }
        });
    }

@end


// ----------------------- AppDelegate & WindowDelegate -----------------------

@implementation AppDelegate
    - (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
        // If we're already in shutdown sequence (stopEventLoop was called), allow termination
        if (g_eventLoopStopping.load()) {
            return NSTerminateNow;
        }

        // If a quit handler is registered, ask bun to run its quit sequence
        if (g_quitRequestedHandler) {
            g_quitRequestedHandler();
            return NSTerminateCancel;
        }

        // No handler registered, allow immediate termination (fallback)
        return NSTerminateNow;
    }

    // Handle URLs opened via custom URL schemes (deep linking)
    - (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
        std::lock_guard<std::mutex> lock(g_urlOpenMutex);
        for (NSURL *url in urls) {
            if (g_urlOpenHandler) {
                g_urlOpenHandler([[url absoluteString] UTF8String]);
            } else {
                // Buffer the URL — the Bun Worker hasn't registered its handler yet.
                g_pendingUrlOpenPaths.push_back(std::string([[url absoluteString] UTF8String]));
            }
        }
    }

    - (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)hasVisibleWindows {
        (void)hasVisibleWindows;

        [application activateIgnoringOtherApps:YES];

        if (g_appReopenHandler) {
            g_appReopenHandler();
        }

        return YES;
    }
@end

@implementation WindowDelegate
    - (BOOL)windowShouldClose:(NSWindow *)sender {
    return YES;
    }
    - (void)windowWillClose:(NSNotification *)notification {
        NSWindow *window = [notification object];

        // cmd+W / red traffic-light close goes straight to Cocoa's window
        // deallocation path — `AbstractView::remove` (where the explicit
        // media-stop lives) is never called. Without this, MSE-based players
        // (YouTube etc.) keep audio playing in WebKit's WebContent process for
        // a moment after the window is gone. Pause + clear every <video>/<audio>
        // synchronously now so the audio HAL releases samples before the
        // webview is torn down.
        NSView *contentView = [window contentView];
        if ([contentView isKindOfClass:[ContainerView class]]) {
            ContainerView *containerView = (ContainerView *)contentView;
            for (AbstractView *abstractView in containerView.abstractViews) {
                if (![abstractView isKindOfClass:[WKWebViewImpl class]]) continue;
                WKWebView *wv = ((WKWebViewImpl *)abstractView).webView;
                if (!wv) continue;
                @try {
                    [wv evaluateJavaScript:@"(function(){try{document.querySelectorAll('video,audio').forEach(function(m){try{m.pause();m.muted=true;m.removeAttribute('src');m.srcObject=null;m.load();}catch(e){}});}catch(e){}})()"
                                   inFrame:nil
                            inContentWorld:[WKContentWorld pageWorld]
                         completionHandler:nil];
                    [wv stopLoading];
                } @catch (NSException *e) {}
            }
        }

        if (self.closeHandler) {
            self.closeHandler(self.windowId);
        }
    }
    - (void)windowDidResize:(NSNotification *)notification {
        NSWindow *window = [notification object];
        NSRect windowFrame = [window frame];
        ContainerView *containerView = [window contentView];
        // Use the content view's bounds (excludes title bar) instead of the
        // window frame so fullSize webviews don't overflow the visible area.
        NSRect fullFrame = containerView.bounds;

        for (AbstractView *abstractView in containerView.abstractViews) {
            if (abstractView.fullSize) {
                [abstractView resize:fullFrame withMasksJSON:""];
            }
        }

        if (self.resizeHandler) {
            NSScreen *primaryScreen = [NSScreen screens][0];
            NSRect screenFrame = [primaryScreen frame];
            windowFrame.origin.y = screenFrame.size.height - windowFrame.origin.y - windowFrame.size.height;
            NSRect contentRect = [window contentRectForFrameRect:windowFrame];
            self.resizeHandler(self.windowId, windowFrame.origin.x, windowFrame.origin.y,
                               contentRect.size.width, contentRect.size.height);
        }

        if (self.hasCustomButtonPosition) {
            applyWindowButtonPosition(window, self.buttonPositionX, self.buttonPositionY);
        } else {
            applyTrafficLightOffsetFromDefault(window);
        }
    }
    - (void)windowWillExitFullScreen:(NSNotification *)notification {
        if (self.hasCustomButtonPosition) {
            NSWindow *window = [notification object];
            [[window standardWindowButton:NSWindowCloseButton] setHidden:YES];
            [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
            [[window standardWindowButton:NSWindowZoomButton] setHidden:YES];
        }
    }
    - (void)windowWillEnterFullScreen:(NSNotification *)notification {
        NSWindow *window = [notification object];
        if (getConfiguredWindowCornerRadius(window) > 0) {
            applyWindowCornerRadius(window, 0);
        }
    }
    - (void)windowDidExitFullScreen:(NSNotification *)notification {
        NSWindow *window = [notification object];
        double cornerRadius = getConfiguredWindowCornerRadius(window);
        if (cornerRadius > 0) {
            applyWindowCornerRadius(window, cornerRadius);
        }
        if (self.hasCustomButtonPosition) {
            applyWindowButtonPosition(window, self.buttonPositionX, self.buttonPositionY);
            [[window standardWindowButton:NSWindowCloseButton] setHidden:NO];
            [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:NO];
            [[window standardWindowButton:NSWindowZoomButton] setHidden:NO];
        } else {
            applyTrafficLightOffsetFromDefault(window);
        }
    }
    - (void)windowDidMove:(NSNotification *)notification {
        if (self.moveHandler) {
            NSWindow *window = [notification object];
            NSRect windowFrame = [window frame];
            NSScreen *primaryScreen = [NSScreen screens][0];
            NSRect screenFrame = [primaryScreen frame];
            windowFrame.origin.y = screenFrame.size.height - windowFrame.origin.y - windowFrame.size.height;
            self.moveHandler(self.windowId, windowFrame.origin.x, windowFrame.origin.y);
        }
    }
    - (void)windowDidBecomeKey:(NSNotification *)notification {
        if (self.focusHandler) {
            self.focusHandler(self.windowId);
        }

        // Prefer WGPU input view as first responder so key events reach GPU windows.
        NSWindow *window = [notification object];
        ContainerView *containerView = [window contentView];
        for (AbstractView *abstractView in containerView.abstractViews) {
            if (abstractView.nsView && [abstractView.nsView isKindOfClass:[WGPUInputView class]]) {
                [window makeFirstResponder:abstractView.nsView];
                break;
            }
        }
    }
    - (void)windowDidResignKey:(NSNotification *)notification {
        if (self.blurHandler) {
            self.blurHandler(self.windowId);
        }
    }
@end

// ----------------------- NavigationToolbarDelegate -----------------------

@implementation NavigationToolbarDelegate

- (AbstractView *)activeWebviewForWindow:(NSWindow *)window {
    if (![window.contentView isKindOfClass:[ContainerView class]]) return nil;
    ContainerView *container = (ContainerView *)window.contentView;
    return container.abstractViews.lastObject;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NavigationBackItemIdentifier, NavigationForwardItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return @[NavigationBackItemIdentifier, NavigationForwardItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];

    if ([itemIdentifier isEqualToString:NavigationBackItemIdentifier]) {
        item.image = [NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Back"];
        item.label = @"Back";
        item.action = @selector(navigateBack:);
        item.target = self;
    } else if ([itemIdentifier isEqualToString:NavigationForwardItemIdentifier]) {
        item.image = [NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Forward"];
        item.label = @"Forward";
        item.action = @selector(navigateForward:);
        item.target = self;
    }

    return item;
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)item {
    NSWindow *window = [item.toolbar valueForKey:@"_window"];
    if (!window) {
        for (NSWindow *w in [NSApp windows]) {
            if (w.toolbar == item.toolbar) { window = w; break; }
        }
    }
    if (!window) return NO;

    AbstractView *view = [self activeWebviewForWindow:window];
    if (!view) return NO;

    if ([item.itemIdentifier isEqualToString:NavigationBackItemIdentifier]) {
        return [view canGoBack];
    }
    if ([item.itemIdentifier isEqualToString:NavigationForwardItemIdentifier]) {
        return [view canGoForward];
    }
    return YES;
}

- (void)navigateBack:(NSToolbarItem *)sender {
    NSWindow *window = sender.toolbar ? [self windowForToolbar:sender.toolbar] : nil;
    if (!window) return;
    AbstractView *view = [self activeWebviewForWindow:window];
    if (view) [view goBack];
}

- (void)navigateForward:(NSToolbarItem *)sender {
    NSWindow *window = sender.toolbar ? [self windowForToolbar:sender.toolbar] : nil;
    if (!window) return;
    AbstractView *view = [self activeWebviewForWindow:window];
    if (view) [view goForward];
}

- (NSWindow *)windowForToolbar:(NSToolbar *)toolbar {
    for (NSWindow *w in [NSApp windows]) {
        if (w.toolbar == toolbar) return w;
    }
    return nil;
}

@end

/*
 * =============================================================================
 * 6. EXTERN "C" BRIDGING FUNCTIONS
 * =============================================================================
 */

// Note: This is executed from the main bun thread
// Note: `name` parameter is accepted for API consistency with Windows but not used on macOS
// Forward declaration - stopEventLoop is defined after startEventLoop
extern "C" void stopEventLoop();

extern "C" void startEventLoop(const char* identifier, const char* name, const char* channel) {
    (void)name; // Unused on macOS - kept for API consistency with Windows/Linux

    // Store identifier and channel globally for use in CEF initialization
    if (identifier && identifier[0]) {
        g_electrobunIdentifier = std::string(identifier);
    }
    if (channel && channel[0]) {
        g_electrobunChannel = std::string(channel);
    }

    useCEF = isCEFAvailable();    
    
    // Initialize the global AbstractView tracking map
    if (!globalAbstractViews) {
        globalAbstractViews = [[NSMutableDictionary alloc] init];
    }
    
    // Initialize webview HTML content storage
    if (!webviewHTMLContent) {
        webviewHTMLContent = [[NSMutableDictionary alloc] init];
        webviewHTMLLock = [[NSLock alloc] init];
    }
    
    // Set up dispatch sources for SIGINT and SIGTERM so they work regardless of
    // which event loop is running (CefRunMessageLoop or [NSApp run]).
    // bun's process.on("SIGINT") depends on bun's event loop to forward signals
    // to the Worker, which doesn't work when the main thread is in [NSApp run].
    // Dispatch sources deliver signal events on the main queue, which both
    // [NSApp run] and CefRunMessageLoop process.
    signal(SIGINT, SIG_IGN);
    signal(SIGTERM, SIG_IGN);

    static int sigint_count = 0;

    dispatch_source_t sigintSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigintSource, ^{
        sigint_count++;
        if (sigint_count == 1) {
            if (g_quitRequestedHandler && !g_eventLoopStopping.load()) {
                g_quitRequestedHandler();
            } else {
                stopEventLoop();
            }
        } else {
            // Second Ctrl+C: force kill entire process group
            kill(0, SIGKILL);
        }
    });
    dispatch_resume(sigintSource);

    dispatch_source_t sigtermSource = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigtermSource, ^{
        if (g_quitRequestedHandler && !g_eventLoopStopping.load()) {
            g_quitRequestedHandler();
        } else {
            stopEventLoop();
        }
    });
    dispatch_resume(sigtermSource);

    if (useCEF) {
        @autoreleasepool {
            if (!initializeCEF()) {
                return;
            }
            NSApplication *app = [NSApplication sharedApplication];
            AppDelegate *delegate = [[AppDelegate alloc] init];
            [app setDelegate:delegate];
            retainObjCObject(delegate);
            [NSApp finishLaunching];
            CefRunMessageLoop();
            CefShutdown();
            g_shutdownComplete.store(true);
        }
    } else {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        retainObjCObject(delegate);
        [app run];
        g_shutdownComplete.store(true);
    }
}

extern "C" void stopEventLoop() {
    if (g_eventLoopStopping.exchange(true)) {
        NSLog(@"[stopEventLoop] Already stopping, ignoring duplicate call");
        return;
    }

    // Intentionally no log here - output after shell prompt return is confusing in dev mode

    if (useCEF) {
        // CefQuitMessageLoop must be called on the main thread on macOS because
        // CEF's message loop is integrated with the Cocoa run loop.
        // dispatch_async to the main queue is processed by CefRunMessageLoop().
        dispatch_async(dispatch_get_main_queue(), ^{
            CefQuitMessageLoop();
        });
    } else {
        // [NSApp stop:nil] is thread-safe per Apple docs
        // Post a dummy event to ensure the run loop wakes up and processes the stop
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSApplication sharedApplication] stop:nil];
            NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                               location:NSMakePoint(0, 0)
                                          modifierFlags:0
                                              timestamp:0
                                           windowNumber:0
                                                context:nil
                                                subtype:0
                                                  data1:0
                                                  data2:0];
            [[NSApplication sharedApplication] postEvent:event atStart:YES];
        });
    }
}

extern "C" void killApp() {
    // Deprecated - delegates to stopEventLoop for backward compatibility
    stopEventLoop();
}

extern "C" void waitForShutdownComplete(int timeoutMs) {
    int waited = 0;
    while (!g_shutdownComplete.load() && waited < timeoutMs) {
        usleep(10000); // 10ms
        waited += 10;
    }
    if (!g_shutdownComplete.load()) {
        NSLog(@"[waitForShutdownComplete] Timed out after %dms", timeoutMs);
    }
}

extern "C" void forceExit(int code) {
    // Last-resort exit that skips atexit handlers.
    // Used when waitForShutdownComplete times out and calling exit() would
    // deadlock on atexit handlers trying to join still-running CEF threads.
    _exit(code);
}

extern "C" void setQuitRequestedHandler(QuitRequestedHandler handler) {
    g_quitRequestedHandler = handler;
}

extern "C" void shutdownApplication() {
    // Deprecated - CefShutdown now runs inline in startEventLoop after event loop returns
    stopEventLoop();
}



// Global flags set by setNextWebviewFlags, consumed by initWebview
static struct {
    bool startTransparent;
    bool startPassthrough;
} g_nextWebviewFlags = {false, false};

extern "C" void setNextWebviewFlags(bool startTransparent, bool startPassthrough) {
    g_nextWebviewFlags.startTransparent = startTransparent;
    g_nextWebviewFlags.startPassthrough = startPassthrough;
}

extern "C" AbstractView* initWebview(uint32_t webviewId,
                        NSWindow *window,
                        const char *renderer,
                        const char *url,
                        double x, double y,
                        double width, double height,
                        bool autoResize,
                        const char *partitionIdentifier,
                        DecideNavigationCallback navigationCallback,
                        WebviewEventHandler webviewEventHandler,
                        HandlePostMessage eventBridgeHandler,
                        HandlePostMessage bunBridgeHandler,
                        HandlePostMessage internalBridgeHandler,
                        const char *electrobunPreloadScript,
                        const char *customPreloadScript,
                        const char *viewsRoot,
                        bool transparent,
                        bool sandbox ) {

    // Read and clear pre-set flags
    bool startTransparent = g_nextWebviewFlags.startTransparent;
    bool startPassthrough = g_nextWebviewFlags.startPassthrough;
    g_nextWebviewFlags = {false, false};

    // Validate frame values - use defaults if NaN or invalid
    if (isnan(x) || isinf(x)) {
        NSLog(@"WARNING initWebview: x is NaN/Inf for webview %u, using 0", webviewId);
        x = 0;
    }
    if (isnan(y) || isinf(y)) {
        NSLog(@"WARNING initWebview: y is NaN/Inf for webview %u, using 0", webviewId);
        y = 0;
    }
    if (isnan(width) || isinf(width) || width <= 0) {
        NSLog(@"WARNING initWebview: width is NaN/Inf/invalid for webview %u, using 100", webviewId);
        width = 100;
    }
    if (isnan(height) || isinf(height) || height <= 0) {
        NSLog(@"WARNING initWebview: height is NaN/Inf/invalid for webview %u, using 100", webviewId);
        height = 100;
    }

    NSRect frame = NSMakeRect(x, y, width, height);

    __block AbstractView *impl = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
        Class ImplClass = (strcmp(renderer, "cef") == 0 && useCEF) ? [CEFWebViewImpl class] : [WKWebViewImpl class];

        impl = [[ImplClass alloc] initWithWebviewId:webviewId
                                        window:window
                                        url:strdup(url)
                                        frame:frame
                                        autoResize:autoResize
                                        partitionIdentifier:strdup(partitionIdentifier)
                                        navigationCallback:navigationCallback
                                        webviewEventHandler:webviewEventHandler
                                        eventBridgeHandler:eventBridgeHandler
                                        bunBridgeHandler:bunBridgeHandler
                                        internalBridgeHandler:internalBridgeHandler
                                        electrobunPreloadScript:strdup(electrobunPreloadScript)
                                        customPreloadScript:strdup(customPreloadScript)
                                        viewsRoot:strdup(viewsRoot)
                                        transparent:transparent
                                        sandbox:sandbox];

        // Store initial state flags — applied later in each impl's deferred creation block
        // (nsView is nil at this point because view creation is async)
        impl.pendingStartTransparent = startTransparent;
        impl.pendingStartPassthrough = startPassthrough;

    });

    return impl;
}

extern "C" AbstractView* initWGPUView(uint32_t webviewId,
                        NSWindow *window,
                        double x, double y,
                        double width, double height,
                        bool autoResize,
                        bool startTransparent,
                        bool startPassthrough) {

    // Validate frame values - use defaults if NaN or invalid
    if (isnan(x) || isinf(x)) x = 0;
    if (isnan(y) || isinf(y)) y = 0;
    if (isnan(width) || isinf(width) || width <= 0) width = 100;
    if (isnan(height) || isinf(height) || height <= 0) height = 100;

    NSRect frame = NSMakeRect(x, y, width, height);

    __block AbstractView *impl = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
        impl = [[WGPUViewImpl alloc] initWithWebviewId:webviewId
                                                window:window
                                                 frame:frame
                                            autoResize:autoResize];
        impl.pendingStartTransparent = startTransparent;
        impl.pendingStartPassthrough = startPassthrough;
    });

    return impl;
}

extern "C" MyScriptMessageHandlerWithReply* addScriptMessageHandlerWithReply(WKWebView *webView,
                                                                             uint32_t webviewId,
                                                                             const char *name,
                                                                             HandlePostMessageWithReply callback) {

    MyScriptMessageHandlerWithReply *handler = [[MyScriptMessageHandlerWithReply alloc] init];
    handler.zigCallback = callback;
    handler.webviewId = webviewId;
    [webView.configuration.userContentController addScriptMessageHandlerWithReply:handler
                                                                     contentWorld:WKContentWorld.pageWorld
                                                                             name:[NSString stringWithUTF8String:name ?: ""]];
    NSString *key = [NSString stringWithFormat:@"PostMessageHandlerWithReply{%s}", name];
    objc_setAssociatedObject(webView, key.UTF8String, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return handler;
}

extern "C" void loadURLInWebView(AbstractView *abstractView, const char *urlString) {
    if (!abstractView) {
        NSLog(@"loadURLInWebView: abstractView is null");
        return;
    }

    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"loadURLInWebView: webview %u not in tracking, skipping", abstractView.webviewId);
        return;
    }

    NSLog(@"DEBUG loadURLInWebView: webview %u loading URL: %s", abstractView.webviewId, urlString);
    [abstractView loadURL:urlString];
}

extern "C" void loadHTMLInWebView(AbstractView *abstractView, const char *htmlString) {
    if (!abstractView) {
        NSLog(@"loadHTMLInWebView: abstractView is null");
        return;
    }

    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"loadHTMLInWebView: webview %u not in tracking, skipping", abstractView.webviewId);
        return;
    }

    NSLog(@"DEBUG loadHTMLInWebView: webview %u loading HTML content", abstractView.webviewId);
    [abstractView loadHTML:htmlString];
}

extern "C" void webviewGoBack(AbstractView *abstractView) {   
    if (!abstractView) {
        NSLog(@"webviewGoBack: abstractView is null");
        return;
    }
    
    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"webviewGoBack: webview %u not in tracking, skipping", abstractView.webviewId);
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView goBack];
    });
}

extern "C" void wgpuViewSetFrame(AbstractView *abstractView, double x, double y, double width, double height) {
    if (!abstractView) {
        NSLog(@"wgpuViewSetFrame: abstractView is null");
        return;
    }
    NSRect frame = NSMakeRect(x, y, width, height);
    [abstractView storePendingResize:frame parsedMasks:nil];
    g_pendingResizeQueue.enqueue((__bridge void *)abstractView);
    schedulePendingResizeDrain();
}

extern "C" void wgpuViewSetTransparent(AbstractView *abstractView, BOOL transparent) {    
    if (!abstractView) return;
    [abstractView setTransparent:transparent];
}

extern "C" void wgpuViewSetPassthrough(AbstractView *abstractView, BOOL enablePassthrough) {    
    if (!abstractView) return;
    [abstractView setPassthrough:enablePassthrough];
}

extern "C" void wgpuViewSetHidden(AbstractView *abstractView, BOOL hidden) {
    if (!abstractView) return;
    [abstractView setHidden:hidden];
}

extern "C" void wgpuViewRemove(AbstractView *abstractView) {
    if (!abstractView) return;
    [abstractView remove];
}

extern "C" void* wgpuViewGetNativeHandle(AbstractView *abstractView) {
    if (!abstractView) return nullptr;
    __block void* result = nullptr;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!abstractView.nsView) return;
        CALayer *layer = abstractView.nsView.layer;
        if ([layer isKindOfClass:[CAMetalLayer class]]) {
            result = (__bridge void*)layer;
        }
    });
    return result;
}

extern "C" void webviewGoForward(AbstractView *abstractView) {
    if (!abstractView) {
        NSLog(@"webviewGoForward: abstractView is null");
        return;
    }
    
    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"webviewGoForward: webview %u not in tracking, skipping", abstractView.webviewId);
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView goForward];
    });
}

extern "C" void webviewReload(AbstractView *abstractView) {
    if (!abstractView) {
        NSLog(@"webviewReload: abstractView is null");
        return;
    }
    
    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"webviewReload: webview %u not in tracking, skipping", abstractView.webviewId);
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView reload];
    });
}

extern "C" void webviewRemove(AbstractView *abstractView) {
    if (!abstractView) {
        return;
    }

    // Check global tracking map instead of individual flag
    NSNumber *webviewKey = @(abstractView.webviewId);
    AbstractView *trackedView = globalAbstractViews[webviewKey];
    
    if (!trackedView) {
        return;
    }
    
    if (trackedView != abstractView) {
        NSLog(@"webviewRemove: WARNING - tracked view %p != passed view %p for webviewId %u", trackedView, abstractView, abstractView.webviewId);
    }
    
    // Remove from global tracking immediately to prevent re-entry
    [globalAbstractViews removeObjectForKey:webviewKey];
    [abstractView remove];
}

extern "C" BOOL webviewCanGoBack(AbstractView *abstractView) {
    if (!abstractView) {
        NSLog(@"webviewCanGoBack: abstractView is null");
        return NO;
    }
    
    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"webviewCanGoBack: webview %u not in tracking, returning NO", abstractView.webviewId);
        return NO;
    }
    
    return [abstractView canGoBack];
}

extern "C" BOOL webviewCanGoForward(AbstractView *abstractView) {
    if (!abstractView) {
        NSLog(@"webviewCanGoForward: abstractView is null");
        return NO;
    }
    
    // Check if webview still exists in global tracking
    if (!globalAbstractViews[@(abstractView.webviewId)]) {
        NSLog(@"webviewCanGoForward: webview %u not in tracking, returning NO", abstractView.webviewId);
        return NO;
    }
    
    return [abstractView canGoForward];
}

extern "C" void evaluateJavaScriptWithNoCompletion(AbstractView *abstractView, const char *script) {
    if (!abstractView) {
        return;
    }
    [abstractView evaluateJavaScriptWithNoCompletion:script];
}

extern "C" const char* evaluateJavascriptSync(AbstractView *abstractView, const char *script) {
    return [abstractView evaluateJavaScriptSync:script];
}

extern "C" void testFFI(void *ptr) {              
    NSLog(@"ObjC side - raw ptr: %p", ptr);
    
    // Dump memory contents
    uintptr_t *memory = (uintptr_t *)ptr;
    NSLog(@"Memory contents - first 4 words:");
    for(int i = 0; i < 4; i++) {
        NSLog(@"  Offset %d: %lx", i * 8, memory[i]);
    }
    
    // Try to get object type information
    Class cls = object_getClass((__bridge id)ptr);
    if (cls) {
        NSLog(@"Object appears to be of class: %@", cls);
    } else {
        NSLog(@"Not a valid Objective-C class pointer");
    }
    
    // Try to check vtable if it's a C++ object
    void **vtable = *(void***)ptr;
    NSLog(@"Possible vtable pointer: %p", vtable);
}

extern "C" void callAsyncJavaScript(const char *messageId,
                                    AbstractView *abstractView,
                                    const char *jsString,
                                    uint32_t webviewId,
                                    uint32_t hostWebviewId,
                                    callAsyncJavascriptCompletionHandler completionHandler) {

    
   [abstractView callAsyncJavascript:messageId
                        jsString:jsString
                       webviewId:webviewId
                  hostWebviewId:hostWebviewId
               completionHandler:completionHandler];
}

extern "C" void addPreloadScriptToWebView(AbstractView *abstractView, const char *scriptContent, BOOL forMainFrameOnly) {                
    [abstractView addPreloadScriptToWebView:scriptContent];    
}

// todo: remove identifier and add option forMainFrameOnly
extern "C" void updatePreloadScriptToWebView(AbstractView *abstractView,
                                             const char *scriptIdentifier,
                                             const char *scriptContent,
                                             BOOL forMainFrameOnly) {
    [abstractView updateCustomPreloadScript:scriptContent];    
}

extern "C" void invokeDecisionHandler(void (^decisionHandler)(WKNavigationActionPolicy), WKNavigationActionPolicy policy) {
    if (decisionHandler) {
        decisionHandler(policy);
    }
}

extern "C" const char* getUrlFromNavigationAction(WKNavigationAction *navigationAction) {
    NSURLRequest *request = navigationAction.request;
    NSURL *url = request.URL;
    return url.absoluteString.UTF8String;
}

extern "C" const char* getBodyFromScriptMessage(WKScriptMessage *message) {
    NSString *body = message.body;
    return body.UTF8String;
}

extern "C" void webviewSetTransparent(AbstractView *abstractView, BOOL transparent) {    
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView setTransparent:transparent];    
    });
}

extern "C" void webviewSetPassthrough(AbstractView *abstractView, BOOL enablePassthrough) {    
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView setPassthrough:enablePassthrough];    
    });
}

extern "C" void webviewSetHidden(AbstractView *abstractView, BOOL hidden) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView setHidden:hidden];
    });
}

extern "C" void setWebviewNavigationRules(AbstractView *abstractView, const char *rulesJson) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView setNavigationRulesFromJSON:rulesJson];
    });
}

extern "C" void setWebviewUserAgent(AbstractView *abstractView, const char *userAgent) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!abstractView || ![abstractView isKindOfClass:[WKWebViewImpl class]]) return;
        WKWebViewImpl *wkImpl = (WKWebViewImpl *)abstractView;
        if (!wkImpl.webView) return;
        NSString *ua = userAgent ? [NSString stringWithUTF8String:userAgent] : nil;
        wkImpl.webView.customUserAgent = (ua.length > 0) ? ua : nil;
    });
}

extern "C" void setAcceptLanguage(const char *lang) {
    if (lang && lang[0]) {
        g_acceptLanguage = std::string(lang);
    } else {
        g_acceptLanguage = "";
    }
}

static void applyAppearanceToViewTree(NSView *view, NSAppearance *appearance) {
    if (!view) return;
    view.appearance = appearance;
    for (NSView *subview in view.subviews) {
        applyAppearanceToViewTree(subview, appearance);
    }
}

static void applyAppearanceToWindow(NSWindow *window, NSAppearance *appearance) {
    if (!window) return;
    NSNumber *adaptiveTheme = objc_getAssociatedObject(window, "adaptiveTheme");
    // Browser windows with native toolbars derive chrome contrast from page pixels.
    if (adaptiveTheme && adaptiveTheme.boolValue) return;
    window.appearance = appearance;
    applyAppearanceToViewTree(window.contentView, appearance);
}

extern "C" void setAppAppearance(const char *mode) {
    NSString *appearanceName = nil;
    if (mode) {
        NSString *m = [NSString stringWithUTF8String:mode];
        if ([m isEqualToString:@"dark"]) {
            appearanceName = NSAppearanceNameDarkAqua;
        } else if ([m isEqualToString:@"light"]) {
            appearanceName = NSAppearanceNameAqua;
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        g_appAppearanceName = appearanceName;
        NSAppearance *appearance = g_appAppearanceName
            ? [NSAppearance appearanceNamed:g_appAppearanceName]
            : nil;
        [NSApp setAppearance:appearance];
        for (NSWindow *window in [NSApp windows]) {
            applyAppearanceToWindow(window, appearance);
        }
    });
}

extern "C" void webviewFindInPage(AbstractView *abstractView, const char *searchText, bool forward, bool matchCase) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView findInPage:searchText forward:forward matchCase:matchCase];
    });
}

extern "C" void webviewStopFind(AbstractView *abstractView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView stopFindInPage];
    });
}

extern "C" void webviewShowFindBar(NSWindow *window) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!window) return;
        FindBarView *bar = objc_getAssociatedObject(window, FindBarAssociatedKey.UTF8String);
        if (!bar) {
            bar = [[FindBarView alloc] initWithFrame:NSMakeRect(0, 0, 400, 32)];
            objc_setAssociatedObject(window, FindBarAssociatedKey.UTF8String, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [bar showInWindow:window];
    });
}

extern "C" void webviewHideFindBar(NSWindow *window) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!window) return;
        FindBarView *bar = objc_getAssociatedObject(window, FindBarAssociatedKey.UTF8String);
        if (bar) [bar dismiss];
    });
}

extern "C" void webviewOpenDevTools(AbstractView *abstractView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView openDevTools];
    });
}

extern "C" void webviewCloseDevTools(AbstractView *abstractView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView closeDevTools];
    });
}

extern "C" void webviewToggleDevTools(AbstractView *abstractView) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [abstractView toggleDevTools];
    });
}

extern "C" void webviewSetPageZoom(AbstractView *abstractView, double zoomLevel) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([abstractView isKindOfClass:[WKWebViewImpl class]]) {
            WKWebViewImpl *wkImpl = (WKWebViewImpl *)abstractView;
            if (wkImpl.webView) {
                wkImpl.webView.pageZoom = zoomLevel;
                [wkImpl.webView setNeedsDisplay:YES];
                [wkImpl.webView setNeedsLayout:YES];
            }
        }
    });
}

extern "C" double webviewGetPageZoom(AbstractView *abstractView) {
    __block double zoomLevel = 1.0;
    if ([abstractView isKindOfClass:[WKWebViewImpl class]]) {
        WKWebViewImpl *wkImpl = (WKWebViewImpl *)abstractView;
        if (wkImpl.webView) {
            if ([NSThread isMainThread]) {
                zoomLevel = wkImpl.webView.pageZoom;
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    zoomLevel = wkImpl.webView.pageZoom;
                });
            }
        }
    }
    return zoomLevel;
}


extern "C" NSRect createNSRectWrapper(double x, double y, double width, double height) {
    return NSMakeRect(x, y, width, height);
}


@interface ElectrobunWindow : NSWindow
@end

@implementation ElectrobunWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface ElectrobunPanel : NSPanel
@end

@implementation ElectrobunPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

NSWindow *createNSWindowWithFrameAndStyle(uint32_t windowId,
                                                     createNSWindowWithFrameAndStyleParams config,
                                                     WindowCloseHandler zigCloseHandler,
                                                     WindowMoveHandler zigMoveHandler,
                                                     WindowResizeHandler zigResizeHandler,
                                                     WindowFocusHandler zigFocusHandler,
                                                     WindowBlurHandler zigBlurHandler,
                                                     WindowKeyHandler zigKeyHandler) {
    
    NSScreen *primaryScreen = [NSScreen screens][0];
    NSRect screenFrame = [primaryScreen frame];
    config.frame.origin.y = screenFrame.size.height - config.frame.origin.y;
    
    BOOL hasClose = (config.styleMask & NSWindowStyleMaskClosable) != 0;
    BOOL hasMini  = (config.styleMask & NSWindowStyleMaskMiniaturizable) != 0;
    BOOL hasZoom  = (config.styleMask & NSWindowStyleMaskResizable) != 0;
    BOOL hasNoTrafficLights = !hasClose && !hasMini && !hasZoom;
    BOOL hidesTitleBar = strcmp(config.titleBarStyle, "hidden") == 0 ||
        strcmp(config.titleBarStyle, "hiddenInset") == 0;

    // Only custom-shaped windows should lose AppKit's titled frame. Normal
    // hidden-titlebar windows keep it so macOS owns the native rounded border.
    if (hidesTitleBar && hasNoTrafficLights && config.cornerRadius > 0) {
        config.styleMask &= ~NSWindowStyleMaskTitled;
    }

    BOOL isPanel = (config.styleMask & NSWindowStyleMaskNonactivatingPanel) != 0;
    
    NSWindow *window;
    if (isPanel) {
        window = [[ElectrobunPanel alloc] initWithContentRect:config.frame
                                                   styleMask:config.styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES
                                                      screen:primaryScreen];
        [(NSPanel *)window setFloatingPanel:YES];
        [(NSPanel *)window setBecomesKeyOnlyIfNeeded:NO];
    } else {
        window = [[ElectrobunWindow alloc] initWithContentRect:config.frame
                                                    styleMask:config.styleMask
                                                      backing:NSBackingStoreBuffered
                                                        defer:YES
                                                       screen:primaryScreen];
    }
    
    [window setFrameTopLeftPoint:config.frame.origin];
    // Allow hidden titlebar windows to participate in native fullscreen.
    [window setCollectionBehavior:
        [window collectionBehavior] | NSWindowCollectionBehaviorFullScreenPrimary];
    if (hidesTitleBar) {
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleHidden;
        if (!hasClose) [[window standardWindowButton:NSWindowCloseButton] setHidden:YES];
        if (!hasMini)  [[window standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        if (!hasZoom)  [[window standardWindowButton:NSWindowZoomButton] setHidden:YES];

        if (hasNoTrafficLights) {
            NSWindowCollectionBehavior behavior = [window collectionBehavior];
            behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
            behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;
            behavior |= NSWindowCollectionBehaviorFullScreenNone;
            behavior |= NSWindowCollectionBehaviorFullScreenDisallowsTiling;
            [window setCollectionBehavior:behavior];

            @try {
                [window setValue:@1 forKey:@"tilingBehavior"];
            } @catch (NSException *) {}
        }
    }
    objc_setAssociatedObject(window, kTrafficLightTitleBarStyleKey, [NSString stringWithUTF8String:config.titleBarStyle ?: "default"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kTrafficLightOffsetXKey, @(config.trafficLightOffsetX), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kTrafficLightOffsetYKey, @(config.trafficLightOffsetY), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kTrafficLightAppliedOffsetXKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kTrafficLightAppliedOffsetYKey, @(0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WindowDelegate *delegate = [[WindowDelegate alloc] init];
    delegate.closeHandler = zigCloseHandler;
    delegate.resizeHandler = zigResizeHandler;
    delegate.moveHandler = zigMoveHandler;
    delegate.focusHandler = zigFocusHandler;
    delegate.blurHandler = zigBlurHandler;
    delegate.keyHandler = zigKeyHandler;
    delegate.windowId = windowId;
    delegate.window = window;
    [window setDelegate:delegate];
    objc_setAssociatedObject(window, "WindowDelegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    window.releasedWhenClosed = NO;

    ContainerView *contentView = [[ContainerView alloc] initWithFrame:[window frame]];
    contentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [window setContentView:contentView];

    if (config.toolbar) {
        window.titlebarAppearsTransparent = YES;
        window.titleVisibility = NSWindowTitleVisible;
        objc_setAssociatedObject(window, "adaptiveTheme", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"NavigationToolbar"];
        NavigationToolbarDelegate *toolbarDelegate = [[NavigationToolbarDelegate alloc] init];
        objc_setAssociatedObject(window, "toolbarDelegate", toolbarDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        toolbar.delegate = toolbarDelegate;
        toolbar.displayMode = NSToolbarDisplayModeIconOnly;
        [window setToolbar:toolbar];
        if (@available(macOS 11.0, *)) {
            window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
        }
    }

    return window;

    // return (void*)window;
    
}

static BOOL isElectrobunPanelWindow(NSWindow *window) {
    return [window isKindOfClass:[ElectrobunPanel class]];
}

static void focusTopInteractiveView(NSWindow *window) {
    if (![window.contentView isKindOfClass:[ContainerView class]]) return;

    ContainerView *containerView = (ContainerView *)window.contentView;
    for (AbstractView *abstractView in containerView.abstractViews) {
        NSView *view = abstractView.nsView;
        if (!view || view.hidden) continue;

        if ([view acceptsFirstResponder]) {
            [window makeFirstResponder:view];
            return;
        }
    }
}

extern "C" void testFFI2(void (*completionHandler)()) {
    NSLog(@"C++  TEST FFI 2 0");
    completionHandler();
    NSLog(@"C++  TEST FFI 2 1");
}

extern "C" NSWindow *createWindowWithFrameAndStyleFromWorker(
  uint32_t windowId,
  double x, double y,
  double width, double height,
  uint32_t styleMask,
  const char* titleBarStyle,
  bool transparent,
  bool toolbar,
  double trafficLightOffsetX,
  double trafficLightOffsetY,
  double cornerRadius,
  WindowCloseHandler zigCloseHandler,
  WindowMoveHandler zigMoveHandler,
  WindowResizeHandler zigResizeHandler,
  WindowFocusHandler zigFocusHandler,
  WindowBlurHandler zigBlurHandler,
  WindowKeyHandler zigKeyHandler
  ) {

    // Validate frame values - use defaults if NaN or invalid
    if (isnan(x) || isinf(x)) x = 100;
    if (isnan(y) || isinf(y)) y = 100;
    if (isnan(width) || isinf(width) || width <= 0) width = 800;
    if (isnan(height) || isinf(height) || height <= 0) height = 600;

    NSRect frame = NSMakeRect(x, y, width, height);

    createNSWindowWithFrameAndStyleParams config = {
        .frame = frame,
        .styleMask = styleMask,
        .titleBarStyle = titleBarStyle,
        .toolbar = toolbar,
        .trafficLightOffsetX = trafficLightOffsetX,
        .trafficLightOffsetY = trafficLightOffsetY,
        .cornerRadius = cornerRadius
    };

    // Use a dispatch semaphore to wait for the window creation to complete
    __block NSWindow* window = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        window = createNSWindowWithFrameAndStyle(
            windowId,
            config,
            zigCloseHandler,
            zigMoveHandler,
            zigResizeHandler,
            zigFocusHandler,
            zigBlurHandler,
            zigKeyHandler
        );

        // Handle transparent window background
        if (transparent) {
            window.backgroundColor = [NSColor clearColor];
            window.opaque = NO;
            window.hasShadow = NO;

            // Also configure the content view for transparency
            NSView *contentView = window.contentView;
            contentView.wantsLayer = YES;
            contentView.layer.backgroundColor = [[NSColor clearColor] CGColor];
            contentView.layer.opaque = NO;
        }

        if (config.cornerRadius > 0) {
            setConfiguredWindowCornerRadius(window, config.cornerRadius);
        }

    });

    return window;
}

extern "C" void showWindow(NSWindow *window, bool activate) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (activate) {
            if ([window isKindOfClass:[NSPanel class]]) {
                [window orderFrontRegardless];
                [window makeKeyWindow];
                focusTopInteractiveView(window);
            } else {
                [window orderFront:nil];
                [window makeKeyAndOrderFront:nil];
                [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
            }
        } else {
            [window orderFrontRegardless];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            WindowDelegate *delegate = (WindowDelegate *)[window delegate];
            if (delegate && delegate.hasCustomButtonPosition) {
                applyWindowButtonPosition(window, delegate.buttonPositionX, delegate.buttonPositionY);
            } else {
                applyTrafficLightOffset(window);
            }
        });
    });
}

extern "C" void activateWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (![window isVisible]) {
            return;
        }

        if (isElectrobunPanelWindow(window)) {
            [window orderFrontRegardless];
            [window makeKeyWindow];
            focusTopInteractiveView(window);
            return;
        }

        [window makeKeyAndOrderFront:nil];
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
    });
}

extern "C" void hideWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window orderOut:nil];
    });
}

static const char *kWindowCloakSavedAlphaKey = "ElectrobunWindowCloakSavedAlpha";
static const char *kWindowCloakSavedIgnoresMouseKey = "ElectrobunWindowCloakSavedIgnoresMouse";

extern "C" void setWindowCloaked(NSWindow *window, bool cloaked) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!window) return;

        if (cloaked) {
            if (!objc_getAssociatedObject(window, kWindowCloakSavedAlphaKey)) {
                objc_setAssociatedObject(
                    window,
                    kWindowCloakSavedAlphaKey,
                    @([window alphaValue]),
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
                objc_setAssociatedObject(
                    window,
                    kWindowCloakSavedIgnoresMouseKey,
                    @([window ignoresMouseEvents]),
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC
                );
            }
            [window setAlphaValue:0.0];
            [window setIgnoresMouseEvents:YES];
            return;
        }

        NSNumber *savedAlpha = objc_getAssociatedObject(window, kWindowCloakSavedAlphaKey);
        NSNumber *savedIgnoresMouse = objc_getAssociatedObject(window, kWindowCloakSavedIgnoresMouseKey);
        [window setAlphaValue:savedAlpha ? [savedAlpha doubleValue] : 1.0];
        [window setIgnoresMouseEvents:savedIgnoresMouse ? [savedIgnoresMouse boolValue] : NO];
        objc_setAssociatedObject(window, kWindowCloakSavedAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
        objc_setAssociatedObject(window, kWindowCloakSavedIgnoresMouseKey, nil, OBJC_ASSOCIATION_ASSIGN);
    });
}

extern "C" void setWindowTitle(NSWindow *window, const char *title) {
    NSString *titleString = [NSString stringWithUTF8String:title ?: ""];

    dispatch_sync(dispatch_get_main_queue(), ^{
        [window setTitle:titleString];
    });
}

extern "C" void closeWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window close];
    });
}

extern "C" void minimizeWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window miniaturize:nil];
    });
}

extern "C" void restoreWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        [window deminiaturize:nil];
    });
}

extern "C" bool isWindowMinimized(NSWindow *window) {
    __block bool result = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = [window isMiniaturized];
    });
    return result;
}

extern "C" void maximizeWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        // Only zoom if not already zoomed
        if (![window isZoomed]) {
            [window zoom:nil];
        }
    });
}

extern "C" void unmaximizeWindow(NSWindow *window) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        // Only unzoom if currently zoomed
        if ([window isZoomed]) {
            [window zoom:nil];
        }
    });
}

extern "C" bool isWindowMaximized(NSWindow *window) {
    __block bool result = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = [window isZoomed];
    });
    return result;
}

extern "C" void setWindowFullScreen(NSWindow *window, bool fullScreen) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        bool isCurrentlyFullScreen = ([window styleMask] & NSWindowStyleMaskFullScreen) != 0;
        if (fullScreen != isCurrentlyFullScreen) {
            [window toggleFullScreen:nil];
        }
    });
}

extern "C" bool isWindowFullScreen(NSWindow *window) {
    __block bool result = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = ([window styleMask] & NSWindowStyleMaskFullScreen) != 0;
    });
    return result;
}

extern "C" void setWindowAlwaysOnTop(NSWindow *window, bool alwaysOnTop) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (alwaysOnTop) {
            if (isElectrobunPanelWindow(window)) {
                [window setLevel:NSModalPanelWindowLevel];
            } else {
                [window setLevel:NSFloatingWindowLevel];
            }
        } else {
            [window setLevel:NSNormalWindowLevel];
        }
    });
}

extern "C" bool isWindowAlwaysOnTop(NSWindow *window) {
    __block bool result = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = [window level] >= NSFloatingWindowLevel;
    });
    return result;
}

static CGFloat topLeftCoordinateReferenceHeight() {
    NSScreen *screen = [[NSScreen screens] firstObject] ?: [NSScreen mainScreen];
    return screen ? screen.frame.size.height : 0;
}

extern "C" void setWindowPosition(NSWindow *window, double x, double y) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!window) return;
        // macOS uses bottom-left origin, so convert from Electrobun's global
        // top-left coordinate space. This must match Screen.getAllDisplays().
        CGFloat screenHeight = topLeftCoordinateReferenceHeight();
        CGFloat windowHeight = window.frame.size.height;
        CGFloat adjustedY = screenHeight - y - windowHeight;
        [window setFrameOrigin:NSMakePoint(x, adjustedY)];
    });
}

extern "C" void setWindowButtonPosition(NSWindow *window, double x, double y) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!window) return;

        WindowDelegate *delegate = (WindowDelegate *)[window delegate];
        if (delegate) {
            delegate.hasCustomButtonPosition = YES;
            delegate.buttonPositionX = x;
            delegate.buttonPositionY = y;
        }

        applyWindowButtonPosition(window, x, y);
    });
}

extern "C" void setWindowSize(NSWindow *window, double width, double height) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!window) return;
        NSRect frame = window.frame;
        // Keep the top-left corner fixed when resizing
        CGFloat oldHeight = frame.size.height;
        frame.size.width = width;
        frame.size.height = height;
        // Adjust y to keep top-left corner fixed (macOS uses bottom-left origin)
        frame.origin.y += (oldHeight - height);
        [window setFrame:frame display:YES animate:NO];
    });
}

extern "C" void setWindowFrame(NSWindow *window, double x, double y, double width, double height) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!window) return;
        // macOS uses bottom-left origin, so convert from Electrobun's global
        // top-left coordinate space. Do not use [window screen] here: hidden
        // or offscreen windows can have no screen, and panels may otherwise
        // be restored using the focused app's display height.
        CGFloat screenHeight = topLeftCoordinateReferenceHeight();
        CGFloat adjustedY = screenHeight - y - height;
        NSRect frame = NSMakeRect(x, adjustedY, width, height);
        [window setFrame:frame display:YES animate:NO];
    });
}

extern "C" void getWindowFrame(NSWindow *window, double *outX, double *outY, double *outWidth, double *outHeight) {
    __block NSRect frame = NSZeroRect;
    __block CGFloat screenHeight = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!window) return;
        frame = window.frame;
        screenHeight = topLeftCoordinateReferenceHeight();
    });
    // Convert from bottom-left origin to top-left origin
    *outX = frame.origin.x;
    *outY = screenHeight - frame.origin.y - frame.size.height;
    *outWidth = frame.size.width;
    *outHeight = frame.size.height;
}

extern "C" void resizeWebview(AbstractView *abstractView, double x, double y, double width, double height, const char *masksJson) {
    // Validate frame values - use defaults if NaN or invalid
    if (isnan(x) || isinf(x)) x = 0;
    if (isnan(y) || isinf(y)) y = 0;
    if (isnan(width) || isinf(width) || width <= 0) width = 100;
    if (isnan(height) || isinf(height) || height <= 0) height = 100;

    NSRect frame = NSMakeRect(x, y, width, height);

    // Pre-parse masks JSON off the main thread (NSJSONSerialization is thread-safe)
    NSArray *parsedMasks = nil;
    if (masksJson && strlen(masksJson) > 0) {
        @autoreleasepool {
            NSString *jsonString = [NSString stringWithUTF8String:masksJson];
            NSData *jsonData = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
            if (jsonData) {
                NSError *error = nil;
                parsedMasks = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
                if (error) parsedMasks = nil;
            }
        }
    }

    [abstractView storePendingResize:frame parsedMasks:parsedMasks];
    g_pendingResizeQueue.enqueue((__bridge void *)abstractView);
    schedulePendingResizeDrain();
}

extern "C" void stopWindowMove() {
    isMovingWindow = NO;
    targetWindow = nil;
    offsetX = 0.0;
    offsetY = 0.0;
    if (mouseDraggedMonitor) {
        [NSEvent removeMonitor:mouseDraggedMonitor];
        mouseDraggedMonitor = nil;
    }
    if (mouseUpMonitor) {
        [NSEvent removeMonitor:mouseUpMonitor];
        mouseUpMonitor = nil;
    }
}

extern "C" void startWindowMove(NSWindow *window) {
    targetWindow = window;
    if (!targetWindow) {
        NSLog(@"No window found for the given WebView.");
        return;
    }
    isMovingWindow = YES;
    NSPoint initialLocation = [NSEvent mouseLocation];

    mouseDraggedMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskMouseMoved)
                                                                handler:^NSEvent *(NSEvent *event) {
        if (isMovingWindow) {
            NSPoint currentLocation = [NSEvent mouseLocation];
            if (offsetX == 0.0 && offsetY == 0.0) {
                NSPoint windowOrigin = targetWindow.frame.origin;
                offsetX = initialLocation.x - windowOrigin.x;
                offsetY = initialLocation.y - windowOrigin.y;
            }
            CGFloat newX = currentLocation.x - offsetX;
            CGFloat newY = currentLocation.y - offsetY;
            [targetWindow setFrameOrigin:NSMakePoint(newX, newY)];
        }
        return event;
    }];
    mouseUpMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                                           handler:^NSEvent *(NSEvent *event) {
        if (isMovingWindow) {
            stopWindowMove();
        }
        return event;
    }];
}


extern "C" BOOL moveToTrash(char *pathString) {
    NSString *path = [NSString stringWithUTF8String:pathString ?: ""];
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    NSError *error = nil;
    NSURL *resultingURL = nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL success = [fileManager trashItemAtURL:fileURL resultingItemURL:&resultingURL error:&error];
    if (success) {
        NSLog(@"moveToTrash succeeded source=%@ result=%@", path, resultingURL.path);
    } else {
        NSLog(@"moveToTrash failed source=%@ domain=%@ code=%ld description=%@ recovery=%@",
              path,
              error.domain,
              (long)error.code,
              error.localizedDescription,
              error.localizedRecoverySuggestion);
    }
    return success;
}

extern "C" void showItemInFolder(char *path) {
    NSString *pathString = [NSString stringWithUTF8String:path ?: ""];
    NSURL *fileURL = [NSURL fileURLWithPath:pathString];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[fileURL]];
}

extern "C" BOOL removeImageBackground(const char *inputPathC, const char *outputPathC) {
    if (@available(macOS 14.0, *)) {
        @autoreleasepool {
            NSString *inputPath = [NSString stringWithUTF8String:inputPathC ?: ""];
            NSString *outputPath = [NSString stringWithUTF8String:outputPathC ?: ""];
            NSURL *inputURL = [NSURL fileURLWithPath:inputPath];
            CIImage *inputImage = [CIImage imageWithContentsOfURL:inputURL];
            if (!inputImage) {
                NSLog(@"[removeImageBackground] Could not load image at %@", inputPath);
                return NO;
            }

            VNGenerateForegroundInstanceMaskRequest *request =
                [[VNGenerateForegroundInstanceMaskRequest alloc] init];
            VNImageRequestHandler *handler =
                [[VNImageRequestHandler alloc] initWithCIImage:inputImage options:@{}];
            NSError *requestError = nil;
            if (![handler performRequests:@[request] error:&requestError]) {
                NSLog(@"[removeImageBackground] Vision request failed: %@", requestError);
                return NO;
            }

            VNInstanceMaskObservation *observation = request.results.firstObject;
            if (!observation) {
                NSLog(@"[removeImageBackground] No mask observation");
                return NO;
            }

            NSError *maskError = nil;
            CVPixelBufferRef maskedBuffer =
                [observation generateMaskedImageOfInstances:observation.allInstances
                                        fromRequestHandler:handler
                                  croppedToInstancesExtent:NO
                                                     error:&maskError];
            if (!maskedBuffer || maskError) {
                NSLog(@"[removeImageBackground] Mask generation failed: %@", maskError);
                return NO;
            }

            CIImage *maskedImage = [CIImage imageWithCVPixelBuffer:maskedBuffer];
            if (!maskedImage) {
                NSLog(@"[removeImageBackground] Could not create CIImage from mask buffer");
                return NO;
            }

            NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
            CIContext *context = [CIContext contextWithOptions:nil];
            NSError *writeError = nil;
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            BOOL wrote = [context writePNGRepresentationOfImage:maskedImage
                                                         toURL:outputURL
                                                        format:kCIFormatRGBA8
                                                   colorSpace:colorSpace
                                                      options:@{}
                                                        error:&writeError];
            CGColorSpaceRelease(colorSpace);
            if (!wrote || writeError) {
                NSLog(@"[removeImageBackground] Write failed: %@", writeError);
                return NO;
            }
            return YES;
        }
    }
    NSLog(@"[removeImageBackground] Requires macOS 14.0+");
    return NO;
}

static NSPanel *g_shareAnchorPanel = nil;

static void dismissShareAnchorPanel(void) {
    if (g_shareAnchorPanel) {
        [g_shareAnchorPanel orderOut:nil];
        g_shareAnchorPanel = nil;
    }
}

static NSPanel *shareAnchorPanelAtCursor(void) {
    dismissShareAnchorPanel();
    NSPoint mouseLoc = [NSEvent mouseLocation];
    NSRect frame = NSMakeRect(mouseLoc.x - 24, mouseLoc.y - 24, 48, 48);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:frame
                                                styleMask:NSWindowStyleMaskBorderless
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.backgroundColor = [NSColor clearColor];
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.level = NSPopUpMenuWindowLevel;
    panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorTransient;
    panel.releasedWhenClosed = NO;
    g_shareAnchorPanel = panel;
    [panel orderFrontRegardless];
    return panel;
}

@interface ElectrobunSharePickerDelegate : NSObject <NSSharingServicePickerDelegate>
@end

@implementation ElectrobunSharePickerDelegate
- (void)sharingServicePicker:(NSSharingServicePicker *)picker
       didChooseSharingService:(NSSharingService *)service {
    (void)picker;
    (void)service;
    dismissShareAnchorPanel();
}
@end

static ElectrobunSharePickerDelegate *g_sharePickerDelegate = nil;

extern "C" void shareFile(const char *pathString) {
    NSString *path = [NSString stringWithUTF8String:pathString ?: ""];
    if (path.length == 0) {
        return;
    }
    NSURL *fileURL = [NSURL fileURLWithPath:path];
    if (![[NSFileManager defaultManager] isReadableFileAtPath:path]) {
        NSLog(@"[shareFile] File is not readable: %@", path);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];

        NSArray *items = @[fileURL];
        NSSharingService *airDrop =
            [NSSharingService sharingServiceNamed:NSSharingServiceNameSendViaAirDrop];
        if (airDrop != nil && [airDrop canPerformWithItems:items]) {
            [airDrop performWithItems:items];
            return;
        }

        NSLog(@"[shareFile] AirDrop unavailable, showing share picker");
        NSPanel *panel = shareAnchorPanelAtCursor();
        if (!g_sharePickerDelegate) {
            g_sharePickerDelegate = [[ElectrobunSharePickerDelegate alloc] init];
        }
        NSSharingServicePicker *picker = [[NSSharingServicePicker alloc] initWithItems:items];
        picker.delegate = g_sharePickerDelegate;
        NSView *anchorView = panel.contentView;
        [picker showRelativeToRect:NSMakeRect(0, 0, 48, 48)
                            ofView:anchorView
                     preferredEdge:NSMinYEdge];
    });
}

static void activateDefaultApplicationForURL(NSURL *url) {
    NSURL *appURL = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:url];
    if (!appURL) return;

    NSString *bundleIdentifier = [NSBundle bundleWithURL:appURL].bundleIdentifier;
    if (bundleIdentifier.length == 0) return;

    void (^activate)(void) = ^{
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
        NSRunningApplication *app = apps.firstObject;
        if (!app) return;
        [app activateWithOptions:NSApplicationActivateAllWindows];
    };

    dispatch_async(dispatch_get_main_queue(), activate);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), activate);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), activate);
}

// Open a URL in the default browser or appropriate application
extern "C" BOOL openExternal(const char *urlString) {
    NSString *urlStr = [NSString stringWithUTF8String:urlString ?: ""];
    NSURL *url = [NSURL URLWithString:urlStr];

    if (!url) {
        NSLog(@"[openExternal] Invalid URL: %@", urlStr);
        return NO;
    }

    BOOL success = [[NSWorkspace sharedWorkspace] openURL:url];
    if (success) {
        activateDefaultApplicationForURL(url);
    }
    return success;
}

// Open a file or folder with the default application
extern "C" BOOL openPath(const char *pathString) {
    NSString *path = [NSString stringWithUTF8String:pathString ?: ""];
    NSURL *fileURL = [NSURL fileURLWithPath:path];

    BOOL success = [[NSWorkspace sharedWorkspace] openURL:fileURL];

    if (!success) {
        NSLog(@"[openPath] Failed to open path: %@", path);
    }

    return success;
}

// Show a native desktop notification
// Track notification authorization state
static BOOL notificationAuthRequested = NO;
static BOOL notificationAuthGranted = NO;
static BOOL useModernNotifications = YES;

// Fallback to deprecated NSUserNotification API (works better in dev mode without proper bundle)
static void showNotificationLegacy(NSString *titleStr, NSString *bodyStr, NSString *subtitleStr, BOOL silent) {
    dispatch_async(dispatch_get_main_queue(), ^{
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"

        NSUserNotification *notification = [[NSUserNotification alloc] init];
        notification.title = titleStr;
        notification.informativeText = bodyStr;
        if (subtitleStr) {
            notification.subtitle = subtitleStr;
        }
        notification.soundName = silent ? nil : NSUserNotificationDefaultSoundName;

        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
        NSLog(@"Notification delivered via legacy API: %@", titleStr);

        #pragma clang diagnostic pop
    });
}

extern "C" void showNotification(const char *title, const char *body, const char *subtitle, BOOL silent) {
    NSString *titleStr = [NSString stringWithUTF8String:title ?: ""];
    NSString *bodyStr = [NSString stringWithUTF8String:body ?: ""];
    NSString *subtitleStr = subtitle ? [NSString stringWithUTF8String:subtitle] : nil;

    // If we've already determined modern API doesn't work, use legacy
    if (!useModernNotifications) {
        showNotificationLegacy(titleStr, bodyStr, subtitleStr, silent);
        return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];

    // Request authorization if we haven't already
    if (!notificationAuthRequested) {
        notificationAuthRequested = YES;

        // Use a semaphore to wait for authorization result on first call
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);

        [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
                              completionHandler:^(BOOL granted, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Notification authorization error: %@ - falling back to legacy API", error);
                useModernNotifications = NO;
            } else if (!granted) {
                NSLog(@"Notification permission denied by user - falling back to legacy API");
                useModernNotifications = NO;
            } else {
                NSLog(@"Notification permission granted");
                notificationAuthGranted = YES;
            }
            dispatch_semaphore_signal(sem);
        }];

        // Wait briefly for authorization (with timeout)
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC));

        // If modern API failed, use legacy for this and future calls
        if (!useModernNotifications) {
            showNotificationLegacy(titleStr, bodyStr, subtitleStr, silent);
            return;
        }
    }

    // Create notification content
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = titleStr;
    content.body = bodyStr;
    if (subtitleStr) {
        content.subtitle = subtitleStr;
    }
    if (!silent) {
        content.sound = [UNNotificationSound defaultSound];
    }

    // Create a unique identifier for this notification
    NSString *identifier = [[NSUUID UUID] UUIDString];

    // Create the request with no trigger (immediate delivery)
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                          content:content
                                                                          trigger:nil];

    // Schedule the notification
    [center addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
        if (error) {
            NSLog(@"Failed to schedule notification via modern API: %@ - trying legacy", error);
            // Fall back to legacy API
            useModernNotifications = NO;
            showNotificationLegacy(titleStr, bodyStr, subtitleStr, silent);
        } else {
            NSLog(@"Notification scheduled successfully: %@", titleStr);
        }
    }];
}

extern "C" const char *openFileDialog(const char *startingFolder,
                                      const char *allowedFileTypes,
                                      BOOL canChooseFiles,
                                      BOOL canChooseDirectories,
                                      BOOL allowsMultipleSelection) {


    __block NSOpenPanel *panel;
    __block NSInteger result = NSModalResponseCancel;
    __block NSString *concatenatedPaths = nil;
    
    dispatch_sync(dispatch_get_main_queue(), ^{        
        panel = [NSOpenPanel openPanel];        
        [panel setCanChooseFiles:canChooseFiles];        
        [panel setCanChooseDirectories:canChooseDirectories];        
        [panel setAllowsMultipleSelection:allowsMultipleSelection];        

        NSString *startFolder = [NSString stringWithUTF8String:startingFolder ?: ""];
        [panel setDirectoryURL:[NSURL fileURLWithPath:startFolder]];        
        
        if (allowedFileTypes && strcmp(allowedFileTypes, "*") != 0 && strcmp(allowedFileTypes, "") != 0) {            
            NSString *allowedTypesStr = [NSString stringWithUTF8String:allowedFileTypes];
            NSArray *fileTypesArray = [allowedTypesStr componentsSeparatedByString:@","];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [panel setAllowedFileTypes:fileTypesArray];
            #pragma clang diagnostic pop
        }
                
        result = [panel runModal]; // Run the modal dialog on the main thread        
        
        if (result == NSModalResponseOK) {            
            NSArray<NSURL *> *selectedFileURLs = [panel URLs];
            NSMutableArray<NSString *> *pathStrings = [NSMutableArray array];
            for (NSURL *u in selectedFileURLs) {
                [pathStrings addObject:u.path];
            }
            concatenatedPaths = [pathStrings componentsJoinedByString:@","];
        }        
    });
    
    // Return the result after the dispatch_sync completes
    return (concatenatedPaths) ? strdup([concatenatedPaths UTF8String]) : NULL;
}

// showMessageBox - Display a native message box dialog with custom buttons
// type: 0=none, 1=info, 2=warning, 3=error, 4=question
// buttons: comma-separated list of button labels (e.g., "OK,Cancel")
// Returns: index of the clicked button (0-based), or -1 if cancelled
extern "C" int showMessageBox(const char *type,
                              const char *title,
                              const char *message,
                              const char *detail,
                              const char *buttons,
                              int defaultId,
                              int cancelId) {
    __block int result = -1;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];

        // Set the message and informative text
        if (title && strlen(title) > 0) {
            [alert setMessageText:[NSString stringWithUTF8String:title]];
        }
        if (message && strlen(message) > 0) {
            [alert setInformativeText:[NSString stringWithUTF8String:message]];
        }

        // Set the alert style based on type
        if (type) {
            NSString *typeStr = [NSString stringWithUTF8String:type];
            if ([typeStr isEqualToString:@"warning"]) {
                [alert setAlertStyle:NSAlertStyleWarning];
            } else if ([typeStr isEqualToString:@"error"] || [typeStr isEqualToString:@"critical"]) {
                [alert setAlertStyle:NSAlertStyleCritical];
            } else {
                // info, question, none all use informational style
                [alert setAlertStyle:NSAlertStyleInformational];
            }
        }

        // Add buttons from comma-separated list
        if (buttons && strlen(buttons) > 0) {
            NSString *buttonsStr = [NSString stringWithUTF8String:buttons];
            NSArray *buttonArray = [buttonsStr componentsSeparatedByString:@","];
            for (NSString *buttonTitle in buttonArray) {
                NSString *trimmedTitle = [buttonTitle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmedTitle.length > 0) {
                    [alert addButtonWithTitle:trimmedTitle];
                }
            }
        } else {
            // Default to OK button if none specified
            [alert addButtonWithTitle:@"OK"];
        }

        // Run the modal and get the response
        NSModalResponse response = [alert runModal];

        // Convert NSModalResponse to button index (0-based)
        // NSAlertFirstButtonReturn = 1000, NSAlertSecondButtonReturn = 1001, etc.
        result = (int)(response - NSAlertFirstButtonReturn);
    });

    return result;
}

// ============================================================================
// Clipboard API
// ============================================================================

// clipboardReadText - Read text from the system clipboard
// Returns: UTF-8 string (caller must free) or NULL if no text available
extern "C" const char* clipboardReadText() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSString *text = [pasteboard stringForType:NSPasteboardTypeString];
        if (text) {
            result = strdup([text UTF8String]);
        }
    });

    return result;
}

// clipboardWriteText - Write text to the system clipboard
extern "C" void clipboardWriteText(const char *text) {
    if (!text) return;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard setString:[NSString stringWithUTF8String:text] forType:NSPasteboardTypeString];
    });
}

// clipboardGetChangeCount - Get the global change count
extern "C" long clipboardGetChangeCount() {
    __block long count = 0;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        count = [pasteboard changeCount];
    });
    return count;
}

// clipboardReadImage - Read image from clipboard as PNG data
// Returns: PNG data (caller must free) and sets outSize, or NULL if no image
extern "C" const uint8_t* clipboardReadImage(size_t *outSize) {
    __block const uint8_t* result = NULL;
    __block size_t size = 0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];

        // Try to read image data (supports PNG, TIFF, etc.)
        NSArray *imageTypes = @[NSPasteboardTypePNG, NSPasteboardTypeTIFF];
        NSString *bestType = [pasteboard availableTypeFromArray:imageTypes];

        if (bestType) {
            NSData *imageData = [pasteboard dataForType:bestType];
            if (imageData) {
                // Convert to PNG if not already
                if ([bestType isEqualToString:NSPasteboardTypePNG]) {
                    size = [imageData length];
                    uint8_t *buffer = (uint8_t*)malloc(size);
                    memcpy(buffer, [imageData bytes], size);
                    result = buffer;
                } else {
                    // Convert TIFF or other formats to PNG
                    NSImage *image = [[NSImage alloc] initWithData:imageData];
                    if (image) {
                        NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithData:[image TIFFRepresentation]];
                        NSData *pngData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                        if (pngData) {
                            size = [pngData length];
                            uint8_t *buffer = (uint8_t*)malloc(size);
                            memcpy(buffer, [pngData bytes], size);
                            result = buffer;
                        }
                    }
                }
            }
        }
    });

    if (outSize) *outSize = size;
    return result;
}

// clipboardWriteImage - Write PNG image data to clipboard
extern "C" void clipboardWriteImage(const uint8_t *pngData, size_t size) {
    if (!pngData || size == 0) return;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];

        NSData *data = [NSData dataWithBytes:pngData length:size];
        [pasteboard setData:data forType:NSPasteboardTypePNG];
    });
}

// clipboardReadFilePaths - Read file paths from the system clipboard as a JSON string array
extern "C" const char* clipboardReadFilePaths() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSArray *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
                                                  options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSURL *url in urls) {
            if ([url isFileURL] && [url path]) {
                [paths addObject:[url path]];
            }
        }

        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:paths options:0 error:nil];
        NSString *json = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[]";
        result = strdup([json UTF8String]);
    });

    return result;
}

// clipboardWriteFilePaths - Write file paths to the system clipboard from a JSON string array
extern "C" void clipboardWriteFilePaths(const char *pathsJson) {
    if (!pathsJson) return;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSData *jsonData = [NSData dataWithBytes:pathsJson length:strlen(pathsJson)];
        id parsed = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        if (![parsed isKindOfClass:[NSArray class]]) return;

        NSMutableArray *urls = [NSMutableArray array];
        for (id value in (NSArray *)parsed) {
            if (![value isKindOfClass:[NSString class]]) continue;
            NSURL *url = [NSURL fileURLWithPath:(NSString *)value];
            if (url) [urls addObject:url];
        }
        if ([urls count] == 0) return;

        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        [pasteboard writeObjects:urls];
    });
}

// clipboardClear - Clear the clipboard
extern "C" void clipboardClear() {
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
    });
}

// clipboardAvailableFormats - Get available formats in clipboard
// Returns: comma-separated list of formats (caller must free)
extern "C" const char* clipboardAvailableFormats() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSMutableArray *formats = [NSMutableArray array];

        // Check for text
        if ([pasteboard stringForType:NSPasteboardTypeString]) {
            [formats addObject:@"text"];
        }

        // Check for image
        NSArray *imageTypes = @[NSPasteboardTypePNG, NSPasteboardTypeTIFF];
        if ([pasteboard availableTypeFromArray:imageTypes]) {
            [formats addObject:@"image"];
        }

        // Check for files
        if ([pasteboard availableTypeFromArray:@[NSPasteboardTypeFileURL]]) {
            [formats addObject:@"files"];
        }

        // Check for HTML
        if ([pasteboard availableTypeFromArray:@[NSPasteboardTypeHTML]]) {
            [formats addObject:@"html"];
        }

        NSString *joined = [formats componentsJoinedByString:@","];
        result = strdup([joined UTF8String]);
    });

    return result;
}

// simulatePaste - Simulate a Cmd+V keystroke to paste from clipboard.
// Uses CGEvents to synthesize the key press on the current session.
extern "C" void simulatePaste() {
    dispatch_sync(dispatch_get_main_queue(), ^{
        CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (!source) return;

        // Key code 9 = 'V' on macOS
        CGEventRef keyDown = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, true);
        CGEventRef keyUp = CGEventCreateKeyboardEvent(source, (CGKeyCode)9, false);

        CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
        CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);

        CGEventPost(kCGAnnotatedSessionEventTap, keyDown);
        CGEventPost(kCGAnnotatedSessionEventTap, keyUp);

        CFRelease(keyDown);
        CFRelease(keyUp);
        CFRelease(source);
    });
}

typedef NS_ENUM(NSInteger, EBMacPermissionKind) {
    EBMacPermissionKindUnknown = 0,
    EBMacPermissionKindAccessibility = 1,
    EBMacPermissionKindScreenRecording = 2,
    EBMacPermissionKindCamera = 3,
    EBMacPermissionKindMicrophone = 4,
    EBMacPermissionKindContacts = 5,
    EBMacPermissionKindFullDiskAccess = 6,
    EBMacPermissionKindFilesAndFolders = 7,
    EBMacPermissionKindDesktopFolder = 8,
    EBMacPermissionKindDocumentsFolder = 9,
    EBMacPermissionKindDownloadsFolder = 10,
    EBMacPermissionKindRemovableVolumes = 11,
    EBMacPermissionKindAutomation = 12,
    EBMacPermissionKindInputMonitoring = 13,
    EBMacPermissionKindLocation = 14,
    EBMacPermissionKindCalendar = 15,
    EBMacPermissionKindReminders = 16,
    EBMacPermissionKindPhotos = 17,
    EBMacPermissionKindBluetooth = 18,
    EBMacPermissionKindSpeechRecognition = 19,
    EBMacPermissionKindLocalNetwork = 20,
    EBMacPermissionKindMediaLibrary = 21,
    EBMacPermissionKindMotionFitness = 22,
    EBMacPermissionKindHomeKit = 23,
    EBMacPermissionKindFocusStatus = 24,
    EBMacPermissionKindRemoteDesktop = 25,
    EBMacPermissionKindDeveloperTools = 26,
    EBMacPermissionKindAppManagement = 27,
    EBMacPermissionKindPasskeyAccess = 28,
};

static NSPanel *g_macPermissionGuidePanel = nil;
static NSWindow *g_macPermissionSourceWindow = nil;
static NSRect g_macPermissionSourceFrame = NSZeroRect;
static BOOL g_hasMacPermissionSourceFrame = NO;
static BOOL g_macPermissionGuideAttachedToSource = NO;
static NSInteger g_macPermissionGuideRequestID = 0;

static EBMacPermissionKind macPermissionKindFromCString(const char *kind) {
    if (!kind) return EBMacPermissionKindUnknown;
    if (strcmp(kind, "accessibility") == 0) return EBMacPermissionKindAccessibility;
    if (strcmp(kind, "screenRecording") == 0) return EBMacPermissionKindScreenRecording;
    if (strcmp(kind, "camera") == 0) return EBMacPermissionKindCamera;
    if (strcmp(kind, "microphone") == 0) return EBMacPermissionKindMicrophone;
    if (strcmp(kind, "contacts") == 0) return EBMacPermissionKindContacts;
    if (strcmp(kind, "fullDiskAccess") == 0) return EBMacPermissionKindFullDiskAccess;
    if (strcmp(kind, "filesAndFolders") == 0) return EBMacPermissionKindFilesAndFolders;
    if (strcmp(kind, "desktopFolder") == 0) return EBMacPermissionKindDesktopFolder;
    if (strcmp(kind, "documentsFolder") == 0) return EBMacPermissionKindDocumentsFolder;
    if (strcmp(kind, "downloadsFolder") == 0) return EBMacPermissionKindDownloadsFolder;
    if (strcmp(kind, "removableVolumes") == 0) return EBMacPermissionKindRemovableVolumes;
    if (strcmp(kind, "automation") == 0) return EBMacPermissionKindAutomation;
    if (strcmp(kind, "inputMonitoring") == 0) return EBMacPermissionKindInputMonitoring;
    if (strcmp(kind, "location") == 0) return EBMacPermissionKindLocation;
    if (strcmp(kind, "calendar") == 0) return EBMacPermissionKindCalendar;
    if (strcmp(kind, "reminders") == 0) return EBMacPermissionKindReminders;
    if (strcmp(kind, "photos") == 0) return EBMacPermissionKindPhotos;
    if (strcmp(kind, "bluetooth") == 0) return EBMacPermissionKindBluetooth;
    if (strcmp(kind, "speechRecognition") == 0) return EBMacPermissionKindSpeechRecognition;
    if (strcmp(kind, "localNetwork") == 0) return EBMacPermissionKindLocalNetwork;
    if (strcmp(kind, "mediaLibrary") == 0) return EBMacPermissionKindMediaLibrary;
    if (strcmp(kind, "motionFitness") == 0) return EBMacPermissionKindMotionFitness;
    if (strcmp(kind, "homeKit") == 0) return EBMacPermissionKindHomeKit;
    if (strcmp(kind, "focusStatus") == 0) return EBMacPermissionKindFocusStatus;
    if (strcmp(kind, "remoteDesktop") == 0) return EBMacPermissionKindRemoteDesktop;
    if (strcmp(kind, "developerTools") == 0) return EBMacPermissionKindDeveloperTools;
    if (strcmp(kind, "appManagement") == 0) return EBMacPermissionKindAppManagement;
    if (strcmp(kind, "passkeyAccess") == 0) return EBMacPermissionKindPasskeyAccess;
    return EBMacPermissionKindUnknown;
}

static BOOL canReadAnyExpandedPath(NSArray<NSString *> *paths) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        NSString *expandedPath = [path stringByExpandingTildeInPath];
        if ([fileManager isReadableFileAtPath:expandedPath]) return YES;
    }
    return NO;
}

static BOOL isMacPermissionGranted(EBMacPermissionKind kind) {
    switch (kind) {
        case EBMacPermissionKindAccessibility:
            return AXIsProcessTrusted();
        case EBMacPermissionKindScreenRecording:
            return CGPreflightScreenCaptureAccess();
        case EBMacPermissionKindCamera:
            return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized;
        case EBMacPermissionKindMicrophone:
            return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized;
        case EBMacPermissionKindContacts:
            return [CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts] == CNAuthorizationStatusAuthorized;
        case EBMacPermissionKindFullDiskAccess:
            return canReadAnyExpandedPath(@[
                @"~/Library/Messages/chat.db",
                @"~/Library/Safari/CloudTabs.db",
                @"~/Library/Application Support/AddressBook/AddressBook-v22.abcddb"
            ]);
        case EBMacPermissionKindInputMonitoring:
            return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
        case EBMacPermissionKindLocation: {
            CLLocationManager *manager = [[CLLocationManager alloc] init];
            CLAuthorizationStatus status = manager.authorizationStatus;
            return status == kCLAuthorizationStatusAuthorizedAlways;
        }
        case EBMacPermissionKindCalendar: {
            EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
            return status == EKAuthorizationStatusFullAccess || status == EKAuthorizationStatusWriteOnly;
        }
        case EBMacPermissionKindReminders: {
            EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
            return status == EKAuthorizationStatusFullAccess || status == EKAuthorizationStatusWriteOnly;
        }
        case EBMacPermissionKindPhotos: {
            PHAuthorizationStatus status = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
            return status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited;
        }
        case EBMacPermissionKindBluetooth:
            return [CBManager authorization] == CBManagerAuthorizationAllowedAlways;
        case EBMacPermissionKindSpeechRecognition:
            return [SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusAuthorized;
        case EBMacPermissionKindFilesAndFolders:
        case EBMacPermissionKindDesktopFolder:
        case EBMacPermissionKindDocumentsFolder:
        case EBMacPermissionKindDownloadsFolder:
        case EBMacPermissionKindRemovableVolumes:
        case EBMacPermissionKindAutomation:
        case EBMacPermissionKindLocalNetwork:
        case EBMacPermissionKindMediaLibrary:
        case EBMacPermissionKindMotionFitness:
        case EBMacPermissionKindHomeKit:
        case EBMacPermissionKindFocusStatus:
        case EBMacPermissionKindRemoteDesktop:
        case EBMacPermissionKindDeveloperTools:
        case EBMacPermissionKindAppManagement:
        case EBMacPermissionKindPasskeyAccess:
            return NO;
        default:
            return NO;
    }
}

static NSString *macPermissionSettingsQuery(EBMacPermissionKind kind) {
    switch (kind) {
        case EBMacPermissionKindAccessibility:
            return @"Privacy_Accessibility";
        case EBMacPermissionKindScreenRecording:
            return @"Privacy_ScreenCapture";
        case EBMacPermissionKindCamera:
            return @"Privacy_Camera";
        case EBMacPermissionKindMicrophone:
            return @"Privacy_Microphone";
        case EBMacPermissionKindContacts:
            return @"Privacy_Contacts";
        case EBMacPermissionKindFullDiskAccess:
            return @"Privacy_AllFiles";
        case EBMacPermissionKindFilesAndFolders:
        case EBMacPermissionKindDesktopFolder:
        case EBMacPermissionKindDocumentsFolder:
        case EBMacPermissionKindDownloadsFolder:
        case EBMacPermissionKindRemovableVolumes:
            return @"Privacy_FilesAndFolders";
        case EBMacPermissionKindAutomation:
            return @"Privacy_Automation";
        case EBMacPermissionKindInputMonitoring:
            return @"Privacy_ListenEvent";
        case EBMacPermissionKindLocation:
            return @"Privacy_LocationServices";
        case EBMacPermissionKindCalendar:
            return @"Privacy_Calendars";
        case EBMacPermissionKindReminders:
            return @"Privacy_Reminders";
        case EBMacPermissionKindPhotos:
            return @"Privacy_Photos";
        case EBMacPermissionKindBluetooth:
            return @"Privacy_Bluetooth";
        case EBMacPermissionKindSpeechRecognition:
            return @"Privacy_SpeechRecognition";
        case EBMacPermissionKindLocalNetwork:
            return @"Privacy_LocalNetwork";
        case EBMacPermissionKindMediaLibrary:
            return @"Privacy_Media";
        case EBMacPermissionKindMotionFitness:
            return @"Privacy_Motion";
        case EBMacPermissionKindHomeKit:
            return @"Privacy_HomeKit";
        case EBMacPermissionKindFocusStatus:
            return @"Privacy_Focus";
        case EBMacPermissionKindRemoteDesktop:
            return @"Privacy_RemoteDesktop";
        case EBMacPermissionKindDeveloperTools:
            return @"Privacy_DevTools";
        case EBMacPermissionKindAppManagement:
            return @"Privacy_AppBundles";
        case EBMacPermissionKindPasskeyAccess:
            return @"Privacy_PasskeyAccess";
        default:
            return nil;
    }
}

static NSString *macPermissionGuideInstruction(EBMacPermissionKind kind) {
    switch (kind) {
        case EBMacPermissionKindScreenRecording:
            return @"Then click Quit & Reopen.";
        case EBMacPermissionKindFullDiskAccess:
            return @"Then turn Cachy on and relaunch the command.";
        case EBMacPermissionKindFilesAndFolders:
        case EBMacPermissionKindDesktopFolder:
        case EBMacPermissionKindDocumentsFolder:
        case EBMacPermissionKindDownloadsFolder:
        case EBMacPermissionKindRemovableVolumes:
            return @"Then turn Cachy on for the needed folders.";
        case EBMacPermissionKindCamera:
        case EBMacPermissionKindMicrophone:
        case EBMacPermissionKindContacts:
        case EBMacPermissionKindAutomation:
        case EBMacPermissionKindInputMonitoring:
        case EBMacPermissionKindLocation:
        case EBMacPermissionKindCalendar:
        case EBMacPermissionKindReminders:
        case EBMacPermissionKindPhotos:
        case EBMacPermissionKindBluetooth:
        case EBMacPermissionKindSpeechRecognition:
        case EBMacPermissionKindLocalNetwork:
        case EBMacPermissionKindMediaLibrary:
        case EBMacPermissionKindMotionFitness:
        case EBMacPermissionKindHomeKit:
        case EBMacPermissionKindFocusStatus:
        case EBMacPermissionKindRemoteDesktop:
        case EBMacPermissionKindDeveloperTools:
        case EBMacPermissionKindAppManagement:
        case EBMacPermissionKindPasskeyAccess:
            return @"Then turn Cachy on and try again.";
        case EBMacPermissionKindAccessibility:
            return @"Then return to Cachy and click Done.";
        default:
            return @"Then return to Cachy.";
    }
}

static BOOL openMacPermissionSettings(EBMacPermissionKind kind) {
    NSString *query = macPermissionSettingsQuery(kind);
    if (!query) return NO;

    NSString *urlString = [NSString stringWithFormat:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?%@", query];
    NSURL *url = [NSURL URLWithString:urlString];
    if (url && [[NSWorkspace sharedWorkspace] openURL:url]) return YES;

    NSString *legacy = [NSString stringWithFormat:@"x-apple.systempreferences:com.apple.preference.security?%@", query];
    NSURL *legacyURL = [NSURL URLWithString:legacy];
    return legacyURL ? [[NSWorkspace sharedWorkspace] openURL:legacyURL] : NO;
}

static void activateSystemSettingsApp(void) {
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        NSString *bundleIdentifier = app.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.apple.systempreferences"]) continue;
        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        return;
    }
}

static NSScreen *screenForPoint(NSPoint point) {
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSPointInRect(point, screen.frame)) return screen;
    }
    return [NSScreen mainScreen];
}

static NSScreen *screenForRect(NSRect rect) {
    NSPoint center = NSMakePoint(NSMidX(rect), NSMidY(rect));
    return screenForPoint(center);
}

typedef CFArrayRef (*EBMacCGWindowListCopyWindowInfoFn)(uint32_t, uint32_t);

static BOOL findSystemSettingsFrame(NSRect *outFrame) {
    auto copyInfo = (EBMacCGWindowListCopyWindowInfoFn)dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
    if (!copyInfo) return NO;

    CFArrayRef list = copyInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return NO;

    BOOL found = NO;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
        NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
        if (!layer || [layer intValue] != 0) continue;

        NSString *owner = info[(__bridge NSString *)kCGWindowOwnerName];
        if (![owner isEqualToString:@"System Settings"] && ![owner isEqualToString:@"System Preferences"]) continue;

        NSDictionary *bounds = info[(__bridge NSString *)kCGWindowBounds];
        CGRect cgBounds = CGRectZero;
        if (!bounds || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds, &cgBounds)) continue;

        CGFloat screenHeight = CGDisplayBounds(CGMainDisplayID()).size.height;
        if (screenHeight <= 0) continue;

        *outFrame = NSMakeRect(cgBounds.origin.x, screenHeight - cgBounds.origin.y - cgBounds.size.height, cgBounds.size.width, cgBounds.size.height);
        found = YES;
        break;
    }

    CFRelease(list);
    return found;
}

static BOOL hasSystemSettingsFrame(void) {
    NSRect frame = NSZeroRect;
    return findSystemSettingsFrame(&frame);
}

static NSWindow *currentPermissionSourceWindow() {
    NSWindow *candidate = [NSApp keyWindow] ?: [NSApp mainWindow];
    if (candidate && candidate != g_macPermissionGuidePanel && candidate.isVisible) {
        return candidate;
    }

    for (NSWindow *window in [NSApp windows]) {
        if (window == g_macPermissionGuidePanel) continue;
        if (!window.isVisible) continue;
        if ([window isKindOfClass:[NSPanel class]]) continue;
        return window;
    }
    return nil;
}

static void capturePermissionSourceWindow() {
    g_macPermissionSourceWindow = currentPermissionSourceWindow();
    if (g_macPermissionSourceWindow) {
        g_macPermissionSourceFrame = g_macPermissionSourceWindow.frame;
        g_hasMacPermissionSourceFrame = YES;
    } else {
        g_macPermissionSourceFrame = NSZeroRect;
        g_hasMacPermissionSourceFrame = NO;
    }
}

static NSRect permissionGuidePanelFrame(CGFloat width, CGFloat height, BOOL *attachToSourceWindow) {
    if (attachToSourceWindow) {
        *attachToSourceWindow = NO;
    }

    NSRect settingsFrame = NSZeroRect;
    if (findSystemSettingsFrame(&settingsFrame)) {
        NSScreen *screen = screenForRect(settingsFrame);
        NSRect visible = screen ? screen.visibleFrame : [[NSScreen mainScreen] visibleFrame];
        CGFloat padding = 28;
        CGFloat x = NSMaxX(settingsFrame) - width - padding;
        CGFloat y = settingsFrame.origin.y + padding;
        x = MAX(NSMinX(visible) + padding, MIN(x, NSMaxX(visible) - width - padding));
        y = MAX(NSMinY(visible) + padding, MIN(y, NSMaxY(visible) - height - padding));
        return NSMakeRect(x, y, width, height);
    }

    NSScreen *screen = nil;
    if (g_hasMacPermissionSourceFrame) {
        NSRect sourceFrame = g_macPermissionSourceWindow ? g_macPermissionSourceWindow.frame : g_macPermissionSourceFrame;
        screen = screenForRect(sourceFrame);
    }
    if (!screen) {
        screen = screenForPoint([NSEvent mouseLocation]);
    }
    NSRect visible = screen ? screen.visibleFrame : [[NSScreen mainScreen] visibleFrame];
    CGFloat padding = 28;
    return NSMakeRect(NSMaxX(visible) - width - padding, NSMinY(visible) + padding, width, height);
}

@interface EBMacPermissionDragView : NSView <NSDraggingSource>
@property(nonatomic, strong) NSURL *bundleURL;
@property(nonatomic, copy) NSString *appName;
@property(nonatomic, strong) NSImage *appIcon;
@property(nonatomic, strong) NSEvent *mouseDownEvent;
@property(nonatomic) BOOL hasStartedDrag;
@end

@implementation EBMacPermissionDragView

- (instancetype)initWithFrame:(NSRect)frame bundleURL:(NSURL *)bundleURL appName:(NSString *)appName {
    self = [super initWithFrame:frame];
    if (self) {
        self.bundleURL = bundleURL;
        self.appName = appName;
        self.appIcon = [[NSWorkspace sharedWorkspace] iconForFile:bundleURL.path];
        self.appIcon.size = NSMakeSize(32, 32);
        self.wantsLayer = YES;
    }
    return self;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor openHandCursor]];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect pillRect = NSInsetRect(self.bounds, 0, 0);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:10 yRadius:10];
    [[NSColor colorWithWhite:1 alpha:0.10] setFill];
    [pill fill];
    [[NSColor colorWithWhite:1 alpha:0.16] setStroke];
    [pill stroke];

    NSRect iconRect = NSMakeRect(12, NSMidY(self.bounds) - 16, 32, 32);
    [self.appIcon drawInRect:iconRect];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor labelColor],
    };
    NSRect textRect = NSMakeRect(54, NSMidY(self.bounds) - 9, self.bounds.size.width - 66, 18);
    [self.appName drawInRect:textRect withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)event {
    self.mouseDownEvent = event;
    self.hasStartedDrag = NO;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.mouseDownEvent || self.hasStartedDrag) {
        [super mouseDragged:event];
        return;
    }

    CGFloat dx = event.locationInWindow.x - self.mouseDownEvent.locationInWindow.x;
    CGFloat dy = event.locationInWindow.y - self.mouseDownEvent.locationInWindow.y;
    if (hypot(dx, dy) < 3) return;

    self.hasStartedDrag = YES;
    [self startDragWithEvent:self.mouseDownEvent];
}

- (void)mouseUp:(NSEvent *)event {
    self.mouseDownEvent = nil;
    self.hasStartedDrag = NO;
    [super mouseUp:event];
}

- (void)startDragWithEvent:(NSEvent *)event {
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:self.bundleURL];
    NSImage *image = [self dragPreviewImage] ?: self.appIcon;
    [item setDraggingFrame:self.bounds contents:image];

    NSDraggingSession *session = [self beginDraggingSessionWithItems:@[item] event:event source:self];
    session.animatesToStartingPositionsOnCancelOrFail = YES;
    session.draggingFormation = NSDraggingFormationNone;
}

- (NSImage *)dragPreviewImage {
    NSBitmapImageRep *rep = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    if (!rep) return nil;
    [self cacheDisplayInRect:self.bounds toBitmapImageRep:rep];
    NSImage *image = [[NSImage alloc] initWithSize:self.bounds.size];
    [image addRepresentation:rep];
    return image;
}

- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    return NSDragOperationCopy;
}

- (void)draggingSession:(NSDraggingSession *)session endedAtPoint:(NSPoint)screenPoint operation:(NSDragOperation)operation {
    self.mouseDownEvent = nil;
    self.hasStartedDrag = NO;
}

@end

static NSString *fallbackAppName(NSString *appName) {
    if (appName && appName.length > 0) return appName;
    NSString *processName = [[NSProcessInfo processInfo] processName];
    return processName.length > 0 ? processName : @"This app";
}

static void showMacPermissionGuidePanel(EBMacPermissionKind kind, NSURL *bundleURL, NSString *appName) {
    CGFloat width = 340;
    CGFloat height = 112;

    if (g_macPermissionGuidePanel) {
        if (g_macPermissionGuideAttachedToSource && g_macPermissionSourceWindow) {
            [g_macPermissionSourceWindow removeChildWindow:g_macPermissionGuidePanel];
        }
        [g_macPermissionGuidePanel close];
        g_macPermissionGuidePanel = nil;
        g_macPermissionGuideAttachedToSource = NO;
    }

    BOOL attachToSourceWindow = NO;
    NSRect panelFrame = permissionGuidePanelFrame(width, height, &attachToSourceWindow);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:panelFrame
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.releasedWhenClosed = NO;
    panel.opaque = NO;
    panel.backgroundColor = [NSColor clearColor];
    panel.hasShadow = YES;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    content.wantsLayer = YES;
    content.layer.cornerRadius = 16;
    content.layer.masksToBounds = YES;
    content.layer.borderWidth = 1;
    content.layer.borderColor = [[NSColor colorWithWhite:1 alpha:0.18] CGColor];

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
    background.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    background.material = NSVisualEffectMaterialPopover;
    background.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    background.state = NSVisualEffectStateActive;
    [content addSubview:background];

    NSView *arrowBubble = [[NSView alloc] initWithFrame:NSMakeRect(18, 66, 28, 28)];
    arrowBubble.wantsLayer = YES;
    arrowBubble.layer.cornerRadius = 14;
    arrowBubble.layer.backgroundColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.18].CGColor;
    [content addSubview:arrowBubble];

    NSTextField *arrow = [NSTextField labelWithString:@"↑"];
    arrow.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    arrow.textColor = [NSColor systemBlueColor];
    arrow.alignment = NSTextAlignmentCenter;
    arrow.frame = NSMakeRect(18, 65, 28, 28);
    [content addSubview:arrow];

    NSTextField *title = [NSTextField labelWithString:[NSString stringWithFormat:@"Drag %@ into the list above.", fallbackAppName(appName)]];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = [NSColor labelColor];
    title.frame = NSMakeRect(58, 76, width - 76, 18);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:title];

    NSTextField *subtitle = [NSTextField labelWithString:macPermissionGuideInstruction(kind)];
    subtitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    subtitle.textColor = [NSColor secondaryLabelColor];
    subtitle.frame = NSMakeRect(58, 58, width - 76, 16);
    subtitle.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:subtitle];

    NSButton *backButton = [[NSButton alloc] initWithFrame:NSMakeRect(18, 18, 30, 30)];
    backButton.title = @"‹";
    backButton.font = [NSFont systemFontOfSize:20 weight:NSFontWeightRegular];
    backButton.bezelStyle = NSBezelStyleCircular;
    backButton.target = panel;
    backButton.action = @selector(close);
    [content addSubview:backButton];

    EBMacPermissionDragView *dragView = [[EBMacPermissionDragView alloc] initWithFrame:NSMakeRect(58, 18, width - 76, 40)
                                                                             bundleURL:bundleURL
                                                                               appName:fallbackAppName(appName)];
    [content addSubview:dragView];

    panel.contentView = content;
    [panel orderFrontRegardless];
    if (attachToSourceWindow && g_macPermissionSourceWindow) {
        [g_macPermissionSourceWindow addChildWindow:panel ordered:NSWindowAbove];
    }
    g_macPermissionGuideAttachedToSource = attachToSourceWindow;
    g_macPermissionGuidePanel = panel;
}

static void showMacPermissionGuidePanelWhenSettingsReady(EBMacPermissionKind kind, NSURL *bundleURL, NSString *appName, NSInteger requestID, NSInteger attempt) {
    if (requestID != g_macPermissionGuideRequestID) return;

    const NSInteger maxAttempts = 28;
    if (hasSystemSettingsFrame() || attempt >= maxAttempts) {
        showMacPermissionGuidePanel(kind, bundleURL, appName);
        return;
    }

    activateSystemSettingsApp();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        showMacPermissionGuidePanelWhenSettingsReady(kind, bundleURL, appName, requestID, attempt + 1);
    });
}

extern "C" BOOL macPermissionStatus(const char *kind) {
    return isMacPermissionGranted(macPermissionKindFromCString(kind));
}

// requestMacPermissionDragGuide
// Return codes:
//   1  already granted
//   0  guide shown
//  -1  unsupported permission kind
//  -2  current process is not running from a .app bundle
//  -3  failed to open System Settings
extern "C" int requestMacPermissionDragGuide(const char *kindCString, const char *appNameCString, BOOL forceGuide) {
    __block int result = -1;
    dispatch_sync(dispatch_get_main_queue(), ^{
        EBMacPermissionKind kind = macPermissionKindFromCString(kindCString);
        if (kind == EBMacPermissionKindUnknown) {
            result = -1;
            return;
        }

        if (!forceGuide && isMacPermissionGranted(kind)) {
            result = 1;
            return;
        }

        NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
        if (!bundleURL || ![[bundleURL.pathExtension lowercaseString] isEqualToString:@"app"]) {
            result = -2;
            return;
        }

        capturePermissionSourceWindow();
        NSInteger requestID = ++g_macPermissionGuideRequestID;

        if (!openMacPermissionSettings(kind)) {
            result = -3;
            return;
        }
        activateSystemSettingsApp();

        NSString *appName = appNameCString && strlen(appNameCString) > 0
            ? [NSString stringWithUTF8String:appNameCString]
            : nil;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            activateSystemSettingsApp();
            showMacPermissionGuidePanelWhenSettingsReady(kind, bundleURL, appName, requestID, 0);
        });
        result = 0;
    });
    return result;
}

extern "C" void closeMacPermissionDragGuide(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_macPermissionGuideRequestID++;
        if (g_macPermissionGuidePanel) {
            if (g_macPermissionGuideAttachedToSource && g_macPermissionSourceWindow) {
                [g_macPermissionSourceWindow removeChildWindow:g_macPermissionGuidePanel];
            }
            [g_macPermissionGuidePanel close];
            g_macPermissionGuidePanel = nil;
        }
        g_macPermissionSourceWindow = nil;
        g_hasMacPermissionSourceFrame = NO;
        g_macPermissionGuideAttachedToSource = NO;
    });
}

// hasScreenRecordingPermission - Check whether the app has Screen Recording permission.
// Returns YES if granted, NO otherwise. Available since macOS 10.15.
extern "C" BOOL hasScreenRecordingPermission(void) {
    return CGPreflightScreenCaptureAccess();
}

// requestScreenRecordingPermission - Prompt the user to grant Screen Recording permission.
// On macOS 10.15+, this opens System Settings to the Screen Recording pane.
// Returns YES if permission was already granted, NO if the prompt was shown.
extern "C" BOOL requestScreenRecordingPermission(void) {
    return CGRequestScreenCaptureAccess();
}

// captureScreenExcludingWindow - Capture the screen as PNG, excluding a specific window.
// Uses the legacy CGWindowList API loaded via dlsym to avoid ScreenCaptureKit's
// recording indicator. The functions still exist in CoreGraphics at runtime even
// though the macOS 15 SDK marks them as obsoleted.
// Captures the display under the mouse cursor (multi-monitor aware).
// window: NSWindow* to exclude (or NULL to capture the entire screen)
// outSize: receives the byte length of the returned PNG buffer
// Returns: malloc'd PNG data (caller must free), or NULL on failure

typedef CFArrayRef (*CGWindowListCreateFn)(uint32_t, uint32_t);
typedef CGImageRef (*CGWindowListCreateImageFromArrayFn)(CGRect, CFArrayRef, uint32_t);

extern "C" const uint8_t* captureScreenExcludingWindow(NSWindow *window, size_t *outSize) {
    __block const uint8_t* result = NULL;
    __block size_t size = 0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        CGWindowID excludeId = 0;
        if (window) {
            excludeId = (CGWindowID)[window windowNumber];
        }

        auto listCreate = (CGWindowListCreateFn)dlsym(RTLD_DEFAULT, "CGWindowListCreate");
        auto imageCreate = (CGWindowListCreateImageFromArrayFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImageFromArray");
        if (!listCreate || !imageCreate) return;

        CFArrayRef windowList = listCreate(
            kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!windowList) return;

        CFMutableArrayRef filtered = CFArrayCreateMutableCopy(NULL, 0, windowList);
        CFRelease(windowList);

        if (excludeId != 0) {
            for (CFIndex i = CFArrayGetCount(filtered) - 1; i >= 0; i--) {
                CGWindowID wid = (CGWindowID)(uintptr_t)
                    CFArrayGetValueAtIndex(filtered, i);
                if (wid == excludeId) {
                    CFArrayRemoveValueAtIndex(filtered, i);
                }
            }
        }

        CGDirectDisplayID targetDisplay = CGMainDisplayID();
        NSPoint mouse = [NSEvent mouseLocation];
        for (NSScreen *screen in [NSScreen screens]) {
            if (NSPointInRect(mouse, [screen frame])) {
                NSDictionary *desc = [screen deviceDescription];
                NSNumber *displayId = desc[@"NSScreenNumber"];
                if (displayId) {
                    targetDisplay = [displayId unsignedIntValue];
                }
                break;
            }
        }
        CGRect screenBounds = CGDisplayBounds(targetDisplay);
        CGImageRef image = imageCreate(screenBounds, filtered, kCGWindowImageDefault);
        CFRelease(filtered);
        if (!image) return;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        CGImageRelease(image);
        NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                           properties:@{}];
        if (!pngData || [pngData length] == 0) return;

        size = [pngData length];
        uint8_t *buffer = (uint8_t*)malloc(size);
        memcpy(buffer, [pngData bytes], size);
        result = buffer;
    });

    if (outSize) *outSize = size;
    return result;
}

// getOnScreenWindowList - Return JSON array of on-screen, normal-layer windows.
// Each entry includes the native window id plus app metadata when available.
// Returns: malloc'd JSON string (caller must free), or NULL on failure.
typedef CFArrayRef (*CGWindowListCopyWindowInfoFn)(uint32_t, uint32_t);

extern "C" const char* getOnScreenWindowList() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        auto copyInfo = (CGWindowListCopyWindowInfoFn)dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
        if (!copyInfo) return;

        CFArrayRef list = copyInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        if (!list) return;

        NSMutableArray *windows = [NSMutableArray array];
        CFIndex count = CFArrayGetCount(list);

        for (CFIndex i = 0; i < count; i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
            NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
            if (!layer || [layer intValue] != 0) continue;

            NSString *owner = info[(__bridge NSString *)kCGWindowOwnerName];
            NSString *name  = info[(__bridge NSString *)kCGWindowName];
            NSNumber *num   = info[(__bridge NSString *)kCGWindowNumber];
            NSNumber *ownerPid = info[(__bridge NSString *)kCGWindowOwnerPID];
            if (!owner || !num) continue;

            NSMutableDictionary *payload = [@{
                @"owner": owner,
                @"name": name ?: @"",
                @"id": num
            } mutableCopy];

            if (ownerPid) {
                payload[@"ownerPid"] = ownerPid;
                NSRunningApplication *app =
                    [NSRunningApplication runningApplicationWithProcessIdentifier:[ownerPid intValue]];
                if (app) {
                    payload[@"bundleId"] = app.bundleIdentifier ?: @"";
                    payload[@"path"] = app.bundleURL.path ?: @"";
                }
            }

            [windows addObject:payload];
        }

        CFRelease(list);
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:windows options:0 error:&error];
        if (!data || error) return;

        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!json) return;
        result = strdup([json UTF8String]);
    });

    return result;
}

// captureWindowById - Capture a single window by its CGWindowID as PNG.
// windowId: the CGWindowID to capture
// outSize: receives the byte length of the returned PNG buffer
// Returns: malloc'd PNG data (caller must free), or NULL on failure
typedef CGImageRef (*CGWindowListCreateImageFn)(CGRect, uint32_t, uint32_t, uint32_t);

extern "C" const uint8_t* captureWindowById(uint32_t windowId, size_t *outSize) {
    __block const uint8_t* result = NULL;
    __block size_t size = 0;

    dispatch_sync(dispatch_get_main_queue(), ^{
        auto imageCreate = (CGWindowListCreateImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        if (!imageCreate) return;

        CGImageRef image = imageCreate(
            CGRectNull,
            kCGWindowListOptionIncludingWindow,
            windowId,
            kCGWindowImageBoundsIgnoreFraming);
        if (!image) return;

        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
        CGImageRelease(image);
        NSData *pngData = [rep representationUsingType:NSBitmapImageFileTypePNG
                                           properties:@{}];
        if (!pngData || [pngData length] == 0) return;

        size = [pngData length];
        uint8_t *buffer = (uint8_t*)malloc(size);
        memcpy(buffer, [pngData bytes], size);
        result = buffer;
    });

    if (outSize) *outSize = size;
    return result;
}

static const char* copyJsonCStringFromObject(id object) {
    if (!object) return NULL;

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data || error) return NULL;

    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!json) return NULL;

    return strdup([json UTF8String]);
}

// getRunningApplications - Return regular running GUI applications with bundle metadata.
// Returns: JSON array string (caller must free), or NULL on failure.
extern "C" const char* getRunningApplications() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSMutableArray *apps = [NSMutableArray array];
        for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
            if (app.activationPolicy != NSApplicationActivationPolicyRegular) continue;

            [apps addObject:@{
                @"bundleId": app.bundleIdentifier ?: @"",
                @"name": app.localizedName ?: @"",
                @"path": app.bundleURL.path ?: @"",
                @"pid": @(app.processIdentifier),
                @"active": @(app.active),
                @"hidden": @(app.hidden)
            }];
        }

        result = copyJsonCStringFromObject(apps);
    });

    return result;
}

// getFrontmostAppInfo - Get info about the currently frontmost application
// Returns: JSON string with bundleId, name, path (caller must free), or NULL
extern "C" const char* getFrontmostAppInfo() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (!app) return;

        NSDictionary *payload = @{
            @"bundleId": app.bundleIdentifier ?: @"",
            @"name": app.localizedName ?: @"",
            @"path": app.bundleURL.path ?: @""
        };
        result = copyJsonCStringFromObject(payload);
    });

    return result;
}

// getFrontmostWindowInfo - Get the exact frontmost window for the active app.
// Returns: JSON string with app info plus windowId/windowTitle/ownerPid, or NULL.
extern "C" const char* getFrontmostWindowInfo() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (!app) return;

        auto copyInfo = (CGWindowListCopyWindowInfoFn)dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
        if (!copyInfo) return;

        pid_t pid = app.processIdentifier;
        CFArrayRef list = copyInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        if (!list) return;

        NSDictionary *matchedInfo = nil;
        CFIndex count = CFArrayGetCount(list);
        for (CFIndex i = 0; i < count; i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
            NSNumber *layer = info[(__bridge NSString *)kCGWindowLayer];
            NSNumber *ownerPid = info[(__bridge NSString *)kCGWindowOwnerPID];
            NSNumber *windowNumber = info[(__bridge NSString *)kCGWindowNumber];
            if (!layer || !ownerPid || !windowNumber) continue;
            if ([layer intValue] != 0) continue;
            if ([ownerPid intValue] != pid) continue;
            matchedInfo = info;
            break;
        }

        if (matchedInfo) {
            NSNumber *windowNumber = matchedInfo[(__bridge NSString *)kCGWindowNumber];
            NSString *windowTitle = matchedInfo[(__bridge NSString *)kCGWindowName] ?: @"";
            NSDictionary *payload = @{
                @"bundleId": app.bundleIdentifier ?: @"",
                @"name": app.localizedName ?: @"",
                @"path": app.bundleURL.path ?: @"",
                @"windowId": windowNumber,
                @"windowTitle": windowTitle,
                @"ownerPid": @(pid)
            };
            result = copyJsonCStringFromObject(payload);
        }

        CFRelease(list);
    });

    return result;
}

typedef AXError (*AXUIElementGetWindowFn)(AXUIElementRef, CGWindowID *);

static bool getOwnerPidForWindowId(CGWindowID windowId, pid_t *outPid) {
    auto copyInfo = (CGWindowListCopyWindowInfoFn)dlsym(RTLD_DEFAULT, "CGWindowListCopyWindowInfo");
    if (!copyInfo) return false;

    CFArrayRef list = copyInfo(kCGWindowListOptionIncludingWindow, windowId);
    if (!list) return false;

    bool found = false;
    if (CFArrayGetCount(list) > 0) {
        NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, 0);
        NSNumber *ownerPid = info[(__bridge NSString *)kCGWindowOwnerPID];
        if (ownerPid) {
            *outPid = (pid_t)[ownerPid intValue];
            found = true;
        }
    }

    CFRelease(list);
    return found;
}

static bool copyAXWindowForCGWindowId(pid_t pid, CGWindowID targetWindowId, AXUIElementRef *outApp, AXUIElementRef *outWindow) {
    AXUIElementGetWindowFn getAXWindow = (AXUIElementGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    if (!getAXWindow) return false;

    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) return false;

    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    if (err != kAXErrorSuccess || !windowsRef) {
        CFRelease(appRef);
        return false;
    }

    CFArrayRef windows = (CFArrayRef)windowsRef;
    AXUIElementRef matchedWindow = NULL;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef winRef = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CGWindowID currentWindowId = 0;
        if (getAXWindow(winRef, &currentWindowId) == kAXErrorSuccess && currentWindowId == targetWindowId) {
            matchedWindow = winRef;
            CFRetain(matchedWindow);
            break;
        }
    }

    CFRelease(windows);

    if (!matchedWindow) {
        CFRelease(appRef);
        return false;
    }

    *outApp = appRef;
    *outWindow = matchedWindow;
    return true;
}

extern "C" bool activateWindowById(uint32_t windowId) {
    if (windowId == 0) return false;

    __block bool success = false;

    dispatch_sync(dispatch_get_main_queue(), ^{
        pid_t pid = 0;
        if (!getOwnerPidForWindowId((CGWindowID)windowId, &pid)) return;

        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!app) return;

        AXUIElementRef appRef = NULL;
        AXUIElementRef winRef = NULL;
        if (!copyAXWindowForCGWindowId(pid, (CGWindowID)windowId, &appRef, &winRef)) return;

        [app activateWithOptions:0];
        AXUIElementSetAttributeValue(winRef, kAXMinimizedAttribute, kCFBooleanFalse);
        AXError focusedErr = AXUIElementSetAttributeValue(appRef, kAXFocusedWindowAttribute, winRef);
        AXError windowFocusedErr = AXUIElementSetAttributeValue(winRef, kAXFocusedAttribute, kCFBooleanTrue);
        AXError mainErr = AXUIElementSetAttributeValue(winRef, kAXMainAttribute, kCFBooleanTrue);
        AXError raiseErr = AXUIElementPerformAction(winRef, kAXRaiseAction);

        success = focusedErr == kAXErrorSuccess
            || windowFocusedErr == kAXErrorSuccess
            || mainErr == kAXErrorSuccess
            || raiseErr == kAXErrorSuccess;

        CFRelease(winRef);
        CFRelease(appRef);
    });

    return success;
}

// Helper: get AXUIElementRef for the frontmost application's first window.
// Caller must CFRelease both *outApp and *outWindow when done.
static bool getFrontmostAXWindow(AXUIElementRef *outApp, AXUIElementRef *outWindow) {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (!app) return false;

    pid_t pid = app.processIdentifier;
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) return false;

    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    if (err != kAXErrorSuccess || !windowsRef) {
        CFRelease(appRef);
        return false;
    }

    CFArrayRef windows = (CFArrayRef)windowsRef;
    if (CFArrayGetCount(windows) == 0) {
        CFRelease(windows);
        CFRelease(appRef);
        return false;
    }

    AXUIElementRef winRef = (AXUIElementRef)CFArrayGetValueAtIndex(windows, 0);
    CFRetain(winRef);
    CFRelease(windows);

    *outApp = appRef;
    *outWindow = winRef;
    return true;
}

static bool getAXWindowBounds(AXUIElementRef winRef, CGPoint *outPos, CGSize *outSize) {
    CFTypeRef posRef = NULL;
    CFTypeRef sizeRef = NULL;

    AXError err = AXUIElementCopyAttributeValue(winRef, kAXPositionAttribute, &posRef);
    if (err != kAXErrorSuccess || !posRef) return false;

    err = AXUIElementCopyAttributeValue(winRef, kAXSizeAttribute, &sizeRef);
    if (err != kAXErrorSuccess || !sizeRef) {
        CFRelease(posRef);
        return false;
    }

    AXValueGetValue((AXValueRef)posRef, (AXValueType)kAXValueCGPointType, outPos);
    AXValueGetValue((AXValueRef)sizeRef, (AXValueType)kAXValueCGSizeType, outSize);
    CFRelease(posRef);
    CFRelease(sizeRef);
    return true;
}

extern "C" const char* getFrontmostWindowBounds() {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        AXUIElementRef appRef = NULL;
        AXUIElementRef winRef = NULL;
        if (!getFrontmostAXWindow(&appRef, &winRef)) return;

        CGPoint pos;
        CGSize size;
        if (getAXWindowBounds(winRef, &pos, &size)) {
            NSString *json = [NSString stringWithFormat:@"{\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}",
                (int)pos.x, (int)pos.y, (int)size.width, (int)size.height];
            result = strdup([json UTF8String]);
        }

        CFRelease(winRef);
        CFRelease(appRef);
    });

    return result;
}

extern "C" const char* setFrontmostWindowBounds(int x, int y, int w, int h) {
    __block const char* result = NULL;

    dispatch_sync(dispatch_get_main_queue(), ^{
        AXUIElementRef appRef = NULL;
        AXUIElementRef winRef = NULL;
        if (!getFrontmostAXWindow(&appRef, &winRef)) return;

        CGPoint oldPos;
        CGSize oldSize;
        if (getAXWindowBounds(winRef, &oldPos, &oldSize)) {
            NSString *json = [NSString stringWithFormat:@"{\"x\":%d,\"y\":%d,\"width\":%d,\"height\":%d}",
                (int)oldPos.x, (int)oldPos.y, (int)oldSize.width, (int)oldSize.height];
            result = strdup([json UTF8String]);
        }

        CGPoint newPos = CGPointMake(x, y);
        CGSize newSize = CGSizeMake(w, h);
        AXValueRef posVal = AXValueCreate((AXValueType)kAXValueCGPointType, &newPos);
        AXValueRef sizeVal = AXValueCreate((AXValueType)kAXValueCGSizeType, &newSize);

        if (posVal) {
            AXUIElementSetAttributeValue(winRef, kAXPositionAttribute, posVal);
            CFRelease(posVal);
        }
        if (sizeVal) {
            AXUIElementSetAttributeValue(winRef, kAXSizeAttribute, sizeVal);
            CFRelease(sizeVal);
        }

        CFRelease(winRef);
        CFRelease(appRef);
    });

    return result;
}

// getAppIconToPath - Extract an app/file icon and save as PNG
// appPath: path to the .app bundle (or any file/folder)
// outputPath: where to write the PNG
// size: desired width/height in pixels
// Returns: true on success
extern "C" bool getAppIconToPath(const char* appPath, const char* outputPath, int size) {
    if (!appPath || !outputPath || size <= 0) return false;

    __block bool success = false;

    dispatch_sync(dispatch_get_main_queue(), ^{
        NSString *path = [NSString stringWithUTF8String:appPath];
        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        if (!icon) return;

        [icon setSize:NSMakeSize(size, size)];

        NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:size
            pixelsHigh:size
            bitsPerSample:8
            samplesPerPixel:4
            hasAlpha:YES
            isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace
            bytesPerRow:0
            bitsPerPixel:0];

        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmapRep];
        [NSGraphicsContext setCurrentContext:ctx];
        [icon drawInRect:NSMakeRect(0, 0, size, size)
            fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
            fraction:1.0];
        [NSGraphicsContext restoreGraphicsState];

        NSData *pngData = [bitmapRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (pngData) {
            NSString *outPath = [NSString stringWithUTF8String:outputPath];
            success = [pngData writeToFile:outPath atomically:YES];
        }
    });

    return success;
}

// ============================================================================
// URL Scheme / Deep Linking API
// ============================================================================

// setURLOpenHandler - Set the callback for handling URLs opened via custom URL schemes.
// Flushes any URLs that arrived before the handler was registered (cold-launch).
extern "C" void setURLOpenHandler(URLOpenHandler handler) {
    std::vector<std::string> pending;
    {
        std::lock_guard<std::mutex> lock(g_urlOpenMutex);
        g_urlOpenHandler = handler;
        pending = std::move(g_pendingUrlOpenPaths);
    }
    // Deliver outside the lock to avoid holding it during the FFI call into Bun
    for (const auto& url : pending) {
        handler(url.c_str());
    }
}

extern "C" void setAppReopenHandler(AppReopenHandler handler) {
    g_appReopenHandler = handler;
}

extern "C" void setDockIcon(const char* imagePath) {
    void (^apply)(void) = ^{
        if (imagePath && strlen(imagePath) > 0) {
            NSString *path = [NSString stringWithUTF8String:imagePath];
            NSImage *favicon = [[NSImage alloc] initWithContentsOfFile:path];
            if (!favicon) return;

            CGFloat canvasSize = 1024;
            CGFloat iconSize = 832;
            CGFloat radius = 183;
            CGFloat offset = (canvasSize - iconSize) / 2;

            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(NULL, canvasSize, canvasSize, 8, canvasSize * 4,
                colorSpace, kCGImageAlphaPremultipliedLast);
            CGColorSpaceRelease(colorSpace);
            if (!ctx) return;

            CALayer *layer = [CALayer layer];
            layer.frame = CGRectMake(0, 0, iconSize, iconSize);
            layer.cornerRadius = radius;
            layer.cornerCurve = kCACornerCurveContinuous;
            layer.masksToBounds = YES;

            CGImageRef faviconCG = [favicon CGImageForProposedRect:NULL context:nil hints:nil];
            layer.contents = (__bridge id)faviconCG;
            layer.contentsGravity = kCAGravityResizeAspectFill;

            CGContextTranslateCTM(ctx, offset, offset);
            CGContextSetShadowWithColor(ctx, CGSizeMake(0, -10), 10,
                [[NSColor colorWithCalibratedRed:0 green:0 blue:0 alpha:0.3] CGColor]);
            [layer renderInContext:ctx];

            CGImageRef renderedCG = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);

            NSImage *icon = [[NSImage alloc] initWithCGImage:renderedCG size:NSMakeSize(512, 512)];;
            CGImageRelease(renderedCG);

            [NSApp setApplicationIconImage:icon];
        } else {
            [NSApp setApplicationIconImage:nil];
        }
    };

    if ([NSThread isMainThread]) {
        apply();
    } else {
        dispatch_async(dispatch_get_main_queue(), apply);
    }
}

extern "C" void setDockIconVisible(bool visible) {
    void (^applyVisibility)(void) = ^{
        NSApplication *app = [NSApplication sharedApplication];
        if (visible) {
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
            [app activateIgnoringOtherApps:YES];
        } else {
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        }
    };

    if ([NSThread isMainThread]) {
        applyVisibility();
    } else {
        dispatch_async(dispatch_get_main_queue(), applyVisibility);
    }
}

extern "C" bool isDockIconVisible() {
    __block bool isVisible = true;

    void (^readVisibility)(void) = ^{
        NSApplication *app = [NSApplication sharedApplication];
        isVisible = [app activationPolicy] == NSApplicationActivationPolicyRegular;
    };

    if ([NSThread isMainThread]) {
        readVisibility();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readVisibility);
    }

    return isVisible;
}

extern "C" NSStatusItem* createTray(uint32_t trayId, const char *title, const char *pathToImage, bool isTemplate,
                                    uint32_t width, uint32_t height, ZigStatusItemHandler zigTrayItemHandler) {
    
    __block NSStatusItem* trayPtr;
    
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSString *pathToImageString = [NSString stringWithUTF8String:pathToImage ?: ""];    
        NSString *titleString = [NSString stringWithUTF8String:title ?: ""];    
        NSStatusItem *statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        if (pathToImageString.length > 0) {
            statusItem.button.image = [[NSImage alloc] initWithContentsOfFile:pathToImageString];
            [statusItem.button.image setTemplate:isTemplate];
            statusItem.button.image.size = NSMakeSize(width, height);
        }    

        if (titleString.length > 0) {
            statusItem.button.title = titleString;
        }    

        if (zigTrayItemHandler) {
            StatusItemTarget *target = [[StatusItemTarget alloc] init];
            target.statusItem = statusItem;
            target.zigHandler = zigTrayItemHandler;
            target.trayId = trayId;        
            objc_setAssociatedObject(statusItem.button, "statusItemTarget", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [statusItem.button setTarget:target];
            [statusItem.button setAction:@selector(statusItemClicked:)];
            [statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
        }

        retainObjCObject(statusItem);    

        trayPtr = statusItem;
    });

    return trayPtr;
    
}

extern "C" void setTrayTitle(NSStatusItem *statusItem, const char *title) {
    if (statusItem) {
        statusItem.button.title = [NSString stringWithUTF8String:title ?: ""];
    }
}

extern "C" void setTrayImage(NSStatusItem *statusItem, const char *image, bool isTemplate,
                              uint32_t width, uint32_t height) {
    if (!statusItem) return;
    NSString *imgPath = [NSString stringWithUTF8String:image ?: ""];
    if (imgPath.length == 0) {
        statusItem.button.image = nil;
        return;
    }
    NSImage *img = [[NSImage alloc] initWithContentsOfFile:imgPath];
    if (!img) return;
    // `setTemplate:YES` makes NSStatusItem render the image as a monochrome
    // glyph that auto-tints with the menu bar appearance (white on dark, black
    // on light). Without this, the raw RGBA bitmap shows through — including
    // any anti-aliased edges from SVG rasterisers like qlmanage — which is
    // why menu-bar extensions like Coffee looked like a giant coloured square.
    [img setTemplate:isTemplate];
    if (width > 0 && height > 0) {
        // Setting `image.size` constrains the *displayed* size. The underlying
        // bitmap can stay at whatever native resolution qlmanage produced
        // (44px for retina), so the icon stays crisp on HiDPI displays.
        img.size = NSMakeSize(width, height);
    }
    statusItem.button.image = img;
}


extern "C" void setTrayMenuFromJSON(NSStatusItem *statusItem, const char *jsonString) {
    // Copy the string before dispatch_async since the JS-side buffer may be GC'd
    char *jsonCopy = strdup(jsonString);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusItem) {
            StatusItemTarget *target = objc_getAssociatedObject(statusItem.button, "statusItemTarget");
            NSData *jsonData = [NSData dataWithBytes:jsonCopy length:strlen(jsonCopy)];
            NSError *error;
            NSArray *menuArray = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
            free(jsonCopy);
            if (error) {
                NSLog(@"Failed to parse JSON: %@", error);
                return;
            }
            NSMenu *menu = createMenuFromConfig(menuArray, target);
            [statusItem setMenu:menu];
        } else {
            free(jsonCopy);
        }
    });
}

extern "C" void setTrayMenu(NSStatusItem *statusItem, const char *menuConfig) {
    if (statusItem) {
        setTrayMenuFromJSON(statusItem, menuConfig);
    }
}

extern "C" void removeTray(NSStatusItem *statusItem) {
    if (statusItem) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
        });
    }
}

extern "C" const char* getTrayBounds(NSStatusItem *statusItem) {
    if (!statusItem) {
        return strdup("{\"x\":0,\"y\":0,\"width\":0,\"height\":0}");
    }

    __block NSString *json = nil;

    void (^readBounds)(void) = ^{
        NSStatusBarButton *button = statusItem.button;
        if (!button || !button.window) {
            json = @"{\"x\":0,\"y\":0,\"width\":0,\"height\":0}";
            return;
        }

        NSRect frameInWindow = button.frame;
        NSRect frameOnScreen = [button.window convertRectToScreen:frameInWindow];
        json = [NSString stringWithFormat:@"{\"x\":%.0f,\"y\":%.0f,\"width\":%.0f,\"height\":%.0f}",
            frameOnScreen.origin.x,
            frameOnScreen.origin.y,
            frameOnScreen.size.width,
            frameOnScreen.size.height];
    };

    if ([NSThread isMainThread]) {
        readBounds();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readBounds);
    }

    return strdup([json UTF8String]);
}

extern "C" void setApplicationMenu(const char *jsonString, ZigStatusItemHandler zigTrayItemHandler) {
    // Copy the string before dispatch_async since the JS-side buffer may be GC'd
    char *jsonCopy = strdup(jsonString);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *jsonData = [NSData dataWithBytes:jsonCopy length:strlen(jsonCopy)];
        NSError *error;
        NSArray *menuArray = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        free(jsonCopy);
        if (error) {
            NSLog(@"Failed to parse JSON: %@", error);
            return;
        }
        StatusItemTarget *target = [[StatusItemTarget alloc] init];
        target.zigHandler = zigTrayItemHandler;
        target.trayId = 0;
        NSMenu *menu = createMenuFromConfig(menuArray, target);
        objc_setAssociatedObject(NSApp, "AppMenuTarget", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSApp setMainMenu:menu];
    });
}

extern "C" void showContextMenu(const char *jsonString, ZigStatusItemHandler contextMenuHandler) {
    // Copy the string before dispatch_async since the JS-side buffer may be GC'd
    char *jsonCopy = strdup(jsonString);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSData *jsonData = [NSData dataWithBytes:jsonCopy length:strlen(jsonCopy)];
        NSError *error;
        NSArray *menuArray = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
        free(jsonCopy);
        if (error) {
            NSLog(@"Failed to parse JSON: %@", error);
            return;
        }
        StatusItemTarget *target = [[StatusItemTarget alloc] init];
        target.zigHandler = contextMenuHandler;
        target.trayId = 0;
        NSMenu *menu = createMenuFromConfig(menuArray, target);
        objc_setAssociatedObject(menu, "ContextMenuTarget", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSPoint mouseLocation = [NSEvent mouseLocation];
        NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeRightMouseUp
                                            location:mouseLocation
                                    modifierFlags:0
                                        timestamp:0
                                        windowNumber:0
                                            context:nil
                                        eventNumber:0
                                        clickCount:1
                                            pressure:1];
        [menu popUpMenuPositioningItem:nil atLocation:mouseLocation inView:nil];
        objc_setAssociatedObject(NSApp, "ContextMenu", target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

extern "C" void getWebviewSnapshot(uint32_t hostId, uint32_t webviewId,
                                   WKWebView *webView,
                                   zigSnapshotCallback callback) {
    WKSnapshotConfiguration *snapshotConfig = [[WKSnapshotConfiguration alloc] init];
    [webView takeSnapshotWithConfiguration:snapshotConfig completionHandler:^(NSImage *snapshotImage, NSError *error) {
        if (error) {
            NSLog(@"Error capturing snapshot: %@", error);
            return;
        }
        NSBitmapImageRep *imgRep = [[NSBitmapImageRep alloc] initWithData:[snapshotImage TIFFRepresentation]];
        NSData *pngData = [imgRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSString *base64String = [pngData base64EncodedStringWithOptions:0];
        NSString *dataUrl = [NSString stringWithFormat:@"data:image/png;base64,%@", base64String];
        if (callback) {
            callback(hostId, webviewId, [dataUrl UTF8String]);
        }
    }];
}


extern "C" void setJSUtils(GetMimeType getMimeType, GetHTMLForWebviewSync getHTMLForWebviewSync) {    
    // NO-OP: jsUtils callbacks are deprecated, now using map-based approach
    // The function is kept for compatibility but does nothing
    
    // create a dispatch queue on the current thread (worker thread) that
    // can later be called from main
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, 0);
    jsWorkerQueue = dispatch_queue_create("com.electrobun.jsworker", attr);    

}

// MARK: - Webview HTML Content Management (replaces JSCallback approach)

extern "C" void setWebviewHTMLContent(uint32_t webviewId, const char* htmlContent) {
    if (!webviewHTMLContent) {
        NSLog(@"ERROR: setWebviewHTMLContent called before initialization");
        return;
    }
    
    [webviewHTMLLock lock];
    NSNumber *key = @(webviewId);
    if (htmlContent) {
        webviewHTMLContent[key] = [NSString stringWithUTF8String:htmlContent];
        NSLog(@"setWebviewHTMLContent: Set HTML for webview %u", webviewId);
    } else {
        [webviewHTMLContent removeObjectForKey:key];
        NSLog(@"setWebviewHTMLContent: Cleared HTML for webview %u", webviewId);
    }
    [webviewHTMLLock unlock];
}

const char* getWebviewHTMLContent(uint32_t webviewId) {
    if (!webviewHTMLContent) {
        NSLog(@"ERROR: getWebviewHTMLContent called before initialization");
        return NULL;
    }

    [webviewHTMLLock lock];
    NSString *htmlContent = webviewHTMLContent[@(webviewId)];
    const char* result = NULL;
    if (htmlContent) {
        result = strdup([htmlContent UTF8String]);
        NSLog(@"getWebviewHTMLContent: Retrieved HTML for webview %u", webviewId);
    } else {
        NSLog(@"getWebviewHTMLContent: No HTML found for webview %u", webviewId);
    }
    [webviewHTMLLock unlock];

    return result;
}

/*
 * =============================================================================
 * GLOBAL KEYBOARD SHORTCUTS
 * =============================================================================
 */

// Callback type for global shortcut triggers
typedef void (*GlobalShortcutCallback)(int shortcutId);
static GlobalShortcutCallback g_globalShortcutCallback = nullptr;

struct RegisteredShortcut {
    int id;
    CGKeyCode keyCode;
    CGEventFlags modifierFlags;
    std::string accelerator;
};

static std::vector<RegisteredShortcut> g_registeredShortcuts;
static NSLock *g_globalShortcutsLock = nil;
static CFMachPortRef g_eventTap = nullptr;
static CFRunLoopSourceRef g_eventTapSource = nullptr;
static int g_nextGlobalShortcutId = 1;

static CGEventFlags cgModifierFlagsFromAccelerator(const electrobun::AcceleratorParts& parts) {
    CGEventFlags flags = 0;
    if (parts.commandOrControl || parts.command) flags |= kCGEventFlagMaskCommand;
    if (parts.control)                           flags |= kCGEventFlagMaskControl;
    if (parts.alt)                               flags |= kCGEventFlagMaskAlternate;
    if (parts.shift)                             flags |= kCGEventFlagMaskShift;
    return flags;
}

static unsigned short keyCodeFromString(NSString *key) {
    static NSDictionary *keyMap = nil;
    if (!keyMap) {
        keyMap = @{
            @"a": @(0x00), @"b": @(0x0B), @"c": @(0x08), @"d": @(0x02),
            @"e": @(0x0E), @"f": @(0x03), @"g": @(0x05), @"h": @(0x04),
            @"i": @(0x22), @"j": @(0x26), @"k": @(0x28), @"l": @(0x25),
            @"m": @(0x2E), @"n": @(0x2D), @"o": @(0x1F), @"p": @(0x23),
            @"q": @(0x0C), @"r": @(0x0F), @"s": @(0x01), @"t": @(0x11),
            @"u": @(0x20), @"v": @(0x09), @"w": @(0x0D), @"x": @(0x07),
            @"y": @(0x10), @"z": @(0x06),
            @"0": @(0x1D), @"1": @(0x12), @"2": @(0x13), @"3": @(0x14),
            @"4": @(0x15), @"5": @(0x17), @"6": @(0x16), @"7": @(0x1A),
            @"8": @(0x1C), @"9": @(0x19),
            @"f1": @(0x7A), @"f2": @(0x78), @"f3": @(0x63), @"f4": @(0x76),
            @"f5": @(0x60), @"f6": @(0x61), @"f7": @(0x62), @"f8": @(0x64),
            @"f9": @(0x65), @"f10": @(0x6D), @"f11": @(0x67), @"f12": @(0x6F),
            @"f13": @(0x69), @"f14": @(0x6B), @"f15": @(0x71), @"f16": @(0x6A),
            @"f17": @(0x40), @"f18": @(0x4F), @"f19": @(0x50), @"f20": @(0x5A),
            @"space": @(0x31), @" ": @(0x31),
            @"return": @(0x24), @"enter": @(0x24),
            @"tab": @(0x30),
            @"escape": @(0x35), @"esc": @(0x35),
            @"backspace": @(0x33), @"delete": @(0x33),
            @"up": @(0x7E), @"down": @(0x7D), @"left": @(0x7B), @"right": @(0x7C),
            @"home": @(0x73), @"end": @(0x77),
            @"pageup": @(0x74), @"pagedown": @(0x79),
            @"-": @(0x1B), @"=": @(0x18), @"[": @(0x21), @"]": @(0x1E),
            @"\\": @(0x2A), @";": @(0x29), @"'": @(0x27), @",": @(0x2B),
            @".": @(0x2F), @"/": @(0x2C), @"`": @(0x32),
        };
    }

    NSNumber *code = keyMap[key];
    return code ? [code unsignedShortValue] : 0xFFFF;
}

// CGEventTap callback — returns NULL to consume matched shortcuts
static CGEventRef globalShortcutTapCallback(CGEventTapProxy proxy, CGEventType type,
                                            CGEventRef event, void *userInfo) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        NSLog(@"[GlobalShortcut] CGEventTap disabled (type=%u), re-enabling", type);
        if (g_eventTap) {
            CGEventTapEnable(g_eventTap, true);
        }
        return event;
    }

    if (type != kCGEventKeyDown) {
        return event;
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    int64_t isAutorepeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat);
    CGEventFlags flags = CGEventGetFlags(event);
    CGEventFlags relevantMask = (kCGEventFlagMaskCommand | kCGEventFlagMaskControl |
                                 kCGEventFlagMaskAlternate | kCGEventFlagMaskShift);
    CGEventFlags eventMods = flags & relevantMask;

    [g_globalShortcutsLock lock];
    for (const auto& shortcut : g_registeredShortcuts) {
        if (shortcut.keyCode == keyCode && shortcut.modifierFlags == eventMods) {
            if (isAutorepeat != 0) {
                [g_globalShortcutsLock unlock];
                return nullptr;
            }

            int shortcutId = shortcut.id;
            std::string accelerator = shortcut.accelerator;
            [g_globalShortcutsLock unlock];
            NSLog(@"[GlobalShortcut] Matched: %s (keyCode: %d, eventMods: 0x%llX)",
                  accelerator.c_str(), keyCode, (unsigned long long)eventMods);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_globalShortcutCallback) {
                    NSLog(@"[GlobalShortcut] Dispatching JS callback id=%d (%s)", shortcutId, accelerator.c_str());
                    g_globalShortcutCallback(shortcutId);
                } else {
                    NSLog(@"[GlobalShortcut] Missing JS callback for matched shortcut");
                }
            });
            return nullptr;
        }
    }
    [g_globalShortcutsLock unlock];

    return event;
}

static void ensureEventTap() {
    if (g_eventTap) return;

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    g_eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                  mask, globalShortcutTapCallback, nullptr);

    if (!g_eventTap) {
        NSLog(@"[GlobalShortcut] Failed to create CGEventTap — accessibility permissions required");
        return;
    }

    g_eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_eventTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(g_eventTap, true);
    NSLog(@"[GlobalShortcut] CGEventTap installed");
}

static void teardownEventTapIfEmpty() {
    if (!g_registeredShortcuts.empty() || !g_eventTap) return;

    CGEventTapEnable(g_eventTap, false);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), g_eventTapSource, kCFRunLoopCommonModes);
    CFRelease(g_eventTapSource);
    CFRelease(g_eventTap);
    g_eventTapSource = nullptr;
    g_eventTap = nullptr;
    NSLog(@"[GlobalShortcut] CGEventTap removed (no shortcuts registered)");
}

extern "C" void setGlobalShortcutCallback(GlobalShortcutCallback callback) {
    g_globalShortcutCallback = callback;

    if (!g_globalShortcutsLock) {
        g_globalShortcutsLock = [[NSLock alloc] init];
    }
}

extern "C" int registerGlobalShortcut(const char* accelerator) {
    if (!accelerator || !g_globalShortcutCallback) {
        NSLog(@"[GlobalShortcut] Cannot register: invalid accelerator or no callback set");
        return 0;
    }

    std::string accelStr(accelerator);

    auto parts = electrobun::parseAccelerator(accelerator);
    NSString *keyStr = [NSString stringWithUTF8String:parts.key.c_str()];
    unsigned short keyCode = keyCodeFromString(keyStr);

    if (keyCode == 0xFFFF) {
        NSLog(@"[GlobalShortcut] Unknown key: %s", parts.key.c_str());
        return 0;
    }

    CGEventFlags modifiers = cgModifierFlagsFromAccelerator(parts);

    [g_globalShortcutsLock lock];

    for (const auto& s : g_registeredShortcuts) {
        if (s.accelerator == accelStr) {
            [g_globalShortcutsLock unlock];
            NSLog(@"[GlobalShortcut] Already registered: %s", accelerator);
            return 0;
        }
    }

    int shortcutId = g_nextGlobalShortcutId++;
    g_registeredShortcuts.push_back({shortcutId, (CGKeyCode)keyCode, modifiers, accelStr});
    [g_globalShortcutsLock unlock];

    ensureEventTap();

    if (!g_eventTap) {
        // Event tap creation failed (accessibility denied) — roll back so retries work
        [g_globalShortcutsLock lock];
        auto it = std::remove_if(g_registeredShortcuts.begin(), g_registeredShortcuts.end(),
                                 [&](const RegisteredShortcut& s) { return s.accelerator == accelStr; });
        g_registeredShortcuts.erase(it, g_registeredShortcuts.end());
        [g_globalShortcutsLock unlock];
        NSLog(@"[GlobalShortcut] Failed to register %s — no event tap (accessibility denied)", accelerator);
        return 0;
    }

    NSLog(@"[GlobalShortcut] Registered: %s id=%d (keyCode: %d, modifiers: 0x%llX)",
          accelerator, shortcutId, keyCode, (unsigned long long)modifiers);
    return shortcutId;
}

extern "C" BOOL unregisterGlobalShortcut(const char* accelerator) {
    if (!accelerator) return NO;

    std::string accelStr(accelerator);

    [g_globalShortcutsLock lock];
    auto it = std::remove_if(g_registeredShortcuts.begin(), g_registeredShortcuts.end(),
                             [&](const RegisteredShortcut& s) { return s.accelerator == accelStr; });
    bool found = (it != g_registeredShortcuts.end());
    g_registeredShortcuts.erase(it, g_registeredShortcuts.end());
    [g_globalShortcutsLock unlock];

    if (found) {
        teardownEventTapIfEmpty();
        NSLog(@"[GlobalShortcut] Unregistered: %s", accelerator);
    }

    return found ? YES : NO;
}

extern "C" void unregisterAllGlobalShortcuts(void) {
    [g_globalShortcutsLock lock];
    g_registeredShortcuts.clear();
    [g_globalShortcutsLock unlock];

    teardownEventTapIfEmpty();
    NSLog(@"[GlobalShortcut] Unregistered all shortcuts");
}

// Check if a shortcut is registered
extern "C" BOOL isGlobalShortcutRegistered(const char* accelerator) {
    if (!accelerator) return NO;

    std::string accelStr(accelerator);

    [g_globalShortcutsLock lock];
    bool found = false;
    for (const auto& s : g_registeredShortcuts) {
        if (s.accelerator == accelStr) { found = true; break; }
    }
    [g_globalShortcutsLock unlock];

    return found ? YES : NO;
}

/*
 * =============================================================================
 * SCREEN API
 * =============================================================================
 */

// Get all displays as JSON array
// Returns: [{"id":123,"bounds":{x,y,width,height},"workArea":{...},"scaleFactor":2.0,"isPrimary":true},...]
extern "C" const char* getAllDisplays(void) {
    @autoreleasepool {
        NSArray<NSScreen *> *screens = [NSScreen screens];
        CGDirectDisplayID primaryDisplayId = CGMainDisplayID();

        NSMutableArray *displays = [NSMutableArray array];

        for (NSScreen *screen in screens) {
            // Get the display ID from the screen's deviceDescription
            NSDictionary *deviceDescription = [screen deviceDescription];
            NSNumber *screenNumber = deviceDescription[@"NSScreenNumber"];
            CGDirectDisplayID displayId = [screenNumber unsignedIntValue];

            // Get frame (full bounds) - need to flip Y coordinate for consistency
            NSRect frame = [screen frame];
            // macOS uses bottom-left origin, convert to top-left for consistency with other platforms
            CGFloat primaryHeight = [[[NSScreen screens] firstObject] frame].size.height;
            CGFloat flippedY = primaryHeight - frame.origin.y - frame.size.height;

            // Get visible frame (excludes menu bar and dock)
            NSRect visibleFrame = [screen visibleFrame];
            CGFloat visibleFlippedY = primaryHeight - visibleFrame.origin.y - visibleFrame.size.height;

            // Get scale factor (Retina = 2.0)
            CGFloat scaleFactor = [screen backingScaleFactor];

            // Check if this is the primary display
            BOOL isPrimary = (displayId == primaryDisplayId);

            NSDictionary *displayInfo = @{
                @"id": @(displayId),
                @"bounds": @{
                    @"x": @((int)frame.origin.x),
                    @"y": @((int)flippedY),
                    @"width": @((int)frame.size.width),
                    @"height": @((int)frame.size.height)
                },
                @"workArea": @{
                    @"x": @((int)visibleFrame.origin.x),
                    @"y": @((int)visibleFlippedY),
                    @"width": @((int)visibleFrame.size.width),
                    @"height": @((int)visibleFrame.size.height)
                },
                @"scaleFactor": @(scaleFactor),
                @"isPrimary": @(isPrimary)
            };

            [displays addObject:displayInfo];
        }

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:displays options:0 error:&error];
        if (error) {
            NSLog(@"[Screen] Failed to serialize displays: %@", error);
            return strdup("[]");
        }

        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return strdup([jsonString UTF8String]);
    }
}

// Get primary display as JSON
extern "C" const char* getPrimaryDisplay(void) {
    @autoreleasepool {
        NSArray<NSScreen *> *screens = [NSScreen screens];
        CGDirectDisplayID primaryDisplayId = CGMainDisplayID();

        for (NSScreen *screen in screens) {
            NSDictionary *deviceDescription = [screen deviceDescription];
            NSNumber *screenNumber = deviceDescription[@"NSScreenNumber"];
            CGDirectDisplayID displayId = [screenNumber unsignedIntValue];

            if (displayId == primaryDisplayId) {
                NSRect frame = [screen frame];
                CGFloat primaryHeight = [[[NSScreen screens] firstObject] frame].size.height;
                CGFloat flippedY = primaryHeight - frame.origin.y - frame.size.height;

                NSRect visibleFrame = [screen visibleFrame];
                CGFloat visibleFlippedY = primaryHeight - visibleFrame.origin.y - visibleFrame.size.height;

                CGFloat scaleFactor = [screen backingScaleFactor];

                NSDictionary *displayInfo = @{
                    @"id": @(displayId),
                    @"bounds": @{
                        @"x": @((int)frame.origin.x),
                        @"y": @((int)flippedY),
                        @"width": @((int)frame.size.width),
                        @"height": @((int)frame.size.height)
                    },
                    @"workArea": @{
                        @"x": @((int)visibleFrame.origin.x),
                        @"y": @((int)visibleFlippedY),
                        @"width": @((int)visibleFrame.size.width),
                        @"height": @((int)visibleFrame.size.height)
                    },
                    @"scaleFactor": @(scaleFactor),
                    @"isPrimary": @YES
                };

                NSError *error = nil;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:displayInfo options:0 error:&error];
                if (error) {
                    NSLog(@"[Screen] Failed to serialize primary display: %@", error);
                    return strdup("{}");
                }

                NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                return strdup([jsonString UTF8String]);
            }
        }

        return strdup("{}");
    }
}

// Get current cursor position as JSON: {"x": 123, "y": 456}
extern "C" const char* getCursorScreenPoint(void) {
    @autoreleasepool {
        NSPoint mouseLocation = [NSEvent mouseLocation];

        // Convert from bottom-left origin to top-left origin
        CGFloat primaryHeight = [[[NSScreen screens] firstObject] frame].size.height;
        CGFloat flippedY = primaryHeight - mouseLocation.y;

        NSDictionary *point = @{
            @"x": @((int)mouseLocation.x),
            @"y": @((int)flippedY)
        };

        NSError *error = nil;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:point options:0 error:&error];
        if (error) {
            return strdup("{\"x\":0,\"y\":0}");
        }

        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return strdup([jsonString UTF8String]);
    }
}

extern "C" uint64_t getMouseButtons(void) {
    return (uint64_t)[NSEvent pressedMouseButtons];
}

/*
 * =============================================================================
 * COOKIE MANAGEMENT API
 * =============================================================================
 */

// Helper to convert NSHTTPCookie to NSDictionary for JSON serialization
static NSDictionary* cookieToDictionary(NSHTTPCookie *cookie) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"name"] = cookie.name ?: @"";
    dict[@"value"] = cookie.value ?: @"";
    dict[@"domain"] = cookie.domain ?: @"";
    dict[@"path"] = cookie.path ?: @"/";
    dict[@"secure"] = @(cookie.secure);
    dict[@"httpOnly"] = @(cookie.HTTPOnly);
    if (cookie.expiresDate) {
        dict[@"expirationDate"] = @([cookie.expiresDate timeIntervalSince1970]);
    }
    if (cookie.sameSitePolicy) {
        dict[@"sameSite"] = cookie.sameSitePolicy;
    }
    return dict;
}

// Get cookies for a partition (WKWebView)
// filterJson: {"url": "https://example.com"} or {"domain": ".example.com"} or {} for all
// Returns JSON array of cookies
extern "C" const char* sessionGetCookies(const char* partitionIdentifier, const char* filterJson) {
    // Copy strings for use in block
    NSString *partitionStr = partitionIdentifier ? [NSString stringWithUTF8String:partitionIdentifier] : @"";
    NSString *filterStr = filterJson ? [NSString stringWithUTF8String:filterJson] : @"{}";

    __block char* result = strdup("[]");
    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSData *filterData = [filterStr dataUsingEncoding:NSUTF8StringEncoding];
            NSError *parseError = nil;
            NSDictionary *filter = [NSJSONSerialization JSONObjectWithData:filterData options:0 error:&parseError];
            if (parseError) {
                filter = @{};
            }

            NSString *filterUrl = filter[@"url"];
            NSString *filterDomain = filter[@"domain"];

            // Get the data store for this partition
            WKWebsiteDataStore *dataStore = createDataStoreForPartition([partitionStr UTF8String]);
            WKHTTPCookieStore *cookieStore = dataStore.httpCookieStore;

            [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
                NSMutableArray *matchingCookies = [NSMutableArray array];

                for (NSHTTPCookie *cookie in cookies) {
                    BOOL matches = YES;

                    if (filterUrl) {
                        NSURL *url = [NSURL URLWithString:filterUrl];
                        NSString *host = url.host;
                        NSString *cookieDomain = cookie.domain;
                        if ([cookieDomain hasPrefix:@"."]) {
                            matches = [host hasSuffix:cookieDomain] || [host isEqualToString:[cookieDomain substringFromIndex:1]];
                        } else {
                            matches = [host isEqualToString:cookieDomain];
                        }
                        if (matches && cookie.path && url.path) {
                            matches = [url.path hasPrefix:cookie.path];
                        }
                    } else if (filterDomain) {
                        NSString *cookieDomain = cookie.domain;
                        if ([filterDomain hasPrefix:@"."]) {
                            matches = [cookieDomain isEqualToString:filterDomain] ||
                                      [cookieDomain hasSuffix:filterDomain];
                        } else {
                            matches = [cookieDomain isEqualToString:filterDomain] ||
                                      [cookieDomain isEqualToString:[@"." stringByAppendingString:filterDomain]];
                        }
                    }

                    if (matches) {
                        [matchingCookies addObject:cookieToDictionary(cookie)];
                    }
                }

                NSError *error = nil;
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:matchingCookies options:0 error:&error];
                if (!error) {
                    NSString *resultJson = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                    free(result);
                    result = strdup([resultJson UTF8String]);
                }

                dispatch_semaphore_signal(completionSemaphore);
            }];
        }
    });

    dispatch_semaphore_wait(completionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return result;
}

// Set a cookie for a partition (WKWebView)
// cookieJson: {"url":"https://example.com","name":"token","value":"abc","domain":".example.com","path":"/","secure":true,"httpOnly":true,"expirationDate":1234567890,"sameSite":"Lax"}
extern "C" bool sessionSetCookie(const char* partitionIdentifier, const char* cookieJson) {
    // Copy strings for use in block
    NSString *partitionStr = partitionIdentifier ? [NSString stringWithUTF8String:partitionIdentifier] : @"";
    NSString *jsonStr = cookieJson ? [NSString stringWithUTF8String:cookieJson] : @"{}";

    // Parse cookie JSON first (can be done off main thread)
    NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
    NSError *parseError = nil;
    NSDictionary *cookieDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseError];
    if (parseError || !cookieDict[@"name"] || !cookieDict[@"value"]) {
        NSLog(@"[Cookie] Invalid cookie JSON: %@", jsonStr);
        return false;
    }

    // Build cookie properties
    NSMutableDictionary *properties = [NSMutableDictionary dictionary];
    properties[NSHTTPCookieName] = cookieDict[@"name"];
    properties[NSHTTPCookieValue] = cookieDict[@"value"];

    // Domain - required, derive from URL if not provided
    if (cookieDict[@"domain"]) {
        properties[NSHTTPCookieDomain] = cookieDict[@"domain"];
    } else if (cookieDict[@"url"]) {
        NSURL *url = [NSURL URLWithString:cookieDict[@"url"]];
        properties[NSHTTPCookieDomain] = url.host;
    } else {
        NSLog(@"[Cookie] Missing domain or url");
        return false;
    }

    // Path
    properties[NSHTTPCookiePath] = cookieDict[@"path"] ?: @"/";

    // Secure
    if ([cookieDict[@"secure"] boolValue]) {
        properties[NSHTTPCookieSecure] = @"TRUE";
    }

    // HttpOnly
    if ([cookieDict[@"httpOnly"] boolValue]) {
        properties[@"HttpOnly"] = @"TRUE";
    }

    // Expiration date
    if (cookieDict[@"expirationDate"]) {
        NSTimeInterval timestamp = [cookieDict[@"expirationDate"] doubleValue];
        properties[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:timestamp];
    }

    // SameSite
    if (cookieDict[@"sameSite"]) {
        properties[NSHTTPCookieSameSitePolicy] = cookieDict[@"sameSite"];
    }

    NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
    if (!cookie) {
        NSLog(@"[Cookie] Failed to create cookie from properties");
        return false;
    }

    __block bool success = false;
    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            WKWebsiteDataStore *dataStore = createDataStoreForPartition([partitionStr UTF8String]);
            WKHTTPCookieStore *cookieStore = dataStore.httpCookieStore;

            [cookieStore setCookie:cookie completionHandler:^{
                success = true;
                dispatch_semaphore_signal(completionSemaphore);
            }];
        }
    });

    dispatch_semaphore_wait(completionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return success;
}

// Remove a specific cookie for a partition (WKWebView)
extern "C" bool sessionRemoveCookie(const char* partitionIdentifier, const char* urlStr, const char* cookieName) {
    if (!urlStr || !cookieName) {
        return false;
    }

    NSString *partitionStr = partitionIdentifier ? [NSString stringWithUTF8String:partitionIdentifier] : @"";
    NSString *url = [NSString stringWithUTF8String:urlStr];
    NSString *name = [NSString stringWithUTF8String:cookieName];
    NSURL *nsUrl = [NSURL URLWithString:url];
    if (!nsUrl) {
        return false;
    }

    __block bool found = false;
    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            WKWebsiteDataStore *dataStore = createDataStoreForPartition([partitionStr UTF8String]);
            WKHTTPCookieStore *cookieStore = dataStore.httpCookieStore;

            [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
                for (NSHTTPCookie *cookie in cookies) {
                    if ([cookie.name isEqualToString:name]) {
                        // Check if domain matches
                        NSString *host = nsUrl.host;
                        NSString *cookieDomain = cookie.domain;
                        BOOL domainMatches = NO;
                        if ([cookieDomain hasPrefix:@"."]) {
                            domainMatches = [host hasSuffix:cookieDomain] || [host isEqualToString:[cookieDomain substringFromIndex:1]];
                        } else {
                            domainMatches = [host isEqualToString:cookieDomain];
                        }

                        if (domainMatches) {
                            [cookieStore deleteCookie:cookie completionHandler:^{
                                found = true;
                                dispatch_semaphore_signal(completionSemaphore);
                            }];
                            return;
                        }
                    }
                }
                dispatch_semaphore_signal(completionSemaphore);
            }];
        }
    });

    dispatch_semaphore_wait(completionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    return found;
}

// Remove all cookies for a partition (WKWebView)
extern "C" void sessionClearCookies(const char* partitionIdentifier) {
    NSString *partitionStr = partitionIdentifier ? [NSString stringWithUTF8String:partitionIdentifier] : @"";

    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            WKWebsiteDataStore *dataStore = createDataStoreForPartition([partitionStr UTF8String]);

            NSSet *dataTypes = [NSSet setWithObject:WKWebsiteDataTypeCookies];
            NSDate *dateFrom = [NSDate dateWithTimeIntervalSince1970:0];

            [dataStore removeDataOfTypes:dataTypes modifiedSince:dateFrom completionHandler:^{
                dispatch_semaphore_signal(completionSemaphore);
            }];
        }
    });

    dispatch_semaphore_wait(completionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
}

// Clear all storage data for a partition (WKWebView)
// storageTypesJson: ["cookies", "localStorage", "sessionStorage", "indexedDB", "cache"] or null for all
extern "C" void sessionClearStorageData(const char* partitionIdentifier, const char* storageTypesJson) {
    NSString *partitionStr = partitionIdentifier ? [NSString stringWithUTF8String:partitionIdentifier] : @"";
    NSString *typesStr = storageTypesJson ? [NSString stringWithUTF8String:storageTypesJson] : @"";

    dispatch_semaphore_t completionSemaphore = dispatch_semaphore_create(0);

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            WKWebsiteDataStore *dataStore = createDataStoreForPartition([partitionStr UTF8String]);

            NSMutableSet *dataTypes = [NSMutableSet set];

            if (typesStr.length > 0) {
                NSData *jsonData = [typesStr dataUsingEncoding:NSUTF8StringEncoding];
                NSArray *types = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];

                for (NSString *type in types) {
                    if ([type isEqualToString:@"cookies"]) {
                        [dataTypes addObject:WKWebsiteDataTypeCookies];
                    } else if ([type isEqualToString:@"localStorage"]) {
                        [dataTypes addObject:WKWebsiteDataTypeLocalStorage];
                    } else if ([type isEqualToString:@"sessionStorage"]) {
                        [dataTypes addObject:WKWebsiteDataTypeSessionStorage];
                    } else if ([type isEqualToString:@"indexedDB"]) {
                        [dataTypes addObject:WKWebsiteDataTypeIndexedDBDatabases];
                    } else if ([type isEqualToString:@"cache"]) {
                        [dataTypes addObject:WKWebsiteDataTypeDiskCache];
                        [dataTypes addObject:WKWebsiteDataTypeMemoryCache];
                    } else if ([type isEqualToString:@"serviceWorkers"]) {
                        [dataTypes addObject:WKWebsiteDataTypeServiceWorkerRegistrations];
                    }
                }
            } else {
                // Clear all
                dataTypes = [NSMutableSet setWithSet:[WKWebsiteDataStore allWebsiteDataTypes]];
            }

            if (dataTypes.count == 0) {
                dispatch_semaphore_signal(completionSemaphore);
                return;
            }

            NSDate *dateFrom = [NSDate dateWithTimeIntervalSince1970:0];

            [dataStore removeDataOfTypes:dataTypes modifiedSince:dateFrom completionHandler:^{
                dispatch_semaphore_signal(completionSemaphore);
            }];
        }
    });

    dispatch_semaphore_wait(completionSemaphore, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
}

// Window icon - Linux only, no-op for macOS (macOS uses app bundle icon)
extern "C" void setWindowIcon(void* window, const char* iconPath) {
    // Not supported on macOS - macOS windows use the app bundle icon
}

static BOOL electrobunWindowHidesTitleBar(NSWindow *window) {
    NSString *titleBarStyle = objc_getAssociatedObject(window, kTrafficLightTitleBarStyleKey);
    return [titleBarStyle isEqualToString:@"hidden"] ||
        [titleBarStyle isEqualToString:@"hiddenInset"];
}

static BOOL electrobunWindowHasNoTrafficLights(NSWindow *window) {
    NSWindowStyleMask styleMask = [window styleMask];
    BOOL hasClose = (styleMask & NSWindowStyleMaskClosable) != 0;
    BOOL hasMini = (styleMask & NSWindowStyleMaskMiniaturizable) != 0;
    BOOL hasZoom = (styleMask & NSWindowStyleMaskResizable) != 0;
    return !hasClose && !hasMini && !hasZoom;
}

extern "C" void setWindowVisibleOnAllWorkspaces(NSWindow *window, bool visible) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSWindowCollectionBehavior behavior = [window collectionBehavior];
        if (visible) {
            behavior |= NSWindowCollectionBehaviorCanJoinAllSpaces;
            behavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
            behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
            behavior &= ~NSWindowCollectionBehaviorFullScreenNone;
            behavior &= ~NSWindowCollectionBehaviorFullScreenDisallowsTiling;
        } else {
            behavior &= ~NSWindowCollectionBehaviorCanJoinAllSpaces;
            behavior &= ~NSWindowCollectionBehaviorFullScreenAuxiliary;

            if (electrobunWindowHidesTitleBar(window) && electrobunWindowHasNoTrafficLights(window)) {
                behavior &= ~NSWindowCollectionBehaviorFullScreenPrimary;
                behavior |= NSWindowCollectionBehaviorFullScreenNone;
                behavior |= NSWindowCollectionBehaviorFullScreenDisallowsTiling;
            } else {
                behavior &= ~NSWindowCollectionBehaviorFullScreenNone;
                behavior &= ~NSWindowCollectionBehaviorFullScreenDisallowsTiling;
                behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
            }
        }
        [window setCollectionBehavior:behavior];
    });
}

extern "C" bool isWindowVisibleOnAllWorkspaces(NSWindow *window) {
    __block bool result = false;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = ([window collectionBehavior] & NSWindowCollectionBehaviorCanJoinAllSpaces) != 0;
    });
    return result;
}

extern "C" void setWindowHiddenFromMissionControl(NSWindow *window, bool hidden) {
    dispatch_sync(dispatch_get_main_queue(), ^{
        if (!window) return;

        NSWindowCollectionBehavior behavior = [window collectionBehavior];
        if (hidden) {
            behavior |= NSWindowCollectionBehaviorTransient;
            behavior |= NSWindowCollectionBehaviorIgnoresCycle;
            behavior &= ~NSWindowCollectionBehaviorManaged;
            behavior &= ~NSWindowCollectionBehaviorParticipatesInCycle;
        } else {
            behavior &= ~NSWindowCollectionBehaviorTransient;
            behavior &= ~NSWindowCollectionBehaviorIgnoresCycle;
        }
        [window setCollectionBehavior:behavior];
    });
}

// ----------------------- Content Blocker -----------------------

static NSMutableArray<WKContentRuleList *> *g_compiledContentRuleLists = nil;
static NSMutableSet<NSString *> *g_compiledContentRuleListIdentifiers = nil;
static dispatch_queue_t g_contentBlockerQueue = dispatch_queue_create("electrobun.contentblocker", DISPATCH_QUEUE_SERIAL);
static WKContentRuleListStore *g_contentRuleListStore = nil;
static NSString *g_contentRuleListStorePath = nil;
static uint32_t g_contentBlockerRuleLoadCompletions = 0;
static uint32_t g_contentBlockerRuleLoadFailures = 0;

static WKContentRuleListStore *contentRuleListStore() {
    if (g_contentRuleListStore) {
        return g_contentRuleListStore;
    }

    if (g_contentRuleListStorePath && [g_contentRuleListStorePath length] > 0) {
        NSURL *storeURL = [NSURL fileURLWithPath:g_contentRuleListStorePath isDirectory:YES];
        g_contentRuleListStore = [WKContentRuleListStore storeWithURL:storeURL];
        return g_contentRuleListStore;
    }

    g_contentRuleListStore = WKContentRuleListStore.defaultStore;
    return g_contentRuleListStore;
}

static void recordContentBlockerRuleLoadCompletion(BOOL failed) {
    dispatch_sync(g_contentBlockerQueue, ^{
        g_contentBlockerRuleLoadCompletions += 1;
        if (failed) {
            g_contentBlockerRuleLoadFailures += 1;
        }
    });
}

extern "C" void setContentBlockerStorePath(const char* pathData) {
    if (!pathData || strlen(pathData) == 0) {
        return;
    }

    NSString *path = [NSString stringWithUTF8String:pathData];
    if (!path || [path length] == 0) {
        return;
    }

    void (^applyStorePath)(void) = ^{
        if ([path isEqualToString:g_contentRuleListStorePath]) {
            return;
        }

        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        if (error) {
            NSLog(@"[ContentBlocker] Failed to create rule-list store %@: %@", path, error.localizedDescription);
            return;
        }

        g_contentRuleListStorePath = [path copy];
        g_contentRuleListStore = nil;
        NSLog(@"[ContentBlocker] Using shared rule-list store %@", path);
    };

    if ([NSThread isMainThread]) {
        applyStorePath();
    } else {
        dispatch_sync(dispatch_get_main_queue(), applyStorePath);
    }
}

static NSString *contentBlockerHashForString(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return hex;
}

static BOOL addCompiledRuleList(NSString *identifier, WKContentRuleList *list) {
    __block BOOL added = NO;
    dispatch_sync(g_contentBlockerQueue, ^{
        if (!g_compiledContentRuleLists) {
            g_compiledContentRuleLists = [NSMutableArray new];
        }
        if (!g_compiledContentRuleListIdentifiers) {
            g_compiledContentRuleListIdentifiers = [NSMutableSet new];
        }
        if ([g_compiledContentRuleListIdentifiers containsObject:identifier]) {
            return;
        }
        [g_compiledContentRuleListIdentifiers addObject:identifier];
        [g_compiledContentRuleLists addObject:list];
        electrobun::ContentBlockerRuleStore::instance().setReady(true);
        added = YES;
    });
    return added;
}

static void pushRuleListToActiveWebviews(WKContentRuleList *list) {
    if (!globalAbstractViews) return;
    for (NSNumber *key in globalAbstractViews) {
        AbstractView *view = globalAbstractViews[key];
        if (!view.contentBlockerEnabled) continue;
        if (![view respondsToSelector:@selector(webView)]) continue;
        WKWebView *webView = [(id)view webView];
        if (!webView) continue;
        [webView.configuration.userContentController addContentRuleList:list];
        NSLog(@"[ContentBlocker] Pushed rule list to webview %u", view.webviewId);
    }
}

extern "C" uint32_t getContentBlockerCompiledCount() {
    __block uint32_t count = 0;
    dispatch_sync(g_contentBlockerQueue, ^{
        count = g_compiledContentRuleLists ? (uint32_t)g_compiledContentRuleLists.count : 0;
    });
    return count;
}

extern "C" uint32_t getContentBlockerLoadCompletionCount() {
    __block uint32_t count = 0;
    dispatch_sync(g_contentBlockerQueue, ^{
        count = g_contentBlockerRuleLoadCompletions;
    });
    return count;
}

extern "C" uint32_t getContentBlockerLoadFailureCount() {
    __block uint32_t count = 0;
    dispatch_sync(g_contentBlockerQueue, ^{
        count = g_contentBlockerRuleLoadFailures;
    });
    return count;
}

extern "C" void loadContentBlockerRuleList(const char* identifierData) {
    if (!identifierData || strlen(identifierData) == 0) {
        NSLog(@"[ContentBlocker] loadRuleList called with empty identifier, skipping");
        return;
    }

    NSString *identifier = [NSString stringWithUTF8String:identifierData];
    if (!identifier || identifier.length == 0) {
        NSLog(@"[ContentBlocker] Failed to create NSString from rule list identifier");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [contentRuleListStore()
            lookUpContentRuleListForIdentifier:identifier
                            completionHandler:^(WKContentRuleList *cachedList, NSError *lookupError) {
            if (!cachedList) {
                NSLog(@"[ContentBlocker] Cache MISS for %@", identifier);
                recordContentBlockerRuleLoadCompletion(YES);
                return;
            }

            NSLog(@"[ContentBlocker] Cache HIT for %@", identifier);
            BOOL added = addCompiledRuleList(identifier, cachedList);
            if (added) {
                pushRuleListToActiveWebviews(cachedList);
            }
            recordContentBlockerRuleLoadCompletion(NO);
        }];
    });
}

extern "C" void loadContentBlockerRules(const char* jsonData, uint32_t jsonLen) {
    if (!jsonData || jsonLen == 0) {
        NSLog(@"[ContentBlocker] loadRules called with empty data, skipping");
        return;
    }

    NSString *json = [[NSString alloc] initWithBytes:jsonData length:jsonLen encoding:NSUTF8StringEncoding];
    if (!json) {
        NSLog(@"[ContentBlocker] Failed to create NSString from JSON data (%u bytes)", jsonLen);
        return;
    }

    // Append ignore-previous-rules for document types to prevent blocking main page navigation.
    NSString *trimmed = [json stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasSuffix:@"]"]) {
        json = [NSString stringWithFormat:@"%@,{\"trigger\":{\"url-filter\":\".*\",\"resource-type\":[\"document\",\"top-document\"]},\"action\":{\"type\":\"ignore-previous-rules\"}}]",
                [trimmed substringToIndex:trimmed.length - 1]];
    }

    static NSUInteger chunkIndex = 0;
    NSUInteger thisChunk = chunkIndex++;
    NSString *identifier = [NSString stringWithFormat:@"electrobun_cb_v3_%@", contentBlockerHashForString(json)];

    NSLog(@"[ContentBlocker] Loading chunk %lu (%u bytes)...", (unsigned long)thisChunk, jsonLen);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Try cache first — lookUp returns a previously compiled list instantly
        [contentRuleListStore()
            lookUpContentRuleListForIdentifier:identifier
                            completionHandler:^(WKContentRuleList *cachedList, NSError *lookupError) {
            if (cachedList) {
                NSLog(@"[ContentBlocker] Cache HIT for chunk %lu", (unsigned long)thisChunk);
                BOOL added = addCompiledRuleList(identifier, cachedList);
                __block uint32_t total = 0;
                dispatch_sync(g_contentBlockerQueue, ^{
                    total = (uint32_t)g_compiledContentRuleLists.count;
                });
                NSLog(@"[ContentBlocker] Loaded chunk %lu from cache (%u total)", (unsigned long)thisChunk, total);
                if (added) {
                    pushRuleListToActiveWebviews(cachedList);
                }
                recordContentBlockerRuleLoadCompletion(NO);
                return;
            }

            // Cache miss — compile from JSON
            NSLog(@"[ContentBlocker] Cache miss for chunk %lu, compiling...", (unsigned long)thisChunk);
            [contentRuleListStore()
                compileContentRuleListForIdentifier:identifier
                             encodedContentRuleList:json
                                  completionHandler:^(WKContentRuleList *list, NSError *error) {
                if (error) {
                    NSLog(@"[ContentBlocker] FAILED chunk %lu '%@': %@ (code %ld)",
                          (unsigned long)thisChunk, identifier, error.localizedDescription, (long)error.code);
                    recordContentBlockerRuleLoadCompletion(YES);
                    return;
                }
                BOOL added = addCompiledRuleList(identifier, list);
                __block uint32_t total = 0;
                dispatch_sync(g_contentBlockerQueue, ^{
                    total = (uint32_t)g_compiledContentRuleLists.count;
                });
                NSLog(@"[ContentBlocker] Compiled chunk %lu (%u total)", (unsigned long)thisChunk, total);
                if (added) {
                    pushRuleListToActiveWebviews(list);
                }
                recordContentBlockerRuleLoadCompletion(NO);
            }];
        }];
    });
}

extern "C" void setContentBlockerEnabled(AbstractView *abstractView, bool enabled) {
    if (!abstractView) {
        NSLog(@"[ContentBlocker] setEnabled called with null abstractView");
        return;
    }

    uint32_t webviewId = abstractView.webviewId;
    NSLog(@"[ContentBlocker] setEnabled(%s) for webview %u", enabled ? "true" : "false", webviewId);

    dispatch_async(dispatch_get_main_queue(), ^{
        abstractView.contentBlockerEnabled = enabled;

        if (![abstractView respondsToSelector:@selector(webView)]) {
            NSLog(@"[ContentBlocker] webview %u has no WKWebView (CEF?), skipping", webviewId);
            return;
        }
        WKWebView *webView = [(id)abstractView webView];
        if (!webView) {
            NSLog(@"[ContentBlocker] webview %u WKWebView is nil, skipping", webviewId);
            return;
        }

        WKUserContentController *ucc = webView.configuration.userContentController;

        if (enabled) {
            __block NSArray<WKContentRuleList *> *lists = nil;
            dispatch_sync(g_contentBlockerQueue, ^{
                lists = [g_compiledContentRuleLists copy];
            });
            for (WKContentRuleList *list in lists) {
                [ucc addContentRuleList:list];
            }
            NSLog(@"[ContentBlocker] Enabled for webview %u with %lu rule lists",
                  webviewId, (unsigned long)lists.count);
        } else {
            [ucc removeAllContentRuleLists];
            NSLog(@"[ContentBlocker] Disabled for webview %u", webviewId);
        }
    });
}

// ----------------------- System Appearance -----------------------

extern "C" const char* getSystemAppearance() {
    NSString *style = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleInterfaceStyle"];
    if (style && [style caseInsensitiveCompare:@"Dark"] == NSOrderedSame) {
        return strdup("dark");
    }
    return strdup("light");
}

typedef void (*ThemeChangedCallback)(const char* theme);
static ThemeChangedCallback g_themeChangedCallback = nullptr;
static id g_themeObserver = nil;

extern "C" void setThemeChangedCallback(ThemeChangedCallback callback) {
    g_themeChangedCallback = callback;

    if (g_themeObserver) {
        [[NSDistributedNotificationCenter defaultCenter] removeObserver:g_themeObserver];
        g_themeObserver = nil;
    }

    if (callback) {
        g_themeObserver = [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"AppleInterfaceThemeChangedNotification"
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification * _Nonnull note) {
                NSString *style = [[NSUserDefaults standardUserDefaults]
                    stringForKey:@"AppleInterfaceStyle"];
                const char *theme = (style && [style caseInsensitiveCompare:@"Dark"] == NSOrderedSame)
                    ? "dark" : "light";
                if (g_themeChangedCallback) {
                    g_themeChangedCallback(theme);
                }
            }];
    }
}

// ----------------------- Activate App by Bundle ID -----------------------

extern "C" void activateAppByBundleId(const char* bundleId) {
    if (!bundleId) return;
    NSString *bid = [NSString stringWithUTF8String:bundleId];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bid];
        [apps.firstObject activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    });
}
