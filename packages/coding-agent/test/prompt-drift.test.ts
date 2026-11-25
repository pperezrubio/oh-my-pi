import { describe, expect, it } from "bun:test";
import { diffPrompts } from "@oh-my-pi/pi-coding-agent/session/prompt-drift";

describe("diffPrompts", () => {
	it("returns undefined for equal prompts", () => {
		expect(diffPrompts(["a", "b"], ["a", "b"])).toBeUndefined();
	});

	it("locates the first differing block, offset and heading", () => {
		const before = ["intro", "# Rules\n## delegation-tiers\nold description here"];
		const after = ["intro", "# Rules\n## delegation-tiers\nnew description here"];
		const report = diffPrompts(before, after);
		expect(report?.blockIndex).toBe(1);
		expect(report?.offset).toBe("# Rules\n## delegation-tiers\n".length);
		expect(report?.heading).toBe("## delegation-tiers");
		expect(report?.before).toContain("old description");
		expect(report?.after).toContain("new description");
	});

	it("reports an appended block", () => {
		const report = diffPrompts(["base"], ["base", "recall"]);
		expect(report?.blockIndex).toBe(1);
		expect(report?.blockCountBefore).toBe(1);
		expect(report?.blockCountAfter).toBe(2);
		expect(report?.after).toBe("recall");
	});
});
