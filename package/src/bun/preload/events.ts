// Shared Event Emission for webview lifecycle events
// Uses __electrobunEventBridge which is available on ALL webviews (including sandboxed)
// Falls back to __electrobunInternalBridge for backwards compatibility until native code
// is updated to include the eventBridge handler
// This is a one-way channel for emitting events to native/bun - no RPC capability

import "./globals.d.ts";

// Emit a webview event to native code
export function emitWebviewEvent(eventName: string, detail: string) {
	// setTimeout works around a race condition with Bun FFI
	setTimeout(() => {
		// Prefer eventBridge (available on all webviews), fall back to internalBridge
		// (for backwards compatibility until native code adds eventBridge handler)
		const bridge = window.__electrobunEventBridge || window.__electrobunInternalBridge;
		bridge?.postMessage(
			JSON.stringify({
				id: "webviewEvent",
				type: "message",
				payload: {
					id: window.__electrobunWebviewId,
					eventName,
					detail
				}
			})
		);
	});
}

// Set up standard lifecycle event listeners
export function initLifecycleEvents() {
	function emitInPageNavigation() {
		emitWebviewEvent("did-navigate-in-page", window.location.href);
	}

	const originalPushState = history.pushState;
	history.pushState = function (
		this: History,
		...args: [data: unknown, unused: string, url?: string | URL | null]
	) {
		const result = originalPushState.apply(this, args);
		emitInPageNavigation();
		return result;
	};

	const originalReplaceState = history.replaceState;
	history.replaceState = function (
		this: History,
		...args: [data: unknown, unused: string, url?: string | URL | null]
	) {
		const result = originalReplaceState.apply(this, args);
		emitInPageNavigation();
		return result;
	};

	// Emit dom-ready when page loads (top-level window only)
	window.addEventListener("load", () => {
		if (window === window.top) {
			emitWebviewEvent("dom-ready", document.location.href);
		}
	});

	// Track in-page navigation
	window.addEventListener("popstate", () => {
		emitInPageNavigation();
	});

	window.addEventListener("hashchange", () => {
		emitInPageNavigation();
	});
}

function getModifierFlags(event: MouseEvent): number {
	let flags = 0;
	if (event.shiftKey) flags |= 1;
	if (event.ctrlKey) flags |= 2;
	if (event.altKey) flags |= 4;
	if (event.metaKey) flags |= 8;
	return flags;
}

function isNativeMacWebKit(): boolean {
	return window.__electrobunPlatform === "darwin" && window.__electrobunRenderer === "native";
}

function closestAnchor(target: EventTarget | null): HTMLAnchorElement | null {
	if (!(target instanceof Element)) return null;
	const anchor = target.closest("a[href]");
	return anchor instanceof HTMLAnchorElement ? anchor : null;
}

function eventTargetElement(event: PointerEvent): Element | null {
	try {
		const path = event.composedPath();
		for (const candidate of path) {
			if (candidate instanceof Element) return candidate;
		}
	} catch {}
	if (event.target instanceof Element) return event.target;
	if (event.target instanceof Node) return event.target.parentElement;
	return null;
}

function rootHost(element: Element): Element | null {
	try {
		const root = element.getRootNode();
		return root instanceof ShadowRoot && root.host instanceof Element ? root.host : null;
	} catch {
		return null;
	}
}

function closestLinkElement(element: Element | null): Element | null {
	let current = element;
	while (current) {
		const tagName = current.tagName;
		if ((tagName === "A" || tagName === "AREA") && current.hasAttribute("href")) {
			return current;
		}
		current = current.parentElement ?? rootHost(current);
	}
	return null;
}

function targetUrl(element: Element | null): string {
	const link = closestLinkElement(element);
	if (!link) return "";
	const href = link.getAttribute("href");
	if (!href) return "";
	try {
		return new URL(href, link.ownerDocument.baseURI).href;
	} catch {
		return "";
	}
}

/**
 * Reports the resolved URL under the pointer without exposing an RPC bridge to
 * the page. The standard preload runs in every frame, so links inside iframes
 * use the same event path as links in the top-level document.
 */
export function initTargetUrlTracking() {
	let currentUrl = "";

	function publish(url: string) {
		if (url === currentUrl) return;
		currentUrl = url;
		emitWebviewEvent("update-target-url", url);
	}

	window.addEventListener(
		"pointerover",
		(event) => {
			publish(targetUrl(eventTargetElement(event)));
		},
		true
	);

	window.addEventListener(
		"pointerout",
		(event) => {
			const related = event.relatedTarget;
			publish(targetUrl(related instanceof Element ? related : null));
		},
		true
	);

	window.addEventListener("blur", () => publish(""));
	window.addEventListener("pagehide", () => publish(""));
	document.addEventListener("visibilitychange", () => {
		if (document.hidden) publish("");
	});
}

// Set up cmd+click detection for opening links in new windows
export function initCmdClickHandling() {
	if (isNativeMacWebKit()) return;

	// Intercept cmd+clicks on anchors before SPA frameworks can handle them
	window.addEventListener(
		"click",
		(event) => {
			if (!event.metaKey && !event.ctrlKey) return;
			const anchor = closestAnchor(event.target);
			if (!anchor?.href) return;

			event.preventDefault();
			event.stopPropagation();
			event.stopImmediatePropagation();
			emitWebviewEvent(
				"new-window-open",
				JSON.stringify({
					source: "preload-anchor",
					url: anchor.href,
					isCmdClick: true,
					isSPANavigation: false,
					navigationType: "link-activated",
					modifierFlags: getModifierFlags(event),
					isUserGesture: event.isTrusted,
					targetFrame: "main-frame",
					button: event.button
				})
			);
		},
		true
	);
}

// Prevent overscroll bounce effect
export function initOverscrollPrevention() {
	document.addEventListener("DOMContentLoaded", () => {
		const style = document.createElement("style");
		style.type = "text/css";
		style.appendChild(document.createTextNode("html, body { overscroll-behavior: none; }"));
		document.head.appendChild(style);
	});
}
