/**
 * System prompt drift diagnostics.
 *
 * The system prompt heads every provider request, so any byte that changes in
 * it invalidates the provider's prefix cache for the whole transcript. On a
 * single-slot local engine that means re-prefilling hundreds of thousands of
 * tokens. When the prompt a primary model call sends differs from the previous
 * one (in this process, or the one a resumed transcript recorded), this logs
 * where it changed: the block, the nearest heading, and both sides of the first
 * differing span.
 *
 * Snapshots are written under `<logs>/prompt-snapshots/<digest>.json`, so a
 * resumed process can still diff against the prompt the transcript was sent
 * with. Files older than {@link SNAPSHOT_MAX_AGE_MS} are pruned.
 */
import * as fs from "node:fs/promises";
import * as path from "node:path";
import { getLogsDir, logger } from "@oh-my-pi/pi-utils";

const SNAPSHOT_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;
const CONTEXT_CHARS = 160;

export interface PromptDriftReport {
	blockIndex: number;
	blockCountBefore: number;
	blockCountAfter: number;
	offset: number;
	heading: string | undefined;
	before: string;
	after: string;
	charsBefore: number;
	charsAfter: number;
}

function snapshotDir(): string {
	return path.join(getLogsDir(), "prompt-snapshots");
}

function nearestHeading(text: string, offset: number): string | undefined {
	const head = text.slice(0, offset);
	const match = head.match(/^#{1,4} .+$/gm);
	return match?.at(-1);
}

/** First difference between two prompts, or `undefined` when they are equal. */
export function diffPrompts(before: readonly string[], after: readonly string[]): PromptDriftReport | undefined {
	const count = Math.max(before.length, after.length);
	for (let blockIndex = 0; blockIndex < count; blockIndex++) {
		const left = before[blockIndex] ?? "";
		const right = after[blockIndex] ?? "";
		if (left === right) continue;
		let offset = 0;
		const limit = Math.min(left.length, right.length);
		while (offset < limit && left.charCodeAt(offset) === right.charCodeAt(offset)) offset++;
		const start = Math.max(0, offset - CONTEXT_CHARS / 2);
		return {
			blockIndex,
			blockCountBefore: before.length,
			blockCountAfter: after.length,
			offset,
			heading: nearestHeading(right || left, offset),
			before: left.slice(start, offset + CONTEXT_CHARS),
			after: right.slice(start, offset + CONTEXT_CHARS),
			charsBefore: before.reduce((sum, block) => sum + block.length, 0),
			charsAfter: after.reduce((sum, block) => sum + block.length, 0),
		};
	}
	return undefined;
}

async function readSnapshot(digest: string): Promise<string[] | undefined> {
	try {
		const parsed: unknown = JSON.parse(await fs.readFile(path.join(snapshotDir(), `${digest}.json`), "utf8"));
		return Array.isArray(parsed) && parsed.every(block => typeof block === "string") ? parsed : undefined;
	} catch {
		return undefined;
	}
}

async function writeSnapshot(digest: string, blocks: readonly string[]): Promise<void> {
	const dir = snapshotDir();
	await fs.mkdir(dir, { recursive: true });
	await Bun.write(path.join(dir, `${digest}.json`), JSON.stringify(blocks));
	const cutoff = Date.now() - SNAPSHOT_MAX_AGE_MS;
	for (const name of await fs.readdir(dir)) {
		const file = path.join(dir, name);
		const stats = await fs.stat(file).catch(() => undefined);
		if (stats && stats.mtimeMs < cutoff) await fs.rm(file, { force: true });
	}
}

/**
 * Records the prompt a primary model call sends and, when it differs from
 * `previous` (an in-process prompt or a recorded digest), logs the first
 * difference. Fire-and-forget: never throws, never delays the request.
 */
export function notePromptDrift(
	sessionId: string | undefined,
	digest: string,
	blocks: readonly string[],
	previous: { digest: string; blocks?: readonly string[] } | undefined,
): void {
	// Steady state: the same prompt as the previous call of this process, nothing to do.
	if (previous?.blocks && previous.digest === digest) return;
	void (async () => {
		await writeSnapshot(digest, blocks);
		if (!previous || previous.digest === digest) return;
		const before = previous.blocks ?? (await readSnapshot(previous.digest));
		if (!before) {
			logger.warn("System prompt changed; previous snapshot unavailable", {
				sessionId,
				from: previous.digest,
				to: digest,
			});
			return;
		}
		logger.warn("System prompt changed; provider prefix cache invalidated", {
			sessionId,
			from: previous.digest,
			to: digest,
			...diffPrompts(before, blocks),
		});
	})().catch(error => logger.debug("Prompt drift snapshot failed", { error: String(error) }));
}
