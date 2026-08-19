```
 ⠀⠀⠀⠀⠀⠀⣠⣾⣿⣿⣿⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⠀⠀⢰⣿⡿⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
 ⠀⠀⠀⣠⣶⣿⣿⣷⣶⡶⣶⣶⣆⠀⠀⠀⣴⣶⣶⠆
 ⠀⠀⠀⠉⢹⣿⣿⠉⠉⠀⠘⢿⣿⣧⣀⣾⣿⡿⠃⠀             Tiny, open, embeddable, native coding agent.
 ⠀⠀⠀⠀⣼⣿⡏⠀⠀⠀⠀⠀⠻⣿⣿⣿⠟⠀⠀⠀
 ⠀⠀⠀⢀⣿⣿⠃⠀⠀⠀⠀⢠⣦⠘⢿⣿⣷⡀⠀⠀             curl -fsSL https://fx.sh/setup.sh | bash
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

```bash
curl -fsSL https://fx.sh/setup.sh | bash
```

## Run fx

To get started, point fx at an OpenAI-compatible Chat Completions server:

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

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands. Paste a screenshot with Ctrl+V, drop a png/jpg/gif/webp file into the prompt, or run `/paste` and `/image <path>` to attach it as vision input.

Run `/feedback` to open the feedback form at `fx.sh/feedback`. It does not create a diagnostic or change the clipboard.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fx copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fx ask` for a single request:

```bash
fx ask "explain the changes in this repository"
```

fx starts in `auto` permission mode, which reviews unresolved sensitive actions. See [Permissions](https://fx.sh/docs/configure-fx/permissions) for other modes and persistent rules.

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

Add reusable instructions with [skills](https://fx.sh/docs/capabilities/skills), connect external tools through [MCP](https://fx.sh/docs/capabilities/mcp), or delegate independent work to [subagents](https://fx.sh/docs/capabilities/subagents). Project instruction files may link within their scope, and read-only workspace or compatibility skill directories may link within their owning workspace or home; managed skills, `SKILL.md` files, resources, and escaping links remain no-follow. `fx status` and `fx doctor` report an invalid trusted MCP profile without starting its servers.

Native fx also loads Lua 5.4 from `~/.fx/init.lua`, then `<workspace>/.fx/init.lua`. A broken file prints a notice and does not abort startup. `/lua` lists loaded files and registered commands; `/lua reload` reloads both files.

```lua
fx.command("hello", function()
  fx.notify("hello from lua")
end)
```

`fx.command`, `fx.keymap`, `fx.hook`, `fx.notify`, `fx.opt`, `fx.model`, `fx.provider`, `fx.view.open`, and `fx.lsp.start` are the v1 API. `/view [path]` opens the read-only code viewer; `/view --diff` opens the latest edit hunks. `fx.view.open(path, { line = n })` opens the same viewer. `fx.lsp.start({ name = "zls", cmd = { "zls" }, root = fx.workspace.root })` starts a user-installed language server. Diagnostics show in the viewer; `d` jumps to definition and reopens the viewer. fx does not bundle language servers. LSP process spawn is permission-gated: yolo and auto allow it, ask requires an `lsp` allow rule. Lua file reads stay inside `~/.fx/lua`, `~/.fx/pack`, and the workspace `.fx/` tree. `os.execute` and `io.popen` stay blocked unless permission mode is yolo. WebAssembly and NAPI hosts skip Lua.

## Documentation

Read the [fx documentation](https://fx.sh/docs).

## Build from source

Building fx requires [Zig 0.16.0+](https://ziglang.org/download/):

```bash
git clone https://github.com/vercel-labs/fx.git
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
