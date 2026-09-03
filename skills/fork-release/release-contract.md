# Fork release contract

Load this when Ship needs to verify or repair how binaries get published and fetched.

## Upgrade fetch

`src/core/upgrade/upgrade_helpers.zig` pins:

- `release_repo = "keejkrej/fx"`
- latest pointer: GitHub matching-refs `https://api.github.com/repos/keejkrej/fx/git/matching-refs/tags/v`, then the newest `vX.Y.Z-N`. Fallback is `https://github.com/keejkrej/fx/releases/latest/download/latest.txt` only when that body is also `vX.Y.Z-N`
- archives: `https://github.com/keejkrej/fx/releases/download/<artifact_ref>/fx-<platform>.tar.gz` on Unix, or `fx-<platform>.zip` on Windows
- checksums: the same URL with `.sha256`

`<artifact_ref>` is the selected git tag (`vX.Y.Z-N`), not the normalized version. Plain `vX.Y.Z` tags are ignored so leftover upstream-shaped tags cannot win.

Stable installs only when `compareVersions(latest, current) == .gt`. Fork revision `N` is newer than its upstream base: `0.0.7` < `0.0.7-1` < `0.0.7-2` < `0.0.8-1`. Shipping the same version as an already-installed fork binary is a no-op.

## GitHub Release assets

`release.yml` attaches `latest.txt` (body `v<version>`), `install`, `install.ps1`, the four `fx-*.tar.gz` archives, the Windows `fx-*.zip` archives, and `.sha256` files on the GitHub Release, then tries Vercel Blob. The fork has no official CDN. Blob publish is skipped when `BLOB_READ_WRITE_TOKEN` is empty so the GitHub Release still succeeds. Users install with `curl .../install | bash` or `irm .../install.ps1 | iex`.

macOS arm64 uses the same ReleaseSafe cross-compile as the other platforms. The upstream PGSO qualifier is not required for this fork's upgrade assets.

## Workflow map

| Workflow | On this fork's `main` |
| --- | --- |
| CI | Runs on push. Required before trusting the commit. |
| Release | Runs on push. Publishes when `pub const version` is `X.Y.Z-N` and tag `vX.Y.Z-N` is missing. Plain `X.Y.Z` does not publish. |
| Dev Release | After CI success. Still talks to Blob; ignore if the token is missing. |
| Full CI | Does not run on `main`. |

First-time forks often have Actions enabled but zero runs until someone opens the Actions tab or dispatches **CI**.

## Version

Keep `pub const version` in `src/main.zig` as upstream `X.Y.Z` while developing. Ship only `X.Y.Z-N` where `N` is a positive integer with no leading zeros. That hyphen is a fork revision, not a SemVer prerelease and not a GitHub prerelease. Reject `0.0.7-alpha`, `0.0.7+1`, and `0.0.7/1`. `release.yml` must publish hyphenated tags with `prerelease: false` and `make_latest: true`.
