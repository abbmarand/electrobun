// Default Bun version shipped with this Electrobun release.
// All platforms use the same version. Update this when bumping Bun.
export const BUN_VERSION = "1.3.14";

/** Maps a Bun version override to its official oven-sh/bun release tag. */
export function getBunReleaseTag(version: string): string {
	if (version === "canary") {
		return "canary";
	}

	return `bun-v${version}`;
}
