# Environment bump and config validation

## Problem

The daily `mise-bump` job (`scripts/mise-bump.sh`,
`.github/workflows/mise-bump.yaml`) keeps `.config/mise/config.toml` current,
but the rest of the environment drifts by hand:

- **Codex hook trust.** `.codex/config.toml` pins a `trusted_hash` per plugin
  hook. When a plugin changes a hook upstream, or a codex bump changes the
  hashing, the pins go stale and codex silently stops running the hook. Today
  `scripts/codex-hook-hashes.sh` can print fresh pins, but only a human runs
  it; CI only detects staleness (`validate-devpod.sh`).
- **Settings files.** Nothing checks that `.claude/settings.json`,
  `.codex/config.toml` and `.pi/agent/settings.json` are accepted by the tool
  versions the image ships. A bump that renames or removes a setting is found
  by a user, not by CI.
- **Pinned-path drift.** The Claude `statusLine` command hardcodes
  `mise/installs/bun/1.4.2/bin/bun` while bun is pinned at `1.4.3`, so the
  status line is broken in the current image. Each bun bump has needed a hand
  edit (`ff7489f`, `038ca73`).

## Goals

- One daily job, **env-bump**, that bumps the mise toolchain *and* refreshes
  Codex hook trust, in one rolling PR.
- A validator, run against the built image on every PR and before every image
  push, that checks each tool accepts its settings, every declared
  plugin/package resolves, and no settings file names a versioned mise install
  path.
- Pinned-path drift becomes impossible rather than detected.

## Non-goals

- Bumping anything other than `.config/mise/config.toml` pins and Codex hook
  trust (e.g. pi package versions, Claude plugin versions, the image's
  `MISE_VERSION`, `NIX_VERSION`, `NIXPKGS_REV`).
- Validating the repo's own root `mise.toml`.
- Renaming the `MISE_BUMP_TOKEN` secret.
- Validating against Claude or Codex credentials; every check runs without
  login.

## Design

### Tool capabilities this relies on

Verified against the versions in the image at time of writing (claude 2.1.296,
codex 0.162.1, pi 1.1.0), without credentials:

| Need | Command | Signal |
|---|---|---|
| Claude accepts settings | `claude doctor` | Prints an `Invalid settings` block naming each bad key; **exits 0 regardless**, so the output is matched |
| Codex accepts config | `codex doctor --json` | `.checks["config.load"].status` is `ok`, or `warning` with "ignoring N unrecognized configuration setting(s)"; the overall exit is 1 without auth, so it is ignored |
| pi accepts settings | none | `pi list` prints a stack trace on invalid JSON but exits 0, so pi's file is checked with `jq` |
| Claude plugins resolve | `claude plugin marketplace add <repo>`, `claude plugin install <id>` | Exit 1 with a message when a plugin is missing. A fresh HOME has only the built-in Anthropic Directory, so `claude-plugins-official` must be added explicitly |
| mise install path without a version | `~/.local/share/mise/installs/<tool>/latest` | mise maintains `latest` (and major/minor) symlinks to the installed version |

### `scripts/env-bump.sh` (replaces `scripts/mise-bump.sh`)

Run by the daily workflow. Steps, in order:

1. **Bump mise pins.** Unchanged from `mise-bump.sh`: two passes (dependency
   tools, then the rest), `MISE_PIN=1`, `MISE_OVERRIDE_CONFIG_FILENAMES`
   scoped to `.config/mise/config.toml`, `--minimum-release-age 0s`, and
   refusal of a partial bump.
2. **Refresh Codex hook trust.**
   - `mise install codex`. The runner sets `install: false`, so codex is only
     present if step 1 moved it.
   - Create a scratch `CODEX_HOME` holding a copy of `.codex/config.toml`, and
     run `scripts/install-codex-plugins.sh` against it.
   - Run `scripts/codex-hook-hashes.sh` (print mode) against that
     `CODEX_HOME` to get the current `[hooks.state]` block.
   - Rewrite `.codex/config.toml`: remove every `[hooks.state."…"]` table and
     append the new block. Every other table is left byte-for-byte as it was.
3. **Write the summary** (stdout, and `--summary-out <file>` for the PR body):
   - the tools table, rendered exactly as today, or "No tool updates
     available.";
   - a **Codex hook trust** section listing hook keys added, changed (hash
     differs) and removed, or nothing when the set is unchanged.

Pure, offline entry points (no mise, no codex, no network), for the tests:

| Flag | Does |
|---|---|
| `--summary <before> <after>` | Tools table (existing) |
| `--partial-bump <stderr-file>` | Exit 0 if the bump was partial (existing) |
| `--rewrite-hooks <config> <block-file>` | Print `<config>` with its hooks tables replaced by `<block-file>` |
| `--hooks-summary <before-config> <after-config>` | Render the Codex hook trust section |

**Failure handling.** A failed run leaves both files as they were and opens no
PR:

- `mise upgrade` exits nonzero, or a partial bump: restore and exit 1 (as
  today).
- Plugin install or hash generation fails: restore **both** files and exit 1.
  Hashes can't be computed without the plugins, and stale pins would mislead.
- Nothing changed: no diff, so `create-pull-request` does nothing (as today).

A bumped tool that rejects a setting does **not** fail the bump. The PR opens
and fails its DevPod checks via `validate-config.sh`, which shows the breakage
on the PR.

### `.github/workflows/env-bump.yaml` (replaces `mise-bump.yaml`)

Same schedule, permissions, PAT handling (`MISE_BUMP_TOKEN`,
`persist-credentials: false`) and comments as today, with:

- `name: Env Bump`, `concurrency.group: env-bump`, `branch: env-bump`;
- the step runs `scripts/env-bump.sh --summary-out …`;
- `add-paths` lists `.config/mise/config.toml` and `.codex/config.toml`;
- commit message and title: `chore(env): bump toolchain and refresh codex hook
  trust`.

### `scripts/validate-config.sh` (new)

Runs inside the image as `dev` and validates the home dotfiles
(`~/.claude/settings.json`, `~/.codex/config.toml`,
`~/.pi/agent/settings.json`). Every check runs even if an earlier one failed.
Each prints an `ok` or `FAIL` line, failures with detail. The script exits 1
if any check failed.

| Check | Rule |
|---|---|
| Pinned-path drift | No settings file contains `mise/installs/<tool>/<digit>`. Paths through `latest/` pass |
| Claude settings | Canary first: `claude doctor` against a scratch HOME with a deliberately invalid `settings.json` must print `Invalid settings`, otherwise fail as "detection broken". Then `claude doctor`, run from a scratch directory against the real HOME, must print no `Invalid settings` block. On failure, print that block |
| Claude plugins resolve | In a scratch `HOME` holding a copy of `settings.json`: `claude plugin marketplace add` for `anthropics/claude-plugins-official` and for each `extraKnownMarketplaces` entry (GitHub `repo` sources), then `claude plugin install` for each `enabledPlugins` entry set to `true`. The real `~/.claude` is not touched. Plugins from marketplaces that something else wires locally are skipped by name, with a `skip` line: currently only `always-further`, which nono's packs set up as a local directory marketplace. A plugin from any other undeclared marketplace fails |
| Codex config | `codex doctor --json` gives `config.load` status `ok`. On failure, print its summary and any unrecognized-setting detail |
| Codex plugins | `codex plugin list` shows every enabled `[plugins."<id>"]` as `installed, enabled` (moved from `validate-devpod.sh`) |
| Codex hook trust | `scripts/codex-hook-hashes.sh --check` passes (moved from `validate-devpod.sh`) |
| pi settings | `jq`: a JSON object whose `packages`, if present, is an array of strings |
| pi packages | Each declared package's install dir exists (moved from `validate-devpod.sh`) |

### `scripts/validate-devpod.sh`

- Runs `validate-config.sh` in the image with `docker run --rm`, mounting
  `scripts/` read-only, alongside the existing image-PATH check. The separate
  `codex-hook-hashes.sh --check` `docker run` is folded into it.
- The smoke script drops its Codex plugin and pi package checks, which now
  live in `validate-config.sh`.

### One-time fix: `.claude/settings.json`

The `statusLine` command's
`/home/dev/.local/share/mise/installs/bun/1.4.2/bin/bun` becomes
`/home/dev/.local/share/mise/installs/bun/latest/bin/bun`. Nothing else in the
file changes.

### Repo plumbing

- `mise.toml` `test` task: `mise-bump.test.sh` becomes `env-bump.test.sh`, and
  `validate-config.test.sh` is added.
- `README.md`: the toolchain-bump and validation text describes env-bump and
  `validate-config.sh`.
- The 2026-07-14 mise-bump spec and plan stay as historical records.

## Testing

All offline and part of `mise run test`:

- **`scripts/tests/env-bump.test.sh`** (renamed from `mise-bump.test.sh`,
  existing cases kept):
  - `--rewrite-hooks`: replaces all hooks tables, keeps the other tables and
    their order, handles a config with no hooks tables, keeps the trailing
    newline;
  - `--hooks-summary`: added, changed, removed, and unchanged (empty output).
- **`scripts/tests/validate-config.test.sh`** (new): fixture HOMEs and stub
  `claude`, `codex` and `pi`, like `post-create.test.sh`:
  - a versioned install path fails and a `latest/` path passes;
  - `Invalid settings` in the doctor output fails;
  - a canary run that lacks `Invalid settings` fails as "detection broken";
  - a plugin from `always-further` is skipped, and one from any other
    undeclared marketplace fails;
  - a non-`ok` `config.load` fails;
  - non-string pi `packages` fails;
  - a failing check doesn't stop later checks;
  - a clean fixture exits 0.

End to end, `validate-devpod.sh` runs `validate-config.sh` against the real
image in the PR's DevPod CI. Before the PR is opened, it is also run here
against this container's dotfiles.

## Migration

- The first `env-bump` run will likely open a PR immediately, since hook trust
  is refreshed even when no tool moves.
- The stale `mise-bump` branch on origin (no open PR) is deleted after
  env-bump lands, with confirmation.

## Risks

- **`claude doctor` output format.** Matching `Invalid settings` depends on
  wording that may change. If it does, the check passes silently. To catch
  that, `validate-config.sh` first runs `claude doctor` against a scratch HOME
  holding a deliberately invalid settings file, and fails if that output lacks
  `Invalid settings`. A wording change then fails CI instead of disabling the
  check.
- **`codex doctor --json` schema.** It is versioned (`schemaVersion: 1`); a
  missing `config.load` check is treated as a failure, not a pass.
- **Network in validation.** The plugin-resolve checks clone marketplaces, so
  the DevPod job depends on GitHub availability, as the image build already
  does.
