import { existsSync } from "fs";
import { dirname, join, resolve } from "path";
import electrobunEventEmitter from "../events/eventEmitter";
import ElectrobunEvent from "../events/event";
import type {
	BrowserDownloadEventDetail,
	BrowserPermissionPlatform,
	BrowserPermissionRequestDetail,
	BrowserPermissionType
} from "../events/webviewEvents";
import { BrowserView } from "../core/BrowserView";
import { WGPUView } from "../core/WGPUView";
import { Tray } from "../core/Tray";
import { preloadScript, preloadScriptSandboxed } from "../preload/.generated/compiled";

// Menu data reference system to avoid serialization overhead
const menuDataRegistry = new Map<string, any>();
let menuDataCounter = 0;

function storeMenuData(data: any): string {
	const id = `menuData_${++menuDataCounter}`;
	menuDataRegistry.set(id, data);
	return id;
}

function getMenuData(id: string): any {
	return menuDataRegistry.get(id);
}

function clearMenuData(id: string): void {
	menuDataRegistry.delete(id);
}

// Shared methods for EB delimiter serialization/deserialization
const ELECTROBUN_DELIMITER = "|EB|";

function serializeMenuAction(action: string, data: any): string {
	const dataId = storeMenuData(data);
	return `${ELECTROBUN_DELIMITER}${dataId}|${action}`;
}

function deserializeMenuAction(encodedAction: string): {
	action: string;
	data: any;
} {
	let actualAction = encodedAction;
	let data = undefined;

	if (encodedAction.startsWith(ELECTROBUN_DELIMITER)) {
		const parts = encodedAction.split("|");
		if (parts.length >= 4) {
			// ['', 'EB', 'dataId', 'actualAction', ...]
			const dataId = parts[2]!;
			actualAction = parts.slice(3).join("|"); // Rejoin in case action contains |
			data = getMenuData(dataId);

			// Clean up data from registry after use
			clearMenuData(dataId);
		}
	}

	return { action: actualAction, data };
}

// todo: set up FFI, this is already in the webworker.

import {
	dlopen,
	suffix,
	JSCallback,
	CString,
	ptr,
	FFIType,
	toArrayBuffer,
	type Pointer
} from "bun:ffi";
import { BrowserWindow } from "../core/BrowserWindow";
import { GpuWindow } from "../core/GpuWindow";

function getWindowPtr(winId: number) {
	return BrowserWindow.getById(winId)?.ptr ?? GpuWindow.getById(winId)?.ptr ?? null;
}

type WindowStyleMaskOptions = {
	Borderless: boolean;
	Titled: boolean;
	Closable: boolean;
	Miniaturizable: boolean;
	Resizable: boolean;
	UnifiedTitleAndToolbar: boolean;
	FullScreen: boolean;
	FullSizeContentView: boolean;
	UtilityWindow: boolean;
	DocModalWindow: boolean;
	NonactivatingPanel: boolean;
	HUDWindow: boolean;
};

function getMacWindowStyleMask(options: WindowStyleMaskOptions): number {
	let mask = 0;
	if (options.Titled) mask |= 1;
	if (options.Closable) mask |= 2;
	if (options.Miniaturizable) mask |= 4;
	if (options.Resizable) mask |= 8;
	if (options.UtilityWindow) mask |= 16;
	if (options.DocModalWindow) mask |= 64;
	if (options.NonactivatingPanel) mask |= 128;
	if (options.UnifiedTitleAndToolbar) mask |= 4096;
	if (options.HUDWindow) mask |= 8192;
	if (options.FullScreen) mask |= 16384;
	if (options.FullSizeContentView) mask |= 32768;
	return mask;
}

function uniqueNativeWrapperCandidates(name: string): string[] {
	const cwd = process.cwd();
	const execDir = dirname(process.execPath);
	const candidates = [
		join(cwd, name),
		join(cwd, "bin", name),
		join(execDir, name),
		join(execDir, "..", name),
		join(execDir, "..", "bin", name)
	];
	const seen = new Set<string>();
	return candidates
		.map((candidate) => resolve(candidate))
		.filter((candidate) => {
			if (seen.has(candidate)) return false;
			seen.add(candidate);
			return true;
		});
}

function getNativeWrapperPath(name: string): string {
	const candidates = uniqueNativeWrapperCandidates(name);
	return candidates.find((candidate) => existsSync(candidate)) ?? candidates[0]!;
}

export const native = (() => {
	try {
		const nativeWrapperName = `libNativeWrapper.${suffix}`;
		const nativeWrapperPath = getNativeWrapperPath(nativeWrapperName);
		return dlopen(nativeWrapperPath, {
			// window
			createWindowWithFrameAndStyleFromWorker: {
				args: [
					FFIType.u32, // windowId
					FFIType.f64,
					FFIType.f64, // x, y
					FFIType.f64,
					FFIType.f64, // width, height
					FFIType.u32, // styleMask
					FFIType.cstring, // titleBarStyle
					FFIType.bool, // transparent
					FFIType.bool, // toolbar
					FFIType.f64, // trafficLightOffsetX
					FFIType.f64, // trafficLightOffsetY
					FFIType.f64, // cornerRadius
					FFIType.function, // closeHandler
					FFIType.function, // moveHandler
					FFIType.function, // resizeHandler
					FFIType.function, // focusHandler
					FFIType.function, // blurHandler
					FFIType.function // keyHandler
				],
				returns: FFIType.ptr
			},
			setWindowTitle: {
				args: [
					FFIType.ptr, // window ptr
					FFIType.cstring // title
				],
				returns: FFIType.void
			},
			showWindow: {
				args: [
					FFIType.ptr, // window ptr
					FFIType.bool // activate
				],
				returns: FFIType.void
			},
			activateWindow: {
				args: [
					FFIType.ptr // window ptr
				],
				returns: FFIType.void
			},
			hideWindow: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			setWindowCloaked: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			closeWindow: {
				args: [
					FFIType.ptr // window ptr
				],
				returns: FFIType.void
			},
			minimizeWindow: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			restoreWindow: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			isWindowMinimized: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			maximizeWindow: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			unmaximizeWindow: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			isWindowMaximized: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			setWindowFullScreen: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			isWindowFullScreen: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			setWindowAlwaysOnTop: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			isWindowAlwaysOnTop: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			setWindowVisibleOnAllWorkspaces: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			isWindowVisibleOnAllWorkspaces: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			setWindowHiddenFromMissionControl: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			setWindowPosition: {
				args: [FFIType.ptr, FFIType.f64, FFIType.f64],
				returns: FFIType.void
			},
			setWindowButtonPosition: {
				args: [FFIType.ptr, FFIType.f64, FFIType.f64],
				returns: FFIType.void
			},
			setWindowSize: {
				args: [FFIType.ptr, FFIType.f64, FFIType.f64],
				returns: FFIType.void
			},
			setWindowFrame: {
				args: [FFIType.ptr, FFIType.f64, FFIType.f64, FFIType.f64, FFIType.f64],
				returns: FFIType.void
			},
			getWindowFrame: {
				args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr],
				returns: FFIType.void
			},
			// webview
			initWebview: {
				args: [
					FFIType.u32, // webviewId
					FFIType.ptr, // windowPtr
					FFIType.cstring, // renderer
					FFIType.cstring, // url
					FFIType.f64,
					FFIType.f64, // x, y
					FFIType.f64,
					FFIType.f64, // width, height
					FFIType.bool, // autoResize
					FFIType.cstring, // partition
					FFIType.function, // decideNavigation: *const fn (u32, [*:0]const u8) callconv(.C) bool,
					FFIType.function, // webviewEventHandler: *const fn (u32, [*:0]const u8, [*:0]const u8) callconv(.C) u32,
					FFIType.function, // eventBridgeHandler: *const fn (u32, [*:0]const u8) callconv(.C) void (events only, always active)
					FFIType.function, // bunBridgePostmessageHandler: *const fn (u32, [*:0]const u8) callconv(.C) void (user RPC, disabled in sandbox)
					FFIType.function, // internalBridgeHandler: *const fn (u32, [*:0]const u8) callconv(.C) void (internal RPC, disabled in sandbox)
					FFIType.cstring, // electrobunPreloadScript
					FFIType.cstring, // customPreloadScript
					FFIType.cstring, // viewsRoot
					FFIType.bool, // transparent
					FFIType.bool // sandbox - when true, bunBridge and internalBridge are not set up
				],
				returns: FFIType.ptr
			},
			initWGPUView: {
				args: [
					FFIType.u32, // viewId
					FFIType.ptr, // windowPtr
					FFIType.f64,
					FFIType.f64, // x, y
					FFIType.f64,
					FFIType.f64, // width, height
					FFIType.bool, // autoResize
					FFIType.bool, // startTransparent
					FFIType.bool // startPassthrough
				],
				returns: FFIType.ptr
			},
			// Pre-set flags for the next initWebview call (workaround for FFI param count limits)
			setNextWebviewFlags: {
				args: [
					FFIType.bool, // startTransparent
					FFIType.bool // startPassthrough
				],
				returns: FFIType.void
			},

			// webviewtag
			webviewCanGoBack: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},

			webviewCanGoForward: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			// Note: callAsyncJavaScript not implemented - CEF doesn't support this directly.
			// Users can use RPC for JavaScript execution.
			resizeWebview: {
				args: [
					FFIType.ptr, // webview handle
					FFIType.f64, // x
					FFIType.f64, // y
					FFIType.f64, // width
					FFIType.f64, // height
					FFIType.cstring // maskJson
				],
				returns: FFIType.void
			},

			loadURLInWebView: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},
			loadHTMLInWebView: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},

			updatePreloadScriptToWebView: {
				args: [
					FFIType.ptr, // webview handle
					FFIType.cstring, // script identifier
					FFIType.cstring, // script
					FFIType.bool // allframes
				],
				returns: FFIType.void
			},
			webviewGoBack: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewGoForward: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewReload: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewCancelDownload: {
				args: [FFIType.ptr, FFIType.u32],
				returns: FFIType.bool
			},
			webviewRemove: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			setWebviewHTMLContent: {
				args: [FFIType.u32, FFIType.cstring],
				returns: FFIType.void
			},
			startWindowMove: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			stopWindowMove: {
				args: [],
				returns: FFIType.void
			},
			webviewSetTransparent: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			webviewSetPassthrough: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			webviewSetHidden: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			setWebviewNavigationRules: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},
			setWebviewUserAgent: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},
			setAcceptLanguage: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			setAppAppearance: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			webviewFindInPage: {
				args: [FFIType.ptr, FFIType.cstring, FFIType.bool, FFIType.bool],
				returns: FFIType.void
			},
			webviewStopFind: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewShowFindBar: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewHideFindBar: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			evaluateJavaScriptWithNoCompletion: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},
			evaluateJavascriptSync: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.cstring
			},
			webviewPrint: {
				args: [FFIType.ptr],
				returns: FFIType.bool
			},
			webviewSavePageAs: {
				args: [FFIType.ptr, FFIType.cstring, FFIType.cstring],
				returns: FFIType.bool
			},
			webviewOpenDevTools: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewCloseDevTools: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewToggleDevTools: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			webviewSetPageZoom: {
				args: [FFIType.ptr, FFIType.f64],
				returns: FFIType.void
			},
			webviewGetPageZoom: {
				args: [FFIType.ptr],
				returns: FFIType.f64
			},
			webviewRespondToPermissionRequest: {
				args: [FFIType.cstring, FFIType.cstring],
				returns: FFIType.void
			},
			...(process.platform === "darwin"
				? {
						showNativePermissionSheet: {
							args: [
								FFIType.ptr,
								FFIType.cstring,
								FFIType.cstring,
								FFIType.cstring,
								FFIType.cstring
							],
							returns: FFIType.void
						}
					}
				: {}),
			wgpuViewSetFrame: {
				args: [FFIType.ptr, FFIType.f64, FFIType.f64, FFIType.f64, FFIType.f64],
				returns: FFIType.void
			},
			wgpuViewSetTransparent: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			wgpuViewSetPassthrough: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			wgpuViewSetHidden: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			wgpuViewRemove: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			wgpuViewGetNativeHandle: {
				args: [FFIType.ptr],
				returns: FFIType.ptr
			},
			wgpuInstanceCreateSurfaceMainThread: {
				args: [FFIType.ptr, FFIType.ptr],
				returns: FFIType.ptr
			},
			wgpuSurfaceConfigureMainThread: {
				args: [FFIType.ptr, FFIType.ptr],
				returns: FFIType.void
			},
			wgpuSurfaceGetCurrentTextureMainThread: {
				args: [FFIType.ptr, FFIType.ptr],
				returns: FFIType.void
			},
			wgpuSurfacePresentMainThread: {
				args: [FFIType.ptr],
				returns: FFIType.i32
			},
			wgpuQueueOnSubmittedWorkDoneShim: {
				args: [FFIType.ptr, FFIType.ptr],
				returns: FFIType.u64
			},
			wgpuBufferMapAsyncShim: {
				args: [FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u64, FFIType.ptr],
				returns: FFIType.u64
			},
			wgpuInstanceWaitAnyShim: {
				args: [FFIType.ptr, FFIType.u64, FFIType.u64],
				returns: FFIType.i32
			},
			wgpuBufferReadSyncShim: {
				args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u64, FFIType.ptr],
				returns: FFIType.ptr
			},
			wgpuBufferReadSyncIntoShim: {
				args: [FFIType.ptr, FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.u64, FFIType.ptr],
				returns: FFIType.i32
			},
			wgpuBufferReadbackBeginShim: {
				args: [FFIType.ptr, FFIType.u64, FFIType.u64, FFIType.ptr],
				returns: FFIType.ptr
			},
			wgpuBufferReadbackStatusShim: {
				args: [FFIType.ptr],
				returns: FFIType.i32
			},
			wgpuBufferReadbackFreeShim: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			wgpuRunGPUTest: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			wgpuCreateAdapterDeviceMainThread: {
				args: [FFIType.ptr, FFIType.ptr, FFIType.ptr],
				returns: FFIType.void
			},
			wgpuCreateSurfaceForView: {
				args: [FFIType.ptr, FFIType.ptr],
				returns: FFIType.ptr
			},
			// Tray
			createTray: {
				args: [
					FFIType.u32, // id
					FFIType.cstring, // title
					FFIType.cstring, // pathToImage
					FFIType.bool, // isTemplate
					FFIType.u32, // width
					FFIType.u32, //height
					FFIType.function // trayItemHandler
				],
				returns: FFIType.ptr
			},
			setTrayTitle: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},
			setTrayImage: {
				args: [
					FFIType.ptr, // statusItem
					FFIType.cstring, // pathToImage
					FFIType.bool, // isTemplate
					FFIType.u32, // width
					FFIType.u32 // height
				],
				returns: FFIType.void
			},
			setTrayMenu: {
				args: [FFIType.ptr, FFIType.cstring],
				returns: FFIType.void
			},
			removeTray: {
				args: [FFIType.ptr],
				returns: FFIType.void
			},
			getTrayBounds: {
				args: [FFIType.ptr],
				returns: FFIType.cstring
			},
			setApplicationMenu: {
				args: [FFIType.cstring, FFIType.function],
				returns: FFIType.void
			},
			showContextMenu: {
				args: [FFIType.cstring, FFIType.function],
				returns: FFIType.void
			},
			moveToTrash: {
				args: [FFIType.cstring],
				returns: FFIType.bool
			},
			showItemInFolder: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			...(process.platform === "darwin"
				? {
						removeImageBackground: {
							args: [FFIType.cstring, FFIType.cstring],
							returns: FFIType.bool
						},
						shareFile: {
							args: [FFIType.cstring],
							returns: FFIType.void
						}
					}
				: {}),
			openExternal: {
				args: [FFIType.cstring],
				returns: FFIType.bool
			},
			openPath: {
				args: [FFIType.cstring],
				returns: FFIType.bool
			},
			showNotification: {
				args: [
					FFIType.cstring, // title
					FFIType.cstring, // body
					FFIType.cstring, // subtitle
					FFIType.bool // silent
				],
				returns: FFIType.void
			},

			// Global keyboard shortcuts
			setGlobalShortcutCallback: {
				args: [FFIType.function],
				returns: FFIType.void
			},
			registerGlobalShortcut: {
				args: [FFIType.cstring],
				returns: FFIType.int
			},
			unregisterGlobalShortcut: {
				args: [FFIType.cstring],
				returns: FFIType.bool
			},
			unregisterAllGlobalShortcuts: {
				args: [],
				returns: FFIType.void
			},
			isGlobalShortcutRegistered: {
				args: [FFIType.cstring],
				returns: FFIType.bool
			},

			// System appearance
			getSystemAppearance: {
				args: [],
				returns: FFIType.cstring
			},
			setThemeChangedCallback: {
				args: [FFIType.function],
				returns: FFIType.void
			},

			// App activation
			activateAppByBundleId: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			activateWindowById: {
				args: [FFIType.u32],
				returns: FFIType.bool
			},

			// Screen API
			getAllDisplays: {
				args: [],
				returns: FFIType.cstring
			},
			getPrimaryDisplay: {
				args: [],
				returns: FFIType.cstring
			},
			getCursorScreenPoint: {
				args: [],
				returns: FFIType.cstring
			},
			getMouseButtons: {
				args: [],
				returns: FFIType.u64
			},

			openFileDialog: {
				args: [FFIType.cstring, FFIType.cstring, FFIType.int, FFIType.int, FFIType.int],
				returns: FFIType.cstring
			},
			showMessageBox: {
				args: [
					FFIType.cstring, // type
					FFIType.cstring, // title
					FFIType.cstring, // message
					FFIType.cstring, // detail
					FFIType.cstring, // buttons (comma-separated)
					FFIType.int, // defaultId
					FFIType.int // cancelId
				],
				returns: FFIType.int
			},

			// Clipboard API
			clipboardReadText: {
				args: [],
				returns: FFIType.cstring
			},
			clipboardWriteText: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			clipboardGetChangeCount: {
				args: [],
				returns: FFIType.i64
			},
			clipboardReadImage: {
				args: [FFIType.ptr], // pointer to size_t for output size
				returns: FFIType.ptr // pointer to PNG data
			},
			clipboardWriteImage: {
				args: [FFIType.ptr, FFIType.u64], // PNG data pointer, size
				returns: FFIType.void
			},
			clipboardReadFilePaths: {
				args: [],
				returns: FFIType.cstring
			},
			clipboardWriteFilePaths: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			clipboardClear: {
				args: [],
				returns: FFIType.void
			},
			simulatePaste: {
				args: [],
				returns: FFIType.void
			},
			clipboardAvailableFormats: {
				args: [],
				returns: FFIType.cstring
			},
			hasScreenRecordingPermission: {
				args: [],
				returns: FFIType.bool
			},
			requestScreenRecordingPermission: {
				args: [],
				returns: FFIType.bool
			},
			macPermissionStatus: {
				args: [FFIType.cstring],
				returns: FFIType.bool
			},
			requestMacPermissionDragGuide: {
				args: [FFIType.cstring, FFIType.cstring, FFIType.bool],
				returns: FFIType.int
			},
			...(process.platform === "darwin"
				? {
						requestMacMediaPermission: {
							args: [FFIType.cstring],
							returns: FFIType.int
						},
						getCurrentLocationJson: {
							args: [FFIType.f64],
							returns: FFIType.cstring
						}
					}
				: {}),
			closeMacPermissionDragGuide: {
				args: [],
				returns: FFIType.void
			},
			captureScreenExcludingWindow: {
				args: [FFIType.ptr, FFIType.ptr], // window ptr, size_t* outSize
				returns: FFIType.ptr // pointer to PNG data
			},
			getOnScreenWindowList: {
				args: [],
				returns: FFIType.cstring
			},
			getRunningApplications: {
				args: [],
				returns: FFIType.cstring
			},
			captureWindowById: {
				args: [FFIType.u32, FFIType.ptr], // CGWindowID, size_t* outSize
				returns: FFIType.ptr // pointer to PNG data
			},
			getFrontmostAppInfo: {
				args: [],
				returns: FFIType.cstring
			},
			getFrontmostWindowInfo: {
				args: [],
				returns: FFIType.cstring
			},
			getFrontmostWindowBounds: {
				args: [],
				returns: FFIType.cstring
			},
			setFrontmostWindowBounds: {
				args: [FFIType.i32, FFIType.i32, FFIType.i32, FFIType.i32],
				returns: FFIType.cstring
			},
			getAppIconToPath: {
				args: [FFIType.cstring, FFIType.cstring, FFIType.i32],
				returns: FFIType.bool
			},

			// Session/Cookie API
			sessionGetCookies: {
				args: [FFIType.cstring, FFIType.cstring],
				returns: FFIType.cstring
			},
			sessionSetCookie: {
				args: [FFIType.cstring, FFIType.cstring],
				returns: FFIType.bool
			},
			sessionRemoveCookie: {
				args: [FFIType.cstring, FFIType.cstring, FFIType.cstring],
				returns: FFIType.bool
			},
			sessionClearCookies: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			sessionClearStorageData: {
				args: [FFIType.cstring, FFIType.cstring],
				returns: FFIType.void
			},

			// URL scheme handler (macOS only)
			setURLOpenHandler: {
				args: [FFIType.function], // handler callback
				returns: FFIType.void
			},
			setAppReopenHandler: {
				args: [FFIType.function],
				returns: FFIType.void
			},
			setDockIcon: {
				args: [FFIType.cstring],
				returns: FFIType.void
			},
			setDockIconVisible: {
				args: [FFIType.bool],
				returns: FFIType.void
			},
			isDockIconVisible: {
				args: [],
				returns: FFIType.bool
			},

			// Window style utilities
			getWindowStyle: {
				args: [
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool,
					FFIType.bool
				],
				returns: FFIType.u32
			},
			// JSCallback utils for native code to use
			setJSUtils: {
				args: [
					FFIType.function, // get Mimetype from url/filename
					FFIType.function // get html property from webview
				],
				returns: FFIType.void
			},
			setWindowIcon: {
				args: [
					FFIType.ptr, // window pointer
					FFIType.cstring // icon path
				],
				returns: FFIType.void
			},
			killApp: {
				args: [],
				returns: FFIType.void
			},
			stopEventLoop: {
				args: [],
				returns: FFIType.void
			},
			waitForShutdownComplete: {
				args: [FFIType.i32],
				returns: FFIType.void
			},
			forceExit: {
				args: [FFIType.i32],
				returns: FFIType.void
			},
			setQuitRequestedHandler: {
				args: [FFIType.function],
				returns: FFIType.void
			},
			testFFI2: {
				args: [FFIType.function],
				returns: FFIType.void
			}
			// FFIFn: {
			//   args: [],
			//   returns: FFIType.void
			// },
		});
	} catch (err) {
		const nativeWrapperName = `libNativeWrapper.${suffix}`;
		console.error("[native] failed to load native wrapper:", {
			error: err,
			candidates: uniqueNativeWrapperCandidates(nativeWrapperName),
			cwd: process.cwd(),
			execPath: process.execPath
		});
		// FFI not available — running as a carrot inside Bunny Ears or in a build-only context.
		return null;
	}
})();

// Probe whether the native library exports content blocker symbols before
// creating FFI wrappers. Bun's dlopen uses lazy binding on macOS — it succeeds
// even for missing symbols, but calling them triggers SIGTRAP. We use the C
// library's dlopen(RTLD_NOW) + dlsym to verify symbols exist first.
const contentBlockerNative = (() => {
	if (process.platform === "win32") return null;
	try {
		const libcName = process.platform === "darwin" ? "libSystem.B.dylib" : "libc.so.6";
		const libc = dlopen(libcName, {
			dlopen: { args: [FFIType.cstring, FFIType.i32], returns: FFIType.ptr },
			dlsym: { args: [FFIType.ptr, FFIType.cstring], returns: FFIType.ptr }
		});

		const nativeWrapperPath = join(process.cwd(), `libNativeWrapper.${suffix}`);
		const handle = libc.symbols.dlopen(toCString(nativeWrapperPath), 0x2); // RTLD_NOW
		if (!handle) {
			console.log("[ContentBlocker] Could not open native library for symbol probe");
			libc.close();
			return null;
		}

		const sym = libc.symbols.dlsym(handle, toCString("loadContentBlockerRules"));
		const ruleListSym = libc.symbols.dlsym(handle, toCString("loadContentBlockerRuleList"));
		const storePathSym = libc.symbols.dlsym(handle, toCString("setContentBlockerStorePath"));
		const completionCountSym = libc.symbols.dlsym(
			handle,
			toCString("getContentBlockerLoadCompletionCount")
		);
		const failureCountSym = libc.symbols.dlsym(
			handle,
			toCString("getContentBlockerLoadFailureCount")
		);
		libc.close();

		if (!sym) {
			console.log(
				"[ContentBlocker] Native content blocker symbols not found — disabled until native rebuild"
			);
			return null;
		}

		const symbols = {
			loadContentBlockerRules: {
				args: [FFIType.cstring, FFIType.u32],
				returns: FFIType.void
			},
			...(ruleListSym
				? {
						loadContentBlockerRuleList: {
							args: [FFIType.cstring],
							returns: FFIType.void
						}
					}
				: {}),
			...(storePathSym
				? {
						setContentBlockerStorePath: {
							args: [FFIType.cstring],
							returns: FFIType.void
						}
					}
				: {}),
			setContentBlockerEnabled: {
				args: [FFIType.ptr, FFIType.bool],
				returns: FFIType.void
			},
			getContentBlockerCompiledCount: {
				args: [],
				returns: FFIType.u32
			},
			...(completionCountSym
				? {
						getContentBlockerLoadCompletionCount: {
							args: [],
							returns: FFIType.u32
						}
					}
				: {}),
			...(failureCountSym
				? {
						getContentBlockerLoadFailureCount: {
							args: [],
							returns: FFIType.u32
						}
					}
				: {})
		};
		const lib = dlopen(nativeWrapperPath, symbols);
		console.log("[ContentBlocker] Native content blocker symbols available");
		return {
			lib,
			canLoadRuleListByIdentifier: !!ruleListSym,
			canSetStorePath: !!storePathSym,
			canReadLoadStats: !!completionCountSym && !!failureCountSym
		};
	} catch (e) {
		console.log("[ContentBlocker] Native symbols not available:", e);
		return null;
	}
})();

export const hasFFI = native !== null;

// PostMessage bridge for carrot workers (inter-carrot communication, host events).
// Created when __bunnyCarrotBootstrap exists, regardless of FFI availability.
class PostMessageBridge {
	private requestId = 0;
	private pendingRequests = new Map<
		number,
		{
			resolve: (value: unknown) => void;
			reject: (error: Error) => void;
		}
	>();
	private eventHandlers = new Map<string, Set<(payload: unknown) => void>>();

	constructor() {
		if (typeof self !== "undefined" && typeof self.addEventListener === "function") {
			self.addEventListener("message", (event: MessageEvent) => {
				this.handleMessage(event.data);
			});
		}
	}

	sendAction(action: string, payload?: unknown) {
		self.postMessage({ type: "action", action, payload });
	}

	requestHost<T = unknown>(method: string, params?: unknown): Promise<T> {
		const id = ++this.requestId;
		self.postMessage({ type: "host-request", requestId: id, method, params });
		return new Promise<T>((resolve, reject) => {
			this.pendingRequests.set(id, {
				resolve: (v) => resolve(v as T),
				reject
			});
		});
	}

	on(name: string, handler: (payload: unknown) => void) {
		const handlers = this.eventHandlers.get(name) ?? new Set();
		handlers.add(handler);
		this.eventHandlers.set(name, handlers);
		return () => {
			handlers.delete(handler);
			if (handlers.size === 0) this.eventHandlers.delete(name);
		};
	}

	emit(name: string, payload: unknown) {
		this.eventHandlers.get(name)?.forEach((h) => {
			try {
				h(payload);
			} catch (e) {
				console.error(`[bridge] event handler failed: ${name}`, e);
			}
		});
	}

	private handleMessage(message: any) {
		if (!message || typeof message !== "object" || !("type" in message)) return;

		if (message.type === "host-response") {
			const pending = this.pendingRequests.get(message.requestId);
			if (!pending) return;
			this.pendingRequests.delete(message.requestId);
			if (message.success) {
				pending.resolve(message.payload);
			} else {
				pending.reject(new Error(message.error || "Host request failed"));
			}
		} else if (message.type === "event") {
			this.emit(message.name, message.payload);
		} else if (message.type === "init") {
			this.emit("init", message);
		}
	}
}

const isCarrotWorker = !!(globalThis as any).__bunnyCarrotBootstrap;
export const bridge: PostMessageBridge | null = isCarrotWorker ? new PostMessageBridge() : null;

// Proxy wrapper: routes ffi.request calls through FFI when available,
// or through the postMessage bridge when running as a carrot without FFI.
function createFfiRequestProxy(ffiRequest: Record<string, Function>): Record<string, Function> {
	if (hasFFI) return ffiRequest;

	return new Proxy(ffiRequest, {
		get(target, method: string) {
			if (typeof method !== "string") return target[method];
			return (params?: unknown) => bridge!.requestHost(method, params);
		}
	});
}

const _callbacks: unknown[] = [];

// NOTE: Bun seems to hit limits on args or arg types. eg: trying to send 12 bools results
// in only about 8 going through then params after that. I think it may be similar to
// a zig bug I ran into last year. So check number of args in a signature when alignment issues occur.

// Non-null accessor for use inside _ffiImpl — these methods are only called when hasFFI is true.
const native_ = native!;

const _ffiImpl = {
	request: {
		createWindow: (params: {
			id: number;
			url: string | null;
			title: string;
			frame: {
				width: number;
				height: number;
				x: number;
				y: number;
			};
			styleMask: {
				Borderless: boolean;
				Titled: boolean;
				Closable: boolean;
				Miniaturizable: boolean;
				Resizable: boolean;
				UnifiedTitleAndToolbar: boolean;
				FullScreen: boolean;
				FullSizeContentView: boolean;
				UtilityWindow: boolean;
				DocModalWindow: boolean;
				NonactivatingPanel: boolean;
				HUDWindow: boolean;
			};
			titleBarStyle: string;
			transparent: boolean;
			cornerRadius?: number;
			toolbar: boolean;
			hidden?: boolean;
			activate?: boolean;
			trafficLightOffset?: {
				x: number;
				y: number;
			};
		}): FFIType.ptr => {
			const {
				id,
				url: _url,
				title,
				frame: { x, y, width, height },
				styleMask: {
					Borderless,
					Titled,
					Closable,
					Miniaturizable,
					Resizable,
					UnifiedTitleAndToolbar,
					FullScreen,
					FullSizeContentView,
					UtilityWindow,
					DocModalWindow,
					NonactivatingPanel,
					HUDWindow
				},
				titleBarStyle,
				transparent,
				cornerRadius = 0,
				toolbar,
				hidden = false,
				activate = true,
				trafficLightOffset = { x: 0, y: 0 }
			} = params;

			const styleMask =
				process.platform === "darwin"
					? getMacWindowStyleMask({
							Borderless,
							Titled,
							Closable,
							Miniaturizable,
							Resizable,
							UnifiedTitleAndToolbar,
							FullScreen,
							FullSizeContentView,
							UtilityWindow,
							DocModalWindow,
							NonactivatingPanel,
							HUDWindow
						})
					: native_.symbols.getWindowStyle(
							Borderless,
							Titled,
							Closable,
							Miniaturizable,
							Resizable,
							UnifiedTitleAndToolbar,
							FullScreen,
							FullSizeContentView,
							UtilityWindow,
							DocModalWindow,
							NonactivatingPanel,
							HUDWindow
						);

			const windowPtr = native_.symbols.createWindowWithFrameAndStyleFromWorker(
				id,
				x,
				y,
				width,
				height,
				styleMask,
				toCString(titleBarStyle),
				transparent,
				toolbar,
				trafficLightOffset.x,
				trafficLightOffset.y,
				cornerRadius,
				// callbacks
				windowCloseCallback,
				windowMoveCallback,
				windowResizeCallback,
				windowFocusCallback,
				windowBlurCallback,
				windowKeyCallback
			);

			if (!windowPtr) {
				throw "Failed to create window";
			}

			native_.symbols.setWindowTitle(windowPtr, toCString(title));
			if (!hidden) {
				native_.symbols.showWindow(windowPtr, activate);
			}

			return windowPtr;
		},
		setTitle: (params: { winId: number; title: string }) => {
			const { winId, title } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't add webview to window. window no longer exists`;
			}

			native_.symbols.setWindowTitle(windowPtr, toCString(title));
		},

		closeWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				// Window already closed — silently ignore the race condition
				return;
			}

			native_.symbols.closeWindow(windowPtr);
			// Note: Cleanup of BrowserWindowMap happens in the windowCloseCallback
		},

		showWindow: (params: { winId: number; activate?: boolean }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't show window. Window no longer exists`;
			}

			native_.symbols.showWindow(windowPtr, params.activate ?? true);
		},

		activateWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't activate window. Window no longer exists`;
			}

			native_.symbols.activateWindow(windowPtr);
		},

		hideWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't hide window. Window no longer exists`;
			}

			native_.symbols.hideWindow(windowPtr);
		},

		setWindowCloaked: (params: { winId: number; cloaked: boolean }) => {
			const { winId, cloaked } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't cloak window. Window no longer exists`;
			}

			native_.symbols.setWindowCloaked(windowPtr, cloaked);
		},

		minimizeWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't minimize window. Window no longer exists`;
			}

			native_.symbols.minimizeWindow(windowPtr);
		},

		restoreWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't restore window. Window no longer exists`;
			}

			native_.symbols.restoreWindow(windowPtr);
		},

		isWindowMinimized: (params: { winId: number }): boolean => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				return false;
			}

			return native_.symbols.isWindowMinimized(windowPtr);
		},

		setWindowIcon: (params: { winId: number; iconPath: string }): void => {
			const { winId, iconPath } = params;
			const windowPtr = getWindowPtr(winId);
			if (!windowPtr) {
				return;
			}
			native_.symbols.setWindowIcon(windowPtr, toCString(iconPath));
		},

		maximizeWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't maximize window. Window no longer exists`;
			}

			native_.symbols.maximizeWindow(windowPtr);
		},

		unmaximizeWindow: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't unmaximize window. Window no longer exists`;
			}

			native_.symbols.unmaximizeWindow(windowPtr);
		},

		isWindowMaximized: (params: { winId: number }): boolean => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				return false;
			}

			return native_.symbols.isWindowMaximized(windowPtr);
		},

		setWindowFullScreen: (params: { winId: number; fullScreen: boolean }) => {
			const { winId, fullScreen } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set fullscreen. Window no longer exists`;
			}

			native_.symbols.setWindowFullScreen(windowPtr, fullScreen);
		},

		isWindowFullScreen: (params: { winId: number }): boolean => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				return false;
			}

			return native_.symbols.isWindowFullScreen(windowPtr);
		},

		setWindowAlwaysOnTop: (params: { winId: number; alwaysOnTop: boolean }) => {
			const { winId, alwaysOnTop } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set always on top. Window no longer exists`;
			}

			native_.symbols.setWindowAlwaysOnTop(windowPtr, alwaysOnTop);
		},

		isWindowAlwaysOnTop: (params: { winId: number }): boolean => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				return false;
			}

			return native_.symbols.isWindowAlwaysOnTop(windowPtr);
		},

		setWindowVisibleOnAllWorkspaces: (params: {
			winId: number;
			visibleOnAllWorkspaces: boolean;
		}) => {
			const { winId, visibleOnAllWorkspaces } = params;
			const windowPtr = BrowserWindow.getById(winId)?.ptr;

			if (!windowPtr) {
				throw `Can't set visible on all workspaces. Window no longer exists`;
			}

			native_.symbols.setWindowVisibleOnAllWorkspaces(windowPtr, visibleOnAllWorkspaces);
		},

		isWindowVisibleOnAllWorkspaces: (params: { winId: number }): boolean => {
			const { winId } = params;
			const windowPtr = BrowserWindow.getById(winId)?.ptr;

			if (!windowPtr) {
				return false;
			}

			return native_.symbols.isWindowVisibleOnAllWorkspaces(windowPtr);
		},

		setWindowHiddenFromMissionControl: (params: {
			winId: number;
			hiddenFromMissionControl: boolean;
		}) => {
			const { winId, hiddenFromMissionControl } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set hidden from Mission Control. Window no longer exists`;
			}

			native_.symbols.setWindowHiddenFromMissionControl(windowPtr, hiddenFromMissionControl);
		},

		setWindowPosition: (params: { winId: number; x: number; y: number }) => {
			const { winId, x, y } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set window position. Window no longer exists`;
			}

			native_.symbols.setWindowPosition(windowPtr, x, y);
		},

		setWindowButtonPosition: (params: { winId: number; x: number; y: number }) => {
			const { winId, x, y } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set window button position. Window no longer exists`;
			}

			native_.symbols.setWindowButtonPosition(windowPtr, x, y);
		},

		setWindowSize: (params: { winId: number; width: number; height: number }) => {
			const { winId, width, height } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set window size. Window no longer exists`;
			}

			native_.symbols.setWindowSize(windowPtr, width, height);
		},

		setWindowFrame: (params: {
			winId: number;
			x: number;
			y: number;
			width: number;
			height: number;
		}) => {
			const { winId, x, y, width, height } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				throw `Can't set window frame. Window no longer exists`;
			}

			native_.symbols.setWindowFrame(windowPtr, x, y, width, height);
		},

		getWindowFrame: (params: {
			winId: number;
		}): { x: number; y: number; width: number; height: number } => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);

			if (!windowPtr) {
				return { x: 0, y: 0, width: 0, height: 0 };
			}

			// Create buffers to receive the output values
			const xBuf = new Float64Array(1);
			const yBuf = new Float64Array(1);
			const widthBuf = new Float64Array(1);
			const heightBuf = new Float64Array(1);

			native_.symbols.getWindowFrame(
				windowPtr,
				ptr(xBuf),
				ptr(yBuf),
				ptr(widthBuf),
				ptr(heightBuf)
			);

			return {
				x: xBuf[0]!,
				y: yBuf[0]!,
				width: widthBuf[0]!,
				height: heightBuf[0]!
			};
		},

		showFindBar: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);
			if (!windowPtr) return;
			native_.symbols.webviewShowFindBar(windowPtr);
		},

		hideFindBar: (params: { winId: number }) => {
			const { winId } = params;
			const windowPtr = getWindowPtr(winId);
			if (!windowPtr) return;
			native_.symbols.webviewHideFindBar(windowPtr);
		},

		createWebview: (params: {
			id: number;
			windowId: number;
			renderer: "cef" | "native";
			rpcPort: number;
			secretKey: string;
			hostWebviewId: number | null;
			pipePrefix: string;
			url: string | null;
			html: string | null;
			partition: string | null;
			preload: string | null;
			viewsRoot: string | null;
			frame: {
				x: number;
				y: number;
				width: number;
				height: number;
			};
			autoResize: boolean;
			navigationRules: string | null;
			sandbox: boolean;
			startTransparent: boolean;
			transparentBackground: boolean;
			startPassthrough: boolean;
			contentBlocker: boolean;
		}): FFIType.ptr => {
			const {
				id,
				windowId,
				renderer,
				rpcPort,
				secretKey,
				// hostWebviewId: number | null;
				// pipePrefix: string;
				url,
				// html: string | null;
				partition,
				preload,
				viewsRoot,
				frame: { x, y, width, height },
				autoResize,
				navigationRules,
				sandbox,
				startTransparent,
				transparentBackground,
				startPassthrough,
				contentBlocker
			} = params;

			const parentWindow = BrowserWindow.getById(windowId);
			const windowPtr = parentWindow?.ptr;
			// Get transparent flag from parent window
			const transparent = (parentWindow?.transparent ?? false) || transparentBackground;

			if (!windowPtr) {
				throw `Can't add webview to window. window no longer exists`;
			}

			// Dynamic setup per-webview (variables that change for each webview)
			// EventBridge is available for ALL webviews (including sandboxed) for event emission
			// InternalBridge and BunBridge are only available for trusted (non-sandboxed) webviews
			let dynamicPreload: string;
			let selectedPreloadScript: string;

			if (sandbox) {
				// Sandboxed webview: minimal preload with only event emission capability
				// Note: We set up internalBridge for event emission fallback (until native code
				// adds dedicated eventBridge handler). The security is enforced because:
				// 1. Sandboxed preload has NO RPC code - it can only emit events
				// 2. No bunBridge is set up - no user RPC communication
				// 3. No secretKey/rpcPort - no encrypted socket RPC
				// 4. No webview tag support - can't create OOPIFs
				// Note: Check existing value first to preserve bridges already set by CEF's OnContextCreated
				dynamicPreload = `
window.__electrobunWebviewId = ${id};
window.__electrobunWindowId = ${windowId};
window.__electrobunPlatform = ${JSON.stringify(process.platform)};
window.__electrobunRenderer = ${JSON.stringify(renderer)};
window.__electrobunEventBridge = window.__electrobunEventBridge || window.webkit?.messageHandlers?.eventBridge || window.eventBridge || window.chrome?.webview?.hostObjects?.eventBridge;
window.__electrobunInternalBridge = window.__electrobunInternalBridge || window.webkit?.messageHandlers?.internalBridge || window.internalBridge || window.chrome?.webview?.hostObjects?.internalBridge;
`;
				selectedPreloadScript = preloadScriptSandboxed;
			} else {
				// Trusted webview: all bridges, full preload
				// Note: Check existing value first to preserve bridges already set by CEF's OnContextCreated
				dynamicPreload = `
window.__electrobunWebviewId = ${id};
window.__electrobunWindowId = ${windowId};
window.__electrobunPlatform = ${JSON.stringify(process.platform)};
window.__electrobunRenderer = ${JSON.stringify(renderer)};
window.__electrobunRpcSocketPort = ${rpcPort};
window.__electrobunSecretKeyBytes = [${secretKey}];
window.__electrobunEventBridge = window.__electrobunEventBridge || window.webkit?.messageHandlers?.eventBridge || window.eventBridge || window.chrome?.webview?.hostObjects?.eventBridge;
window.__electrobunInternalBridge = window.__electrobunInternalBridge || window.webkit?.messageHandlers?.internalBridge || window.internalBridge || window.chrome?.webview?.hostObjects?.internalBridge;
window.__electrobunBunBridge = window.__electrobunBunBridge || window.webkit?.messageHandlers?.bunBridge || window.bunBridge || window.chrome?.webview?.hostObjects?.bunBridge;
`;
				selectedPreloadScript = preloadScript;
			}

			const electrobunPreload = dynamicPreload + selectedPreloadScript;

			const customPreload = preload;

			// Pre-set flags before initWebview (workaround for FFI param count limits)
			native_.symbols.setNextWebviewFlags(startTransparent, startPassthrough);
			const webviewPtr = native_.symbols.initWebview(
				id,
				windowPtr,
				toCString(renderer),
				toCString(url || ""),
				x,
				y,
				width,
				height,
				autoResize,
				toCString(partition || "persist:default"),
				webviewDecideNavigation,
				webviewEventJSCallback,
				eventBridgeHandler, // Event-only bridge (always active, for dom-ready, navigation, etc.)
				bunBridgePostmessageHandler, // User RPC bridge (disabled in sandbox mode)
				internalBridgeHandler, // Internal RPC bridge (disabled in sandbox mode)
				toCString(electrobunPreload),
				toCString(customPreload || ""),
				toCString(viewsRoot || ""),
				transparent,
				sandbox // When true, bunBridge and internalBridge are not set up in native code
			);

			if (!webviewPtr) {
				throw "Failed to create webview";
			}

			if (navigationRules) {
				native_.symbols.setWebviewNavigationRules(webviewPtr, toCString(navigationRules));
			}

			if (contentBlocker && contentBlockerNative) {
				contentBlockerNative.lib.symbols.setContentBlockerEnabled(webviewPtr, true);
			}

			return webviewPtr;
		},

		createWGPUView: (params: {
			id: number;
			windowId: number;
			frame: {
				x: number;
				y: number;
				width: number;
				height: number;
			};
			autoResize: boolean;
			startTransparent: boolean;
			startPassthrough: boolean;
		}): FFIType.ptr => {
			const {
				id,
				windowId,
				frame: { x, y, width, height },
				autoResize,
				startTransparent,
				startPassthrough
			} = params;

			const windowPtr = getWindowPtr(windowId);
			if (!windowPtr) {
				throw `Can't add WGPUView to window. window no longer exists`;
			}

			const viewPtr = native_.symbols.initWGPUView(
				id,
				windowPtr,
				x,
				y,
				width,
				height,
				autoResize,
				startTransparent,
				startPassthrough
			);

			if (!viewPtr) {
				throw "Failed to create WGPUView";
			}

			return viewPtr;
		},

		wgpuViewSetFrame: (params: {
			id: number;
			x: number;
			y: number;
			width: number;
			height: number;
		}) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuViewSetFrame: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}

			native_.symbols.wgpuViewSetFrame(view.ptr, params.x, params.y, params.width, params.height);
		},

		wgpuViewSetTransparent: (params: { id: number; transparent: boolean }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(
					`wgpuViewSetTransparent: WGPUView not found or has no ptr for id ${params.id}`
				);
				return;
			}

			native_.symbols.wgpuViewSetTransparent(view.ptr, params.transparent);
		},

		wgpuViewSetPassthrough: (params: { id: number; passthrough: boolean }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(
					`wgpuViewSetPassthrough: WGPUView not found or has no ptr for id ${params.id}`
				);
				return;
			}

			native_.symbols.wgpuViewSetPassthrough(view.ptr, params.passthrough);
		},

		wgpuViewSetHidden: (params: { id: number; hidden: boolean }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuViewSetHidden: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}

			native_.symbols.wgpuViewSetHidden(view.ptr, params.hidden);
		},

		wgpuViewRemove: (params: { id: number }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuViewRemove: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}

			native_.symbols.wgpuViewRemove(view.ptr);
		},
		wgpuViewGetNativeHandle: (params: { id: number }): Pointer | null => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(
					`wgpuViewGetNativeHandle: WGPUView not found or has no ptr for id ${params.id}`
				);
				return null;
			}

			const handle = native_.symbols.wgpuViewGetNativeHandle(view.ptr);
			return handle || null;
		},

		evaluateJavascriptWithNoCompletion: (params: { id: number; js: string }) => {
			const { id, js } = params;
			const webview = BrowserView.getById(id);

			if (!webview?.ptr) {
				return;
			}

			native_.symbols.evaluateJavaScriptWithNoCompletion(webview.ptr, toCString(js));
		},

		evaluateJavascriptSync: (params: { id: number; js: string }): string | null => {
			const webview = BrowserView.getById(params.id);
			if (!webview?.ptr) return null;
			const result = native_.symbols.evaluateJavascriptSync(webview.ptr, toCString(params.js));
			if (!result) return null;
			return result.toString();
		},

		printWebview: (params: { id: number }): boolean => {
			const webview = BrowserView.getById(params.id);
			if (!webview?.ptr) return false;
			return native_.symbols.webviewPrint(webview.ptr);
		},

		saveWebviewPageAs: (params: {
			id: number;
			suggestedName: string;
			format: "webarchive" | "pdf";
		}): boolean => {
			const webview = BrowserView.getById(params.id);
			if (!webview?.ptr) return false;
			return native_.symbols.webviewSavePageAs(
				webview.ptr,
				toCString(params.suggestedName),
				toCString(params.format)
			);
		},

		createTray: (params: {
			id: number;
			title: string;
			image: string;
			template: boolean;
			width: number;
			height: number;
		}): FFIType.ptr => {
			const { id, title, image, template, width, height } = params;

			const trayPtr = native_.symbols.createTray(
				id,
				toCString(title),
				toCString(image),
				template,
				width,
				height,
				trayItemHandler
			);

			if (!trayPtr) {
				throw "Failed to create tray";
			}

			return trayPtr;
		},
		setTrayTitle: (params: { id: number; title: string }): void => {
			const { id, title } = params;

			const tray = Tray.getById(id);
			if (!tray) return;

			native_.symbols.setTrayTitle(tray.ptr, toCString(title));
		},
		setTrayImage: (params: {
			id: number;
			image: string;
			template?: boolean;
			width?: number;
			height?: number;
		}): void => {
			const { id, image, template = true, width = 18, height = 18 } = params;

			const tray = Tray.getById(id);
			if (!tray) return;

			native_.symbols.setTrayImage(tray.ptr, toCString(image), template, width, height);
		},
		setTrayMenu: (params: {
			id: number;
			// json string of config
			menuConfig: string;
		}): void => {
			const { id, menuConfig } = params;

			const tray = Tray.getById(id);
			if (!tray) return;

			native_.symbols.setTrayMenu(tray.ptr, toCString(menuConfig));
		},

		removeTray: (params: { id: number }): void => {
			const { id } = params;
			const tray = Tray.getById(id);

			if (!tray) {
				throw `Can't remove tray. Tray no longer exists`;
			}

			native_.symbols.removeTray(tray.ptr);
			// The Tray class will handle removing from TrayMap
		},
		getTrayBounds: (params: { id: number }): Rectangle => {
			const tray = Tray.getById(params.id);
			if (!tray?.ptr) {
				return { x: 0, y: 0, width: 0, height: 0 };
			}

			const jsonStr = native_.symbols.getTrayBounds(tray.ptr);
			if (!jsonStr) {
				return { x: 0, y: 0, width: 0, height: 0 };
			}

			try {
				return JSON.parse(jsonStr.toString());
			} catch {
				return { x: 0, y: 0, width: 0, height: 0 };
			}
		},
		setApplicationMenu: (params: { menuConfig: string }): void => {
			const { menuConfig } = params;

			native_.symbols.setApplicationMenu(toCString(menuConfig), applicationMenuHandler);
		},
		showContextMenu: (params: { menuConfig: string }): void => {
			const { menuConfig } = params;

			native_.symbols.showContextMenu(toCString(menuConfig), contextMenuHandler);
		},
		moveToTrash: (params: { path: string }): boolean => {
			const { path } = params;

			return native_.symbols.moveToTrash(toCString(path));
		},
		showItemInFolder: (params: { path: string }): void => {
			const { path } = params;

			native_.symbols.showItemInFolder(toCString(path));
		},
		removeImageBackground: (params: { inputPath: string; outputPath: string }): boolean => {
			const symbolName: string = "removeImageBackground";
			const removeImageBackground = Reflect.get(native_.symbols, symbolName);
			if (typeof removeImageBackground !== "function") return false;
			return removeImageBackground(toCString(params.inputPath), toCString(params.outputPath));
		},
		shareFile: (params: { path: string }): void => {
			const symbolName: string = "shareFile";
			const shareFile = Reflect.get(native_.symbols, symbolName);
			if (typeof shareFile !== "function") return;
			shareFile(toCString(params.path));
		},
		openExternal: (params: { url: string }): boolean => {
			const { url } = params;
			return native_.symbols.openExternal(toCString(url));
		},
		openPath: (params: { path: string }): boolean => {
			const { path } = params;
			return native_.symbols.openPath(toCString(path));
		},
		showNotification: (params: {
			title: string;
			body?: string;
			subtitle?: string;
			silent?: boolean;
		}): void => {
			const { title, body = "", subtitle = "", silent = false } = params;
			native_.symbols.showNotification(
				toCString(title),
				toCString(body),
				toCString(subtitle),
				silent
			);
		},
		setDockIcon: (params: { imagePath: string }): void => {
			native_.symbols.setDockIcon(toCString(params.imagePath));
		},
		setDockIconVisible: (params: { visible: boolean }): void => {
			native_.symbols.setDockIconVisible(params.visible);
		},
		isDockIconVisible: (): boolean => {
			return native_.symbols.isDockIconVisible();
		},
		openFileDialog: (params: {
			startingFolder: string;
			allowedFileTypes: string;
			canChooseFiles: boolean;
			canChooseDirectory: boolean;
			allowsMultipleSelection: boolean;
		}): string => {
			const {
				startingFolder,
				allowedFileTypes,
				canChooseFiles,
				canChooseDirectory,
				allowsMultipleSelection
			} = params;
			const filePath = native_.symbols.openFileDialog(
				toCString(startingFolder),
				toCString(allowedFileTypes),
				canChooseFiles ? 1 : 0,
				canChooseDirectory ? 1 : 0,
				allowsMultipleSelection ? 1 : 0
			);

			return filePath.toString();
		},
		showMessageBox: (params: {
			type?: string;
			title?: string;
			message?: string;
			detail?: string;
			buttons?: string[];
			defaultId?: number;
			cancelId?: number;
		}): number => {
			const {
				type = "info",
				title = "",
				message = "",
				detail = "",
				buttons = ["OK"],
				defaultId = 0,
				cancelId = -1
			} = params;
			// Convert buttons array to comma-separated string
			const buttonsStr = buttons.join(",");
			return native_.symbols.showMessageBox(
				toCString(type),
				toCString(title),
				toCString(message),
				toCString(detail),
				toCString(buttonsStr),
				defaultId,
				cancelId
			);
		},

		// Clipboard API
		clipboardReadText: (): string | null => {
			const result = native_.symbols.clipboardReadText();
			if (!result) return null;
			return result.toString();
		},
		clipboardWriteText: (params: { text: string }): void => {
			native_.symbols.clipboardWriteText(toCString(params.text));
		},
		clipboardGetChangeCount: (): number => {
			return Number(native_.symbols.clipboardGetChangeCount());
		},
		clipboardReadImage: (): Uint8Array | null => {
			// Allocate a buffer for the size output
			const sizeBuffer = new BigUint64Array(1);
			const dataPtr = native_.symbols.clipboardReadImage(ptr(sizeBuffer));

			if (!dataPtr) return null;

			const size = Number(sizeBuffer[0]);
			if (size === 0) return null;

			// Copy the data to a Uint8Array
			const result = new Uint8Array(size);
			const sourceView = new Uint8Array(toArrayBuffer(dataPtr, 0, size));
			result.set(sourceView);

			// Note: The native code allocated this memory with malloc
			// We should free it, but Bun's FFI doesn't expose free directly
			// The memory will be reclaimed when the process exits

			return result;
		},
		clipboardWriteImage: (params: { pngData: Uint8Array }): void => {
			const { pngData } = params;
			native_.symbols.clipboardWriteImage(ptr(pngData), BigInt(pngData.length));
		},
		clipboardReadFilePaths: (): string[] => {
			const result = native_.symbols.clipboardReadFilePaths();
			if (!result) return [];
			const raw = result.toString();
			if (!raw) return [];
			let parsed: unknown;
			try {
				parsed = JSON.parse(raw);
			} catch {
				return [];
			}
			if (!Array.isArray(parsed)) return [];
			const paths: string[] = [];
			for (const value of parsed) {
				if (typeof value === "string" && value.length > 0) paths.push(value);
			}
			return paths;
		},
		clipboardWriteFilePaths: (params: { paths: string[] }): void => {
			native_.symbols.clipboardWriteFilePaths(toCString(JSON.stringify(params.paths)));
		},
		clipboardClear: (): void => {
			native_.symbols.clipboardClear();
		},
		simulatePaste: (): void => {
			native_.symbols.simulatePaste();
		},
		clipboardAvailableFormats: (): string[] => {
			const result = native_.symbols.clipboardAvailableFormats();
			if (!result) return [];
			const formatsStr = result.toString();
			if (!formatsStr) return [];
			return formatsStr.split(",").filter((f) => f.length > 0);
		},
		hasScreenRecordingPermission: (): boolean => {
			return native_.symbols.hasScreenRecordingPermission();
		},
		requestScreenRecordingPermission: (): boolean => {
			return native_.symbols.requestScreenRecordingPermission();
		},
		macPermissionStatus: (params: { kind: MacPermissionKind }): boolean => {
			return native_.symbols.macPermissionStatus(toCString(params.kind));
		},
		requestMacPermissionDragGuide: (params: {
			kind: MacPermissionKind;
			appName: string;
			forceGuide?: boolean;
		}): MacPermissionDragGuideResult => {
			const code = native_.symbols.requestMacPermissionDragGuide(
				toCString(params.kind),
				toCString(params.appName),
				params.forceGuide ?? false
			);
			if (code === 1) return { ok: true, alreadyGranted: true };
			if (code === 0) return { ok: true, alreadyGranted: false };
			if (code === -2) {
				return {
					ok: false,
					error:
						"Cachy must be running from a signed macOS app bundle before it can be dragged into System Settings."
				};
			}
			if (code === -3) {
				return {
					ok: false,
					error:
						"Could not open System Settings. Open Privacy & Security manually and drag Cachy into the permission list."
				};
			}
			return {
				ok: false,
				error: "This macOS permission is not supported by the drag-to-Settings flow."
			};
		},
		requestMacMediaPermission: (params: { kind: MacPermissionKind }): boolean => {
			const symbolName: string = "requestMacMediaPermission";
			const requestMacMediaPermission = Reflect.get(native_.symbols, symbolName);
			if (typeof requestMacMediaPermission !== "function") return false;
			return requestMacMediaPermission(toCString(params.kind)) === 1;
		},
		getCurrentLocation: (params: { timeoutSeconds?: number }): CurrentLocationResult => {
			const symbolName: string = "getCurrentLocationJson";
			const getCurrentLocationJson = Reflect.get(native_.symbols, symbolName);
			if (typeof getCurrentLocationJson !== "function") {
				return {
					ok: false,
					name: "PositionUnavailableError",
					message: "Location is unavailable."
				};
			}
			const result = getCurrentLocationJson(params.timeoutSeconds ?? 8);
			if (!result) {
				return {
					ok: false,
					name: "PositionUnavailableError",
					message: "Location is unavailable."
				};
			}
			return readCurrentLocationResult(result.toString());
		},
		closeMacPermissionDragGuide: (): void => {
			native_.symbols.closeMacPermissionDragGuide();
		},
		captureScreenExcludingWindow: (params: { winId: number | null }): Uint8Array | null => {
			const windowPtr = params.winId != null ? getWindowPtr(params.winId) : null;
			const sizeBuffer = new BigUint64Array(1);
			const dataPtr = native_.symbols.captureScreenExcludingWindow(
				windowPtr ?? null,
				ptr(sizeBuffer)
			);
			if (!dataPtr) return null;
			const size = Number(sizeBuffer[0]);
			if (size === 0) return null;
			const result = new Uint8Array(size);
			result.set(new Uint8Array(toArrayBuffer(dataPtr, 0, size)));
			return result;
		},
		getOnScreenWindowList: (): string | null => {
			const result = native_.symbols.getOnScreenWindowList();
			if (!result) return null;
			return result.toString();
		},
		getRunningApplications: (): string | null => {
			const result = native_.symbols.getRunningApplications();
			if (!result) return null;
			return result.toString();
		},
		captureWindowById: (params: { windowId: number }): Uint8Array | null => {
			const sizeBuffer = new BigUint64Array(1);
			const dataPtr = native_.symbols.captureWindowById(params.windowId, ptr(sizeBuffer));
			if (!dataPtr) return null;
			const size = Number(sizeBuffer[0]);
			if (size === 0) return null;
			const result = new Uint8Array(size);
			result.set(new Uint8Array(toArrayBuffer(dataPtr, 0, size)));
			return result;
		},
		getFrontmostAppInfo: (): string | null => {
			const result = native_.symbols.getFrontmostAppInfo();
			if (!result) return null;
			return result.toString();
		},
		getSystemAppearance: (): string => {
			const result = native_.symbols.getSystemAppearance();
			return result ? result.toString() : "light";
		},
		activateAppByBundleId: (bundleId: string): void => {
			native_.symbols.activateAppByBundleId(toCString(bundleId));
		},
		activateWindowById: (params: { windowId: number }): boolean => {
			return !!native_.symbols.activateWindowById(params.windowId);
		},
		getFrontmostWindowBounds: (): string | null => {
			const result = native_.symbols.getFrontmostWindowBounds();
			if (!result) return null;
			return result.toString();
		},
		getFrontmostWindowInfo: (): string | null => {
			const result = native_.symbols.getFrontmostWindowInfo();
			if (!result) return null;
			return result.toString();
		},
		setFrontmostWindowBounds: (params: {
			x: number;
			y: number;
			width: number;
			height: number;
		}): string | null => {
			const result = native_.symbols.setFrontmostWindowBounds(
				params.x,
				params.y,
				params.width,
				params.height
			);
			if (!result) return null;
			return result.toString();
		},
		getAppIconToPath: (params: { appPath: string; outputPath: string; size: number }): boolean => {
			return !!native_.symbols.getAppIconToPath(
				toCString(params.appPath),
				toCString(params.outputPath),
				params.size
			);
		},
		loadContentBlockerRules: (params: { jsonData: string }) => {
			if (!contentBlockerNative) return;
			const { jsonData } = params;
			if (!jsonData) return;
			contentBlockerNative.lib.symbols.loadContentBlockerRules(
				toCString(jsonData),
				Buffer.byteLength(jsonData, "utf8")
			);
		},
		loadContentBlockerRuleList: (params: { identifier: string }) => {
			if (!contentBlockerNative?.canLoadRuleListByIdentifier) return;
			const { identifier } = params;
			if (!identifier) return;
			const symbolName: string = "loadContentBlockerRuleList";
			const loadContentBlockerRuleList = Reflect.get(contentBlockerNative.lib.symbols, symbolName);
			if (typeof loadContentBlockerRuleList !== "function") return;
			loadContentBlockerRuleList(toCString(identifier));
		},
		setContentBlockerStorePath: (params: { path: string }) => {
			if (!contentBlockerNative?.canSetStorePath) return;
			const { path } = params;
			if (!path) return;
			const symbolName: string = "setContentBlockerStorePath";
			const setContentBlockerStorePath = Reflect.get(contentBlockerNative.lib.symbols, symbolName);
			if (typeof setContentBlockerStorePath !== "function") return;
			setContentBlockerStorePath(toCString(path));
		},
		canLoadContentBlockerRuleList: (): boolean => {
			return contentBlockerNative?.canLoadRuleListByIdentifier ?? false;
		},
		canSetContentBlockerStorePath: (): boolean => {
			return contentBlockerNative?.canSetStorePath ?? false;
		},
		isContentBlockerAvailable: (): boolean => {
			return contentBlockerNative !== null;
		},
		setContentBlockerEnabled: (params: { id: number; enabled: boolean }) => {
			if (!contentBlockerNative) return;
			const webview = BrowserView.getById(params.id);
			if (!webview?.ptr) return;
			contentBlockerNative.lib.symbols.setContentBlockerEnabled(webview.ptr, params.enabled);
		},
		getContentBlockerCompiledCount: (): number => {
			if (!contentBlockerNative) return 0;
			const symbolName: string = "getContentBlockerCompiledCount";
			const getContentBlockerCompiledCount = Reflect.get(
				contentBlockerNative.lib.symbols,
				symbolName
			);
			if (typeof getContentBlockerCompiledCount !== "function") return 0;
			return Number(getContentBlockerCompiledCount()) || 0;
		},
		getContentBlockerLoadCompletionCount: (): number => {
			if (!contentBlockerNative?.canReadLoadStats) return 0;
			const symbolName: string = "getContentBlockerLoadCompletionCount";
			const getContentBlockerLoadCompletionCount = Reflect.get(
				contentBlockerNative.lib.symbols,
				symbolName
			);
			if (typeof getContentBlockerLoadCompletionCount !== "function") return 0;
			return Number(getContentBlockerLoadCompletionCount()) || 0;
		},
		getContentBlockerLoadFailureCount: (): number => {
			if (!contentBlockerNative?.canReadLoadStats) return 0;
			const symbolName: string = "getContentBlockerLoadFailureCount";
			const getContentBlockerLoadFailureCount = Reflect.get(
				contentBlockerNative.lib.symbols,
				symbolName
			);
			if (typeof getContentBlockerLoadFailureCount !== "function") return 0;
			return Number(getContentBlockerLoadFailureCount()) || 0;
		}
	},
	// Internal functions for menu data management
	internal: {
		storeMenuData,
		getMenuData,
		clearMenuData,
		serializeMenuAction,
		deserializeMenuAction
	}
};

export const ffi = {
	request: createFfiRequestProxy(
		_ffiImpl.request as unknown as Record<string, Function>
	) as typeof _ffiImpl.request,
	internal: _ffiImpl.internal
};

export const WGPUBridge = {
	available: !!native?.symbols?.wgpuInstanceCreateSurfaceMainThread,
	instanceCreateSurface: (instancePtr: Pointer, descriptorPtr: Pointer): Pointer =>
		native_.symbols.wgpuInstanceCreateSurfaceMainThread(
			instancePtr as any,
			descriptorPtr as any
		) as Pointer,
	surfaceConfigure: (surfacePtr: Pointer, configPtr: Pointer) =>
		native_.symbols.wgpuSurfaceConfigureMainThread(surfacePtr as any, configPtr as any),
	surfaceGetCurrentTexture: (surfacePtr: Pointer, surfaceTexturePtr: Pointer) =>
		native_.symbols.wgpuSurfaceGetCurrentTextureMainThread(
			surfacePtr as any,
			surfaceTexturePtr as any
		),
	surfacePresent: (surfacePtr: Pointer): number =>
		native_.symbols.wgpuSurfacePresentMainThread(surfacePtr as any),
	queueOnSubmittedWorkDone: (queuePtr: Pointer, callbackInfoPtr: Pointer): bigint =>
		native_.symbols.wgpuQueueOnSubmittedWorkDoneShim(queuePtr as any, callbackInfoPtr as any),
	bufferMapAsync: (
		bufferPtr: Pointer,
		mode: bigint,
		offset: bigint,
		size: bigint,
		callbackInfoPtr: Pointer
	): bigint =>
		native_.symbols.wgpuBufferMapAsyncShim(
			bufferPtr as any,
			mode as any,
			offset as any,
			size as any,
			callbackInfoPtr as any
		),
	instanceWaitAny: (instancePtr: Pointer, futureId: bigint, timeoutNs: bigint): number =>
		native_.symbols.wgpuInstanceWaitAnyShim(instancePtr as any, futureId as any, timeoutNs as any),
	bufferReadSync: (
		instancePtr: Pointer,
		bufferPtr: Pointer,
		offset: bigint,
		size: bigint,
		timeoutNs: bigint,
		outSizePtr: Pointer
	): Pointer =>
		native_.symbols.wgpuBufferReadSyncShim(
			instancePtr as any,
			bufferPtr as any,
			offset as any,
			size as any,
			timeoutNs as any,
			outSizePtr as any
		) as Pointer,
	bufferReadSyncInto: (
		instancePtr: Pointer,
		bufferPtr: Pointer,
		offset: bigint,
		size: bigint,
		timeoutNs: bigint,
		dstPtr: Pointer
	): number =>
		native_.symbols.wgpuBufferReadSyncIntoShim(
			instancePtr as any,
			bufferPtr as any,
			offset as any,
			size as any,
			timeoutNs as any,
			dstPtr as any
		),
	bufferReadbackBegin: (
		bufferPtr: Pointer,
		offset: bigint,
		size: bigint,
		dstPtr: Pointer
	): Pointer =>
		native_.symbols.wgpuBufferReadbackBeginShim(
			bufferPtr as any,
			offset as any,
			size as any,
			dstPtr as any
		) as Pointer,
	bufferReadbackStatus: (jobPtr: Pointer): number =>
		native_.symbols.wgpuBufferReadbackStatusShim(jobPtr as any),
	bufferReadbackFree: (jobPtr: Pointer) =>
		native_.symbols.wgpuBufferReadbackFreeShim(jobPtr as any),
	runTest: (viewId: number) => {
		const view = WGPUView.getById(viewId);
		if (!view?.ptr) {
			console.error(`wgpuRunGPUTest: WGPUView not found for id ${viewId}`);
			return;
		}
		if (!native?.symbols?.wgpuRunGPUTest) {
			console.error("wgpuRunGPUTest not available");
			return;
		}
		native_.symbols.wgpuRunGPUTest(view.ptr);
	},
	createAdapterDeviceMainThread: (
		instancePtr: Pointer,
		surfacePtr: Pointer,
		outAdapterDevicePtr: Pointer
	) =>
		native_.symbols.wgpuCreateAdapterDeviceMainThread(
			instancePtr as any,
			surfacePtr as any,
			outAdapterDevicePtr as any
		),
	createSurfaceForView: (instancePtr: Pointer, viewPtr: Pointer): Pointer | null => {
		if (!native?.symbols?.wgpuCreateSurfaceForView) return null;
		return native_.symbols.wgpuCreateSurfaceForView(instancePtr as any, viewPtr as any) as Pointer;
	}
};

// Worker management. Move to a different file
process.on("uncaughtException", (err) => {
	console.error("Uncaught exception in worker:", err);
	if (native) {
		native_.symbols.stopEventLoop();
		native_.symbols.waitForShutdownComplete(5000);
		native_.symbols.forceExit(1);
	} else {
		process.exit(1);
	}
});

process.on("unhandledRejection", (reason, _promise) => {
	console.error("Unhandled rejection in worker:", reason);
});

process.on("SIGINT", () => {
	console.log("[electrobun] Received SIGINT, running quit sequence...");
	const { quit } = require("../core/Utils");
	quit();
});

process.on("SIGTERM", () => {
	console.log("[electrobun] Received SIGTERM, running quit sequence...");
	const { quit } = require("../core/Utils");
	quit();
});

// const testCallback = new JSCallback(
//   (windowId, x, y) => {
//     console.log(`TEST FFI Callback reffed GLOBALLY in js`);
//     // Your window move handler implementation
//   },
//   {
//     args: [],
//     returns: "void",
//     threadsafe: true,

//   }
// );

const windowCloseCallback = new JSCallback(
	(id) => {
		const handler = electrobunEventEmitter.events.window.close;
		const event = handler({
			id
		});

		// emit specific event first so user per-window handlers run
		// before the global handler (e.g. exitOnLastWindowClosed)
		electrobunEventEmitter.emitEvent(event, id);
		electrobunEventEmitter.emitEvent(event);
	},
	{
		args: ["u32"],
		returns: "void",
		threadsafe: true
	}
);

const windowMoveCallback = new JSCallback(
	(id, x, y) => {
		const handler = electrobunEventEmitter.events.window.move;
		const event = handler({
			id,
			x,
			y
		});

		// global event
		electrobunEventEmitter.emitEvent(event);
		electrobunEventEmitter.emitEvent(event, id);
	},
	{
		args: ["u32", "f64", "f64"],
		returns: "void",
		threadsafe: true
	}
);

const windowResizeCallback = new JSCallback(
	(id, x, y, width, height) => {
		const handler = electrobunEventEmitter.events.window.resize;
		const event = handler({
			id,
			x,
			y,
			width,
			height
		});

		// global event
		electrobunEventEmitter.emitEvent(event);
		electrobunEventEmitter.emitEvent(event, id);
	},
	{
		args: ["u32", "f64", "f64", "f64", "f64"],
		returns: "void",
		threadsafe: true
	}
);

const windowFocusCallback = new JSCallback(
	(id) => {
		const handler = electrobunEventEmitter.events.window.focus;
		const event = handler({
			id
		});

		// global event
		electrobunEventEmitter.emitEvent(event);
		electrobunEventEmitter.emitEvent(event, id);
	},
	{
		args: ["u32"],
		returns: "void",
		threadsafe: true
	}
);

const windowBlurCallback = new JSCallback(
	(id) => {
		const handler = electrobunEventEmitter.events.window.blur;
		const event = handler({
			id
		});

		// global event
		electrobunEventEmitter.emitEvent(event);
		electrobunEventEmitter.emitEvent(event, id);
	},
	{
		args: ["u32"],
		returns: "void",
		threadsafe: true
	}
);

// global event
const windowKeyCallback = new JSCallback(
	(id, keyCode, modifiers, isDown, isRepeat) => {
		const handler = isDown
			? electrobunEventEmitter.events.window.keyDown
			: electrobunEventEmitter.events.window.keyUp;
		const event = handler({
			id,
			keyCode,
			modifiers,
			isRepeat: !!isRepeat
		});
		electrobunEventEmitter.emitEvent(event);
		electrobunEventEmitter.emitEvent(event, id);
	},
	{
		args: ["u32", "u32", "u32", "u32", "u32"],
		returns: "void",
		threadsafe: true
	}
);

const getMimeType = new JSCallback(
	(filePath) => {
		const _filePath = new CString(filePath).toString();
		const mimeType = Bun.file(_filePath).type; // || "application/octet-stream";

		// For this usecase we generally don't want the charset included in the mimetype
		// otherwise it can break. eg: for html with text/javascript;charset=utf-8 browsers
		// will tend to render the code/text instead of interpreting the html.

		return toCString(mimeType.split(";")[0]!);
	},
	{
		args: [FFIType.cstring],
		returns: FFIType.cstring
		// threadsafe: true
	}
);

const getHTMLForWebviewSync = new JSCallback(
	(webviewId) => {
		const webview = BrowserView.getById(webviewId);

		return toCString(webview?.html || "");
	},
	{
		args: [FFIType.u32],
		returns: FFIType.cstring
		// threadsafe: true
	}
);

if (native) native_.symbols.setJSUtils(getMimeType, getHTMLForWebviewSync);

// Native-only init: URL scheme handlers, quit handler, global shortcuts.
// Skipped when running without FFI (carrot mode).
const globalShortcutHandlers = new Map<number, () => void>();
const globalShortcutIdsByAccelerator = new Map<string, number>();

if (native) {
	const urlOpenCallback = new JSCallback(
		(urlPtr) => {
			const url = new CString(urlPtr).toString();
			const handler = electrobunEventEmitter.events.app.openUrl;
			const event = handler({ url });
			electrobunEventEmitter.emitEvent(event);
		},
		{ args: [FFIType.cstring], returns: "void", threadsafe: true }
	);
	_callbacks.push(urlOpenCallback);
	if (process.platform === "darwin") {
		native_.symbols.setURLOpenHandler(urlOpenCallback);
	}

	const appReopenCallback = new JSCallback(
		() => {
			if (process.platform === "darwin") {
				native_.symbols.setDockIconVisible(true);
			}
			const handler = electrobunEventEmitter.events.app.reopen;
			const event = handler({});
			electrobunEventEmitter.emitEvent(event);
		},
		{ args: [], returns: "void", threadsafe: true }
	);
	_callbacks.push(appReopenCallback);
	if (process.platform === "darwin") {
		native_.symbols.setAppReopenHandler(appReopenCallback);
	}

	const quitRequestedCallback = new JSCallback(
		() => {
			const { quit } = require("../core/Utils");
			quit();
		},
		{ args: [], returns: "void", threadsafe: true }
	);
	_callbacks.push(quitRequestedCallback);
	native_.symbols.setQuitRequestedHandler(quitRequestedCallback);

	const globalShortcutCallback = new JSCallback(
		(shortcutId) => {
			const handler = globalShortcutHandlers.get(shortcutId);
			console.log(
				`[GlobalShortcut] JS callback received id=${shortcutId} handler=${handler ? "yes" : "no"}`
			);
			if (handler) handler();
		},
		{ args: ["i32"], returns: "void", threadsafe: true }
	);
	_callbacks.push(globalShortcutCallback);
	native_.symbols.setGlobalShortcutCallback(globalShortcutCallback);

	const themeChangedCallback = new JSCallback(
		(themePtr) => {
			const theme = new CString(themePtr).toString();
			for (const handler of themeChangedHandlers) {
				handler(theme);
			}
		},
		{ args: [FFIType.cstring], returns: "void", threadsafe: true }
	);
	_callbacks.push(themeChangedCallback);
	native_.symbols.setThemeChangedCallback(themeChangedCallback);
}

const themeChangedHandlers: Set<(theme: string) => void> = new Set();

export const SystemTheme = {
	onChanged: (handler: (theme: string) => void): (() => void) => {
		themeChangedHandlers.add(handler);
		return () => themeChangedHandlers.delete(handler);
	}
};

// GlobalShortcut module for external use
export const GlobalShortcut = {
	/**
	 * Register a global keyboard shortcut
	 * @param accelerator - The shortcut string (e.g., "CommandOrControl+Shift+Space")
	 * @param callback - Function to call when the shortcut is triggered
	 * @returns true if registered successfully, false otherwise
	 */
	register: (accelerator: string, callback: () => void): boolean => {
		if (!native || globalShortcutIdsByAccelerator.has(accelerator)) return false;
		const shortcutId = native_.symbols.registerGlobalShortcut(toCString(accelerator));
		console.log(`[GlobalShortcut] register("${accelerator}") => id=${shortcutId}`);
		if (shortcutId > 0) {
			globalShortcutHandlers.set(shortcutId, callback);
			globalShortcutIdsByAccelerator.set(accelerator, shortcutId);
			return true;
		}
		return false;
	},
	unregister: (accelerator: string): boolean => {
		if (!native) return false;
		const result = native_.symbols.unregisterGlobalShortcut(toCString(accelerator));
		console.log(`[GlobalShortcut] unregister("${accelerator}") => ${result}`);
		if (result) {
			const shortcutId = globalShortcutIdsByAccelerator.get(accelerator);
			if (shortcutId !== undefined) globalShortcutHandlers.delete(shortcutId);
			globalShortcutIdsByAccelerator.delete(accelerator);
		}
		return result;
	},
	unregisterAll: (): void => {
		if (native) native_.symbols.unregisterAllGlobalShortcuts();
		globalShortcutHandlers.clear();
		globalShortcutIdsByAccelerator.clear();
	},
	isRegistered: (accelerator: string): boolean => {
		if (!native) return false;
		return native_.symbols.isGlobalShortcutRegistered(toCString(accelerator));
	}
};

// Types for Screen API
export interface Rectangle {
	x: number;
	y: number;
	width: number;
	height: number;
}

export interface Display {
	id: number;
	bounds: Rectangle;
	workArea: Rectangle;
	scaleFactor: number;
	isPrimary: boolean;
}

export interface Point {
	x: number;
	y: number;
}

export type CurrentLocationCoordinates = {
	latitude: number;
	longitude: number;
	accuracy: number;
	altitude?: number;
	altitudeAccuracy?: number;
	heading?: number;
	speed?: number;
};

export type CurrentLocationResult =
	| {
			ok: true;
			coords: CurrentLocationCoordinates;
			timestamp: number;
	  }
	| {
			ok: false;
			name: string;
			message: string;
	  };

export type OnScreenWindowInfo = {
	owner: string;
	name: string;
	id: number;
	ownerPid?: number;
	bundleId?: string;
	path?: string;
};

export type MacPermissionKind =
	| "accessibility"
	| "screenRecording"
	| "camera"
	| "microphone"
	| "contacts"
	| "fullDiskAccess"
	| "filesAndFolders"
	| "desktopFolder"
	| "documentsFolder"
	| "downloadsFolder"
	| "removableVolumes"
	| "automation"
	| "inputMonitoring"
	| "location"
	| "calendar"
	| "reminders"
	| "photos"
	| "bluetooth"
	| "speechRecognition"
	| "localNetwork"
	| "mediaLibrary"
	| "motionFitness"
	| "homeKit"
	| "focusStatus"
	| "remoteDesktop"
	| "developerTools"
	| "appManagement"
	| "passkeyAccess";

export type MacPermissionDragGuideResult =
	| { ok: true; alreadyGranted: boolean }
	| { ok: false; error: string };

function numericRecordField(record: Record<string, unknown>, key: string): number | undefined {
	const value = record[key];
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stringRecordField(record: Record<string, unknown>, key: string): string | undefined {
	const value = record[key];
	return typeof value === "string" && value.length > 0 ? value : undefined;
}

function readCurrentLocationResult(json: string): CurrentLocationResult {
	try {
		const parsed: unknown = JSON.parse(json);
		if (!isRecord(parsed)) {
			return {
				ok: false,
				name: "PositionUnavailableError",
				message: "Location is unavailable."
			};
		}

		const coordsValue = parsed["coords"];
		if (parsed["ok"] === true && isRecord(coordsValue)) {
			const latitude = numericRecordField(coordsValue, "latitude");
			const longitude = numericRecordField(coordsValue, "longitude");
			const accuracy = numericRecordField(coordsValue, "accuracy");
			if (latitude !== undefined && longitude !== undefined && accuracy !== undefined) {
				const coords: CurrentLocationCoordinates = { latitude, longitude, accuracy };
				const altitude = numericRecordField(coordsValue, "altitude");
				const altitudeAccuracy = numericRecordField(coordsValue, "altitudeAccuracy");
				const heading = numericRecordField(coordsValue, "heading");
				const speed = numericRecordField(coordsValue, "speed");
				if (altitude !== undefined) coords.altitude = altitude;
				if (altitudeAccuracy !== undefined) coords.altitudeAccuracy = altitudeAccuracy;
				if (heading !== undefined) coords.heading = heading;
				if (speed !== undefined) coords.speed = speed;
				return {
					ok: true,
					coords,
					timestamp: numericRecordField(parsed, "timestamp") ?? Date.now()
				};
			}
		}

		return {
			ok: false,
			name: stringRecordField(parsed, "name") ?? "PositionUnavailableError",
			message: stringRecordField(parsed, "message") ?? "Location is unavailable."
		};
	} catch {
		return {
			ok: false,
			name: "PositionUnavailableError",
			message: "Location is unavailable."
		};
	}
}

// Screen module for display and cursor information
export const Screen = {
	/**
	 * Get the primary display
	 * @returns Display object for the primary monitor
	 */
	getPrimaryDisplay: (): Display => {
		const jsonStr = native ? native_.symbols.getPrimaryDisplay() : null;
		if (!jsonStr) {
			return {
				id: 0,
				bounds: { x: 0, y: 0, width: 0, height: 0 },
				workArea: { x: 0, y: 0, width: 0, height: 0 },
				scaleFactor: 1,
				isPrimary: true
			};
		}
		try {
			return JSON.parse(jsonStr.toString());
		} catch {
			return {
				id: 0,
				bounds: { x: 0, y: 0, width: 0, height: 0 },
				workArea: { x: 0, y: 0, width: 0, height: 0 },
				scaleFactor: 1,
				isPrimary: true
			};
		}
	},

	/**
	 * Get all connected displays
	 * @returns Array of Display objects
	 */
	getAllDisplays: (): Display[] => {
		const jsonStr = native ? native_.symbols.getAllDisplays() : null;
		if (!jsonStr) {
			return [];
		}
		try {
			return JSON.parse(jsonStr.toString());
		} catch {
			return [];
		}
	},

	/**
	 * Get the current cursor position in screen coordinates
	 * @returns Point with x and y coordinates
	 */
	getCursorScreenPoint: (): Point => {
		const jsonStr = native ? native_.symbols.getCursorScreenPoint() : null;
		if (!jsonStr) {
			return { x: 0, y: 0 };
		}
		try {
			return JSON.parse(jsonStr.toString());
		} catch {
			return { x: 0, y: 0 };
		}
	},

	/**
	 * Get current mouse button bitmask (bit 0 = left, bit 1 = right, bit 2 = middle)
	 */
	getMouseButtons: (): bigint => {
		try {
			return native ? native_.symbols.getMouseButtons() : BigInt(0);
		} catch {
			return 0n;
		}
	},

	/**
	 * Check whether the app has Screen Recording permission (macOS only).
	 * @returns true if permission is granted, false otherwise
	 */
	hasScreenRecordingPermission: (): boolean => {
		return ffi.request.hasScreenRecordingPermission();
	},

	/**
	 * Prompt the user to grant Screen Recording permission (macOS only).
	 * Opens System Settings to the Screen Recording pane.
	 * @returns true if already granted, false if the prompt was shown
	 */
	requestScreenRecordingPermission: (): boolean => {
		return ffi.request.requestScreenRecordingPermission();
	},

	/**
	 * Check a macOS permission used by app flows.
	 */
	getMacPermissionStatus: (kind: MacPermissionKind): boolean => {
		return ffi.request.macPermissionStatus({ kind });
	},

	/**
	 * Open the matching System Settings pane and show a native draggable app guide.
	 */
	requestMacPermissionDragGuide: (
		kind: MacPermissionKind,
		appName = "Cachy",
		forceGuide = false
	): MacPermissionDragGuideResult => {
		return ffi.request.requestMacPermissionDragGuide({ kind, appName, forceGuide });
	},

	/**
	 * Request macOS Camera or Microphone access using the native system prompt.
	 */
	requestMacMediaPermission: (kind: "camera" | "microphone"): boolean => {
		return ffi.request.requestMacMediaPermission({ kind });
	},

	/**
	 * Close the native draggable permission guide panel if it is visible.
	 */
	closeMacPermissionDragGuide: (): void => {
		ffi.request.closeMacPermissionDragGuide();
	},

	/**
	 * Request a one-shot native location fix through CoreLocation.
	 */
	getCurrentLocation: (timeoutSeconds = 8): CurrentLocationResult => {
		return ffi.request.getCurrentLocation({ timeoutSeconds });
	},

	/**
	 * Capture the screen as PNG, optionally excluding a window by its ID.
	 * Uses CGWindowListCreateImageFromArray to composite all on-screen windows
	 * minus the excluded one. Captures the full virtual desktop across displays.
	 * @param excludeWinId - Electrobun window ID to exclude, or null for full capture
	 * @returns PNG data as Uint8Array, or null on failure
	 */
	captureScreen: (excludeWinId: number | null = null): Uint8Array | null => {
		return ffi.request.captureScreenExcludingWindow({ winId: excludeWinId });
	},

	/**
	 * List all on-screen windows (normal layer only).
	 * @returns Array of on-screen window metadata where id is the native window id.
	 */
	getWindowList: (): OnScreenWindowInfo[] => {
		const json = ffi.request.getOnScreenWindowList();
		if (!json) return [];
		try {
			return JSON.parse(json);
		} catch {
			return [];
		}
	},

	/**
	 * Capture a specific window by its CGWindowID.
	 * @param cgWindowId - The CGWindowID to capture
	 * @returns PNG data as Uint8Array, or null on failure
	 */
	captureWindow: (cgWindowId: number): Uint8Array | null => {
		return ffi.request.captureWindowById({ windowId: cgWindowId });
	},

	/**
	 * List all connected displays.
	 * @returns Array of Display objects with bounds, workArea, scaleFactor
	 */
	listScreens: (): Display[] => {
		const jsonStr = native_.symbols.getAllDisplays();
		if (!jsonStr) return [];
		try {
			return JSON.parse(jsonStr.toString());
		} catch {
			return [];
		}
	}
};

// Types for Session/Cookie API
export interface Cookie {
	name: string;
	value: string;
	domain?: string;
	path?: string;
	secure?: boolean;
	httpOnly?: boolean;
	sameSite?: "no_restriction" | "lax" | "strict";
	expirationDate?: number; // Unix timestamp in seconds
}

export interface CookieFilter {
	url?: string;
	name?: string;
	domain?: string;
	path?: string;
	secure?: boolean;
	session?: boolean;
}

export type StorageType =
	| "cookies"
	| "localStorage"
	| "sessionStorage"
	| "indexedDB"
	| "webSQL"
	| "cache"
	| "all";

// Cookies API for a session
class SessionCookies {
	private partitionId: string;

	constructor(partitionId: string) {
		this.partitionId = partitionId;
	}

	/**
	 * Get cookies matching the filter criteria
	 * @param filter - Optional filter to match cookies
	 * @returns Array of matching cookies
	 */
	get(filter?: CookieFilter): Cookie[] {
		const filterJson = JSON.stringify(filter || {});
		const result = native_.symbols.sessionGetCookies(
			toCString(this.partitionId),
			toCString(filterJson)
		);
		if (!result) return [];
		try {
			return JSON.parse(result.toString());
		} catch {
			return [];
		}
	}

	/**
	 * Set a cookie
	 * @param cookie - The cookie to set
	 * @returns true if the cookie was set successfully
	 */
	set(cookie: Cookie): boolean {
		const cookieJson = JSON.stringify(cookie);
		return native_.symbols.sessionSetCookie(toCString(this.partitionId), toCString(cookieJson));
	}

	/**
	 * Remove a specific cookie
	 * @param url - The URL associated with the cookie
	 * @param name - The name of the cookie
	 * @returns true if the cookie was removed successfully
	 */
	remove(url: string, name: string): boolean {
		return native_.symbols.sessionRemoveCookie(
			toCString(this.partitionId),
			toCString(url),
			toCString(name)
		);
	}

	/**
	 * Clear all cookies for this session
	 */
	clear(): void {
		native_.symbols.sessionClearCookies(toCString(this.partitionId));
	}
}

// Session class representing a storage partition
class SessionInstance {
	readonly partition: string;
	readonly cookies: SessionCookies;

	constructor(partition: string) {
		this.partition = partition;
		this.cookies = new SessionCookies(partition);
	}

	/**
	 * Clear storage data for this session
	 * @param types - Array of storage types to clear, or 'all' to clear everything
	 */
	clearStorageData(types: StorageType[] | "all" = "all"): void {
		const typesArray = types === "all" ? ["all"] : types;
		native_.symbols.sessionClearStorageData(
			toCString(this.partition),
			toCString(JSON.stringify(typesArray))
		);
	}
}

// Cache of session instances
const sessionCache = new Map<string, SessionInstance>();

// Session module for storage/cookie management
export const Session = {
	/**
	 * Get or create a session for a given partition
	 * @param partition - The partition identifier (e.g., "persist:myapp" or "ephemeral")
	 * @returns Session instance for the partition
	 */
	fromPartition: (partition: string): SessionInstance => {
		let session = sessionCache.get(partition);
		if (!session) {
			session = new SessionInstance(partition);
			sessionCache.set(partition, session);
		}
		return session;
	},

	/**
	 * Get the default session (persist:default partition)
	 */
	get defaultSession(): SessionInstance {
		return Session.fromPartition("persist:default");
	}
};

// DEPRECATED: This callback is no longer used for navigation decisions.
// Navigation rules are now stored in native code and evaluated synchronously
// without calling back to Bun. Use webview.setNavigationRules() instead.
// This callback is kept for FFI signature compatibility but is not called.
const webviewDecideNavigation = new JSCallback(
	(_webviewId, _url) => {
		return true;
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.u32,
		threadsafe: true
	}
);

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isBrowserPermissionType(value: unknown): value is BrowserPermissionType {
	switch (value) {
		case "camera":
		case "microphone":
		case "geolocation":
		case "notifications":
		case "midi":
		case "clipboardRead":
		case "clipboardWrite":
		case "screen":
		case "midiSysex":
		case "topLevelStorageAccess":
		case "storageAccess":
		case "diskQuota":
		case "localFonts":
		case "handTracking":
		case "identityProvider":
		case "idleDetection":
		case "multipleDownloads":
		case "keyboardLock":
		case "pointerLock":
		case "protectedMediaIdentifier":
		case "registerProtocolHandler":
		case "vrSession":
		case "webAppInstallation":
		case "windowManagement":
		case "fileSystemAccess":
		case "localNetwork":
		case "loopbackNetwork":
		case "arSession":
		case "sensors":
		case "localNetworkAccess":
		case "other":
			return true;
	}
	return false;
}

function parseBrowserPermissionType(value: unknown): BrowserPermissionType | null {
	if (typeof value !== "string") return null;
	if (isBrowserPermissionType(value)) return value;
	return value.length > 0 ? "other" : null;
}

function readPermissionTypes(value: unknown): BrowserPermissionType[] | null {
	if (!Array.isArray(value)) return null;
	const types: BrowserPermissionType[] = [];
	const seen = new Set<BrowserPermissionType>();
	for (const item of value) {
		const parsed = parseBrowserPermissionType(item);
		if (!parsed || seen.has(parsed)) continue;
		types.push(parsed);
		seen.add(parsed);
	}
	return types.length > 0 ? types : null;
}

function readPermissionPlatform(value: unknown): BrowserPermissionPlatform | null {
	if (value === "macos" || value === "windows" || value === "linux") return value;
	return null;
}

function parsePermissionRequestDetail(detail: string): BrowserPermissionRequestDetail | null {
	let raw: unknown;
	try {
		raw = JSON.parse(detail);
	} catch {
		return null;
	}
	if (!isRecord(raw)) return null;
	const requestId = raw["requestId"];
	const webviewId = raw["webviewId"];
	const origin = raw["origin"];
	const pageUrl = raw["pageUrl"];
	const frameUrl = raw["frameUrl"];
	const permissionTypes = readPermissionTypes(raw["permissionTypes"]);
	const platform = readPermissionPlatform(raw["platform"]);
	if (
		typeof requestId !== "string" ||
		typeof webviewId !== "number" ||
		typeof origin !== "string" ||
		typeof pageUrl !== "string" ||
		typeof frameUrl !== "string" ||
		!permissionTypes ||
		!platform
	) {
		return null;
	}
	return {
		requestId,
		webviewId,
		origin,
		pageUrl,
		frameUrl,
		permissionTypes,
		platform
	};
}

type PermissionDecision = "allowOnce" | "allow" | "block";

function parsePermissionDecision(value: unknown): PermissionDecision | null {
	if (value === "allowOnce" || value === "allow" || value === "block") return value;
	return null;
}

function parsePermissionDecidedDetail(
	detail: string
): { requestId: string; decision: PermissionDecision } | null {
	const raw = parseJsonObject(detail);
	if (!raw) return null;
	const requestId = raw["requestId"];
	const decision = parsePermissionDecision(raw["decision"]);
	if (typeof requestId !== "string" || !decision) return null;
	return { requestId, decision };
}

function parseJsonObject(detail: string): Record<string, unknown> | null {
	try {
		const raw: unknown = JSON.parse(detail);
		return isRecord(raw) ? raw : null;
	} catch {
		return null;
	}
}

function optionalBooleanField(record: Record<string, unknown>, key: string): boolean | undefined {
	const value = record[key];
	return typeof value === "boolean" ? value : undefined;
}

function optionalNumberField(record: Record<string, unknown>, key: string): number | undefined {
	const value = record[key];
	return typeof value === "number" ? value : undefined;
}

function optionalStringField(record: Record<string, unknown>, key: string): string | undefined {
	const value = record[key];
	return typeof value === "string" ? value : undefined;
}

function optionalStringOrNumberField(
	record: Record<string, unknown>,
	key: string
): string | number | undefined {
	const value = record[key];
	if (typeof value === "string" || typeof value === "number") return value;
	return undefined;
}

function optionalFiniteNumberField(
	record: Record<string, unknown>,
	key: string
): number | undefined {
	const value = record[key];
	return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function optionalByteField(record: Record<string, unknown>, key: string): number | undefined {
	const value = optionalFiniteNumberField(record, key);
	return value !== undefined && value >= 0 ? value : undefined;
}

function optionalProgressField(record: Record<string, unknown>, key: string): number | undefined {
	const value = optionalFiniteNumberField(record, key);
	if (value === undefined || value < 0) return undefined;
	return value > 100 ? 100 : value;
}

function optionalNonEmptyStringField(
	record: Record<string, unknown>,
	key: string
): string | undefined {
	const value = optionalStringField(record, key);
	return value && value.length > 0 ? value : undefined;
}

function readDownloadEventId(record: Record<string, unknown>): string | null {
	const idValue = record["downloadId"] ?? record["id"];
	if (typeof idValue === "string" && idValue.length > 0) return idValue;
	if (typeof idValue === "number" && Number.isFinite(idValue)) return String(idValue);
	return null;
}

function parseDownloadEventDetail(detail: string): BrowserDownloadEventDetail | null {
	const raw = parseJsonObject(detail);
	if (!raw) return null;

	const id = readDownloadEventId(raw);
	if (!id) return null;

	const downloadId = optionalStringOrNumberField(raw, "downloadId");
	const filename =
		optionalNonEmptyStringField(raw, "filename") ??
		optionalNonEmptyStringField(raw, "suggestedFilename");
	const path =
		optionalNonEmptyStringField(raw, "path") ??
		optionalNonEmptyStringField(raw, "destinationPath") ??
		optionalNonEmptyStringField(raw, "fullPath");
	const destinationPath = optionalNonEmptyStringField(raw, "destinationPath") ?? path;
	const sourceUrl =
		optionalNonEmptyStringField(raw, "sourceUrl") ??
		optionalNonEmptyStringField(raw, "url") ??
		optionalNonEmptyStringField(raw, "originalUrl");
	const url = optionalNonEmptyStringField(raw, "url") ?? sourceUrl;
	const originalUrl = optionalNonEmptyStringField(raw, "originalUrl") ?? sourceUrl;
	const mimeType = optionalNonEmptyStringField(raw, "mimeType");
	const totalBytes =
		optionalByteField(raw, "totalBytes") ?? optionalByteField(raw, "expectedBytes");
	const receivedBytes =
		optionalByteField(raw, "receivedBytes") ?? optionalByteField(raw, "completedBytes");
	const progress =
		optionalProgressField(raw, "progress") ?? optionalProgressField(raw, "percentComplete");
	const percentComplete = optionalProgressField(raw, "percentComplete") ?? progress;
	const canResume = optionalBooleanField(raw, "canResume");
	const error =
		optionalNonEmptyStringField(raw, "error") ?? optionalNonEmptyStringField(raw, "errorMessage");
	const errorMessage = optionalNonEmptyStringField(raw, "errorMessage") ?? error;
	const errorCode = optionalStringOrNumberField(raw, "errorCode");
	const errorDomain = optionalNonEmptyStringField(raw, "errorDomain");

	const parsed: BrowserDownloadEventDetail = { id };
	if (downloadId !== undefined) parsed.downloadId = downloadId;
	if (filename !== undefined) parsed.filename = filename;
	if (path !== undefined) parsed.path = path;
	if (destinationPath !== undefined) parsed.destinationPath = destinationPath;
	if (url !== undefined) parsed.url = url;
	if (sourceUrl !== undefined) parsed.sourceUrl = sourceUrl;
	if (originalUrl !== undefined) parsed.originalUrl = originalUrl;
	if (mimeType !== undefined) parsed.mimeType = mimeType;
	if (totalBytes !== undefined) parsed.totalBytes = totalBytes;
	if (receivedBytes !== undefined) parsed.receivedBytes = receivedBytes;
	if (percentComplete !== undefined) parsed.percentComplete = percentComplete;
	if (progress !== undefined) parsed.progress = progress;
	if (canResume !== undefined) parsed.canResume = canResume;
	if (error !== undefined) parsed.error = error;
	if (errorMessage !== undefined) parsed.errorMessage = errorMessage;
	if (errorCode !== undefined) parsed.errorCode = errorCode;
	if (errorDomain !== undefined) parsed.errorDomain = errorDomain;
	return parsed;
}

function createDownloadEvent(
	eventName:
		| "download-started"
		| "download-progress"
		| "download-completed"
		| "download-failed"
		| "download-canceled",
	detail: string
): ElectrobunEvent<unknown, unknown> | null {
	const parsed = parseDownloadEventDetail(detail);
	if (!parsed) return null;

	switch (eventName) {
		case "download-started":
			return electrobunEventEmitter.events.webview.downloadStarted({ detail: parsed });
		case "download-progress":
			return electrobunEventEmitter.events.webview.downloadProgress({ detail: parsed });
		case "download-completed":
			return electrobunEventEmitter.events.webview.downloadCompleted({ detail: parsed });
		case "download-failed":
			return electrobunEventEmitter.events.webview.downloadFailed({ detail: parsed });
		case "download-canceled":
			return electrobunEventEmitter.events.webview.downloadCanceled({ detail: parsed });
	}
}

function createNewWindowOpenEvent(detail: string): ElectrobunEvent<unknown, unknown> | null {
	const raw = parseJsonObject(detail);
	const url = raw?.["url"];
	if (!raw || typeof url !== "string") {
		return electrobunEventEmitter.events.webview.newWindowOpen({ detail });
	}

	const rawIsCmdClick = raw["isCmdClick"];
	const isCmdClick = typeof rawIsCmdClick === "boolean" ? rawIsCmdClick : false;
	return electrobunEventEmitter.events.webview.newWindowOpen({
		detail: {
			url,
			isCmdClick,
			modifierFlags: optionalNumberField(raw, "modifierFlags"),
			navigationType: optionalStringOrNumberField(raw, "navigationType"),
			isUserGesture: optionalBooleanField(raw, "isUserGesture"),
			targetFrame: optionalStringField(raw, "targetFrame"),
			button: optionalNumberField(raw, "button"),
			targetDisposition: optionalNumberField(raw, "targetDisposition"),
			userGesture: optionalBooleanField(raw, "userGesture")
		}
	});
}

function createWebviewEvent(
	eventName: string,
	detail: string
): ElectrobunEvent<unknown, unknown> | null {
	switch (eventName) {
		case "will-navigate":
			return electrobunEventEmitter.events.webview.willNavigate({ detail });
		case "did-navigate":
			return electrobunEventEmitter.events.webview.didNavigate({ detail });
		case "did-navigate-in-page":
			return electrobunEventEmitter.events.webview.didNavigateInPage({ detail });
		case "did-commit-navigation":
			return electrobunEventEmitter.events.webview.didCommitNavigation({ detail });
		case "dom-ready":
			return electrobunEventEmitter.events.webview.domReady({ detail });
		case "new-window-open":
			return createNewWindowOpenEvent(detail);
		case "host-message":
			return electrobunEventEmitter.events.webview.hostMessage({ detail });
		case "download-started":
			return createDownloadEvent("download-started", detail);
		case "download-progress":
			return createDownloadEvent("download-progress", detail);
		case "download-completed":
			return createDownloadEvent("download-completed", detail);
		case "download-failed":
			return createDownloadEvent("download-failed", detail);
		case "download-canceled":
			return createDownloadEvent("download-canceled", detail);
		case "page-title-updated":
			return electrobunEventEmitter.events.webview.pageTitleUpdated({ detail });
		case "favicon-updated":
			return electrobunEventEmitter.events.webview.faviconUpdated({ detail });
		case "permission-requested": {
			const permissionDetail = parsePermissionRequestDetail(detail);
			if (!permissionDetail) return null;
			return electrobunEventEmitter.events.webview.permissionRequested({
				detail: permissionDetail
			});
		}
		case "permission-decided": {
			const permissionDecided = parsePermissionDecidedDetail(detail);
			if (!permissionDecided) return null;
			return electrobunEventEmitter.events.webview.permissionDecided({
				detail: permissionDecided
			});
		}
		default:
			return null;
	}
}

function downloadEventDetailForHostWebview(eventName: string, detail: string): string | null {
	switch (eventName) {
		case "download-started":
		case "download-progress":
		case "download-completed":
		case "download-failed":
		case "download-canceled": {
			const parsed = parseDownloadEventDetail(detail);
			if (!parsed) return null;
			const json = JSON.stringify(parsed);
			return typeof json === "string" ? json : null;
		}
		default:
			return null;
	}
}

const webviewEventHandler = (id: number, eventName: string, detail: string): number => {
	const webview = BrowserView.getById(id);
	if (!webview) {
		console.error("[webviewEventHandler] No webview found for id:", id);
		return 0;
	}

	if (webview.hostWebviewId) {
		const hostWebview = BrowserView.getById(webview.hostWebviewId);

		if (!hostWebview) {
			console.error("[webviewEventHandler] No webview found for id:", id);
			return 0;
		}

		// This is a webviewtag so we should send the event into the parent as well
		// NOTE: for new-window-open and host-message the detail is a json string that needs to be parsed
		let js;
		const downloadDetail = downloadEventDetailForHostWebview(eventName, detail);
		if (downloadDetail) {
			js = `document.querySelector('#electrobun-webview-${id}').emit(${JSON.stringify(eventName)}, ${downloadDetail});`;
		} else if (
			eventName === "new-window-open" ||
			eventName === "host-message" ||
			eventName === "permission-requested" ||
			eventName === "permission-decided"
		) {
			// detail is already a JSON string that will be parsed as a JS object
			js = `document.querySelector('#electrobun-webview-${id}').emit(${JSON.stringify(eventName)}, ${detail});`;
		} else {
			js = `document.querySelector('#electrobun-webview-${id}').emit(${JSON.stringify(eventName)}, ${JSON.stringify(detail)});`;
		}

		native_.symbols.evaluateJavaScriptWithNoCompletion(hostWebview.ptr, toCString(js));
	}

	const event = createWebviewEvent(eventName, detail);
	if (!event) return 0;

	const hadListeners =
		electrobunEventEmitter.listenerCount(event.name) +
			electrobunEventEmitter.listenerCount(`${event.name}-${id}`) >
		0;

	// global event
	electrobunEventEmitter.emitEvent(event);
	electrobunEventEmitter.emitEvent(event, id);
	return hadListeners ? 1 : 0;
};

const webviewEventJSCallback = new JSCallback(
	(id, _eventName, _detail) => {
		let eventName = "";
		let detail = "";

		try {
			// Convert cstring pointers to actual strings
			eventName = new CString(_eventName).toString();
			detail = new CString(_detail).toString();
		} catch (err) {
			console.error("[webviewEventJSCallback] Error converting strings:", err);
			console.error("[webviewEventJSCallback] Raw values:", {
				_eventName,
				_detail
			});
			return 0;
		}

		try {
			return webviewEventHandler(id, eventName, detail);
		} catch (err) {
			console.error("[webviewEventJSCallback] Error handling event:", {
				eventName,
				err
			});
		}
		return 0;
	},
	{
		args: [FFIType.u32, FFIType.cstring, FFIType.cstring],
		returns: FFIType.u32,
		threadsafe: true
	}
);

const bunBridgePostmessageHandler = new JSCallback(
	(id, msg) => {
		try {
			const msgStr = new CString(msg);

			if (!msgStr.length) {
				return;
			}
			const rawMessage = msgStr.toString().trim();
			if (!rawMessage || (rawMessage[0] !== "{" && rawMessage[0] !== "[")) {
				return;
			}
			const msgJson = JSON.parse(rawMessage);

			const webview = BrowserView.getById(id);
			if (!webview) return;

			webview.rpcHandler?.(msgJson);
		} catch (err) {
			console.error("error sending message to bun: ", err);
		}
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.void,
		threadsafe: true
	}
);

// internalRPC (bun <-> browser internal stuff)
// BrowserView.rpc (user defined bun <-> browser rpc unique to each webview)
// nativeRPC (internal bun <-> native rpc)

// eventBridgeHandler: handles ONLY webview events (dom-ready, navigation, etc.)
// This is available on ALL webviews including sandboxed ones.
// It cannot process RPC requests - only event emission.
const eventBridgeHandler = new JSCallback(
	(_id: number, msg: number) => {
		try {
			const message = new CString(msg as unknown as Pointer);
			const rawMessage = message.toString().trim();
			if (!rawMessage || (rawMessage[0] !== "{" && rawMessage[0] !== "[")) {
				return;
			}
			const jsonMessage = JSON.parse(rawMessage);

			// Only handle webviewEvent messages - no RPC
			if (jsonMessage.id === "webviewEvent") {
				const { payload } = jsonMessage;
				webviewEventHandler(payload.id, payload.eventName, payload.detail);
			}
			// Silently ignore any other message types - sandboxed webviews shouldn't send them
		} catch (err) {
			console.error("error in eventBridgeHandler: ", err);
		}
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.void,
		threadsafe: true
	}
);

// internalBridgeHandler: handles internal RPC (webview tags, drag regions, etc.)
// This is only available on trusted (non-sandboxed) webviews.
const internalBridgeHandler = new JSCallback(
	(_id: number, msg: number) => {
		try {
			const batchMessage = new CString(msg as unknown as Pointer);
			const jsonBatch = JSON.parse(batchMessage.toString());

			if (jsonBatch.id === "webviewEvent") {
				// Note: Some WebviewEvents from inside the webview are routed through here
				// Others call the JSCallback directly from native code.
				const { payload } = jsonBatch;
				webviewEventHandler(payload.id, payload.eventName, payload.detail);
				return;
			}

			jsonBatch.forEach((msgStr: string) => {
				// if (!msgStr.length) {
				//   console.error('WEBVIEW EVENT SENT TO WEBVIEW TAG BRIDGE HANDLER?', )
				//   return;
				// }
				const msgJson = JSON.parse(msgStr);

				if (msgJson.type === "message") {
					const handler = (
						internalRpcHandlers.message as Record<string, (params: unknown) => void>
					)[msgJson.id];
					handler?.(msgJson.payload);
				} else if (msgJson.type === "request") {
					const hostWebview = BrowserView.getById(msgJson.hostWebviewId);
					// const targetWebview = BrowserView.getById(msgJson.params.params.hostWebviewId);
					const handler = (
						internalRpcHandlers.request as Record<string, (params: unknown) => unknown>
					)[msgJson.method];

					const payload = handler?.(msgJson.params);

					const resultObj = {
						type: "response",
						id: msgJson.id,
						success: true,
						payload
					};

					if (!hostWebview) {
						console.log("--->>> internal request in bun: NO HOST WEBVIEW FOUND");
						return;
					}

					hostWebview.sendInternalMessageViaExecute(resultObj);
				}
			});
		} catch (err) {
			console.error("error in internalBridgeHandler: ", err);
			// console.log('msgStr: ', id, new CString(msg));
		}
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.void,
		threadsafe: true
	}
);

const trayItemHandler = new JSCallback(
	(id, action) => {
		// Note: Some invisible character that doesn't appear in .length
		// is causing issues
		const actionString = (new CString(action).toString() || "").trim();

		// Use shared deserialization method
		const { action: actualAction, data } = deserializeMenuAction(actionString);

		const event = electrobunEventEmitter.events.tray.trayClicked({
			id,
			action: actualAction,
			data // Always include data property (undefined if no data)
		});

		// global event
		electrobunEventEmitter.emitEvent(event);
		electrobunEventEmitter.emitEvent(event, id);
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.void,
		threadsafe: true
	}
);

const applicationMenuHandler = new JSCallback(
	(id, action) => {
		const actionString = new CString(action).toString();

		// Use shared deserialization method
		const { action: actualAction, data } = deserializeMenuAction(actionString);

		const event = electrobunEventEmitter.events.app.applicationMenuClicked({
			id,
			action: actualAction,
			data // Always include data property (undefined if no data)
		});

		// global event
		electrobunEventEmitter.emitEvent(event);
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.void,
		threadsafe: true
	}
);

const contextMenuHandler = new JSCallback(
	(_id, action) => {
		const actionString = new CString(action).toString();

		// Use shared deserialization method
		const { action: actualAction, data } = deserializeMenuAction(actionString);

		const event = electrobunEventEmitter.events.app.contextMenuClicked({
			action: actualAction,
			data // Always include data property (undefined if no data)
		});

		electrobunEventEmitter.emitEvent(event);
	},
	{
		args: [FFIType.u32, FFIType.cstring],
		returns: FFIType.void,
		threadsafe: true
	}
);

// Note: When passed over FFI JS will GC the buffer/pointer. Make sure to use strdup() or something
// on the c side to duplicate the string so objc/c++ gc can own it
export function toCString(jsString: string, addNullTerminator: boolean = true): CString {
	let appendWith = "";

	if (addNullTerminator && !jsString.endsWith("\0")) {
		appendWith = "\0";
	}
	const buff = Buffer.from(jsString + appendWith, "utf8");

	// @ts-ignore - This is valid in Bun
	return ptr(buff);
}

type WebviewTagInitParams = {
	url: string | null;
	html: string | null;
	preload: string | null;
	renderer: "native" | "cef";
	partition: string | null;
	frame: { x: number; y: number; width: number; height: number };
	hostWebviewId: number;
	windowId: number;
	navigationRules: string | null;
	sandbox: boolean;
	transparent: boolean;
	passthrough: boolean;
};

type WgpuTagInitParams = {
	windowId: number;
	frame: { x: number; y: number; width: number; height: number };
	transparent: boolean;
	passthrough: boolean;
};

export const internalRpcHandlers = {
	request: {
		// todo: this shouldn't be getting method, just params.
		webviewTagInit: (params: WebviewTagInitParams) => {
			const {
				hostWebviewId,
				windowId,
				renderer,
				html,
				preload,
				partition,
				frame,
				navigationRules,
				sandbox,
				transparent,
				passthrough
			} = params;

			const url = !params.url && !html ? "https://electrobun.dev" : params.url;

			const webviewForTag = new BrowserView({
				url,
				html,
				preload,
				partition,
				frame,
				hostWebviewId,
				autoResize: false,
				windowId,
				renderer, //: "cef",
				navigationRules,
				sandbox,
				startTransparent: transparent,
				startPassthrough: passthrough
			});

			return webviewForTag.id;
		},
		wgpuTagInit: (params: WgpuTagInitParams) => {
			const { windowId, frame, transparent, passthrough } = params;

			const viewForTag = new WGPUView({
				windowId,
				frame,
				autoResize: false,
				startTransparent: transparent,
				startPassthrough: passthrough
			});

			return viewForTag.id;
		},
		webviewTagCanGoBack: (params: { id: number }) => {
			const { id } = params;
			const webviewPtr = BrowserView.getById(id)?.ptr;
			if (!webviewPtr) {
				console.error("no webview ptr");
				return false;
			}

			return native_.symbols.webviewCanGoBack(webviewPtr);
		},
		webviewTagCanGoForward: (params: { id: number }) => {
			const { id } = params;
			const webviewPtr = BrowserView.getById(id)?.ptr;
			if (!webviewPtr) {
				console.error("no webview ptr");
				return false;
			}

			return native_.symbols.webviewCanGoForward(webviewPtr);
		}
	},
	message: {
		webviewTagResize: (params: {
			id: number;
			frame: { x: number; y: number; width: number; height: number };
			masks: string;
		}) => {
			const browserView = BrowserView.getById(params.id);
			const webviewPtr = browserView?.ptr;

			if (!webviewPtr) {
				console.log("[Bun] ERROR: webviewTagResize - no webview ptr found for id:", params.id);
				return;
			}

			const { x, y, width, height } = params.frame;
			native_.symbols.resizeWebview(webviewPtr, x, y, width, height, toCString(params.masks));
		},
		wgpuTagResize: (params: {
			id: number;
			frame: { x: number; y: number; width: number; height: number };
			masks: string;
		}) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuTagResize: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}

			const { x, y, width, height } = params.frame;
			native_.symbols.resizeWebview(view.ptr, x, y, width, height, toCString(params.masks ?? "[]"));
		},
		webviewTagUpdateSrc: (params: { id: number; url: string }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagUpdateSrc: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.loadURLInWebView(webview.ptr, toCString(params.url));
		},
		webviewTagUpdateHtml: (params: { id: number; html: string }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagUpdateHtml: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}

			// Store HTML content in native map for scheme handlers
			native_.symbols.setWebviewHTMLContent(webview.id, toCString(params.html));

			webview.loadHTML(params.html);
			webview.html = params.html;
		},
		webviewTagUpdatePreload: (params: { id: number; preload: string }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagUpdatePreload: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.updatePreloadScriptToWebView(
				webview.ptr,
				toCString("electrobun_custom_preload_script"),
				toCString(params.preload),
				true
			);
		},
		webviewTagGoBack: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(`webviewTagGoBack: BrowserView not found or has no ptr for id ${params.id}`);
				return;
			}
			native_.symbols.webviewGoBack(webview.ptr);
		},
		webviewTagGoForward: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagGoForward: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewGoForward(webview.ptr);
		},
		webviewTagReload: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(`webviewTagReload: BrowserView not found or has no ptr for id ${params.id}`);
				return;
			}
			native_.symbols.webviewReload(webview.ptr);
		},
		webviewTagRemove: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(`webviewTagRemove: BrowserView not found or has no ptr for id ${params.id}`);
				return;
			}
			webview.remove();
		},
		startWindowMove: (params: { id: number }) => {
			const windowPtr = getWindowPtr(params.id);
			if (!windowPtr) return;
			native_.symbols.startWindowMove(windowPtr);
		},
		stopWindowMove: (_params: unknown) => {
			native_.symbols.stopWindowMove();
		},
		webviewTagSetTransparent: (params: { id: number; transparent: boolean }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagSetTransparent: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewSetTransparent(webview.ptr, params.transparent);
		},
		wgpuTagSetTransparent: (params: { id: number; transparent: boolean }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(
					`wgpuTagSetTransparent: WGPUView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.wgpuViewSetTransparent(view.ptr, params.transparent);
		},
		webviewTagSetPassthrough: (params: { id: number; enablePassthrough: boolean }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagSetPassthrough: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewSetPassthrough(webview.ptr, params.enablePassthrough);
		},
		wgpuTagSetPassthrough: (params: { id: number; passthrough: boolean }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(
					`wgpuTagSetPassthrough: WGPUView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.wgpuViewSetPassthrough(view.ptr, params.passthrough);
		},
		webviewTagSetHidden: (params: { id: number; hidden: boolean }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagSetHidden: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewSetHidden(webview.ptr, params.hidden);
		},
		wgpuTagSetHidden: (params: { id: number; hidden: boolean }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuTagSetHidden: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}
			native_.symbols.wgpuViewSetHidden(view.ptr, params.hidden);
		},
		wgpuTagRemove: (params: { id: number }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuTagRemove: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}
			view.remove();
		},
		wgpuTagRunTest: (params: { id: number }) => {
			const view = WGPUView.getById(params.id);
			if (!view?.ptr) {
				console.error(`wgpuTagRunTest: WGPUView not found or has no ptr for id ${params.id}`);
				return;
			}
			if (!native?.symbols?.wgpuRunGPUTest) {
				console.error("wgpuTagRunTest: wgpuRunGPUTest not available");
				return;
			}
			native_.symbols.wgpuRunGPUTest(view.ptr);
		},
		webviewTagSetNavigationRules: (params: { id: number; rules: string[] }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagSetNavigationRules: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			const rulesJson = JSON.stringify(params.rules);
			native_.symbols.setWebviewNavigationRules(webview.ptr, toCString(rulesJson));
		},
		webviewTagFindInPage: (params: {
			id: number;
			searchText: string;
			forward: boolean;
			matchCase: boolean;
		}) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagFindInPage: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewFindInPage(
				webview.ptr,
				toCString(params.searchText),
				params.forward,
				params.matchCase
			);
		},
		webviewTagStopFind: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagStopFind: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewStopFind(webview.ptr);
		},
		webviewTagOpenDevTools: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagOpenDevTools: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewOpenDevTools(webview.ptr);
		},
		webviewTagCloseDevTools: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagCloseDevTools: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewCloseDevTools(webview.ptr);
		},
		webviewTagToggleDevTools: (params: { id: number }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagToggleDevTools: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.webviewToggleDevTools(webview.ptr);
		},
		webviewTagExecuteJavascript: (params: { id: number; js: string }) => {
			const webview = BrowserView.getById(params.id);
			if (!webview || !webview.ptr) {
				console.error(
					`webviewTagExecuteJavascript: BrowserView not found or has no ptr for id ${params.id}`
				);
				return;
			}
			native_.symbols.evaluateJavaScriptWithNoCompletion(webview.ptr, toCString(params.js));
		},
		webviewEvent: (params: unknown) => {
			console.log("-----------------+webviewEvent", params);
		}
	}
};

// todo: consider renaming to TrayMenuItemConfig
export type MenuItemConfig =
	| { type: "divider" | "separator" }
	| {
			type: "normal";
			label: string;
			tooltip?: string;
			action?: string;
			data?: any;
			submenu?: Array<MenuItemConfig>;
			enabled?: boolean;
			checked?: boolean;
			hidden?: boolean;
	  };

export type ApplicationMenuItemConfig =
	| { type: "divider" | "separator" }
	| {
			type?: "normal";
			label: string;
			tooltip?: string;
			action?: string;
			data?: any;
			submenu?: Array<ApplicationMenuItemConfig>;
			enabled?: boolean;
			checked?: boolean;
			hidden?: boolean;
			accelerator?: string;
	  }
	| {
			type?: "normal";
			label?: string;
			tooltip?: string;
			role?: string;
			data?: any;
			submenu?: Array<ApplicationMenuItemConfig>;
			enabled?: boolean;
			checked?: boolean;
			hidden?: boolean;
			accelerator?: string;
	  };
