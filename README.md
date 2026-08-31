## Why this fork

Codex and Grok Build already have OAuth. This fork is the missing terminal UX on [vercel-labs/fx](https://github.com/vercel-labs/fx).

Keep upstream sign-in: `fx login grok`, `fx login codex`. This line does not reimplement OAuth.

**No Gateway.** Point fx at any OpenAI-compatible `/v1/chat/completions` server, or keep those logins. No Vercel account, no AI Gateway billing.

**Lua plugins.** Shipped demos of the plugin API:

- **Full-screen views.** Agent, diff, and code are modes, not a split. `fx.view.register` lets plugins take over the whole terminal. Ctrl-T cycles agent → diff → code → agent. `q` always returns to the agent.
- **In-TUI diff.** `/diffview` (or Ctrl-T) is a unified review: file list, hunks, comments. No pane split, and no old|new columns. `c` comments a hunk into the agent input; `q` returns with that context already in the box.
- **In-TUI code.** `/codeview [path]` (or another Ctrl-T) opens a file in the same full-screen viewer, with syntax highlighting when fx already knows the language. `/view [path]` opens that viewer too.
- **Screenshot buffer paste (Linux/Windows).** macOS already pastes clipboard images in upstream fx. This plugin fills the gap: screenshot-copy on Omarchy, Hyprland, or Windows puts image bytes on the clipboard; the paste hook writes them to tmp and attaches `[Image N]`. Text passes through. Grok Build makes you copy a PNG from disk first.
- **Click `[Image N]` to open.** Click the chip in the composer (or a visible transcript badge). fx launches the snapshot with the system viewer (`open` / `xdg-open` / `start`). OSC 8 `file://` links stay in place for terminals that honor them.

Install from this repo's GitHub Releases, not `fx.sh`:

```bash
curl -fsSL https://github.com/keejkrej/fx/releases/latest/download/install | bash
```

```powershell
irm https://github.com/keejkrej/fx/releases/latest/download/install.ps1 | iex
```

The rest of this README is upstream's.

```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://github.com/keejkrej/fx/releases/latest/download/install | bash
 ⠀⠀⠀⣸⣿⡟⠀⠀⠀⠀⣰⣿⣿⠗⠀⠻⣿⣿⣄⠀
 ⠀⠀⠀⣿⣿⠇⠀⠀⠀⠾⠿⠿⠋⠀⠀⠀⠘⠿⠿⠦             ⚠ Status: Experimental. Use at your own risk.
  ⠀⣸⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⣿⣿⣿⠟⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
```

fx is a coding agent harness and CLI written in Zig, optimized for research and embeddability as part of larger systems.

It focuses on minimalism and performance across the board, from system prompt design to its tools, feature set, and 7.8 MiB binary.

For end users, its CLI output style and form factor aim to be closer to a Unix shell than a heavy "IDE in the terminal" TUI.

It's open source (Apache-2.0), model-agnostic, and suitable for both local and cloud inference.

## Install

Unix and macOS:

```bash
curl -fsSL https://github.com/keejkrej/fx/releases/latest/download/install | bash
```

Windows (PowerShell):

```powershell
irm https://github.com/keejkrej/fx/releases/latest/download/install.ps1 | iex
```

That installs `fx` to `~/.fx/bin` (Unix) or `%USERPROFILE%\.fx\bin` (Windows) and adds that directory to PATH. Override the destination with `FX_INSTALL_DIR`. Pin a tag with `FX_VERSION=0.0.7`.

## Run fx

Sign in with Vercel AI Gateway:

```bash
fx login
```

Or use an eligible ChatGPT subscription through OpenAI Codex OAuth:

```bash
fx login codex
fx
```

Or use an eligible Grok subscription through xAI OAuth:

```bash
fx login grok
fx
```

`fx login codex` and `fx login grok` select that provider and a model from its authenticated catalog. Inside fx, open `/setup` and choose **Model provider** to move between Gateway, Codex, and Grok. `/model` lists the active provider's fetched models. Subscription model IDs are the raw IDs returned by each authenticated catalog. Use `/logout codex` or `/logout grok` to remove that subscription session without affecting other providers; choosing it again from **Model provider** starts sign-in.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

To use an AI Gateway API key instead:

```bash
fx setup
```

That saves a base URL and API key under `~/.fx/settings.json` and `~/.fx/providers/openai_compatible/`. `fx setup openai-compatible` is the same command.

Or set `FX_OPENAI_BASE_URL` and `FX_OPENAI_API_KEY`. Those values are profile-owned (`~/.fx/settings.json`) and are ignored from project `.fx.json`.

A hosted subscription proxy that speaks Chat Completions works the same way. Example:

```bash
export FX_OPENAI_BASE_URL=https://your-proxy.example/v1
export FX_OPENAI_API_KEY=sk-sub-...
```

Model names come from that server (`GET /v1/models`). Prefixed ids such as `chatgpt/gpt-5` or `grok/grok-4.6` are valid when the proxy advertises them.

Run fx from a project:

```bash
cd your_project
fx
```

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. While fx is working, press Enter to queue a follow-up or Ctrl+Enter to steer the active turn at its next model boundary. If the turn has already closed, fx safely queues the steering prompt as the next turn.

Tool calls are expanded by default. Enable `Collapse tool calls` in `/settings`, or set `"collapse_tool_calls": true` in `~/.fx/settings.json`, to show one summary per tool-call group in the main transcript. Individual calls remain available in the full transcript with Ctrl+O.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `fx sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
fx session resume last
fx session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the fx-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

With `--json`, `output` contains accumulated assistant Markdown across the request, while `final_output` contains only a completed final assistant response and is `""` for interrupted, failed, background, or otherwise absent final responses.

Foreground terminal commands run with an explicit finite deadline. fx uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

fx starts in `auto` permission mode. Routine understood development actions run directly. Each unresolved action receives one narrow safety review based on the current user request and the exact pending action. A clear result authorizes only that action. A caution or unavailable review holds the action and returns advice to the agent without opening a permission prompt or ending the turn. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

JSON and quiet requests stay noninteractive by default. Add `--prompt-permissions` to allow configured approval prompts when stdin is a TTY. Automatic safety review never opens that prompt. Prompt text is written to stderr, so JSON stdout stays parseable and quiet stdout stays empty. Piped or redirected stdin remains noninteractive and fails instead of waiting for approval.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fx

fx builds as a native binary or WebAssembly. Applications embedding fx can provide network transport, session storage, configuration, permission handling, and terminal I/O.

| Surface | Use |
| --- | --- |
| `fx acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md) and [ACP documentation](https://fx.sh/docs/using-fx/acp).

## Extend fx

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Run `fx mcp add NAME COMMAND [ARGS...]` for a local server or `fx mcp add --transport http NAME URL` for Streamable HTTP without opening the interactive shell; the equivalent `/mcp add` forms remain available inside fx. A workspace may also provide Claude-compatible `.mcp.json` with a top-level `mcpServers` object. Pending project servers stay disconnected on every surface until they are approved with `/mcp trust approve <server>` or `fx mcp trust approve <server>`. Interactive fx presents the trust prompt after startup. `fx ask` reports skipped pending servers on stderr, and ACP leaves them unavailable. Repository files cannot persist approval or expose environment-expanded values before approval. `/mcp trust reject <server>` rejects one and `/mcp trust reset` clears the workspace choices. Profile entries win same-name collisions. Profile `~/.fx/mcp.json` accepts `mcpServers` as an alias for `mcp`, while writes always use `mcp` and ambiguous server-like keys produce a visible warning. Project instruction files may link within their scope, and read-only workspace or compatibility skill directories and their primary `SKILL.md` files may link within their owning workspace or home; managed skills, secondary resources, and escaping links remain no-follow. Skills installed via symlinks that resolve outside home or workspace (e.g. Nix store paths) are loaded when their resolved target is inside a directory listed in the `FX_SKILL_SYMLINK_AUTHORITIES` environment variable (colon-separated absolute paths). `fx status` and `fx doctor` report invalid or suspicious trusted MCP profiles without starting their servers.

Use `fx mcp list`, `fx mcp path`, and `fx mcp remove NAME` for noninteractive profile management. `fx mcp trust approve|reject NAME`, `fx mcp trust approve-all`, and `fx mcp trust reset` manage workspace-scoped project trust. `fx mcp auth NAME` and `fx mcp logout NAME` run the existing remote credential lifecycle without opening the TUI or contacting the Gateway.

MCP servers have a 30-second startup timeout by default; set `startup_timeout_ms` on a server when its cold start needs a different bound. For direct `docker run` stdio entries, fx uses a private container ID file to remove the owned container after shutdown or startup failure. A configuration that already supplies `--cidfile` keeps ownership of its own cleanup policy.

Native fx also loads Lua 5.4 from `~/.fx/init.lua`, then `<workspace>/.fx/init.lua`. A broken file prints a notice and does not abort startup. `/lua` lists loaded files and registered commands; `/lua reload` reloads both files.

```lua
fx.command("hello", function()
  fx.notify("hello from lua")
end)
```

`fx.command`, `fx.keymap`, `fx.hook`, `fx.notify`, `fx.opt`, `fx.model`, `fx.provider`, `fx.view.open`, `fx.view.diff`, `fx.view.register`, `fx.input.append`, and `fx.lsp.start` are the v1 API. `/view [path]` opens the read-only code viewer; `/view --diff` opens the latest edit hunks. `fx.view.open(path, { line = n })` opens the same viewer. `fx.view.diff(path, old, new)` opens a single-file unified diff. `fx.view.diff({ files = { { path, old, new }, ... }, layout = "unified" })` opens an in-TUI multi-file review that takes over the whole terminal (file list, unified hunks, hunk jumps) without spawning another terminal or splitting agent and diff. In that review, `c` comments the current hunk: the note plus a quoted diff snippet are appended to the main agent input (`fx.input.append` is the same host path) and the review stays open. `fx.view.register("diff", open_fn)` and `fx.view.register("code", open_fn)` add named full-screen views; Ctrl-T (`fx.view.cycle`) walks agent and every registered view. Workspace `lua/?/init.lua` is on `package.path`, so a plugin like `lua/diffview` can `require("diffview")` from `.fx/init.lua`. This repo ships `/diffview` and `/codeview` through the `lua/views` pack. `fx.lsp.start({ name = "zls", cmd = { "zls" }, root = fx.workspace.root })` starts a user-installed language server. Diagnostics show in the viewer; `d` jumps to definition and reopens the viewer. fx does not bundle language servers. LSP process spawn is permission-gated: yolo and auto allow it, ask requires an `lsp` allow rule. Lua file reads stay inside `~/.fx/lua`, `~/.fx/pack`, the workspace `.fx/` tree, and workspace `lua/`. `os.execute` and `io.popen` stay blocked unless permission mode is yolo. WebAssembly and NAPI hosts skip Lua.

## Documentation

Read the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/keejkrej/fx.git
cd fx
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fx
```

Run the test suite with `zig build test`. See [CONTRIBUTING.md](CONTRIBUTING.md) for development and contribution guidelines.

## License

[Apache-2.0](LICENSE)

Third-party licenses and attributions are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Credits

Interface sounds by [cuelume](https://github.com/Danilaa1/cuelume).
