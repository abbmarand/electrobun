import { expect, test } from "bun:test";
import { startAuthRegressionFixture } from "./auth-regression-fixture";

test("auth regression fixture completes same-window and cross-origin redirects", async () => {
	const fixture = startAuthRegressionFixture();
	try {
		const sameWindow = await fetch(fixture.urls.sameWindowStart);
		expect(sameWindow.url).toContain("/same-window/done");
		expect(await sameWindow.text()).toContain("Same-window redirect complete");

		const crossOrigin = await fetch(fixture.urls.crossOriginStart);
		expect(crossOrigin.url).toContain("/cross-origin/done");
		expect(crossOrigin.url.startsWith(fixture.primaryOrigin)).toBe(true);
		expect(await crossOrigin.text()).toContain("Cross-origin redirect complete");
	} finally {
		fixture.stop();
	}
});

test("auth regression fixture records popup reports", async () => {
	const fixture = startAuthRegressionFixture();
	try {
		const reportUrl = new URL(`${fixture.primaryOrigin}/api/report`);
		reportUrl.searchParams.set("case", "popup-noopener");
		reportUrl.searchParams.set("href", `${fixture.primaryOrigin}/popup/noopener-child`);
		reportUrl.searchParams.set("origin", fixture.primaryOrigin);
		reportUrl.searchParams.set("windowName", "authNoopener");
		reportUrl.searchParams.set("hasOpener", "false");

		const response = await fetch(reportUrl);
		expect(response.status).toBe(200);

		const report = await fixture.waitForReport("popup-noopener");
		expect(report.caseName).toBe("popup-noopener");
		expect(report.hasOpener).toBe("false");
		expect(report.windowName).toBe("authNoopener");
	} finally {
		fixture.stop();
	}
});
