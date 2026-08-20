# Fork release contract

Load this when Ship needs to verify or repair how binaries get published and fetched.

## Upgrade fetch

`src/core/upgrade/upgrade_helpers.zig` pins:

- `release_repo = "keejkrej/fx"`
- latest pointer: `https://github.com/keejkrej/fx/releases/latest/download/latest.txt`
- archives: `https://github.com/keejkrej/fx/releases/download/<artifact_ref>/fx-<platform>.tar.gz`
- checksums: the same URL with `.sha256`

`<artifact_ref>` is the exact `latest.txt` body, not the normalized version. `latest.txt` must be `vX.Y.Z` so it matches the git tag `release.yml` creates.

Stable installs only when `compareVersions(latest, current) == .gt`. Shipping the same version as an already-installed fork binary is a no-op.

## GitHub Release assets

`release.yml` attaches `latest.txt` (body `v<version>`) plus the four `fx-*.tar.gz` archives and `.sha256` files on the GitHub Release, then tries Vercel Blob. The fork has no official CDN. Blob publish is skipped when `BLOB_READ_WRITE_TOKEN` is empty so the GitHub Release still succeeds.

macOS arm64 uses the same ReleaseSafe cross-compile as the other platforms. The upstream PGSO qualifier is not required for this fork's upgrade assets.

## Workflow map

| Workflow | On this fork's `main` |
| --- | --- |
| CI | Runs on push. Required before trusting the commit. |
| Release | Runs on push. Publishes when tag `v<version>` is missing. |
| Dev Release | After CI success. Still talks to Blob; ignore if the token is missing. |
| Full CI | Does not run on `main`. |

First-time forks often have Actions enabled but zero runs until someone opens the Actions tab or dispatches **CI**.

## Version

Keep `pub const version` in `src/main.zig` as strict `X.Y.Z`. Do not invent prerelease suffixes; the upgrade parser rejects them.
