import { describe, expect, it } from "bun:test";
import { getBunReleaseTag } from "./bun-version";

describe("getBunReleaseTag", () => {
	it("maps stable versions to versioned release tags", () => {
		expect(getBunReleaseTag("1.3.14")).toBe("bun-v1.3.14");
	});

	it("maps canary to Bun's official moving release tag", () => {
		expect(getBunReleaseTag("canary")).toBe("canary");
	});
});
