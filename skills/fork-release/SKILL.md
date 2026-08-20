---
name: fork-release
description: Fork-line release for keejkrej/fx. Use when the user wants to sync upstream, merge with the upstream version, cut a fork GitHub Release, retarget upgrades, or ship this fork's binaries.
---

This repo's lasting line is **origin/main** (`keejkrej/fx`). `upstream/main` (`vercel-labs/fx`) is fetch-only. `fx upgrade` and auto-upgrade fetch `latest.txt` and archives from this fork's GitHub Releases, not `releases.fx.sh`.

Do the **sync** branch, the **ship** branch, or both. Default is both when the user wants upstream merged and a release cut.

## Guardrails

- Stay on `main`. Topic branches die after they merge.
- Never push to `upstream`.
- Never create git tags by hand. `release.yml` tags `v<version>` when that tag is missing.
- Never dispatch **Release** just to retry CI. Push a version-changing commit, or dispatch only after stating that a GitHub Release is the goal.
- Full CI ignores `main`. On this line, **CI** is the required check; **Release** publishes.

## Sync

Rebase this fork's exclusive commits onto current `upstream/main`.

1. Fetch and name the tips:
   `git fetch origin upstream`
   Record `main`, `origin/main`, `upstream/main`, `src/main.zig`'s `pub const version`, and upstream's version at `upstream/main:src/main.zig`.
2. Rebase `main` onto `upstream/main`. Resolve conflicts in favor of keeping fork-only contracts: `release_repo = "keejkrej/fx"`, GitHub upgrade URLs, OpenAI-compatible provider work, Lua, viewer. Replay upstream's version string into `src/main.zig` unless Ship will bump it again.
3. Push `main` only after `git status -sb` is `main...origin/main` or the expected ahead-of-origin rebase. Fast-forward if possible; force-with-lease only when this rebase rewrote commits already on origin and the user asked to update the fork line.

Done when `main` contains `upstream/main` and the fork-only commits, and `origin/main` matches if a push was in scope.

## Ship

Cut a fork release whose GitHub assets `fx upgrade` can install.

1. Compute the ship version. Read fork `pub const version`, upstream `pub const version`, and `git ls-remote --tags origin 'v*'`. The ship version is the semver-max of fork and upstream. If `v<version>` already exists on origin, bump patch until it does not. Write that version to `src/main.zig`.
2. Rewrite `CHANGELOG.md` for this ship version: one `## <version>` heading, `<!-- release:start -->` / `<!-- release:end -->` only on that entry, public user outcomes for fork-only work plus whatever landed from upstream since the previous fork tag. Follow the changelog rules in `AGENTS.md`.
3. Confirm the **release contract** in [release-contract.md](release-contract.md) still holds. Repair `release.yml` / upgrade helpers before pushing if GitHub Releases would not serve `latest.txt` plus `fx-*.tar.gz` and `.sha256` assets.
4. Enable Actions on this fork if `gh run list --repo keejkrej/fx --limit 1` is empty. Then push `main`.
5. Wait for **CI** and **Release** on that exact commit. Release is success only when tag `v<version>` exists, the GitHub Release exists, and these assets are present:
   - `latest.txt` whose body is `v<version>`
   - `fx-linux-x86_64.tar.gz` and `.sha256`
   - `fx-linux-aarch64.tar.gz` and `.sha256`
   - `fx-macos-x86_64.tar.gz` and `.sha256`
   - `fx-macos-aarch64.tar.gz` and `.sha256`
6. Ignore a failed **Publish to CDN** step when `BLOB_READ_WRITE_TOKEN` is unset. That is official-CDN publishing. Do not treat it as the upgrade source.

Done when `curl -fsSL https://github.com/keejkrej/fx/releases/latest/download/latest.txt` prints `v<version>` and one platform archive URL under `/releases/download/v<version>/` returns 200.

## After ship

Tell the user the tag, the Release URL, and that installed fork binaries pick this up with `fx upgrade`. `./zig-out/bin/fx` does not auto-upgrade.
