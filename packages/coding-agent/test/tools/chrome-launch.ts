import puppeteer from "puppeteer-core";
import type { Browser, LaunchOptions } from "puppeteer-core";

/**
 * Launch the managed Chromium for tests. The fork's GitLab CI build container
 * runs as root, and Chrome refuses to start as root without --no-sandbox
 * (crbug.com/638180); upstream's GitHub runners are unprivileged, so the flag
 * is appended only when it is actually needed.
 */
export async function launchChrome(options: LaunchOptions): Promise<Browser> {
	const args = [...(options.args ?? [])];
	if (typeof process.getuid === "function" && process.getuid() === 0 && !args.includes("--no-sandbox")) {
		args.push("--no-sandbox", "--disable-setuid-sandbox");
	}
	return puppeteer.launch({ ...options, args });
}
