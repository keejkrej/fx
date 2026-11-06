import assert from "node:assert/strict";
import pty from "node-pty";
import headless from "@xterm/headless";
const { Terminal } = headless;
const [binary, workspace] = process.argv.slice(2);
const terminal = new Terminal({ cols: 100, rows: 30, allowProposedApi: true, scrollback: 5000 });
const child = pty.spawn(binary, [], { name: "xterm-256color", cols: 100, rows: 30, cwd: workspace,
  env: { ...process.env, TERM: "xterm-256color" }, useConpty: true });
let exit = null;
let raw = "";
terminal.onData(data => child.write(data));
child.onData(data => { raw += data; terminal.write(data); });
child.onExit(event => { exit = event; });
const screen = () => Array.from({ length: terminal.buffer.active.length }, (_, i) => terminal.buffer.active.getLine(i)?.translateToString(true) ?? "").join("\n");
async function until(predicate, label) {
  const deadline = Date.now() + 15000;
  while (!predicate()) {
    if (exit || Date.now() > deadline) throw Error(`${label}: ${JSON.stringify(exit)}\n${screen()}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}
let code = 0;
try {
  await until(() => screen().includes("local-model"), "composer");
  child.write("Hello café 日本語\r");
  await until(() => screen().includes("Windows response: café 日本語"), "answer");
  assert.ok(screen().includes("Hello café 日本語"));
  assert.ok(screen().includes("windows-shell-ok"));
  assert.ok(!raw.includes("panic:"));
  child.resize(80, 24);
  terminal.resize(80, 24);
  child.write("/help\r");
  await until(() => screen().includes("/quit"), "help after resize");
  child.write("\x1b");
  await until(() => !screen().includes("esc close"), "close help");
  child.write("/exit\r");
  await until(() => exit !== null, "exit");
  assert.equal(exit.exitCode, 0);
  console.log(screen());
} catch (error) {
  console.error(error);
  code = 1;
} finally {
  if (!exit) child.kill();
  terminal.dispose();
  // node-pty's ConPTY helper keeps a handle alive after the child exits.
  setTimeout(() => process.exit(code), 100);
}
