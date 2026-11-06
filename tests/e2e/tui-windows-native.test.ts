import { afterEach, describe, expect, test } from "bun:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { delimiter, dirname, join } from "node:path";
import { FX_BIN, createIsolatedTestHome, cleanupIsolatedTestHome } from "../evals/eval-helpers";
import { completion, toolCompletion } from "./fixtures/chat-completions";

const exec = promisify(execFile);
const answer = "Windows response: café 日本語";
const fixtures: Array<{ close(): void }> = [];
afterEach(() => { for (const fixture of fixtures.splice(0)) fixture.close(); });

async function fixture(command?: string, tools: Array<{ name: string; args: object }> = []) {
  const node = (await exec("node", ["-p", "process.execPath"])).stdout.trim();
  const home = createIsolatedTestHome();
  const workspace = join(home, "workspace café 日本語");
  mkdirSync(workspace);
  const profile = join(home, "profile");
  const env: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (/^(PATH|PATHEXT|SYSTEMROOT|WINDIR|COMSPEC|TEMP|TMP|APPDATA|LOCALAPPDATA|PROGRAMFILES|PROGRAMW6432|USERPROFILE)$/i.test(key)) env[key] = value;
  }
  Object.assign(env, { HOME: home, FX_HOME: profile, FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_TEST_SKIP_ONBOARDING: "1", NO_COLOR: "1" });
  const pathKey = Object.keys(env).find(key => key.toUpperCase() === "PATH") ?? "PATH";
  env[pathKey] = dirname(node) + delimiter + (env[pathKey] ?? "");
  const requests: any[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const body: any = await request.json();
    requests.push(body);
    const step = body.messages.filter((m: any) => m.role === "tool").length;
    if (step < tools.length) return toolCompletion(body.model, tools[step].name, tools[step].args, `call-${step}`);
    if (command && !body.messages.some((m: any) => m.role === "tool")) {
      return toolCompletion(body.model, "shell", { action: "run", command });
    }
    return completion(body.model, answer);
  }});
  const f = { home, workspace, profile, env, requests, node, url: `http://127.0.0.1:${server.port}`,
    run: (args: string[], timeout = 15000) => exec(FX_BIN, args, { cwd: workspace, env, timeout, maxBuffer: 5e6 }),
    close() { server.stop(true); cleanupIsolatedTestHome(home); },
  };
  fixtures.push(f);
  await f.run(["config", "set", "theme", "dark"]);
  writeFileSync(join(profile, "settings.json"), JSON.stringify({
    provider: "local", auto_upgrade: false, permission_mode: "full-access",
    providers: { local: { protocol: "openai-chat-completions", base_url: `http://127.0.0.1:${server.port}/v1`, auth: { type: "none" },
      model_metadata: { "local-model": { context_window: 262144, max_output_tokens: 8192, supports_tool_use: true } } } },
    models: { local: "local-model" },
  }));
  return f;
}

describe.skipIf(process.platform !== "win32")("native Windows", () => {
  test("preserves the web tool restriction against private addresses", async () => {
    const calls: Array<{ name: string; args: object }> = [];
    const f = await fixture(undefined, calls);
    calls.push({ name: "web_fetch", args: { url: `${f.url}/page` } });
    const result = JSON.parse((await f.run(["ask", "Read the local test page", "--json"])).stdout);
    expect(f.requests.at(-1).messages.find((m: any) => m.role === "tool").content).toContain("only fetches known public HTTP(S) URLs");
    expect(result.tool_calls[0].status).toBe("error");
  }, 30000);

  test("writes, edits, reads and indexes Unicode filenames", async () => {
    const path = "nested/café-日本語.txt";
    const f = await fixture(undefined, [
      { name: "write_file", args: { path, content: "before\n" } },
      { name: "edit_file", args: { path, old_string: "before", new_string: "after" } },
      { name: "read_file", args: { path } },
      { name: "glob_files", args: { pattern: "**/*.txt" } },
      { name: "grep_files", args: { pattern: "after" } },
    ]);
    const result = JSON.parse((await f.run(["ask", "Exercise the file tools", "--json"])).stdout);
    expect(result.tool_calls).toHaveLength(5);
    expect(result.tool_calls.filter((call: any) => call.status !== "success")).toEqual([]);
    expect(readFileSync(join(f.workspace, path), "utf8")).toBe("after\n");
    const outputs = f.requests.at(-1).messages.filter((m: any) => m.role === "tool");
    expect(outputs[3].content).toContain("café-日本語.txt");
    expect(outputs[4].content).toContain("after");
  }, 30000);

  test("saves shell output and resumes a session in a Unicode workspace", async () => {
    const f = await fixture("printf windows-shell-ok");
    const first = await f.run(["ask", "Hello café 日本語", "--json"]);
    const result = JSON.parse(first.stdout);
    expect(result.final_output).toBe(answer);
    expect(result.tool_calls[0].command_result.exit_code).toBe(0);
    expect(first.stderr).not.toMatch(/panic:|error:/);
    expect(f.requests[1].messages.some((m: any) => m.role === "tool" && m.content.includes("windows-shell-ok"))).toBe(true);
    const resumed = JSON.parse((await f.run(["ask", "Continue", "--resume", result.session_id, "--json"])).stdout);
    expect(resumed.session_id).toBe(result.session_id);
    expect(resumed.final_output).toBe(answer);
    const sessions = JSON.parse((await f.run(["sessions", "--json"])).stdout);
    expect(sessions.count).toBe(1);
    expect(sessions.sessions[0].workspace_root).toBe(f.workspace);
  }, 30000);

  test("timeout stops descendants without crashing or leaving a delayed writer", async () => {
    const command = `node -e 'setTimeout(()=>require("fs").writeFileSync("escaped.txt","bad"),3000)' & wait`;
    const f = await fixture(command);
    const start = Date.now();
    const result = await f.run(["ask", "Run the timeout test", "--json", "--timeout", "1"]);
    expect(Date.now() - start).toBeLessThan(10000);
    expect(JSON.parse(result.stdout).tool_calls[0].command_result.timed_out).toBe(true);
    expect(result.stderr).not.toMatch(/panic:|assertion failure/);
    await Bun.sleep(3500);
    expect(existsSync(join(f.workspace, "escaped.txt"))).toBe(false);
  }, 20000);

  test("MCP stdio discovers tools and stops its server on exit", async () => {
    const f = await fixture();
    const pidPath = join(f.home, "mcp.pid");
    writeFileSync(join(f.profile, "mcp.json"), JSON.stringify({ mcp: { fixture: {
      type: "local", command: [f.node, join(import.meta.dirname, "fixtures", "mcp-modern-stdio.mjs")], enabled: true,
      environment: { FX_MCP_PID_PATH: pidPath, FX_MCP_IGNORE_EOF: "1", FX_MCP_IGNORE_TERM: "1" },
    } } }));
    const result = await f.run(["mcp", "show", "fixture", "--json"]);
    expect(result.stdout).toContain("echo");
    expect(result.stderr).not.toMatch(/panic:/);
    const pid = Number(readFileSync(pidPath, "utf8"));
    let alive = true;
    for (let i = 0; i < 100; i++) {
      try { process.kill(pid, 0); } catch { alive = false; break; }
      await Bun.sleep(20);
    }
    expect(alive).toBe(false);
  }, 30000);

  test("ConPTY renders Unicode, runs a shell command, resizes and exits", async () => {
    const f = await fixture("printf windows-shell-ok");
    const result = await exec(f.node, [join(import.meta.dirname, "fixtures", "windows-terminal.mjs"), FX_BIN, f.workspace], {
      cwd: f.workspace, env: f.env, timeout: 30000, maxBuffer: 5e6,
    });
    expect(result.stderr).toBe("");
    expect(result.stdout).toContain(answer);
    const sessions = JSON.parse((await f.run(["sessions", "--json"])).stdout);
    expect(sessions.count).toBe(1);
  }, 40000);
});
