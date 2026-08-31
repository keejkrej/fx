import { afterEach, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT } from "../evals/eval-helpers";
import { composerContains, TmuxSession, tmuxAvailable, isComposerLine } from "./tmux-helpers";

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

function x11AuthorityPath(): string | undefined {
  if (process.env.XAUTHORITY && existsSync(process.env.XAUTHORITY)) {
    return process.env.XAUTHORITY;
  }
  const fallback = join(process.env.HOME ?? "", ".Xauthority");
  return existsSync(fallback) ? fallback : undefined;
}

async function launchFx(): Promise<{ terminal: TmuxSession; stderrPath: string }> {
  const root = mkdtempSync(join(tmpdir(), "fx-clipboard-image-"));
  const home = join(root, "home");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(stderrPath, "");
  tempDirs.push(root);
  const terminal = await TmuxSession.create({
    cwd: REPO_ROOT,
    stderrPath,
    env: {
      HOME: home,
      DISPLAY: process.env.DISPLAY,
      WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY,
      XAUTHORITY: x11AuthorityPath(),
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

describe.skipIf(!tmuxAvailable())("tui: click [Image N] opens the system viewer", () => {
  test(
    "attaching an image emits OSC 8, arms mouse tracking, and survives a chip click",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-image-chip-click-"));
      const home = join(root, "home");
      const workspace = join(root, "workspace");
      const stderrPath = join(root, "stderr.log");
      const tapePath = join(root, "session.fxtape");
      const imagePath = join(workspace, "chip.png");
      mkdirSync(join(home, ".fx"), { recursive: true });
      mkdirSync(workspace, { recursive: true });
      writeFileSync(imagePath, ONE_BY_ONE_PNG);
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
          FX_RECORD: tapePath,
          FX_SKIP_ONBOARDING: "1",
          VERCEL_OIDC_TOKEN: undefined,
        },
      });
      session = terminal;
      await terminal.waitForComposer(10_000);
      await terminal.sendText(`/image ${imagePath}`);
      const pane = await terminal.waitForPane(
        (text) => composerContains(text, "[Image 1]"),
        8_000,
      );
      expect(composerContains(pane, "[Image 1]")).toBe(true);

      const tape = readFileSync(tapePath);
      expect(tape.includes(Buffer.from("\x1b]8;;file://"))).toBe(true);
      expect(tape.includes(Buffer.from("[Image 1]"))).toBe(true);
      expect(tape.includes(Buffer.from("\x1b[?1000h\x1b[?1006h"))).toBe(true);

      const composerRow = pane
        .split("\n")
        .findIndex((line) => isComposerLine(line) && line.includes("[Image 1]")) + 1;
      expect(composerRow).toBeGreaterThan(0);
      const click = `\x1b[<0;4;${composerRow}M`;
      await terminal.sendHexBytes(
        Array.from(Buffer.from(click), (byte) => byte.toString(16).padStart(2, "0")),
      );
      await terminal.waitForPane(
        (text) => composerContains(text, "[Image 1]"),
        3_000,
      );
      expect(terminal.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});

describe.skipIf(SKIP)("tui: Lua clipboard screenshot paste plugin", () => {
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
    "Ctrl+V on a text clipboard does not attach an image",
    async () => {
      expect(copyClipboardText("hello-from-text-clipboard")).toBe(true);
      const launched = await launchFx();
      session = launched.terminal;
      await session.waitForComposer(10_000);
      await session.sendKeys("C-v");
      const pane = await session.waitForStableComposer(3_000, 400);
      expect(composerContains(pane, "hello-from-text-clipboard")).toBe(false);
      expect(composerContains(pane, "[Image 1]")).toBe(false);
      expect(pane).not.toContain("no image found on clipboard");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
