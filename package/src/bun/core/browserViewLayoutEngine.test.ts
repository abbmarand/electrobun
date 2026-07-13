import { describe, expect, it } from "bun:test";
import {
	calculateBrowserViewLayout,
	cloneBrowserViewLayoutTree,
	resizeBrowserViewLayoutDivider,
	type BrowserViewLayoutNode
} from "./browserViewLayoutEngine";

function zenStyleThreePaneTree(): BrowserViewLayoutNode {
	return {
		kind: "split",
		id: "root",
		direction: "row",
		weights: [1, 1],
		children: [
			{
				kind: "split",
				id: "left-column",
				direction: "column",
				weights: [1, 1],
				children: [
					{ kind: "leaf", viewId: "a" },
					{ kind: "leaf", viewId: "b" }
				]
			},
			{ kind: "leaf", viewId: "c" }
		]
	};
}

describe("calculateBrowserViewLayout", () => {
	it("lays out a Zen-style three-pane grid and exposes chrome dividers", () => {
		const calculation = calculateBrowserViewLayout(
			zenStyleThreePaneTree(),
			{ x: 0, y: 0, width: 1000, height: 600 },
			{ gap: 8, dividerHitSize: 12 }
		);

		expect(calculation.viewFrames).toEqual([
			{ viewId: "a", frame: { x: 0, y: 0, width: 496, height: 296 } },
			{ viewId: "b", frame: { x: 0, y: 304, width: 496, height: 296 } },
			{ viewId: "c", frame: { x: 504, y: 0, width: 496, height: 600 } }
		]);
		expect(calculation.dividers).toEqual([
			{
				splitId: "left-column",
				dividerIndex: 0,
				direction: "column",
				frame: { x: 0, y: 294, width: 496, height: 12 }
			},
			{
				splitId: "root",
				dividerIndex: 0,
				direction: "row",
				frame: { x: 494, y: 0, width: 12, height: 600 }
			}
		]);
	});

	it("distributes rounding without leaving gaps at the content edge", () => {
		const tree: BrowserViewLayoutNode = {
			kind: "split",
			id: "columns",
			direction: "row",
			weights: [1, 1, 1],
			gap: 1,
			children: [
				{ kind: "leaf", viewId: "a", minimumWidth: 0 },
				{ kind: "leaf", viewId: "b", minimumWidth: 0 },
				{ kind: "leaf", viewId: "c", minimumWidth: 0 }
			]
		};
		const calculation = calculateBrowserViewLayout(tree, {
			x: 0,
			y: 0,
			width: 1000,
			height: 500
		});

		expect(calculation.viewFrames).toEqual([
			{ viewId: "a", frame: { x: 0, y: 0, width: 333, height: 500 } },
			{ viewId: "b", frame: { x: 334, y: 0, width: 333, height: 500 } },
			{ viewId: "c", frame: { x: 668, y: 0, width: 332, height: 500 } }
		]);
	});

	it("honors recursive minimum sizes", () => {
		const calculation = calculateBrowserViewLayout(
			zenStyleThreePaneTree(),
			{ x: 0, y: 0, width: 600, height: 600 },
			{ gap: 8, minimumWidth: 240, minimumHeight: 120 }
		);

		expect(calculation.viewFrames.find((entry) => entry.viewId === "a")?.frame.width).toBe(296);
		expect(calculation.viewFrames.find((entry) => entry.viewId === "c")?.frame.width).toBe(296);
	});

	it("rejects duplicate view ids before applying frames", () => {
		const tree: BrowserViewLayoutNode = {
			kind: "split",
			id: "root",
			direction: "row",
			weights: [1, 1],
			children: [
				{ kind: "leaf", viewId: "duplicate" },
				{ kind: "leaf", viewId: "duplicate" }
			]
		};

		expect(() => cloneBrowserViewLayoutTree(tree)).toThrow("duplicate viewId");
	});
});

describe("resizeBrowserViewLayoutDivider", () => {
	it("resizes adjacent panes and clamps them to their minimum sizes", () => {
		const tree: BrowserViewLayoutNode = {
			kind: "split",
			id: "root",
			direction: "row",
			weights: [1, 1],
			children: [
				{ kind: "leaf", viewId: "a" },
				{ kind: "leaf", viewId: "b" }
			]
		};

		expect(
			resizeBrowserViewLayoutDivider(
				tree,
				{ x: 0, y: 0, width: 1000, height: 600 },
				"root",
				0,
				500,
				{ gap: 8, minimumWidth: 160 }
			)
		).toBe(true);

		const calculation = calculateBrowserViewLayout(
			tree,
			{ x: 0, y: 0, width: 1000, height: 600 },
			{ gap: 8, minimumWidth: 160 }
		);
		expect(calculation.viewFrames).toEqual([
			{ viewId: "a", frame: { x: 0, y: 0, width: 832, height: 600 } },
			{ viewId: "b", frame: { x: 840, y: 0, width: 160, height: 600 } }
		]);
	});
});
