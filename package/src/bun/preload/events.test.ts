import { afterEach, describe, expect, it } from "bun:test";
import { initLifecycleEvents } from "./events";

type HistoryMethodName = "pushState" | "replaceState";

type CapturedHistoryCall = {
	method: HistoryMethodName;
	receiver: unknown;
	args: unknown[];
};

type FakeBridge = {
	postMessage: (message: string) => void;
};

type FakeWindow = {
	top: unknown;
	location: { href: string };
	__electrobunWebviewId: number;
	__electrobunEventBridge: FakeBridge;
	addEventListener: (eventName: string, listener: unknown) => void;
};

type FakeHistory = {
	pushState: (...args: unknown[]) => unknown;
	replaceState: (...args: unknown[]) => unknown;
};

type FakeEnvironmentOptions = {
	throwMethod?: HistoryMethodName;
	error?: Error;
};

const originalWindowDescriptor = Object.getOwnPropertyDescriptor(globalThis, "window");
const originalHistoryDescriptor = Object.getOwnPropertyDescriptor(globalThis, "history");

function restoreGlobalProperty(name: string, descriptor: PropertyDescriptor | undefined): void {
	if (descriptor) {
		Object.defineProperty(globalThis, name, descriptor);
		return;
	}
	Reflect.deleteProperty(globalThis, name);
}

afterEach(() => {
	restoreGlobalProperty("window", originalWindowDescriptor);
	restoreGlobalProperty("history", originalHistoryDescriptor);
});

function createHistoryMethod(
	method: HistoryMethodName,
	calls: CapturedHistoryCall[],
	options: FakeEnvironmentOptions
): (this: unknown, ...args: unknown[]) => unknown {
	return function (this: unknown, ...args: unknown[]) {
		calls.push({ method, receiver: this, args });
		if (options.throwMethod === method) {
			throw options.error ?? new Error(`${method} failed`);
		}
		return `${method}-result`;
	};
}

function installFakePreloadEnvironment(options: FakeEnvironmentOptions = {}) {
	const calls: CapturedHistoryCall[] = [];
	const messages: string[] = [];
	const listeners: Array<{ eventName: string; listener: unknown }> = [];
	const history: FakeHistory = {
		pushState: createHistoryMethod("pushState", calls, options),
		replaceState: createHistoryMethod("replaceState", calls, options)
	};
	const bridge: FakeBridge = {
		postMessage: (message) => {
			messages.push(message);
		}
	};
	const window: FakeWindow = {
		top: null,
		location: { href: "https://www.youtube.com/watch?v=abc123" },
		__electrobunWebviewId: 42,
		__electrobunEventBridge: bridge,
		addEventListener: (eventName, listener) => {
			listeners.push({ eventName, listener });
		}
	};
	window.top = window;

	Object.defineProperty(globalThis, "window", {
		configurable: true,
		value: window
	});
	Object.defineProperty(globalThis, "history", {
		configurable: true,
		value: history
	});

	return { calls, history, listeners, messages };
}

function nextMacrotask(): Promise<void> {
	return new Promise((resolve) => {
		setTimeout(resolve, 0);
	});
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function eventNameFromBridgeMessage(message: string): string | null {
	const parsed: unknown = JSON.parse(message);
	if (!isRecord(parsed)) return null;
	const payload = parsed.payload;
	if (!isRecord(payload)) return null;
	const eventName = payload.eventName;
	return typeof eventName === "string" ? eventName : null;
}

describe("preload lifecycle history wrappers", () => {
	it("preserves exact History API arguments and receiver", async () => {
		const env = installFakePreloadEnvironment();
		initLifecycleEvents();

		const receiver = { marker: "youtube-history-receiver" };
		const replaceStateData = { videoId: "VKfQkRbd15k" };
		const replaceResult = env.history.replaceState.call(receiver, replaceStateData, "");
		const pushUrl = new URL("https://www.youtube.com/watch?v=VKfQkRbd15k");
		const pushResult = env.history.pushState.call(receiver, "state", "title", pushUrl);

		expect(replaceResult).toBe("replaceState-result");
		expect(pushResult).toBe("pushState-result");
		expect(env.calls[0]?.method).toBe("replaceState");
		expect(env.calls[0]?.receiver).toBe(receiver);
		expect(env.calls[0]?.args).toEqual([replaceStateData, ""]);
		expect(env.calls[1]?.method).toBe("pushState");
		expect(env.calls[1]?.receiver).toBe(receiver);
		expect(env.calls[1]?.args).toEqual(["state", "title", pushUrl]);
		expect(env.listeners.map((listener) => listener.eventName)).toEqual([
			"load",
			"popstate",
			"hashchange"
		]);

		await nextMacrotask();

		expect(env.messages.map(eventNameFromBridgeMessage)).toEqual([
			"did-navigate-in-page",
			"did-navigate-in-page"
		]);
	});

	it("propagates native History API errors without emitting navigation", async () => {
		const error = new Error("native replaceState rejected");
		const env = installFakePreloadEnvironment({ throwMethod: "replaceState", error });
		initLifecycleEvents();

		const receiver = { marker: "youtube-history-receiver" };
		const replaceStateData = { videoId: "VKfQkRbd15k" };
		let thrown: unknown = null;
		try {
			env.history.replaceState.call(receiver, replaceStateData, "");
		} catch (err) {
			thrown = err;
		}

		expect(thrown).toBe(error);
		expect(env.calls[0]?.method).toBe("replaceState");
		expect(env.calls[0]?.receiver).toBe(receiver);
		expect(env.calls[0]?.args).toEqual([replaceStateData, ""]);

		await nextMacrotask();

		expect(env.messages).toEqual([]);
	});
});
