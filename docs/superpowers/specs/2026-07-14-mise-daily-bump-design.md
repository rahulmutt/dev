# Daily mise toolchain bump PR

## Problem

`.config/mise/config.toml` pins 26 tools that make up the shipped container
toolchain. Every pin is an exact version, so nothing moves until someone edits
the file. Today that happens by hand — the recent history is a run of "Update
config.toml" / "bump codex" commits — which means the toolchain drifts behind
upstream for as long as nobody remembers to look.

Automate it: once a day, check the pins against the latest available releases
and, if anything moved, open a pull request with the bumps.

## Scope

In scope: `.config/mise/config.toml` only — the container toolchain.

Out of scope: the root `mise.toml` (repo dev tooling, currently just
`shellcheck`). It changes rarely, and mixing a CI-tooling bump into a
container-toolchain PR muddles the review.

Also out of scope, deliberately: auto-merge, per-tool PRs, and grouping or
ignore rules. The devpod matrix that runs on the PR is exactly the thing a
human should read before merging, so a human merges.

## Approach

A scheduled workflow runs `mise upgrade --bump`, and if the config file
changed, opens a pull request from a rolling branch. The PR is validated by the
CI that already exists: opening it fires `check.yaml`, which calls
`devpod.yaml`, which builds the image and runs `devpod up` — and therefore
`mise install` — on amd64 + arm64 × default + devenv. That matrix passing is
the evidence that the new pins are safe to merge.

Two files:

- `scripts/mise-bump.sh` — bumps the config and renders the change summary.
- `.github/workflows/mise-bump.yaml` — schedules it, holds the token, opens
  the PR.

Splitting it this way matches the existing repo layout, keeps the workflow YAML
thin, makes the bump runnable locally, and means `mise run lint` shellchecks it
for free (the `lint` task already globs `scripts/*.sh`).

## `scripts/mise-bump.sh`

Runs under `set -euo pipefail`.

1. Snapshot `.config/mise/config.toml` to a temp file.
2. `mise trust --yes .config/mise/config.toml` — a fresh runner has not trusted
   the config, and mise silently ignores an untrusted one.
3. `mise upgrade --bump --yes --minimum-release-age 0s`.
4. Diff the snapshot against the rewritten file. If identical, report "no
   updates" and exit 0 without touching git.
5. Otherwise render a `| tool | from | to |` markdown table from the diff and
   write it to the path named by `$1` (the workflow passes a temp file it later
   feeds to the PR body).

The renderer is reachable on its own, as `mise-bump.sh --summary <before>
<after>`, printing the table to stdout. That is the entry point the test drives,
so no test run touches mise or the network. Step 5 calls the same code path.

### Config scoping

The script exports:

```sh
export MISE_OVERRIDE_CONFIG_FILENAMES=.config/mise/config.toml
```

This is the same mechanism `check.yaml` already uses, pointed the other way: it
makes that file the *only* config mise loads, so the root `mise.toml` is not
bumped. Verified by dry-run against deliberately downgraded pins — it bumps all
three backend families present in the config (core `jq`, `npm:skills`,
`github:rahulmutt/vsync`) and rewrites only that one file.

### Exact pins

`--bump` preserves each entry's existing precision, and all 26 entries are
exact three-part versions, so bumped entries stay exactly pinned. This is what
a `--pin` flag would buy; no such flag exists on `mise upgrade` (it is a flag of
`mise use`). To make the guarantee explicit rather than incidental, the script
also exports `MISE_PIN=1`.

### Failure behaviour

`--bump` installs each new version as it goes, so a version that does not exist
or will not download fails the run before a PR is opened. `set -euo pipefail`
means a backend outage part-way through aborts the script rather than
proposing a half-bumped config. A failed run surfaces as a failed Actions run;
no PR is opened.

## `.github/workflows/mise-bump.yaml`

```yaml
on:
  schedule:
    - cron: "17 6 * * *"
  workflow_dispatch:

concurrency:
  group: mise-bump

permissions:
  contents: write
  pull-requests: write
```

`:17` rather than `:00` because GitHub's scheduler is heavily contended on the
hour and delays those runs the longest. `workflow_dispatch` so the workflow can
be exercised on demand. The concurrency group stops a manual run racing the
cron.

Steps:

1. `actions/checkout@v4` with `token: ${{ secrets.MISE_BUMP_TOKEN }}`.
2. `jdx/mise-action@v2` with `install: false` — it defaults to running
   `mise install`, which here would install the 26 *current* pins for nothing.
   Only the mise CLI itself is wanted; the upgrade installs the new versions.
3. `scripts/mise-bump.sh` — with `GITHUB_TOKEN` in the environment, so the
   `github:` backend is not rate-limited when resolving releases.
4. `peter-evans/create-pull-request`, SHA-pinned to v8
   (`5f6978faf089d4d20b00c7766989d076bb2fc7f1`), with:
   - `token: ${{ secrets.MISE_BUMP_TOKEN }}`
   - `branch: mise-bump`, `delete-branch: true`
   - `labels: dependencies`
   - `title`/`commit-message`: `chore(mise): bump pinned toolchain versions`
   - `body`: the table from step 3

When nothing is outdated the config is unchanged, so the action finds no diff
and no-ops: no branch, no PR.

v8 (rather than v7) is the current major; v8.0.0 was purely a Node 24 runtime
bump with no input changes.

### Rolling branch

Each run rebuilds `mise-bump` from a fresh checkout of `main` and force-pushes,
so there is at most one open bump PR and it is always a clean diff against
current `main` — not an accreting pile of stale proposals. A PR left open for
three days is silently rewritten each morning with whatever is outstanding
against `main` that day.

If CI fails on the PR because one tool broke the image, drop that pin from the
branch by hand; the next scheduled run will propose it again, which is the
correct behaviour — the tool is still outdated.

### Token

`secrets.MISE_BUMP_TOKEN` is a fine-grained PAT scoped to this repository only,
with `contents: write` and `pull requests: write`.

The default `GITHUB_TOKEN` will not do. GitHub deliberately does not fire
`pull_request` workflows for PRs opened with it, so the bump PR would arrive
with no checks — discarding the entire point of the exercise, which is that
`devpod.yaml` proves the new toolchain installs.

Operational cost: fine-grained PATs expire (one year maximum). When it does,
the workflow starts failing with a 403 rather than silently doing nothing. A
comment next to the secret reference in the workflow records this.

## Testing

- `scripts/tests/mise-bump.test.sh`, wired into the existing `mise run test`
  task, following `scripts/tests/sync-dotfiles.test.sh`. It drives
  `mise-bump.sh --summary <before> <after>` with fixture configs and asserts the
  rendered table, covering a multi-tool bump across all three backend families
  and the no-change case.
- `mise run lint` shellchecks the new script automatically via its existing
  `scripts/*.sh` glob.
- The workflow itself is verified after merge by `workflow_dispatch`.

## Setup required before this works

1. Create the fine-grained PAT and add it as the `MISE_BUMP_TOKEN` repository
   secret.
2. Create the `dependencies` label, or drop the `labels:` input.
