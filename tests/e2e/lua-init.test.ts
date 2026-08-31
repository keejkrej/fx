import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { REPO_ROOT } from "../evals/eval-helpers";
import { composerContains, hasEmptyComposer, TmuxSession, tmuxAvailable } from "./tmux-helpers";

const SKIP = !tmuxAvailable();
const TIMEOUT = 30_000;

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

async function launchWithInit(initLua: string): Promise<{
  terminal: TmuxSession;
  stderrPath: string;
}> {
  const root = mkdtempSync(join(tmpdir(), "fx-lua-init-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  const stderrPath = join(root, "stderr.log");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace);
  writeFileSync(join(home, ".fx", "init.lua"), initLua);
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

describe.skipIf(SKIP)("tui: Lua init.lua", () => {
  test(
    "broken init.lua does not crash startup",
    async () => {
      const launched = await launchWithInit("this is not lua [[[\n");
      session = launched.terminal;
      const pane = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(pane)).toBe(true);
      expect(pane.toLowerCase()).toContain("lua");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/hello from init.lua registers and runs",
    async () => {
      const launched = await launchWithInit(
        'fx.command("hello", function()\n  fx.notify("hello from lua")\nend)\n',
      );
      session = launched.terminal;
      await session.waitForComposer(10_000);
      await session.sendText("/hello");
      const pane = await session.waitForText("hello from lua", 5_000);
      expect(pane).toContain("hello from lua");
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(launched.stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/diffview Lua plugin opens a full-screen unified review",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-lua-diffview-"));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      writeFileSync(join(home, ".fx", "init.lua"), "-- profile empty\n");
      writeFileSync(stderrPath, "");
      tempDirs.push(root);
      const terminal = await TmuxSession.create({
        cwd: REPO_ROOT,
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
      session = terminal;
      await session.waitForComposer(10_000);
      await session.sendText("/lua");
      const status = await session.waitForText("/diffview", 5_000);
      expect(status).toContain("Ctrl-T toggles agent and diff");
      await session.sendHexBytes(["14"]);
      const pane = await session.waitForText("DIFFVIEW_DEMO_OLD", 5_000);
      expect(pane).toContain("lua/diffview/demo.lua");
      expect(pane).toMatch(/1\/3/);
      expect(pane).toContain("README.md");
      expect(pane).toContain("unified");
      expect(pane).not.toMatch(/\s+side\s+/);
      expect(pane).toContain("ctrl-t agent");
      expect(pane).toContain("h/l file");
      expect(pane).toContain("{/} hunk");
      expect(pane).toContain("q quit");
      await session.sendKeys("l");
      const next = await session.waitForText("DIFFVIEW_FILE_README", 5_000);
      expect(next).toMatch(/2\/3/);
      await session.sendHexBytes(["14"]);
      const after = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(after)).toBe(true);
      expect(after).not.toContain("DIFFVIEW_DEMO_OLD");
      await session.sendHexBytes(["14"]);
      const again = await session.waitForText("DIFFVIEW_DEMO_OLD", 5_000);
      expect(again).toContain("ctrl-t agent");
      await session.sendKeys("q");
      const closed = await session.waitForComposer(10_000);
      expect(hasEmptyComposer(closed)).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );

  test(
    "/diffview comment injects a hunk note; Ctrl-T returns to the agent input",
    async () => {
      const root = mkdtempSync(join(tmpdir(), "fx-lua-diffview-comment-"));
      const home = join(root, "home");
      const stderrPath = join(root, "stderr.log");
      mkdirSync(join(home, ".fx"), { recursive: true });
      writeFileSync(join(home, ".fx", "init.lua"), "-- profile empty\n");
      writeFileSync(stderrPath, "");
      tempDirs.push(root);
      const terminal = await TmuxSession.create({
        cwd: REPO_ROOT,
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
      session = terminal;
      await session.waitForComposer(10_000);
      await session.sendText("/diffview");
      await session.waitForText("DIFFVIEW_DEMO_OLD", 5_000);
      await session.sendKeys("c");
      await session.waitForText("inject to input", 5_000);
      await session.sendLiteralText("DIFFVIEW_COMMENT_NOTE");
      await session.sendKeys("Enter");
      const stillDiff = await session.waitForText("DIFFVIEW_DEMO_OLD", 5_000);
      expect(stillDiff).toContain("ctrl-t agent");
      expect(stillDiff).toContain("q quit");
      expect(composerContains(stillDiff, "DIFFVIEW_COMMENT_NOTE")).toBe(false);
      await session.sendHexBytes(["14"]);
      const pane = await session.waitForText("DIFFVIEW_COMMENT_NOTE", 10_000);
      expect(pane).toContain("Diff comment on lua/diffview/demo.lua");
      expect(pane).toContain("```diff");
      expect(pane).toContain("DIFFVIEW_COMMENT_NOTE");
      expect(composerContains(pane, "DIFFVIEW_COMMENT_NOTE")).toBe(true);
      expect(session.paneStatus()).toEqual({ dead: false, status: null });
      expect(readFileSync(stderrPath, "utf8")).toBe("");
    },
    TIMEOUT,
  );
});
