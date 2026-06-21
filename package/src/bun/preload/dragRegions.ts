// Drag Region Support for custom titlebars
// Detects elements with CSS app-region: drag or .electrobun-webkit-app-region-drag class

import "./globals.d.ts";
import { send } from "./internalRpc";

function computedAppRegion(element: HTMLElement): string {
	const styles = window.getComputedStyle(element);
	const webkitRegion = styles.getPropertyValue("-webkit-app-region").trim();
	if (webkitRegion) return webkitRegion;
	return styles.getPropertyValue("app-region").trim();
}

function closestComputedAppRegion(
	target: HTMLElement,
	region: "drag" | "no-drag",
): HTMLElement | null {
	let element: HTMLElement | null = target;
	while (element) {
		if (computedAppRegion(element) === region) return element;
		element = element.parentElement;
	}
	return null;
}

function isAppRegionDrag(e: MouseEvent): boolean {
	const target = e.target;
	if (!(target instanceof HTMLElement)) return false;

	// If the target is inside a no-drag region, it should not trigger window move
	if (
		target.closest(".electrobun-webkit-app-region-no-drag") ||
		target.closest('[style*="app-region"][style*="no-drag"]') ||
		closestComputedAppRegion(target, "no-drag")
	) {
		return false;
	}

	// Check for inline style with app-region: drag
	const draggableByStyle = target.closest(
		'[style*="app-region"][style*="drag"]',
	);
	// Check for class-based drag region
	const draggableByClass = target.closest(".electrobun-webkit-app-region-drag");
	const draggableByComputedStyle = closestComputedAppRegion(target, "drag");

	return !!(draggableByStyle || draggableByClass || draggableByComputedStyle);
}

export function initDragRegions() {
	document.addEventListener("mousedown", (e) => {
		if (isAppRegionDrag(e)) {
			send("startWindowMove", { id: window.__electrobunWindowId });
		}
	});

	document.addEventListener("mouseup", (e) => {
		if (isAppRegionDrag(e)) {
			send("stopWindowMove", { id: window.__electrobunWindowId });
		}
	});
}
