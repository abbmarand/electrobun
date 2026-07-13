import { native, toCString, ffi } from "../proc/native";
import * as fs from "fs";
import electrobunEventEmitter from "../events/eventEmitter";
import {
	type ElectrobunRPCSchema,
	type ElectrobunRPCConfig,
	type RPCWithTransport,
	defineElectrobunRPC
} from "../../shared/rpc.js";
import { Updater } from "./Updater";
import { BuildConfig } from "./BuildConfig";
import { rpcPort, sendMessageToWebviewViaSocket, removeSocketForWebview } from "./Socket";
import { randomBytes } from "crypto";
import { type Pointer } from "bun:ffi";
import type ElectrobunEvent from "../events/event";
import type {
	BrowserDownloadEventDetail,
	BrowserPermissionPlatform,
	BrowserPermissionRequestDetail,
	BrowserPermissionType
} from "../events/webviewEvents";

const BrowserViewMap: {
	[id: number]: BrowserView<any>;
} = {};
let nextWebviewId = 1;

export type BrowserViewOptions<T = undefined> = {
	url: string | null;
	html: string | null;
	preload: string | null;
	viewsRoot: string | null;
	renderer: "native" | "cef";
	partition: string | null;
	frame: {
		x: number;
		y: number;
		width: number;
		height: number;
	};
	rpc: T;
	hostWebviewId: number;
	autoResize: boolean;

	windowId: number;
	navigationRules: string | null;
	// Sandbox mode: when true, disables RPC and only allows event emission
	// Use for untrusted content (remote URLs) to prevent malicious sites from
	// accessing internal APIs, creating OOPIFs, or communicating with Bun
	sandbox: boolean;
	// Set transparent on the AbstractView at creation (before first paint)
	startTransparent: boolean;
	// Make the web contents background transparent without hiding the view.
	transparentBackground: boolean;
	// Set passthrough on the AbstractView at creation (before first paint)
	startPassthrough: boolean;
	// Enable native content blocker (ad blocking) for this webview
	contentBlocker: boolean;
	// renderer:
};

const hash = await Updater.localInfo.hash();
const buildConfig = await BuildConfig.get();

const defaultOptions: Partial<BrowserViewOptions> = {
	url: null,
	html: null,
	preload: null,
	viewsRoot: null,
	renderer: buildConfig.defaultRenderer,
	frame: {
		x: 0,
		y: 0,
		width: 800,
		height: 600
	}
};
// Note: we use the build's hash to separate from different apps and different builds
// but we also want a randomId to separate different instances of the same app
const randomId = Math.random().toString(36).substring(7);

export type {
	BrowserDownloadEventDetail,
	BrowserPermissionPlatform,
	BrowserPermissionRequestDetail,
	BrowserPermissionType
};
export type BrowserPermissionResponseDecision = "allowOnce" | "allow" | "block";
export type BrowserViewSavePageFormat = "webarchive" | "pdf";
export type BrowserViewSavePageOptions = {
	suggestedName?: string;
	format?: BrowserViewSavePageFormat;
};
type BrowserViewEventName =
	| "will-navigate"
	| "did-navigate"
	| "did-navigate-in-page"
	| "did-commit-navigation"
	| "dom-ready"
	| "update-target-url"
	| "new-window-open"
	| "host-message"
	| "download-started"
	| "download-progress"
	| "download-completed"
	| "download-failed"
	| "download-canceled"
	| "page-title-updated"
	| "favicon-updated"
	| "permission-requested"
	| "permission-decided";
type BrowserDownloadEventName =
	| "download-started"
	| "download-progress"
	| "download-completed"
	| "download-failed"
	| "download-canceled";
export type BrowserPermissionRequestEvent = ElectrobunEvent<
	{ detail: BrowserPermissionRequestDetail },
	Record<string, never>
>;
type BrowserPermissionDecidedEvent = ElectrobunEvent<
	{
		detail: { requestId: string; decision: BrowserPermissionResponseDecision };
	},
	Record<string, never>
>;
export type BrowserDownloadEvent = ElectrobunEvent<
	{ detail: BrowserDownloadEventDetail },
	Record<string, never>
>;
export type BrowserTargetUrlEvent = ElectrobunEvent<{ detail: string }, Record<string, never>>;
type BrowserViewTypedEventMap = {
	"permission-requested": BrowserPermissionRequestEvent;
	"permission-decided": BrowserPermissionDecidedEvent;
	"update-target-url": BrowserTargetUrlEvent;
};
type BrowserViewEvent<Name extends BrowserViewEventName> =
	Name extends keyof BrowserViewTypedEventMap
		? BrowserViewTypedEventMap[Name]
		: Name extends BrowserDownloadEventName
			? BrowserDownloadEvent
			: unknown;

export class BrowserView<T extends RPCWithTransport = RPCWithTransport> {
	id: number = nextWebviewId++;
	ptr: Pointer | null = null;
	hostWebviewId?: number;
	windowId!: number;
	renderer!: "cef" | "native";
	url: string | null = null;
	html: string | null = null;
	preload: string | null = null;
	viewsRoot: string | null = null;
	partition: string | null = null;
	autoResize: boolean = true;
	frame: {
		x: number;
		y: number;
		width: number;
		height: number;
	} = {
		x: 0,
		y: 0,
		width: 800,
		height: 600
	};
	pipePrefix!: string;
	inStream!: fs.WriteStream;
	outStream!: ReadableStream<Uint8Array>;
	secretKey!: Uint8Array;
	rpc?: T;
	rpcHandler?: (msg: unknown) => void;
	navigationRules: string | null = null;
	// Sandbox mode disables RPC and only allows event emission (for untrusted content)
	sandbox: boolean = false;
	startTransparent: boolean = false;
	transparentBackground: boolean = false;
	startPassthrough: boolean = false;
	contentBlocker: boolean = false;
	isRemoved: boolean = false;

	constructor(options: Partial<BrowserViewOptions<T>> = defaultOptions) {
		// const rpc = options.rpc;

		this.url = options.url || defaultOptions.url || null;
		this.html = options.html || defaultOptions.html || null;
		this.preload = options.preload || defaultOptions.preload || null;
		this.viewsRoot = options.viewsRoot || defaultOptions.viewsRoot || null;
		this.frame = {
			x: options.frame?.x ?? defaultOptions.frame!.x,
			y: options.frame?.y ?? defaultOptions.frame!.y,
			width: options.frame?.width ?? defaultOptions.frame!.width,
			height: options.frame?.height ?? defaultOptions.frame!.height
		};
		this.rpc = options.rpc;
		this.secretKey = new Uint8Array(randomBytes(32));
		this.partition = options.partition || null;
		// todo (yoav): since collisions can crash the app add a function that checks if the
		// file exists first
		this.pipePrefix = `/private/tmp/electrobun_ipc_pipe_${hash}_${randomId}_${this.id}`;
		this.hostWebviewId = options.hostWebviewId;
		this.windowId = options.windowId ?? 0;
		this.autoResize = options.autoResize === false ? false : true;
		this.navigationRules = options.navigationRules || null;
		this.renderer = options.renderer ?? defaultOptions.renderer ?? "native";
		this.sandbox = options.sandbox ?? false;
		this.startTransparent = options.startTransparent ?? false;
		this.transparentBackground = options.transparentBackground ?? false;
		this.startPassthrough = options.startPassthrough ?? false;
		this.contentBlocker = options.contentBlocker ?? false;

		BrowserViewMap[this.id] = this;
		this.ptr = this.init() as Pointer;

		// If HTML content was provided, load it after webview creation.
		if (this.html) {
			setTimeout(() => {
				this.loadHTML(this.html!);
			}, 100);
		}
	}

	init() {
		this.createStreams();

		return ffi.request.createWebview({
			id: this.id,
			windowId: this.windowId,
			renderer: this.renderer,
			rpcPort: rpcPort,
			// todo: consider sending secretKey as base64
			secretKey: this.secretKey.toString(),
			hostWebviewId: this.hostWebviewId || null,
			pipePrefix: this.pipePrefix,
			partition: this.partition,
			// Only pass URL if no HTML content is provided to avoid conflicts
			url: this.html ? null : this.url,
			html: this.html,
			preload: this.preload,
			viewsRoot: this.viewsRoot,
			frame: {
				width: this.frame.width,
				height: this.frame.height,
				x: this.frame.x,
				y: this.frame.y
			},
			autoResize: this.autoResize,
			navigationRules: this.navigationRules,
			sandbox: this.sandbox,
			startTransparent: this.startTransparent,
			transparentBackground: this.transparentBackground,
			startPassthrough: this.startPassthrough,
			contentBlocker: this.contentBlocker
			// transparent is looked up from parent window in native.ts
		});
	}

	createStreams() {
		if (!this.rpc) {
			// eslint-disable-next-line @typescript-eslint/no-explicit-any
			this.rpc = BrowserView.defineRPC({
				handlers: { requests: {}, messages: {} }
			}) as any;
		}

		this.rpc!.setTransport(this.createTransport());
	}

	sendMessageToWebviewViaExecute(jsonMessage: unknown) {
		const stringifiedMessage =
			typeof jsonMessage === "string" ? jsonMessage : JSON.stringify(jsonMessage);
		// todo (yoav): make this a shared const with the browser api
		const wrappedMessage = `window.__electrobun.receiveMessageFromBun(${stringifiedMessage})`;
		this.executeJavascript(wrappedMessage);
	}

	sendInternalMessageViaExecute(jsonMessage: unknown) {
		const stringifiedMessage =
			typeof jsonMessage === "string" ? jsonMessage : JSON.stringify(jsonMessage);
		// todo (yoav): make this a shared const with the browser api
		const wrappedMessage = `window.__electrobun.receiveInternalMessageFromBun(${stringifiedMessage})`;
		this.executeJavascript(wrappedMessage);
	}

	// Note: the OS has a buffer limit on named pipes. If we overflow it
	// it won't trigger the kevent for zig to read the pipe and we'll be stuck.
	// so we have to chunk it
	// TODO: is this still needed after switching from named pipes
	executeJavascript(js: string) {
		if (!this.ptr || this.isRemoved) {
			return;
		}
		ffi.request.evaluateJavascriptWithNoCompletion({ id: this.id, js });
	}

	executeJavascriptSync(js: string): string | null {
		return ffi.request.evaluateJavascriptSync({ id: this.id, js });
	}

	print(): boolean {
		if (!this.ptr || this.isRemoved) {
			return false;
		}
		return ffi.request.printWebview({ id: this.id });
	}

	savePageAs(options: BrowserViewSavePageOptions = {}): boolean {
		if (!this.ptr || this.isRemoved) {
			return false;
		}
		return ffi.request.saveWebviewPageAs({
			id: this.id,
			suggestedName: options.suggestedName ?? "Page",
			format: options.format ?? "webarchive"
		});
	}

	loadURL(url: string) {
		this.url = url;
		native!.symbols.loadURLInWebView(this.ptr, toCString(this.url));
	}

	loadHTML(html: string) {
		this.html = html;

		if (this.renderer === "cef") {
			// For CEF, store HTML content in native map and use scheme handler
			native!.symbols.setWebviewHTMLContent(this.id, toCString(html));
			this.loadURL("views://internal/index.html");
		} else {
			// For WKWebView, load HTML content directly
			native!.symbols.loadHTMLInWebView(this.ptr, toCString(html));
		}
	}

	setFrame(
		frame: { x: number; y: number; width: number; height: number },
		masks: Array<{ x: number; y: number; width: number; height: number }> = []
	) {
		if (!this.ptr || this.isRemoved) {
			return;
		}
		this.frame = {
			x: frame.x,
			y: frame.y,
			width: frame.width,
			height: frame.height
		};
		native!.symbols.resizeWebview(
			this.ptr,
			frame.x,
			frame.y,
			frame.width,
			frame.height,
			toCString(JSON.stringify(masks))
		);
	}

	setHidden(hidden: boolean) {
		if (!this.ptr || this.isRemoved) {
			return;
		}
		native!.symbols.webviewSetHidden(this.ptr, hidden);
	}

	setPassthrough(enablePassthrough: boolean) {
		if (!this.ptr || this.isRemoved) {
			return;
		}
		native!.symbols.webviewSetPassthrough(this.ptr, enablePassthrough);
	}

	setNavigationRules(rules: string[]) {
		this.navigationRules = JSON.stringify(rules);
		const rulesJson = JSON.stringify(rules);
		native!.symbols.setWebviewNavigationRules(this.ptr, toCString(rulesJson));
	}

	setContentBlockerEnabled(enabled: boolean) {
		this.contentBlocker = enabled;
		ffi.request.setContentBlockerEnabled({ id: this.id, enabled });
	}

	setUserAgent(userAgent: string) {
		native!.symbols.setWebviewUserAgent(this.ptr, toCString(userAgent));
	}

	static setAcceptLanguage(lang: string) {
		native!.symbols.setAcceptLanguage(toCString(lang));
	}

	static setAppAppearance(mode: string) {
		native!.symbols.setAppAppearance(toCString(mode));
	}

	findInPage(searchText: string, options?: { forward?: boolean; matchCase?: boolean }) {
		const forward = options?.forward ?? true;
		const matchCase = options?.matchCase ?? false;
		native!.symbols.webviewFindInPage(this.ptr, toCString(searchText), forward, matchCase);
	}

	stopFindInPage() {
		native!.symbols.webviewStopFind(this.ptr);
	}

	openDevTools() {
		native!.symbols.webviewOpenDevTools(this.ptr);
	}

	closeDevTools() {
		native!.symbols.webviewCloseDevTools(this.ptr);
	}

	toggleDevTools() {
		native!.symbols.webviewToggleDevTools(this.ptr);
	}

	/**
	 * Set the page zoom level (WebKit only, similar to browser zoom).
	 * @param zoomLevel - The zoom level (1.0 = 100%, 1.5 = 150%, etc.)
	 */
	setPageZoom(zoomLevel: number) {
		native!.symbols.webviewSetPageZoom(this.ptr, zoomLevel);
	}

	/**
	 * Get the current page zoom level.
	 * @returns The current zoom level (1.0 = 100%)
	 */
	getPageZoom(): number {
		return native!.symbols.webviewGetPageZoom(this.ptr) as number;
	}

	// todo (yoav): move this to a class that also has off, append, prepend, etc.
	// name should only allow browserView events
	// Note: normalize event names to willNavigate instead of ['will-navigate'] to save
	// 5 characters per usage and allow minification to be more effective.
	on<Name extends BrowserViewEventName>(
		name: Name,
		handler: (event: BrowserViewEvent<Name>) => void
	) {
		const specificName = `${name}-${this.id}`;
		electrobunEventEmitter.on(specificName, handler);
	}

	off<Name extends BrowserViewEventName>(
		name: Name,
		handler: (event: BrowserViewEvent<Name>) => void
	) {
		const specificName = `${name}-${this.id}`;
		electrobunEventEmitter.off(specificName, handler);
	}

	static respondToPermissionRequest(
		requestId: string,
		decision: BrowserPermissionResponseDecision
	) {
		native!.symbols.webviewRespondToPermissionRequest(toCString(requestId), toCString(decision));
	}

	respondToPermissionRequest(requestId: string, decision: BrowserPermissionResponseDecision) {
		BrowserView.respondToPermissionRequest(requestId, decision);
	}

	showNativePermissionSheet(
		requestId: string,
		origin: string,
		faviconUrl: string,
		permissionsJson: string
	) {
		if (!this.ptr) return;
		if (!native) return;
		const symbolName: string = "showNativePermissionSheet";
		const showNativePermissionSheet = Reflect.get(native.symbols, symbolName);
		if (typeof showNativePermissionSheet !== "function") return;
		showNativePermissionSheet(
			this.ptr,
			toCString(requestId),
			toCString(origin),
			toCString(faviconUrl),
			toCString(permissionsJson)
		);
	}

	createTransport = () => {
		const that = this;

		return {
			send(message: any) {
				if (!that.ptr || that.isRemoved) {
					return;
				}
				const sentOverSocket = sendMessageToWebviewViaSocket(that.id, message);

				if (!sentOverSocket) {
					try {
						const messageString = JSON.stringify(message);
						that.sendMessageToWebviewViaExecute(messageString);
					} catch (error) {
						console.error("bun: failed to serialize message to webview", error);
					}
				}
			},
			registerHandler(handler: (msg: unknown) => void) {
				if (that.isRemoved) {
					return;
				}
				that.rpcHandler = (msg: unknown) => {
					// Shared RPC instances must answer on the webview that sent the request.
					that.rpc?.setTransport(that.createTransport());
					handler(msg);
				};
			}
		};
	};

	goBack() {
		native!.symbols.webviewGoBack(this.ptr);
	}

	goForward() {
		native!.symbols.webviewGoForward(this.ptr);
	}

	reload() {
		native!.symbols.webviewReload(this.ptr);
	}

	cancelDownload(downloadId: number): boolean {
		if (!this.ptr || this.isRemoved) return false;
		return native!.symbols.webviewCancelDownload(this.ptr, downloadId);
	}

	canGoBack(): boolean {
		return native!.symbols.webviewCanGoBack(this.ptr);
	}

	canGoForward(): boolean {
		return native!.symbols.webviewCanGoForward(this.ptr);
	}

	remove() {
		if (!this.ptr || this.isRemoved) {
			return;
		}
		const ptr = this.ptr;
		this.isRemoved = true;
		// Drop JS-side references first so late callbacks cannot target a stale view.
		delete BrowserViewMap[this.id];
		removeSocketForWebview(this.id);
		this.rpc?.setTransport({
			send() {},
			registerHandler() {},
			unregisterHandler() {}
		});
		this.rpcHandler = undefined;

		this.rpcHandler = undefined;
		this.ptr = null;
		native!.symbols.webviewRemove(ptr);
	}

	static getById(id: number) {
		return BrowserViewMap[id];
	}

	static getAll() {
		return Object.values(BrowserViewMap);
	}

	static defineRPC<Schema extends ElectrobunRPCSchema>(config: ElectrobunRPCConfig<Schema, "bun">) {
		return defineElectrobunRPC("bun", config);
	}
}
