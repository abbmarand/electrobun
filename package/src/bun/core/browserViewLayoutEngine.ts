export type BrowserViewLayoutRect = {
	x: number;
	y: number;
	width: number;
	height: number;
};

export type BrowserViewLayoutSize = {
	width: number;
	height: number;
};

export type BrowserViewLayoutInsets = {
	top: number;
	right: number;
	bottom: number;
	left: number;
};

export type BrowserViewLayoutDirection = "row" | "column";

export type BrowserViewLayoutLeafNode = {
	kind: "leaf";
	viewId: string;
	minimumWidth?: number;
	minimumHeight?: number;
};

export type BrowserViewLayoutSplitNode = {
	kind: "split";
	id: string;
	direction: BrowserViewLayoutDirection;
	children: BrowserViewLayoutNode[];
	weights: number[];
	gap?: number;
};

export type BrowserViewLayoutNode = BrowserViewLayoutLeafNode | BrowserViewLayoutSplitNode;

export type BrowserViewLayoutMetrics = {
	gap?: number;
	dividerHitSize?: number;
	minimumWidth?: number;
	minimumHeight?: number;
};

export type BrowserViewLayoutViewFrame = {
	viewId: string;
	frame: BrowserViewLayoutRect;
};

export type BrowserViewLayoutSplitFrame = {
	splitId: string;
	frame: BrowserViewLayoutRect;
};

export type BrowserViewLayoutDivider = {
	splitId: string;
	dividerIndex: number;
	direction: BrowserViewLayoutDirection;
	frame: BrowserViewLayoutRect;
};

export type BrowserViewLayoutCalculation = {
	contentRect: BrowserViewLayoutRect;
	viewFrames: BrowserViewLayoutViewFrame[];
	splitFrames: BrowserViewLayoutSplitFrame[];
	dividers: BrowserViewLayoutDivider[];
};

type ResolvedBrowserViewLayoutMetrics = {
	gap: number;
	dividerHitSize: number;
	minimumWidth: number;
	minimumHeight: number;
};

type BrowserViewLayoutValidationState = {
	viewIds: Set<string>;
	splitIds: Set<string>;
};

const DEFAULT_GAP = 8;
const DEFAULT_DIVIDER_HIT_SIZE = 12;
const DEFAULT_MINIMUM_WIDTH = 160;
const DEFAULT_MINIMUM_HEIGHT = 120;
const MINIMUM_WEIGHT = 0.000001;

function requireFinite(value: number, label: string): void {
	if (!Number.isFinite(value)) {
		throw new Error(`${label} must be a finite number`);
	}
}

function requireNonNegative(value: number, label: string): void {
	requireFinite(value, label);
	if (value < 0) {
		throw new Error(`${label} must be greater than or equal to zero`);
	}
}

function normalizeWeights(weights: number[]): number[] {
	let total = 0;
	for (const weight of weights) {
		total += weight;
	}
	return weights.map((weight) => weight / total);
}

function cloneLeafNode(
	node: BrowserViewLayoutLeafNode,
	state: BrowserViewLayoutValidationState
): BrowserViewLayoutLeafNode {
	if (node.viewId.trim().length === 0) {
		throw new Error("BrowserViewLayout leaf viewId cannot be empty");
	}
	if (state.viewIds.has(node.viewId)) {
		throw new Error(`BrowserViewLayout contains duplicate viewId \"${node.viewId}\"`);
	}
	state.viewIds.add(node.viewId);

	if (node.minimumWidth !== undefined) {
		requireNonNegative(node.minimumWidth, `minimumWidth for view \"${node.viewId}\"`);
	}
	if (node.minimumHeight !== undefined) {
		requireNonNegative(node.minimumHeight, `minimumHeight for view \"${node.viewId}\"`);
	}

	const clone: BrowserViewLayoutLeafNode = {
		kind: "leaf",
		viewId: node.viewId
	};
	if (node.minimumWidth !== undefined) clone.minimumWidth = node.minimumWidth;
	if (node.minimumHeight !== undefined) clone.minimumHeight = node.minimumHeight;
	return clone;
}

function cloneSplitNode(
	node: BrowserViewLayoutSplitNode,
	state: BrowserViewLayoutValidationState
): BrowserViewLayoutSplitNode {
	if (node.id.trim().length === 0) {
		throw new Error("BrowserViewLayout split id cannot be empty");
	}
	if (state.splitIds.has(node.id)) {
		throw new Error(`BrowserViewLayout contains duplicate split id \"${node.id}\"`);
	}
	state.splitIds.add(node.id);

	if (node.children.length < 2) {
		throw new Error(`BrowserViewLayout split \"${node.id}\" must have at least two children`);
	}
	if (node.weights.length !== node.children.length) {
		throw new Error(`BrowserViewLayout split \"${node.id}\" must have one weight per child`);
	}
	for (const weight of node.weights) {
		requireFinite(weight, `weight in split \"${node.id}\"`);
		if (weight <= 0) {
			throw new Error(`weights in split \"${node.id}\" must be greater than zero`);
		}
	}
	if (node.gap !== undefined) {
		requireNonNegative(node.gap, `gap in split \"${node.id}\"`);
	}

	const clone: BrowserViewLayoutSplitNode = {
		kind: "split",
		id: node.id,
		direction: node.direction,
		children: node.children.map((child) => cloneLayoutNode(child, state)),
		weights: normalizeWeights(node.weights)
	};
	if (node.gap !== undefined) clone.gap = node.gap;
	return clone;
}

function cloneLayoutNode(
	node: BrowserViewLayoutNode,
	state: BrowserViewLayoutValidationState
): BrowserViewLayoutNode {
	if (node.kind === "leaf") {
		return cloneLeafNode(node, state);
	}
	return cloneSplitNode(node, state);
}

export function cloneBrowserViewLayoutTree(tree: BrowserViewLayoutNode): BrowserViewLayoutNode {
	return cloneLayoutNode(tree, {
		viewIds: new Set(),
		splitIds: new Set()
	});
}

function resolveMetrics(metrics: BrowserViewLayoutMetrics): ResolvedBrowserViewLayoutMetrics {
	const resolved = {
		gap: metrics.gap ?? DEFAULT_GAP,
		dividerHitSize: metrics.dividerHitSize ?? DEFAULT_DIVIDER_HIT_SIZE,
		minimumWidth: metrics.minimumWidth ?? DEFAULT_MINIMUM_WIDTH,
		minimumHeight: metrics.minimumHeight ?? DEFAULT_MINIMUM_HEIGHT
	};
	requireNonNegative(resolved.gap, "BrowserViewLayout gap");
	requireNonNegative(resolved.dividerHitSize, "BrowserViewLayout dividerHitSize");
	requireNonNegative(resolved.minimumWidth, "BrowserViewLayout minimumWidth");
	requireNonNegative(resolved.minimumHeight, "BrowserViewLayout minimumHeight");
	return resolved;
}

function normalizeRect(rect: BrowserViewLayoutRect): BrowserViewLayoutRect {
	requireFinite(rect.x, "BrowserViewLayout rect x");
	requireFinite(rect.y, "BrowserViewLayout rect y");
	requireNonNegative(rect.width, "BrowserViewLayout rect width");
	requireNonNegative(rect.height, "BrowserViewLayout rect height");
	return {
		x: Math.round(rect.x),
		y: Math.round(rect.y),
		width: Math.round(rect.width),
		height: Math.round(rect.height)
	};
}

function nodeGap(
	node: BrowserViewLayoutSplitNode,
	metrics: ResolvedBrowserViewLayoutMetrics
): number {
	return Math.round(node.gap ?? metrics.gap);
}

function minimumNodeSize(
	node: BrowserViewLayoutNode,
	metrics: ResolvedBrowserViewLayoutMetrics
): BrowserViewLayoutSize {
	if (node.kind === "leaf") {
		return {
			width: Math.ceil(node.minimumWidth ?? metrics.minimumWidth),
			height: Math.ceil(node.minimumHeight ?? metrics.minimumHeight)
		};
	}

	const childSizes = node.children.map((child) => minimumNodeSize(child, metrics));
	const totalGap = nodeGap(node, metrics) * (node.children.length - 1);
	if (node.direction === "row") {
		let width = totalGap;
		let height = 0;
		for (const childSize of childSizes) {
			width += childSize.width;
			height = Math.max(height, childSize.height);
		}
		return { width, height };
	}

	let width = 0;
	let height = totalGap;
	for (const childSize of childSizes) {
		width = Math.max(width, childSize.width);
		height += childSize.height;
	}
	return { width, height };
}

function roundAllocations(rawValues: number[], total: number): number[] {
	const roundedTotal = Math.max(0, Math.round(total));
	const allocations = rawValues.map((value) => Math.max(0, Math.floor(value)));
	let allocated = 0;
	for (const allocation of allocations) {
		allocated += allocation;
	}

	let remaining = roundedTotal - allocated;
	const rankedRemainders = rawValues
		.map((value, index) => ({ index, remainder: value - Math.floor(value) }))
		.sort((left, right) => {
			if (right.remainder === left.remainder) {
				return left.index - right.index;
			}
			return right.remainder - left.remainder;
		});

	let rank = 0;
	while (remaining > 0 && rankedRemainders.length > 0) {
		const entry = rankedRemainders[rank % rankedRemainders.length];
		if (!entry) break;
		allocations[entry.index] = (allocations[entry.index] ?? 0) + 1;
		remaining -= 1;
		rank += 1;
	}
	return allocations;
}

function weightedRawValues(total: number, weights: number[]): number[] {
	let totalWeight = 0;
	for (const weight of weights) {
		totalWeight += weight;
	}
	return weights.map((weight) => (total * weight) / totalWeight);
}

function allocateCompressedMinimums(
	total: number,
	minimums: number[],
	weights: number[]
): number[] {
	let minimumTotal = 0;
	for (const minimum of minimums) {
		minimumTotal += minimum;
	}
	if (minimumTotal > 0) {
		return roundAllocations(
			minimums.map((minimum) => (total * minimum) / minimumTotal),
			total
		);
	}
	return roundAllocations(weightedRawValues(total, weights), total);
}

function allocateWeightedSpan(total: number, weights: number[], minimums: number[]): number[] {
	const roundedTotal = Math.max(0, Math.round(total));
	const roundedMinimums = minimums.map((minimum) => Math.max(0, Math.ceil(minimum)));
	let minimumTotal = 0;
	for (const minimum of roundedMinimums) {
		minimumTotal += minimum;
	}
	if (minimumTotal >= roundedTotal) {
		return allocateCompressedMinimums(roundedTotal, roundedMinimums, weights);
	}

	const rawValues = new Array<number>(weights.length).fill(0);
	const activeIndexes = new Set<number>();
	for (let index = 0; index < weights.length; index += 1) {
		activeIndexes.add(index);
	}
	let remainingTotal = roundedTotal;

	while (activeIndexes.size > 0) {
		let remainingWeight = 0;
		for (const index of activeIndexes) {
			remainingWeight += weights[index] ?? 0;
		}

		const constrainedIndexes: number[] = [];
		for (const index of activeIndexes) {
			const weight = weights[index] ?? 0;
			const minimum = roundedMinimums[index] ?? 0;
			const candidate = (remainingTotal * weight) / remainingWeight;
			if (candidate < minimum) {
				constrainedIndexes.push(index);
			}
		}

		if (constrainedIndexes.length === 0) {
			for (const index of activeIndexes) {
				const weight = weights[index] ?? 0;
				rawValues[index] = (remainingTotal * weight) / remainingWeight;
			}
			break;
		}

		for (const index of constrainedIndexes) {
			const minimum = roundedMinimums[index] ?? 0;
			rawValues[index] = minimum;
			remainingTotal -= minimum;
			activeIndexes.delete(index);
		}
	}

	return roundAllocations(rawValues, roundedTotal);
}

function resolvedGapForSpan(requestedGap: number, span: number, childCount: number): number {
	if (childCount <= 1) return 0;
	const maximumGap = Math.floor(Math.max(0, span) / (childCount - 1));
	return Math.min(Math.max(0, requestedGap), maximumGap);
}

function childSpans(
	node: BrowserViewLayoutSplitNode,
	frame: BrowserViewLayoutRect,
	metrics: ResolvedBrowserViewLayoutMetrics
): { gap: number; spans: number[]; availableSpan: number; minimums: number[] } {
	let span = frame.width;
	if (node.direction === "column") {
		span = frame.height;
	}
	const gap = resolvedGapForSpan(nodeGap(node, metrics), span, node.children.length);
	const availableSpan = Math.max(0, span - gap * (node.children.length - 1));
	const minimums = node.children.map((child) => {
		const minimum = minimumNodeSize(child, metrics);
		if (node.direction === "row") {
			return minimum.width;
		}
		return minimum.height;
	});
	return {
		gap,
		spans: allocateWeightedSpan(availableSpan, node.weights, minimums),
		availableSpan,
		minimums
	};
}

function dividerFrame(
	direction: BrowserViewLayoutDirection,
	parentFrame: BrowserViewLayoutRect,
	boundary: number,
	gap: number,
	metrics: ResolvedBrowserViewLayoutMetrics
): BrowserViewLayoutRect {
	const requestedHitSize = Math.max(gap, Math.round(metrics.dividerHitSize));
	if (direction === "row") {
		const hitSize = Math.min(parentFrame.width, requestedHitSize);
		const minimumX = parentFrame.x;
		const maximumX = parentFrame.x + parentFrame.width - hitSize;
		const x = Math.min(maximumX, Math.max(minimumX, Math.round(boundary - hitSize / 2)));
		return { x, y: parentFrame.y, width: hitSize, height: parentFrame.height };
	}

	const hitSize = Math.min(parentFrame.height, requestedHitSize);
	const minimumY = parentFrame.y;
	const maximumY = parentFrame.y + parentFrame.height - hitSize;
	const y = Math.min(maximumY, Math.max(minimumY, Math.round(boundary - hitSize / 2)));
	return { x: parentFrame.x, y, width: parentFrame.width, height: hitSize };
}

function calculateNode(
	node: BrowserViewLayoutNode,
	frame: BrowserViewLayoutRect,
	metrics: ResolvedBrowserViewLayoutMetrics,
	calculation: BrowserViewLayoutCalculation
): void {
	if (node.kind === "leaf") {
		calculation.viewFrames.push({ viewId: node.viewId, frame });
		return;
	}

	calculation.splitFrames.push({ splitId: node.id, frame });
	const allocation = childSpans(node, frame, metrics);
	let cursor = node.direction === "row" ? frame.x : frame.y;

	for (let index = 0; index < node.children.length; index += 1) {
		const child = node.children[index];
		const span = allocation.spans[index];
		if (!child || span === undefined) continue;

		let childFrame: BrowserViewLayoutRect;
		if (node.direction === "row") {
			childFrame = { x: cursor, y: frame.y, width: span, height: frame.height };
		} else {
			childFrame = { x: frame.x, y: cursor, width: frame.width, height: span };
		}
		calculateNode(child, childFrame, metrics, calculation);
		cursor += span;

		if (index < node.children.length - 1) {
			const boundary = cursor + allocation.gap / 2;
			calculation.dividers.push({
				splitId: node.id,
				dividerIndex: index,
				direction: node.direction,
				frame: dividerFrame(node.direction, frame, boundary, allocation.gap, metrics)
			});
			cursor += allocation.gap;
		}
	}
}

export function calculateBrowserViewLayout(
	tree: BrowserViewLayoutNode,
	contentRect: BrowserViewLayoutRect,
	metrics: BrowserViewLayoutMetrics = {}
): BrowserViewLayoutCalculation {
	const normalizedTree = cloneBrowserViewLayoutTree(tree);
	const normalizedRect = normalizeRect(contentRect);
	const resolvedMetrics = resolveMetrics(metrics);
	const calculation: BrowserViewLayoutCalculation = {
		contentRect: normalizedRect,
		viewFrames: [],
		splitFrames: [],
		dividers: []
	};
	calculateNode(normalizedTree, normalizedRect, resolvedMetrics, calculation);
	return calculation;
}

function findSplitNode(
	node: BrowserViewLayoutNode,
	splitId: string
): BrowserViewLayoutSplitNode | null {
	if (node.kind === "leaf") return null;
	if (node.id === splitId) return node;
	for (const child of node.children) {
		const match = findSplitNode(child, splitId);
		if (match) return match;
	}
	return null;
}

export function browserViewLayoutContainsView(
	node: BrowserViewLayoutNode,
	viewId: string
): boolean {
	if (node.kind === "leaf") return node.viewId === viewId;
	return node.children.some((child) => browserViewLayoutContainsView(child, viewId));
}

export function firstBrowserViewLayoutViewId(node: BrowserViewLayoutNode): string {
	if (node.kind === "leaf") return node.viewId;
	const firstChild = node.children[0];
	if (!firstChild) {
		throw new Error(`BrowserViewLayout split \"${node.id}\" has no children`);
	}
	return firstBrowserViewLayoutViewId(firstChild);
}

export function resizeBrowserViewLayoutDivider(
	tree: BrowserViewLayoutNode,
	contentRect: BrowserViewLayoutRect,
	splitId: string,
	dividerIndex: number,
	deltaPixels: number,
	metrics: BrowserViewLayoutMetrics = {}
): boolean {
	requireFinite(deltaPixels, "BrowserViewLayout divider delta");
	const delta = Math.round(deltaPixels);
	if (delta === 0) return false;

	const splitNode = findSplitNode(tree, splitId);
	if (!splitNode) {
		throw new Error(`BrowserViewLayout split \"${splitId}\" does not exist`);
	}
	if (!Number.isInteger(dividerIndex)) {
		throw new Error("BrowserViewLayout divider index must be an integer");
	}
	if (dividerIndex < 0 || dividerIndex >= splitNode.children.length - 1) {
		throw new Error(
			`BrowserViewLayout divider ${dividerIndex} does not exist in split \"${splitId}\"`
		);
	}

	const resolvedMetrics = resolveMetrics(metrics);
	const calculation = calculateBrowserViewLayout(tree, contentRect, metrics);
	const splitFrameEntry = calculation.splitFrames.find((entry) => entry.splitId === splitId);
	if (!splitFrameEntry) return false;
	const allocation = childSpans(splitNode, splitFrameEntry.frame, resolvedMetrics);

	let minimumTotal = 0;
	for (const minimum of allocation.minimums) {
		minimumTotal += minimum;
	}
	if (minimumTotal > allocation.availableSpan) return false;

	const beforeIndex = dividerIndex;
	const afterIndex = dividerIndex + 1;
	const beforeSpan = allocation.spans[beforeIndex];
	const afterSpan = allocation.spans[afterIndex];
	const beforeMinimum = allocation.minimums[beforeIndex];
	const afterMinimum = allocation.minimums[afterIndex];
	if (
		beforeSpan === undefined ||
		afterSpan === undefined ||
		beforeMinimum === undefined ||
		afterMinimum === undefined
	) {
		return false;
	}

	const minimumDelta = beforeMinimum - beforeSpan;
	const maximumDelta = afterSpan - afterMinimum;
	const constrainedDelta = Math.min(maximumDelta, Math.max(minimumDelta, delta));
	if (constrainedDelta === 0) return false;

	const resizedSpans = allocation.spans.map((span) => Math.max(MINIMUM_WEIGHT, span));
	resizedSpans[beforeIndex] = beforeSpan + constrainedDelta;
	resizedSpans[afterIndex] = afterSpan - constrainedDelta;
	splitNode.weights = normalizeWeights(resizedSpans);
	return true;
}
