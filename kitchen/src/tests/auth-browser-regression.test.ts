// Auth/browser regression tests for OAuth/SAML-style redirects and popups.

import { defineTest, expect, type TestWindow } from "../test-framework/types";
import {
	type AuthRegressionCase,
	startAuthRegressionFixture
} from "./fixtures/auth-regression-fixture";

type JsonRecord = Record<string, unknown>;

type AuthPageResult = {
	caseName: string;
	href: string;
	origin: string;
};

function isRecord(value: unknown): value is JsonRecord {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function readEventDetail(event: unknown): unknown {
	if (!isRecord(event)) return null;
	if ("detail" in event) return event.detail;
	const data = event.data;
	if (isRecord(data) && "detail" in data) return data.detail;
	return null;
}

function eventDetailForLog(event: unknown): string {
	const detail = readEventDetail(event);
	if (typeof detail === "string") return detail;
	if (detail === null || detail === undefined) return "";
	try {
		return JSON.stringify(detail);
	} catch {
		return String(detail);
	}
}

function parseJsonRecord(raw: string | null): JsonRecord | null {
	if (!raw) return null;
	try {
		const parsed: unknown = JSON.parse(raw);
		return isRecord(parsed) ? parsed : null;
	} catch {
		return null;
	}
}

function stringField(record: JsonRecord, key: string): string | null {
	const value = record[key];
	return typeof value === "string" ? value : null;
}

function booleanField(record: JsonRecord, key: string): boolean | null {
	const value = record[key];
	return typeof value === "boolean" ? value : null;
}

function parseAuthPageResult(raw: string | null): AuthPageResult | null {
	const record = parseJsonRecord(raw);
	if (!record) return null;
	const caseName = stringField(record, "caseName");
	const href = stringField(record, "href");
	const origin = stringField(record, "origin");
	if (!caseName || !href || !origin) return null;
	return { caseName, href, origin };
}

async function wait(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForPageResult(
	win: TestWindow,
	caseName: AuthRegressionCase,
	timeoutMs = 8000
): Promise<AuthPageResult> {
	const startedAt = Date.now();
	while (Date.now() - startedAt < timeoutMs) {
		const raw = win.webview.executeJavascriptSync(
			`(() => document.body ? document.body.dataset.authResult || "" : "")()`
		);
		const result = parseAuthPageResult(raw);
		if (result?.caseName === caseName) return result;
		await wait(100);
	}
	throw new Error(`Timed out waiting for ${caseName} page result`);
}

async function waitForWindowRecord(
	win: TestWindow,
	expression: string,
	predicate: (record: JsonRecord) => boolean,
	timeoutMs = 6000
): Promise<JsonRecord> {
	const startedAt = Date.now();
	while (Date.now() - startedAt < timeoutMs) {
		const raw = win.webview.executeJavascriptSync(`
(() => {
  const value = ${expression};
  return value ? JSON.stringify(value) : "";
})()
    `);
		const record = parseJsonRecord(raw);
		if (record && predicate(record)) return record;
		await wait(100);
	}
	throw new Error(`Timed out waiting for browser expression ${expression}`);
}

function popupOpenScript(url: string, name: string, features: string): string {
	return `(() => {
  const popup = window.open(${JSON.stringify(url)}, ${JSON.stringify(name)}, ${JSON.stringify(features)});
  return JSON.stringify({
    opened: !!popup,
    returnedNull: popup === null,
    openerIsParent: !!popup && popup.opener === window
  });
})()`;
}

export const authBrowserRegressionTests = [
	defineTest({
		name: "Auth redirects stay in the same native window",
		category: "Authentication",
		description:
			"Covers same-window login redirects and cross-origin IdP redirects without opening a new app window.",
		timeout: 25000,
		async run({ createWindow, log }) {
			const fixture = startAuthRegressionFixture();
			const navigationLog: string[] = [];

			try {
				const win = await createWindow({
					url: fixture.urls.home,
					title: "Auth Redirect Regression",
					width: 820,
					height: 620,
					renderer: "native"
				});

				win.webview.on("will-navigate", (event: unknown) => {
					navigationLog.push(`will ${eventDetailForLog(event)}`);
				});
				win.webview.on("did-navigate", (event: unknown) => {
					navigationLog.push(`did ${eventDetailForLog(event)}`);
				});
				win.webview.on("did-commit-navigation", (event: unknown) => {
					navigationLog.push(`commit ${eventDetailForLog(event)}`);
				});

				await wait(500);

				win.webview.loadURL(fixture.urls.sameWindowStart);
				const sameWindow = await waitForPageResult(win, "same-window");
				expect(sameWindow.href.startsWith(fixture.primaryOrigin)).toBe(true);
				expect(sameWindow.href).toContain("/same-window/done");
				log(`same-window result: ${sameWindow.href}`);

				win.webview.loadURL(fixture.urls.crossOriginStart);
				const crossOrigin = await waitForPageResult(win, "cross-origin");
				expect(crossOrigin.href.startsWith(fixture.primaryOrigin)).toBe(true);
				expect(crossOrigin.href).toContain("/cross-origin/done");
				expect(navigationLog.some((entry) => entry.includes(fixture.secondaryOrigin))).toBe(true);
				log(`cross-origin result: ${crossOrigin.href}`);
				log(`navigation events:\n${navigationLog.join("\n")}`);
			} finally {
				fixture.stop();
			}
		}
	}),

	defineTest({
		name: "Auth popup opener postMessage and noopener",
		category: "Authentication",
		description: "Covers popup opener postMessage delivery and noopener isolation for login flows.",
		timeout: 25000,
		async run({ createWindow, log }) {
			if (process.platform !== "darwin") {
				log("Skipping native WK popup regression on non-macOS platform");
				return;
			}

			const fixture = startAuthRegressionFixture();
			const popupLog: string[] = [];

			try {
				const win = await createWindow({
					url: fixture.urls.home,
					title: "Auth Popup Regression",
					width: 820,
					height: 620,
					renderer: "native"
				});

				win.webview.on("new-window-open", (event: unknown) => {
					popupLog.push(eventDetailForLog(event));
				});
				win.webview.on("permission-requested", (event: unknown) => {
					popupLog.push(`permission ${eventDetailForLog(event)}`);
				});

				await wait(500);

				const openPostMessageRaw = win.webview.executeJavascriptSync(`
(() => {
  window.__authRegressionPostMessage = null;
  window.addEventListener("message", function(event) {
    window.__authRegressionPostMessage = {
      received: true,
      origin: event.origin,
      data: event.data
    };
  }, { once: true });
  return ${popupOpenScript(
		fixture.urls.popupPostMessageChild,
		"authPostMessage",
		"width=480,height=360,left=160,top=120"
	)};
})()
        `);
				const openPostMessage = parseJsonRecord(openPostMessageRaw);
				expect(booleanField(openPostMessage ?? {}, "opened")).toBe(true);
				expect(booleanField(openPostMessage ?? {}, "openerIsParent")).toBe(true);

				const message = await waitForWindowRecord(
					win,
					"window.__authRegressionPostMessage",
					(record) => booleanField(record, "received") === true
				);
				const data = message.data;
				if (!isRecord(data)) throw new Error("Expected postMessage data object");
				expect(stringField(data, "caseName")).toBe("popup-post-message");
				expect(booleanField(data, "hasOpener")).toBe(true);

				const postMessageReport = await fixture.waitForReport("popup-post-message");
				expect(postMessageReport.hasOpener).toBe("true");
				log(`postMessage report: ${JSON.stringify(postMessageReport)}`);

				fixture.clearReports();
				const openNoopener = parseJsonRecord(
					win.webview.executeJavascriptSync(
						popupOpenScript(
							fixture.urls.popupNoopenerChild,
							"authNoopener",
							"noopener,width=480,height=360,left=190,top=150"
						)
					)
				);
				expect(openNoopener).toBeDefined();

				const noopenerReport = await fixture.waitForReport("popup-noopener");
				expect(noopenerReport.hasOpener).toBe("false");
				log(`noopener report: ${JSON.stringify(noopenerReport)}`);
				log(`popup/permission events:\n${popupLog.join("\n") || "(none emitted)"}`);
			} finally {
				fixture.stop();
			}
		}
	}),

	defineTest({
		name: "Auth popup named reuse and about blank lifecycle",
		category: "Authentication",
		description:
			"Covers named popup reuse and the initial about:blank document write before navigation.",
		timeout: 25000,
		async run({ createWindow, log }) {
			if (process.platform !== "darwin") {
				log("Skipping native WK popup regression on non-macOS platform");
				return;
			}

			const fixture = startAuthRegressionFixture();

			try {
				const win = await createWindow({
					url: fixture.urls.home,
					title: "Auth Popup Lifecycle Regression",
					width: 820,
					height: 620,
					renderer: "native"
				});

				await wait(500);

				const namedRaw = win.webview.executeJavascriptSync(`
(() => {
  const first = window.open(${JSON.stringify(
		fixture.urls.popupNamedFirst
	)}, "authNamedWindow", "width=480,height=360,left=220,top=180");
  if (!first) return JSON.stringify({ opened: false, sameWindowProxy: false, firstName: "", secondName: "" });
  const firstName = first.name || "";
  const second = window.open(${JSON.stringify(
		fixture.urls.popupNamedSecond
	)}, "authNamedWindow", "width=480,height=360,left=240,top=200");
  return JSON.stringify({
    opened: true,
    sameWindowProxy: first === second,
    firstName,
    secondName: second ? second.name || "" : ""
  });
})()
        `);
				const named = parseJsonRecord(namedRaw);
				expect(booleanField(named ?? {}, "opened")).toBe(true);
				expect(booleanField(named ?? {}, "sameWindowProxy")).toBe(true);
				expect(stringField(named ?? {}, "firstName")).toBe("authNamedWindow");

				const namedReport = await fixture.waitForReport("popup-named-second");
				expect(namedReport.windowName).toBe("authNamedWindow");
				log(`named-window report: ${JSON.stringify(namedReport)}`);

				fixture.clearReports();
				const aboutBlankRaw = win.webview.executeJavascriptSync(`
(() => {
  const popup = window.open("", "authAboutBlank", "width=480,height=360,left=250,top=210");
  if (!popup) {
    return JSON.stringify({ opened: false, startsBlank: false, wrote: false, openerIsParent: false, text: "" });
  }
  const startsBlank = popup.location.href === "about:blank";
  popup.document.open();
  popup.document.write("<!doctype html><title>Auth about blank</title><main id='status'>written before navigation</main>");
  popup.document.close();
  const status = popup.document.getElementById("status");
  const text = status ? status.textContent || "" : "";
  const openerIsParent = popup.opener === window;
  popup.location.href = ${JSON.stringify(fixture.urls.popupAboutBlankDone)};
  return JSON.stringify({
    opened: true,
    startsBlank,
    wrote: text === "written before navigation",
    openerIsParent,
    text
  });
})()
        `);
				const aboutBlank = parseJsonRecord(aboutBlankRaw);
				expect(booleanField(aboutBlank ?? {}, "opened")).toBe(true);
				expect(booleanField(aboutBlank ?? {}, "startsBlank")).toBe(true);
				expect(booleanField(aboutBlank ?? {}, "wrote")).toBe(true);
				expect(booleanField(aboutBlank ?? {}, "openerIsParent")).toBe(true);

				const aboutBlankReport = await fixture.waitForReport("popup-about-blank");
				expect(aboutBlankReport.hasOpener).toBe("true");
				expect(aboutBlankReport.values.navigatedAfterWrite).toBe("true");
				log(`about:blank report: ${JSON.stringify(aboutBlankReport)}`);
			} finally {
				fixture.stop();
			}
		}
	})
];
