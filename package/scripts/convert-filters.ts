/**
 * Downloads pre-converted WebKit Content Blocker JSON from
 * bnema/ublock-webkit-filters GitHub releases (updated daily).
 * Falls back to downloading raw ABP lists and converting locally.
 *
 * Usage:  bun run scripts/convert-filters.ts [--output <dir>]
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { parseArgs } from "node:util";

const RULES_PER_CHUNK = 50_000;

const RELEASE_BASE = "https://github.com/bnema/ublock-webkit-filters/releases/latest/download";
const MANIFEST_URL = `${RELEASE_BASE}/manifest.json`;

const ABP_LIST_URLS = [
	"https://easylist.to/easylist/easylist.txt",
	"https://easylist.to/easylist/easyprivacy.txt",
];

const { values: args } = parseArgs({
	args: Bun.argv,
	options: {
		output: { type: "string", default: join(process.cwd(), "dist", "content-blockers") },
	},
	allowPositionals: true,
});

const outputDir = typeof args.output === "string" ? args.output : join(process.cwd(), "dist", "content-blockers");

type ContentBlockerManifestBase = {
	source: string;
	upstreamManifestKey?: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function recordValue(value: unknown, key: string): Record<string, unknown> | null {
	if (!isRecord(value)) return null;
	const next = value[key];
	return isRecord(next) ? next : null;
}

function stringArrayValue(value: unknown, key: string): string[] {
	if (!isRecord(value)) return [];
	const next = value[key];
	if (!Array.isArray(next)) return [];
	const out: string[] = [];
	for (const item of next) {
		if (typeof item === "string") out.push(item);
	}
	return out;
}

function contentBlockerNativeJson(json: string): string {
	const trimmed = json.trim();
	if (!trimmed.endsWith("]")) return json;
	return `${trimmed.slice(0, -1)},{"trigger":{"url-filter":".*","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}}]`;
}

function contentBlockerRuleListIdentifier(json: string): string {
	const hash = createHash("sha256").update(contentBlockerNativeJson(json)).digest("hex");
	return `electrobun_cb_v3_${hash.slice(0, 16)}`;
}

// ---- Download helpers ----

async function downloadJSON(url: string): Promise<unknown> {
	console.log(`Downloading ${url}...`);
	const resp = await fetch(url);
	if (!resp.ok) throw new Error(`${resp.status} ${resp.statusText}`);
	return resp.json();
}

async function downloadText(url: string): Promise<string> {
	console.log(`Downloading ${url}...`);
	const resp = await fetch(url);
	if (!resp.ok) throw new Error(`${resp.status} ${resp.statusText}`);
	return resp.text();
}

// ---- Primary: download pre-converted files from bnema/ublock-webkit-filters ----

async function tryPreconverted(): Promise<boolean> {
	try {
		const manifest = await downloadJSON(MANIFEST_URL);
		if (!isRecord(manifest)) throw new Error("Invalid manifest");

		const combined = recordValue(manifest, "combined");
		if (!combined) throw new Error("No combined section in manifest");
		const files = stringArrayValue(combined, "files");
		if (files.length === 0) throw new Error("No combined parts in manifest");
		// Sort so part1 comes before part2, etc.
		const partFiles = files.filter(f => f.startsWith("combined-part")).sort();
		if (partFiles.length === 0) throw new Error("No combined-part files found");

		const allRules: unknown[] = [];
		for (const filename of partFiles) {
			const url = `${RELEASE_BASE}/${filename}`;
			const rules = await downloadJSON(url);
			if (!Array.isArray(rules)) throw new Error(`${filename} is not an array`);
			allRules.push(...rules);
		}

		writeChunks(allRules, outputDir, {
			source: "bnema/ublock-webkit-filters",
			upstreamManifestKey: JSON.stringify(manifest),
		});

		console.log(`Downloaded ${allRules.length} pre-converted rules`);
		return true;
	} catch (e) {
		console.log(`Pre-converted download failed: ${e}`);
		console.log("Falling back to local ABP conversion...");
		return false;
	}
}

// ---- Fallback: ABP to WebKit Content Blocker conversion ----

type ContentBlockerRule = {
	trigger: {
		"url-filter": string;
		"load-type"?: string[];
		"resource-type"?: string[];
		"if-domain"?: string[];
		"unless-domain"?: string[];
	};
	action: {
		type: "block" | "block-cookies" | "css-display-none" | "ignore-previous-rules";
		selector?: string;
	};
};

function escapeRegex(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function convertAbpLine(line: string): ContentBlockerRule | null {
	line = line.trim();
	if (!line || line.startsWith("!") || line.startsWith("[")) return null;

	// Cosmetic filter: ##selector or domain##selector
	const cosmeticMatch = line.match(/^([^#]*?)##(.+)$/);
	if (cosmeticMatch) {
		const domains = cosmeticMatch[1];
		const selector = cosmeticMatch[2];
		if (!selector) return null;

		if (selector.includes(":has(") || selector.includes(":has-text(") ||
			selector.includes(":style(") || selector.includes(":matches-css(") ||
			selector.includes(":xpath(") || selector.includes(":remove()")) {
			return null;
		}

		const rule: ContentBlockerRule = {
			trigger: { "url-filter": ".*" },
			action: { type: "css-display-none", selector },
		};

		if (domains) {
			const domainList = domains.split(",").map(d => d.trim()).filter(Boolean);
			const ifDomains: string[] = [];
			const unlessDomains: string[] = [];
			for (const d of domainList) {
				if (d.startsWith("~")) {
					unlessDomains.push("*" + d.slice(1));
				} else {
					ifDomains.push("*" + d);
				}
			}
			if (ifDomains.length > 0) rule.trigger["if-domain"] = ifDomains;
			if (unlessDomains.length > 0) rule.trigger["unless-domain"] = unlessDomains;
		}

		return rule;
	}

	const isException = line.startsWith("@@");
	if (isException) line = line.slice(2);

	// ||domain^ style
	const domainMatch = line.match(/^\|\|([a-zA-Z0-9._-]+)\^?\s*(\$.*)?$/);
	if (domainMatch) {
		const domain = domainMatch[1];
		if (!domain) return null;
		const options = domainMatch[2] || "";

		const urlFilter = "^[^:]+://+([^:/]+\\.)?" + escapeRegex(domain);

		const rule: ContentBlockerRule = {
			trigger: { "url-filter": urlFilter },
			action: { type: isException ? "ignore-previous-rules" : "block" },
		};

		if (!isException && !options.includes("first-party")) {
			rule.trigger["load-type"] = ["third-party"];
		}

		applyOptions(rule, options);
		return rule;
	}

	// |https://... exact start
	if (line.startsWith("|") && !line.startsWith("||")) {
		const pattern = line.slice(1).replace(/\$.*$/, "");
		const options = line.includes("$") ? "$" + line.split("$")[1] : "";

		const urlFilter = "^" + escapeRegex(pattern).replace(/\\\*/g, ".*");
		const rule: ContentBlockerRule = {
			trigger: { "url-filter": urlFilter },
			action: { type: isException ? "ignore-previous-rules" : "block" },
		};
		applyOptions(rule, options);
		return rule;
	}

	// Plain pattern: /ads/ or ads.js etc
	const plainPattern = line.replace(/\$.*$/, "");
	const plainOptions = line.includes("$") ? "$" + line.split("$")[1] : "";

	if (plainPattern.length < 3) return null;
	if (plainPattern.startsWith("/") && plainPattern.endsWith("/")) return null;

	const urlFilter = escapeRegex(plainPattern)
		.replace(/\\\*/g, ".*")
		.replace(/\\\^/g, "[^a-zA-Z0-9_.%-]");

	if (!urlFilter) return null;

	const rule: ContentBlockerRule = {
		trigger: { "url-filter": urlFilter },
		action: { type: isException ? "ignore-previous-rules" : "block" },
	};
	applyOptions(rule, plainOptions);
	return rule;
}

function applyOptions(rule: ContentBlockerRule, options: string) {
	if (!options || !options.startsWith("$")) return;
	const opts = options.slice(1).split(",");

	const resourceTypes: string[] = [];
	for (const opt of opts) {
		const trimmed = opt.trim();
		switch (trimmed) {
			case "script": resourceTypes.push("script"); break;
			case "image": resourceTypes.push("image"); break;
			case "stylesheet": resourceTypes.push("style-sheet"); break;
			case "font": resourceTypes.push("font"); break;
			case "media": resourceTypes.push("media"); break;
			case "xmlhttprequest": resourceTypes.push("raw"); break;
			case "subdocument": resourceTypes.push("document"); break;
			case "popup": resourceTypes.push("popup"); break;
			case "third-party": rule.trigger["load-type"] = ["third-party"]; break;
			case "first-party": rule.trigger["load-type"] = ["first-party"]; break;
		}

		if (trimmed.startsWith("domain=")) {
			const domainSpec = trimmed.slice(7);
			const domains = domainSpec.split("|");
			const ifDomains: string[] = [];
			const unlessDomains: string[] = [];
			for (const d of domains) {
				if (d.startsWith("~")) {
					unlessDomains.push("*" + d.slice(1));
				} else {
					ifDomains.push("*" + d);
				}
			}
			if (ifDomains.length > 0) rule.trigger["if-domain"] = ifDomains;
			if (unlessDomains.length > 0) rule.trigger["unless-domain"] = unlessDomains;
		}
	}

	if (resourceTypes.length > 0) {
		rule.trigger["resource-type"] = resourceTypes;
	}
}

function convertAbpList(abpText: string): ContentBlockerRule[] {
	const rules: ContentBlockerRule[] = [];
	for (const line of abpText.split("\n")) {
		const rule = convertAbpLine(line);
		if (rule) rules.push(rule);
	}
	return rules;
}

async function convertFromAbp(): Promise<ContentBlockerRule[]> {
	const allRules: ContentBlockerRule[] = [];
	for (const url of ABP_LIST_URLS) {
		const text = await downloadText(url);
		const rules = convertAbpList(text);
		console.log(`Converted ${rules.length} rules from ${url}`);
		allRules.push(...rules);
	}
	return allRules;
}

function writeChunks(
	rules: unknown[],
	outDir: string,
	manifestBase: ContentBlockerManifestBase = { source: "local-abp-conversion" }
) {
	mkdirSync(outDir, { recursive: true });

	const totalChunks = Math.ceil(rules.length / RULES_PER_CHUNK);
	const ruleLists: Array<{ file: string; identifier: string }> = [];
	for (let i = 0; i < totalChunks; i++) {
		const chunk = rules.slice(i * RULES_PER_CHUNK, (i + 1) * RULES_PER_CHUNK);
		const text = JSON.stringify(chunk);
		const outputFile = `content-blockers-${i + 1}.json`;
		const filePath = join(outDir, outputFile);
		writeFileSync(filePath, text);
		ruleLists.push({
			file: outputFile,
			identifier: contentBlockerRuleListIdentifier(text),
		});
		console.log(`Wrote ${chunk.length} rules to ${filePath}`);
	}

	writeFileSync(
		join(outDir, "manifest.json"),
		JSON.stringify({
			...manifestBase,
			totalRules: rules.length,
			chunks: totalChunks,
			ruleLists,
			generatedAt: new Date().toISOString(),
		}, null, 2),
	);
}

// ---- Main ----

async function main() {
	console.log("Preparing WebKit Content Blocker rules...");

	if (await tryPreconverted()) {
		console.log(`Done! Output in ${outputDir}`);
		return;
	}

	const rules = await convertFromAbp();

	if (rules.length === 0) {
		console.error("No rules converted!");
		process.exit(1);
	}

	const seen = new Set<string>();
	const deduped: ContentBlockerRule[] = [];
	for (const rule of rules) {
		const key = rule.trigger["url-filter"] + "|" + rule.action.type + "|" + (rule.action.selector || "");
		if (!seen.has(key)) {
			seen.add(key);
			deduped.push(rule);
		}
	}
	console.log(`Deduplicated: ${rules.length} -> ${deduped.length} rules`);

	writeChunks(deduped, outputDir);
	console.log(`Done! Output in ${outputDir}`);
}

main().catch((e) => {
	console.error("Filter conversion failed:", e);
	process.exit(1);
});
