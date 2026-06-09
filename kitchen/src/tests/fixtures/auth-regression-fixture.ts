export type AuthRegressionCase =
	| "same-window"
	| "cross-origin"
	| "popup-post-message"
	| "popup-noopener"
	| "popup-named-first"
	| "popup-named-second"
	| "popup-about-blank";

export type AuthRegressionReport = {
	caseName: AuthRegressionCase;
	href: string;
	origin: string;
	windowName: string;
	hasOpener: string;
	values: Record<string, string>;
	createdAt: number;
};

export type AuthRegressionFixtureUrls = {
	home: string;
	sameWindowStart: string;
	crossOriginStart: string;
	popupPostMessageChild: string;
	popupNoopenerChild: string;
	popupNamedFirst: string;
	popupNamedSecond: string;
	popupAboutBlankDone: string;
	externalProtocol: string;
};

export type AuthRegressionFixture = {
	primaryOrigin: string;
	secondaryOrigin: string;
	urls: AuthRegressionFixtureUrls;
	reports: () => AuthRegressionReport[];
	clearReports: () => void;
	waitForReport: (
		caseName: AuthRegressionCase,
		timeoutMs?: number
	) => Promise<AuthRegressionReport>;
	stop: () => void;
};

type FixtureRequestContext = {
	role: "primary" | "secondary";
	primaryOrigin: string;
	secondaryOrigin: string;
	reports: AuthRegressionReport[];
};

type ResultPageOptions = {
	caseName: AuthRegressionCase;
	title: string;
	primaryOrigin: string;
	secondaryOrigin: string;
};

const AUTH_FIXTURE_HOST = "127.0.0.1";

function htmlResponse(html: string, status = 200): Response {
	return new Response(html, {
		status,
		headers: { "Content-Type": "text/html; charset=utf-8" }
	});
}

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "Content-Type": "application/json; charset=utf-8" }
	});
}

function redirectResponse(url: string): Response {
	return new Response(null, {
		status: 302,
		headers: { Location: url }
	});
}

function authCaseName(value: string | null): AuthRegressionCase | null {
	switch (value) {
		case "same-window":
		case "cross-origin":
		case "popup-post-message":
		case "popup-noopener":
		case "popup-named-first":
		case "popup-named-second":
		case "popup-about-blank":
			return value;
		default:
			return null;
	}
}

function escapeHtml(value: string): string {
	return value.replace(/[&<>"']/g, (char) => {
		switch (char) {
			case "&":
				return "&amp;";
			case "<":
				return "&lt;";
			case ">":
				return "&gt;";
			case '"':
				return "&quot;";
			case "'":
				return "&#39;";
			default:
				return char;
		}
	});
}

function fixtureUrls(primaryOrigin: string, secondaryOrigin: string): AuthRegressionFixtureUrls {
	return {
		home: `${primaryOrigin}/`,
		sameWindowStart: `${primaryOrigin}/same-window/start`,
		crossOriginStart: `${primaryOrigin}/cross-origin/start`,
		popupPostMessageChild: `${primaryOrigin}/popup/post-message-child`,
		popupNoopenerChild: `${primaryOrigin}/popup/noopener-child`,
		popupNamedFirst: `${primaryOrigin}/popup/named-first`,
		popupNamedSecond: `${primaryOrigin}/popup/named-second`,
		popupAboutBlankDone: `${primaryOrigin}/popup/about-blank-done`,
		externalProtocol:
			"mailto:auth-regression@example.com?subject=Auth%20regression%20external%20protocol"
	};
}

function resultPage(opts: ResultPageOptions): string {
	const payload = {
		caseName: opts.caseName,
		href: "",
		origin: "",
		primaryOrigin: opts.primaryOrigin,
		secondaryOrigin: opts.secondaryOrigin
	};

	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHtml(opts.title)}</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; padding: 24px; color: #1f2937; }
  code { display: block; margin-top: 12px; padding: 10px; border: 1px solid #d1d5db; border-radius: 6px; background: #f9fafb; white-space: pre-wrap; word-break: break-all; }
</style>
</head>
<body>
<h1>${escapeHtml(opts.title)}</h1>
<p id="status">Completed ${escapeHtml(opts.caseName)}.</p>
<code id="result"></code>
<script>
  const result = ${JSON.stringify(payload)};
  result.href = window.location.href;
  result.origin = window.location.origin;
  window.__authRegressionResult = result;
  document.body.dataset.authResult = JSON.stringify(result);
  document.getElementById("result").textContent = JSON.stringify(result, null, 2);
</script>
</body>
</html>`;
}

function childReportScript(caseName: AuthRegressionCase): string {
	return `
function report(extra) {
  const params = new URLSearchParams();
  params.set("case", ${JSON.stringify(caseName)});
  params.set("href", window.location.href);
  params.set("origin", window.location.origin);
  params.set("windowName", window.name || "");
  params.set("hasOpener", String(!!window.opener));
  Object.keys(extra || {}).forEach(function(key) {
    params.set(key, String(extra[key]));
  });
  fetch("/api/report?" + params.toString()).catch(function() {});
}
`;
}

function popupChildPage(caseName: AuthRegressionCase, title: string, bodyScript: string): string {
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>${escapeHtml(title)}</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; padding: 20px; color: #1f2937; }
  code { display: block; margin-top: 10px; white-space: pre-wrap; word-break: break-all; }
</style>
</head>
<body>
<h1>${escapeHtml(title)}</h1>
<p id="status">Running popup fixture.</p>
<code id="details"></code>
<script>
${childReportScript(caseName)}
${bodyScript}
</script>
</body>
</html>`;
}

export function authRegressionHomeHtml(primaryOrigin: string, secondaryOrigin: string): string {
	const urls = fixtureUrls(primaryOrigin, secondaryOrigin);
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Auth Browser Regression Fixture</title>
<style>
  :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: Canvas; color: CanvasText; }
  body { margin: 0; padding: 24px; }
  main { display: grid; grid-template-columns: minmax(280px, 420px) minmax(320px, 1fr); gap: 18px; max-width: 1160px; margin: 0 auto; }
  h1 { margin: 0 0 6px; font-size: 22px; line-height: 1.2; }
  p { margin: 0 0 14px; color: color-mix(in srgb, CanvasText 68%, transparent); font-size: 13px; line-height: 1.45; }
  .panel { border: 1px solid color-mix(in srgb, CanvasText 14%, transparent); border-radius: 8px; padding: 14px; background: color-mix(in srgb, Canvas 94%, CanvasText 6%); }
  .stack { display: grid; gap: 10px; }
  button { min-height: 34px; border: 1px solid color-mix(in srgb, CanvasText 16%, transparent); border-radius: 7px; padding: 8px 10px; background: ButtonFace; color: ButtonText; font: inherit; font-size: 13px; text-align: left; cursor: pointer; }
  button:hover { background: color-mix(in srgb, ButtonFace 88%, CanvasText 12%); }
  code, #log { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; line-height: 1.45; white-space: pre-wrap; word-break: break-word; }
  #log { min-height: 360px; max-height: 620px; overflow: auto; }
  .meta { display: grid; gap: 6px; color: color-mix(in srgb, CanvasText 72%, transparent); }
  @media (max-width: 820px) { body { padding: 16px; } main { grid-template-columns: 1fr; } }
</style>
</head>
<body>
<main>
  <section class="stack">
    <div>
      <h1>Auth Browser Regression Fixture</h1>
      <p>Use these local cases to verify same-window redirects, cross-origin redirects, popup opener behavior, external protocol prompts, and permission request diagnostics. Apple Passwords is intentionally not covered here.</p>
    </div>
    <div class="panel stack">
      <button id="same-window">Same-window login redirect</button>
      <button id="cross-origin">Cross-origin IdP redirect</button>
      <button id="popup-post-message">Popup opener postMessage</button>
      <button id="popup-noopener">Popup noopener</button>
      <button id="popup-named">Named popup reuse</button>
      <button id="popup-about-blank">Initial about:blank write then navigate</button>
      <button id="external-protocol">External protocol prompt</button>
      <button id="permission-probe">Permission request probe</button>
    </div>
    <div class="panel meta">
      <code>Primary: ${escapeHtml(primaryOrigin)}</code>
      <code>Secondary: ${escapeHtml(secondaryOrigin)}</code>
    </div>
  </section>
  <section class="panel">
    <div id="log">Ready.</div>
  </section>
</main>
<script>
  const urls = ${JSON.stringify(urls)};
  const logEl = document.getElementById("log");

  function log(message, payload) {
    const entry = "[" + new Date().toLocaleTimeString() + "] " + message + (payload ? "\\n" + JSON.stringify(payload, null, 2) : "");
    logEl.textContent = entry + "\\n\\n" + logEl.textContent;
    console.log("[auth-regression-fixture]", message, payload || "");
  }

  window.addEventListener("message", function(event) {
    log("postMessage received", { origin: event.origin, data: event.data });
  });

  document.getElementById("same-window").addEventListener("click", function() {
    log("Navigating current window to same-window redirect", { url: urls.sameWindowStart });
    window.location.href = urls.sameWindowStart;
  });

  document.getElementById("cross-origin").addEventListener("click", function() {
    log("Navigating current window to cross-origin redirect", { url: urls.crossOriginStart });
    window.location.href = urls.crossOriginStart;
  });

  document.getElementById("popup-post-message").addEventListener("click", function() {
    const popup = window.open(urls.popupPostMessageChild, "authPostMessage", "width=480,height=360,left=160,top=120");
    log("window.open postMessage popup", { returnedWindow: !!popup, openerVisibleFromParent: !!popup && popup.opener === window });
  });

  document.getElementById("popup-noopener").addEventListener("click", function() {
    const popup = window.open(urls.popupNoopenerChild, "authNoopener", "noopener,width=480,height=360,left=190,top=150");
    log("window.open noopener popup", { returnedWindow: !!popup, returnedNull: popup === null });
  });

  document.getElementById("popup-named").addEventListener("click", function() {
    const first = window.open(urls.popupNamedFirst, "authNamedWindow", "width=480,height=360,left=220,top=180");
    window.setTimeout(function() {
      const second = window.open(urls.popupNamedSecond, "authNamedWindow", "width=480,height=360,left=240,top=200");
      log("named popup reuse", { firstOpened: !!first, secondOpened: !!second, sameWindowProxy: first === second });
    }, 400);
  });

  document.getElementById("popup-about-blank").addEventListener("click", function() {
    const popup = window.open("", "authAboutBlank", "width=480,height=360,left=250,top=210");
    if (!popup) {
      log("about:blank popup failed", { returnedWindow: false });
      return;
    }
    const startsBlank = popup.location.href === "about:blank";
    popup.document.open();
    popup.document.write("<!doctype html><title>Auth about:blank</title><main id='status'>written before navigation</main>");
    popup.document.close();
    const writtenText = popup.document.getElementById("status") ? popup.document.getElementById("status").textContent : "";
    popup.location.href = urls.popupAboutBlankDone;
    log("about:blank popup write then navigate", { startsBlank: startsBlank, writtenText: writtenText });
  });

  document.getElementById("external-protocol").addEventListener("click", function() {
    log("Navigating to external protocol", { url: urls.externalProtocol });
    window.location.href = urls.externalProtocol;
  });

  document.getElementById("permission-probe").addEventListener("click", async function() {
    if (typeof Notification !== "undefined" && typeof Notification.requestPermission === "function") {
      log("Requesting notification permission");
      try {
        const result = await Notification.requestPermission();
        log("Notification permission result", { result: result });
      } catch (error) {
        log("Notification permission error", { error: String(error) });
      }
      return;
    }
    if (navigator.geolocation && navigator.geolocation.getCurrentPosition) {
      log("Requesting geolocation permission");
      navigator.geolocation.getCurrentPosition(
        function(position) { log("Geolocation granted", { latitude: position.coords.latitude, longitude: position.coords.longitude }); },
        function(error) { log("Geolocation denied/error", { message: error.message }); }
      );
      return;
    }
    log("No notification or geolocation permission API available");
  });
</script>
</body>
</html>`;
}

function recordReport(url: URL, reports: AuthRegressionReport[]): Response {
	const caseName = authCaseName(url.searchParams.get("case"));
	if (!caseName) return jsonResponse({ ok: false, error: "Unknown case." }, 400);

	const values: Record<string, string> = {};
	for (const [key, value] of url.searchParams.entries()) {
		if (key === "case") continue;
		values[key] = value;
	}

	const report: AuthRegressionReport = {
		caseName,
		href: url.searchParams.get("href") ?? "",
		origin: url.searchParams.get("origin") ?? "",
		windowName: url.searchParams.get("windowName") ?? "",
		hasOpener: url.searchParams.get("hasOpener") ?? "",
		values,
		createdAt: Date.now()
	};
	reports.push(report);
	return jsonResponse({ ok: true, report });
}

function handlePrimaryRequest(url: URL, ctx: FixtureRequestContext): Response {
	if (url.pathname === "/") {
		return htmlResponse(authRegressionHomeHtml(ctx.primaryOrigin, ctx.secondaryOrigin));
	}

	if (url.pathname === "/same-window/start") {
		return redirectResponse(`${ctx.primaryOrigin}/same-window/done?state=same-window`);
	}

	if (url.pathname === "/same-window/done") {
		return htmlResponse(
			resultPage({
				caseName: "same-window",
				title: "Same-window redirect complete",
				primaryOrigin: ctx.primaryOrigin,
				secondaryOrigin: ctx.secondaryOrigin
			})
		);
	}

	if (url.pathname === "/cross-origin/start") {
		const callback = `${ctx.primaryOrigin}/cross-origin/done?state=cross-origin`;
		return redirectResponse(
			`${ctx.secondaryOrigin}/cross-origin/idp?returnTo=${encodeURIComponent(callback)}`
		);
	}

	if (url.pathname === "/cross-origin/done") {
		return htmlResponse(
			resultPage({
				caseName: "cross-origin",
				title: "Cross-origin redirect complete",
				primaryOrigin: ctx.primaryOrigin,
				secondaryOrigin: ctx.secondaryOrigin
			})
		);
	}

	if (url.pathname === "/popup/post-message-child") {
		return htmlResponse(
			popupChildPage(
				"popup-post-message",
				"Popup postMessage child",
				`
const payload = {
  caseName: "popup-post-message",
  href: window.location.href,
  origin: window.location.origin,
  hasOpener: !!window.opener,
  windowName: window.name || ""
};
document.getElementById("details").textContent = JSON.stringify(payload, null, 2);
report({ messageSent: String(!!window.opener) });
if (window.opener) {
  window.opener.postMessage(payload, "*");
}
window.setTimeout(function() { window.close(); }, 600);
`
			)
		);
	}

	if (url.pathname === "/popup/noopener-child") {
		return htmlResponse(
			popupChildPage(
				"popup-noopener",
				"Popup noopener child",
				`
const payload = {
  caseName: "popup-noopener",
  href: window.location.href,
  origin: window.location.origin,
  hasOpener: !!window.opener,
  windowName: window.name || ""
};
document.getElementById("details").textContent = JSON.stringify(payload, null, 2);
report({ noopenerExpected: "true" });
window.setTimeout(function() { window.close(); }, 600);
`
			)
		);
	}

	if (url.pathname === "/popup/named-first") {
		return htmlResponse(
			popupChildPage(
				"popup-named-first",
				"Named popup first load",
				`
document.getElementById("details").textContent = "name=" + (window.name || "");
report({ phase: "first" });
`
			)
		);
	}

	if (url.pathname === "/popup/named-second") {
		return htmlResponse(
			popupChildPage(
				"popup-named-second",
				"Named popup second load",
				`
document.getElementById("details").textContent = "name=" + (window.name || "");
report({ phase: "second" });
window.setTimeout(function() { window.close(); }, 700);
`
			)
		);
	}

	if (url.pathname === "/popup/about-blank-done") {
		return htmlResponse(
			popupChildPage(
				"popup-about-blank",
				"about:blank popup final page",
				`
document.getElementById("details").textContent = "opener=" + String(!!window.opener) + "\\nname=" + (window.name || "");
report({ navigatedAfterWrite: "true" });
window.setTimeout(function() { window.close(); }, 700);
`
			)
		);
	}

	if (url.pathname === "/api/report") {
		return recordReport(url, ctx.reports);
	}

	if (url.pathname === "/api/reports") {
		return jsonResponse({ reports: ctx.reports });
	}

	return htmlResponse("Not found", 404);
}

function handleSecondaryRequest(url: URL, ctx: FixtureRequestContext): Response {
	if (url.pathname === "/cross-origin/idp") {
		const returnTo = url.searchParams.get("returnTo");
		if (!returnTo) return htmlResponse("Missing returnTo", 400);
		return redirectResponse(returnTo);
	}

	return htmlResponse(
		resultPage({
			caseName: "cross-origin",
			title: "Secondary IdP origin",
			primaryOrigin: ctx.primaryOrigin,
			secondaryOrigin: ctx.secondaryOrigin
		})
	);
}

function handleAuthFixtureRequest(request: Request, ctx: FixtureRequestContext): Response {
	const url = new URL(request.url);
	if (ctx.role === "secondary") return handleSecondaryRequest(url, ctx);
	return handlePrimaryRequest(url, ctx);
}

async function wait(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

export function startAuthRegressionFixture(): AuthRegressionFixture {
	const reports: AuthRegressionReport[] = [];
	let primaryOrigin = "";
	let secondaryOrigin = "";

	const secondary = Bun.serve({
		hostname: AUTH_FIXTURE_HOST,
		port: 0,
		fetch(request: Request) {
			return handleAuthFixtureRequest(request, {
				role: "secondary",
				primaryOrigin,
				secondaryOrigin,
				reports
			});
		}
	});
	secondaryOrigin = `http://${AUTH_FIXTURE_HOST}:${secondary.port}`;

	const primary = Bun.serve({
		hostname: AUTH_FIXTURE_HOST,
		port: 0,
		fetch(request: Request) {
			return handleAuthFixtureRequest(request, {
				role: "primary",
				primaryOrigin,
				secondaryOrigin,
				reports
			});
		}
	});
	primaryOrigin = `http://${AUTH_FIXTURE_HOST}:${primary.port}`;

	return {
		primaryOrigin,
		secondaryOrigin,
		urls: fixtureUrls(primaryOrigin, secondaryOrigin),
		reports: () => [...reports],
		clearReports: () => {
			reports.length = 0;
		},
		waitForReport: async (caseName, timeoutMs = 6000) => {
			const startedAt = Date.now();
			while (Date.now() - startedAt < timeoutMs) {
				const report = reports.find((entry) => entry.caseName === caseName);
				if (report) return report;
				await wait(50);
			}
			throw new Error(
				`Timed out waiting for auth regression report ${caseName}. Reports: ${JSON.stringify(
					reports
				)}`
			);
		},
		stop: () => {
			primary.stop(true);
			secondary.stop(true);
		}
	};
}
