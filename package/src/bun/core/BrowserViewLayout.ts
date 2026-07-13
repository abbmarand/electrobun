import type { BrowserWindowEventMap } from "../events/windowEvents";
import {
	browserViewLayoutContainsView,
	calculateBrowserViewLayout,
	cloneBrowserViewLayoutTree,
	firstBrowserViewLayoutViewId,
	resizeBrowserViewLayoutDivider,
	type BrowserViewLayoutCalculation,
	type BrowserViewLayoutDivider,
	type BrowserViewLayoutDirection,
	type BrowserViewLayoutInsets,
	type BrowserViewLayoutLeafNode,
	type BrowserViewLayoutMetrics,
	type BrowserViewLayoutNode,
	type BrowserViewLayoutRect,
	type BrowserViewLayoutSize,
	type BrowserViewLayoutSplitFrame,
	type BrowserViewLayoutSplitNode,
	type BrowserViewLayoutViewFrame
} from "./browserViewLayoutEngine";

export type {
	BrowserViewLayoutCalculation,
	BrowserViewLayoutDivider,
	BrowserViewLayoutDirection,
	BrowserViewLayoutInsets,
	BrowserViewLayoutLeafNode,
	BrowserViewLayoutMetrics,
	BrowserViewLayoutNode,
	BrowserViewLayoutRect,
	BrowserViewLayoutSize,
	BrowserViewLayoutSplitFrame,
	BrowserViewLayoutSplitNode,
	BrowserViewLayoutViewFrame
};

export { calculateBrowserViewLayout };

type BrowserViewLayoutWindowEventName = "resize" | "close";

export type BrowserViewLayoutWindow = {
	id: number;
	frame: BrowserViewLayoutSize;
	on<Name extends BrowserViewLayoutWindowEventName>(
		name: Name,
		handler: (event: BrowserWindowEventMap[Name]) => void
	): void;
	off<Name extends BrowserViewLayoutWindowEventName>(
		name: Name,
		handler: (event: BrowserWindowEventMap[Name]) => void
	): void;
};

export type BrowserViewLayoutManagedView = {
	windowId: number;
	autoResize: boolean;
	setFrame(frame: BrowserViewLayoutRect): void;
	setHidden(hidden: boolean): void;
};

export type BrowserViewLayoutSnapshot = BrowserViewLayoutCalculation & {
	tree: BrowserViewLayoutNode;
	activeViewId: string;
	maximizedViewId: string | null;
};

export type BrowserViewLayoutOptions = {
	window: BrowserViewLayoutWindow;
	tree: BrowserViewLayoutNode;
	contentSize?: BrowserViewLayoutSize;
	contentInsets?: Partial<BrowserViewLayoutInsets>;
	metrics?: BrowserViewLayoutMetrics;
	onDidLayout?: (snapshot: BrowserViewLayoutSnapshot) => void;
	onActiveViewChange?: (viewId: string) => void;
};

type AppliedViewState = {
	hidden: boolean;
	frame: BrowserViewLayoutRect | null;
};

function requireInset(value: number, name: string): number {
	if (!Number.isFinite(value) || value < 0) {
		throw new Error(`BrowserViewLayout ${name} inset must be a non-negative finite number`);
	}
	return value;
}

function resolveInsets(insets: Partial<BrowserViewLayoutInsets>): BrowserViewLayoutInsets {
	return {
		top: requireInset(insets.top ?? 0, "top"),
		right: requireInset(insets.right ?? 0, "right"),
		bottom: requireInset(insets.bottom ?? 0, "bottom"),
		left: requireInset(insets.left ?? 0, "left")
	};
}

function requireContentSize(size: BrowserViewLayoutSize): BrowserViewLayoutSize {
	if (!Number.isFinite(size.width) || size.width < 0) {
		throw new Error("BrowserViewLayout content width must be a non-negative finite number");
	}
	if (!Number.isFinite(size.height) || size.height < 0) {
		throw new Error("BrowserViewLayout content height must be a non-negative finite number");
	}
	return { width: size.width, height: size.height };
}

function contentRectFromSize(
	size: BrowserViewLayoutSize,
	insets: BrowserViewLayoutInsets
): BrowserViewLayoutRect {
	return {
		x: insets.left,
		y: insets.top,
		width: Math.max(0, size.width - insets.left - insets.right),
		height: Math.max(0, size.height - insets.top - insets.bottom)
	};
}

function sameRect(left: BrowserViewLayoutRect | null, right: BrowserViewLayoutRect): boolean {
	if (!left) return false;
	return (
		left.x === right.x &&
		left.y === right.y &&
		left.width === right.width &&
		left.height === right.height
	);
}

function cloneRect(rect: BrowserViewLayoutRect): BrowserViewLayoutRect {
	return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
}

function cloneCalculation(calculation: BrowserViewLayoutCalculation): BrowserViewLayoutCalculation {
	return {
		contentRect: cloneRect(calculation.contentRect),
		viewFrames: calculation.viewFrames.map((entry) => ({
			viewId: entry.viewId,
			frame: cloneRect(entry.frame)
		})),
		splitFrames: calculation.splitFrames.map((entry) => ({
			splitId: entry.splitId,
			frame: cloneRect(entry.frame)
		})),
		dividers: calculation.dividers.map((entry) => ({
			splitId: entry.splitId,
			dividerIndex: entry.dividerIndex,
			direction: entry.direction,
			frame: cloneRect(entry.frame)
		}))
	};
}

export class BrowserViewLayout {
	private window: BrowserViewLayoutWindow;
	private tree: BrowserViewLayoutNode;
	private windowContentSize: BrowserViewLayoutSize;
	private contentRect: BrowserViewLayoutRect;
	private contentInsets: BrowserViewLayoutInsets;
	private metrics: BrowserViewLayoutMetrics;
	private views = new Map<string, BrowserViewLayoutManagedView>();
	private appliedViewStates = new Map<string, AppliedViewState>();
	private activeViewId: string;
	private maximizedViewId: string | null = null;
	private calculation: BrowserViewLayoutCalculation;
	private destroyed = false;
	private onDidLayout?: (snapshot: BrowserViewLayoutSnapshot) => void;
	private onActiveViewChange?: (viewId: string) => void;

	private handleWindowResize = (event: BrowserWindowEventMap["resize"]): void => {
		this.windowContentSize = requireContentSize({
			width: event.data.width,
			height: event.data.height
		});
		this.contentRect = contentRectFromSize(this.windowContentSize, this.contentInsets);
		this.apply();
	};

	private handleWindowClose = (_event: BrowserWindowEventMap["close"]): void => {
		this.destroy();
	};

	constructor(options: BrowserViewLayoutOptions) {
		this.window = options.window;
		this.tree = cloneBrowserViewLayoutTree(options.tree);
		this.windowContentSize = requireContentSize(options.contentSize ?? options.window.frame);
		this.contentInsets = resolveInsets(options.contentInsets ?? {});
		this.contentRect = contentRectFromSize(this.windowContentSize, this.contentInsets);
		this.metrics = { ...options.metrics };
		this.activeViewId = firstBrowserViewLayoutViewId(this.tree);
		this.onDidLayout = options.onDidLayout;
		this.onActiveViewChange = options.onActiveViewChange;
		this.calculation = calculateBrowserViewLayout(this.tree, this.contentRect, this.metrics);

		this.window.on("resize", this.handleWindowResize);
		this.window.on("close", this.handleWindowClose);
		this.apply();
	}

	attach(viewId: string, view: BrowserViewLayoutManagedView): void {
		this.requireAlive();
		if (viewId.trim().length === 0) {
			throw new Error("BrowserViewLayout managed view id cannot be empty");
		}
		if (view.windowId !== this.window.id) {
			throw new Error(
				`BrowserViewLayout view \"${viewId}\" belongs to window ${view.windowId}, expected ${this.window.id}`
			);
		}
		if (view.autoResize) {
			throw new Error(
				`BrowserViewLayout view \"${viewId}\" must be created with autoResize: false`
			);
		}

		const previousView = this.views.get(viewId);
		if (previousView && previousView !== view) {
			previousView.setHidden(true);
		}
		this.views.set(viewId, view);
		this.appliedViewStates.delete(viewId);
		this.apply();
	}

	detach(viewId: string): BrowserViewLayoutManagedView | null {
		this.requireAlive();
		const view = this.views.get(viewId);
		if (!view) return null;
		view.setHidden(true);
		this.views.delete(viewId);
		this.appliedViewStates.delete(viewId);
		return view;
	}

	setTree(tree: BrowserViewLayoutNode): void {
		this.requireAlive();
		this.tree = cloneBrowserViewLayoutTree(tree);
		if (this.maximizedViewId && !browserViewLayoutContainsView(this.tree, this.maximizedViewId)) {
			this.maximizedViewId = null;
		}
		if (!browserViewLayoutContainsView(this.tree, this.activeViewId)) {
			this.updateActiveView(firstBrowserViewLayoutViewId(this.tree));
		}
		this.apply();
	}

	getTree(): BrowserViewLayoutNode {
		return cloneBrowserViewLayoutTree(this.tree);
	}

	setContentSize(size: BrowserViewLayoutSize): void {
		this.requireAlive();
		this.windowContentSize = requireContentSize(size);
		this.contentRect = contentRectFromSize(this.windowContentSize, this.contentInsets);
		this.apply();
	}

	setContentInsets(insets: Partial<BrowserViewLayoutInsets>): void {
		this.requireAlive();
		this.contentInsets = resolveInsets(insets);
		this.contentRect = contentRectFromSize(this.windowContentSize, this.contentInsets);
		this.apply();
	}

	resizeDivider(splitId: string, dividerIndex: number, deltaPixels: number): boolean {
		this.requireAlive();
		if (this.maximizedViewId) return false;
		const resized = resizeBrowserViewLayoutDivider(
			this.tree,
			this.contentRect,
			splitId,
			dividerIndex,
			deltaPixels,
			this.metrics
		);
		if (resized) this.apply();
		return resized;
	}

	setActiveView(viewId: string): void {
		this.requireAlive();
		if (!browserViewLayoutContainsView(this.tree, viewId)) {
			throw new Error(`BrowserViewLayout view \"${viewId}\" does not exist in the tree`);
		}
		this.updateActiveView(viewId);
		this.emitSnapshot();
	}

	getActiveView(): string {
		return this.activeViewId;
	}

	maximize(viewId: string): void {
		this.requireAlive();
		if (!browserViewLayoutContainsView(this.tree, viewId)) {
			throw new Error(`BrowserViewLayout view \"${viewId}\" does not exist in the tree`);
		}
		this.maximizedViewId = viewId;
		this.updateActiveView(viewId);
		this.apply();
	}

	restore(): void {
		this.requireAlive();
		if (!this.maximizedViewId) return;
		this.maximizedViewId = null;
		this.apply();
	}

	getSnapshot(): BrowserViewLayoutSnapshot {
		const calculation = cloneCalculation(this.visibleCalculation());
		return {
			...calculation,
			tree: cloneBrowserViewLayoutTree(this.tree),
			activeViewId: this.activeViewId,
			maximizedViewId: this.maximizedViewId
		};
	}

	reflow(): void {
		this.requireAlive();
		this.apply();
	}

	destroy(): void {
		if (this.destroyed) return;
		this.destroyed = true;
		this.window.off("resize", this.handleWindowResize);
		this.window.off("close", this.handleWindowClose);
		this.views.clear();
		this.appliedViewStates.clear();
	}

	private updateActiveView(viewId: string): void {
		if (this.activeViewId === viewId) return;
		this.activeViewId = viewId;
		this.onActiveViewChange?.(viewId);
	}

	private visibleCalculation(): BrowserViewLayoutCalculation {
		if (!this.maximizedViewId) return this.calculation;
		return {
			contentRect: this.calculation.contentRect,
			viewFrames: [
				{
					viewId: this.maximizedViewId,
					frame: this.calculation.contentRect
				}
			],
			splitFrames: [],
			dividers: []
		};
	}

	private apply(): void {
		if (this.destroyed) return;
		this.calculation = calculateBrowserViewLayout(this.tree, this.contentRect, this.metrics);
		const visibleCalculation = this.visibleCalculation();
		const framesByViewId = new Map<string, BrowserViewLayoutRect>();
		for (const entry of visibleCalculation.viewFrames) {
			framesByViewId.set(entry.viewId, entry.frame);
		}

		for (const [viewId, view] of this.views) {
			const frame = framesByViewId.get(viewId);
			const previousState = this.appliedViewStates.get(viewId);
			if (!frame) {
				if (!previousState || !previousState.hidden) {
					view.setHidden(true);
				}
				this.appliedViewStates.set(viewId, { hidden: true, frame: null });
				continue;
			}

			if (!previousState || !sameRect(previousState.frame, frame)) {
				view.setFrame(frame);
			}
			if (!previousState || previousState.hidden) {
				view.setHidden(false);
			}
			this.appliedViewStates.set(viewId, { hidden: false, frame: cloneRect(frame) });
		}
		this.emitSnapshot();
	}

	private emitSnapshot(): void {
		if (!this.onDidLayout) return;
		this.onDidLayout(this.getSnapshot());
	}

	private requireAlive(): void {
		if (this.destroyed) {
			throw new Error("BrowserViewLayout has been destroyed");
		}
	}
}
