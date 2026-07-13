import { describe, expect, it } from "bun:test";
import {
	BrowserViewLayout,
	type BrowserViewLayoutManagedView,
	type BrowserViewLayoutNode,
	type BrowserViewLayoutWindow
} from "./BrowserViewLayout";
import type { BrowserWindow } from "./BrowserWindow";
import type { BrowserWindowEventMap } from "../events/windowEvents";

type WindowEventName = "resize" | "close";
type BrowserWindowCompatibility = BrowserWindow extends BrowserViewLayoutWindow ? true : false;

const browserWindowCompatibility: BrowserWindowCompatibility = true;

function fakeWindow() {
	return {
		id: 42,
		frame: { width: 1000, height: 600 },
		on<Name extends WindowEventName>(
			_name: Name,
			_handler: (event: BrowserWindowEventMap[Name]) => void
		): void {},
		off<Name extends WindowEventName>(
			_name: Name,
			_handler: (event: BrowserWindowEventMap[Name]) => void
		): void {}
	};
}

function twoPaneTree(): BrowserViewLayoutNode {
	return {
		kind: "split",
		id: "root",
		direction: "row",
		weights: [1, 1],
		children: [
			{ kind: "leaf", viewId: "a" },
			{ kind: "leaf", viewId: "b" }
		]
	};
}

class FakeManagedView implements BrowserViewLayoutManagedView {
	windowId = 42;
	autoResize = false;
	frames: Array<{ x: number; y: number; width: number; height: number }> = [];
	hiddenStates: boolean[] = [];

	setFrame(frame: { x: number; y: number; width: number; height: number }): void {
		this.frames.push({ ...frame });
	}

	setHidden(hidden: boolean): void {
		this.hiddenStates.push(hidden);
	}
}

describe("BrowserViewLayout", () => {
	it("accepts BrowserWindow as its native resize host", () => {
		expect(browserWindowCompatibility).toBe(true);
	});

	it("coordinates attached BrowserViews and content-sized reflows", () => {
		const layout = new BrowserViewLayout({
			window: fakeWindow(),
			tree: twoPaneTree(),
			metrics: { gap: 8 }
		});
		const a = new FakeManagedView();
		const b = new FakeManagedView();
		layout.attach("a", a);
		layout.attach("b", b);

		expect(a.frames.at(-1)).toEqual({ x: 0, y: 0, width: 496, height: 600 });
		expect(b.frames.at(-1)).toEqual({ x: 504, y: 0, width: 496, height: 600 });

		layout.setContentSize({ width: 1200, height: 700 });

		expect(a.frames.at(-1)).toEqual({ x: 0, y: 0, width: 596, height: 700 });
		expect(b.frames.at(-1)).toEqual({ x: 604, y: 0, width: 596, height: 700 });
	});

	it("applies persistent insets for trusted window chrome", () => {
		const layout = new BrowserViewLayout({
			window: fakeWindow(),
			tree: twoPaneTree(),
			contentInsets: { top: 48, left: 12, right: 12, bottom: 12 },
			metrics: { gap: 8 }
		});
		const a = new FakeManagedView();
		layout.attach("a", a);

		expect(a.frames.at(-1)).toEqual({ x: 12, y: 48, width: 484, height: 540 });
	});

	it("maximizes one pane without destroying the retained split tree", () => {
		const layout = new BrowserViewLayout({
			window: fakeWindow(),
			tree: twoPaneTree(),
			metrics: { gap: 8 }
		});
		const a = new FakeManagedView();
		const b = new FakeManagedView();
		layout.attach("a", a);
		layout.attach("b", b);

		layout.maximize("b");

		expect(a.hiddenStates.at(-1)).toBe(true);
		expect(b.frames.at(-1)).toEqual({ x: 0, y: 0, width: 1000, height: 600 });
		expect(layout.getSnapshot().dividers).toEqual([]);

		layout.restore();

		expect(a.hiddenStates.at(-1)).toBe(false);
		expect(layout.getTree()).toEqual({
			kind: "split",
			id: "root",
			direction: "row",
			weights: [0.5, 0.5],
			children: [
				{ kind: "leaf", viewId: "a" },
				{ kind: "leaf", viewId: "b" }
			]
		});
	});

	it("requires manually sized child BrowserViews", () => {
		const layout = new BrowserViewLayout({
			window: fakeWindow(),
			tree: twoPaneTree()
		});
		const view = new FakeManagedView();
		view.autoResize = true;

		expect(() => layout.attach("a", view)).toThrow("autoResize: false");
	});
});
