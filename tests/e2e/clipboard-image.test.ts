import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT } from "../evals/eval-helpers";
import { composerContains, hasEmptyComposer, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const TIMEOUT = 30_000;
const ONE_BY_ONE_PNG = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==",
  "base64",
);

let session: TmuxSession | null = null;
const tempDirs: string[] = [];

afterEach(async () => {
  if (session) {
    await session.kill();
    session = null;
  }
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function linuxImageClipboardWorks(): boolean {
  if (process.platform !== "linux") return false;
  if (!tmuxAvailable()) return false;
  return copyClipboardImage(ONE_BY_ONE_PNG) && clipboardHasPngMagic();
}

function copyClipboardImage(png: Buffer): boolean {
  if (process.env.WAYLAND_DISPLAY) {
    const put = spawnSync("wl-copy", ["--type", "image/png"], {
      input: png,
      timeout: 3000,
    });
    if (put.status === 0) return true;
  }
  if (process.env.DISPLAY) {
    const put = spawnSync(
      "xclip",
      ["-selection", "clipboard", "-t", "image/png", "-i"],
      { input: png, timeout: 3000 },
    );
    return put.status === 0;
  }
  return false;
}

function clipboardHasPngMagic(): boolean {
  if (process.env.WAYLAND_DISPLAY) {
    const get = spawnSync("wl-paste", ["--type", "image/png"], {
      encoding: "buffer",
      timeout: 3000,
      maxBuffer: 4096,
    });
    if (get.status === 0 && hasPngMagic(get.stdout)) return true;
  }
  if (process.env.DISPLAY) {
    const get = spawnSync(
      "xclip",
      ["-selection", "clipboard", "-t", "image/png", "-o"],
      { encoding: "buffer", timeout: 3000, maxBuffer: 4096 },
    );
    return get.status === 0 && hasPngMagic(get.stdout);
  }
  return false;
}

function hasPngMagic(bytes: Buffer | undefined): boolean {
  return Boolean(bytes && bytes.length >= 8 && bytes.subarray(0, 8).equals(ONE_BY_ONE_PNG.subarray(0, 8)));
}

function copyClipboardText(text: string): boolean {
  if (process.env.WAYLAND_DISPLAY) {
    const put = spawnSync("wl-copy", ["--type", "text/plain"], {
      input: text,
      timeout: 3000,
    });
    if (put.status === 0) return true;
  }
  if (process.env.DISPLAY) {
    const put = spawnSync("xclip", ["-selection", "clipboard", "-i"], {
      input: text,
      timeout: 3000,
    });
    return put.status === 0;
  }
  return false;
}

async function launchFx(): Promise<{ terminal: TmuxSession; stderrPath: string }> {
  const root = mkdtempSync(join(tmpdir(), "fx-clipboard-image-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(stderrPath, "");
  tempDirs.push(root);
  const terminal = await TmuxSession.create({
    cwd: workspace,
    stderrPath,
    env: {
      HOME: home,
      AI_GATEWAY_API_KEY: undefined,
      FX_AUTO_UPGRADE: "0",
      FX_DISABLE_KEYCHAIN: "1",
      FX_PERMISSION_MODE: undefined,
      FX_SKIP_ONBOARDING: "1",
      VERCEL_OIDC_TOKEN: undefined,
    },
  });
  return { terminal, stderrPath };
}

const SKIP = !linuxImageClipboardWorks();

describe.skipIf(SKIP)("tui: clipboard image-buffer paste", () => {
  test(
    "Ctrl+V attaches screenshot PNG bytes as [Image 1]",
    async () => {
      expect(copyClipboardImage(ONE_BY_ONE_PNG)).toBe(true);
      const launched = await launchFx();
      session = launched.terminal;
      await session.waitForComposer(10_000);
      await session.sendKeys("C-v");
      const pane = await session.waitForPane(
        (text) => composerContains(text, "[Image 1]"),
        8_000,
      );
      expect(composerContains(pane, "[Image 1]")).toBe(true);
      expect(pane).not.toContain("/tmp/");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/paste attaches screenshot PNG bytes as [Image 1]",
    async () => {
      expect(copyClipboardImage(ONE_BY_ONE_PNG)).toBe(true);
      const launched = await launchFx();
      session = launched.terminal;
      await session.waitForComposer(10_000);
      await session.sendText("/paste");
      const pane = await session.waitForPane(
        (text) => composerContains(text, "[Image 1]"),
        8_000,
      );
      expect(composerContains(pane, "[Image 1]")).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "Ctrl+V on a text clipboard does not paste the text as an image",
    async () => {
      expect(copyClipboardText("hello-from-text-clipboard")).toBe(true);
      const launched = await launchFx();
      session = launched.terminal;
      await session.waitForComposer(10_000);
      await session.sendKeys("C-v");
      const pane = await session.waitForPane(
        (text) => text.includes("no image found on clipboard"),
        8_000,
      );
      expect(composerContains(pane, "hello-from-text-clipboard")).toBe(false);
      expect(composerContains(pane, "[Image 1]")).toBe(false);
      expect(hasEmptyComposer(pane) || !composerContains(pane, "hello-from-text-clipboard")).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
