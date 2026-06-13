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
