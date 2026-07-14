# Daily mise Toolchain Bump PR — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Once a day, check the 26 exact-pinned tools in `.config/mise/config.toml` against their latest upstream releases and, if anything moved, open a pull request with the bumps.

**Architecture:** A shell script (`scripts/mise-bump.sh`) does the work — it runs `mise upgrade --bump` scoped to that one config file and renders a markdown table of what moved. A scheduled GitHub Actions workflow (`.github/workflows/mise-bump.yaml`) runs it daily and hands the result to `peter-evans/create-pull-request` on a rolling `mise-bump` branch. The PR is validated by CI that already exists: opening it with a PAT (not `GITHUB_TOKEN`) fires `check.yaml` → `devpod.yaml`, which builds the image and runs `devpod up` — hence `mise install` — on amd64 + arm64 × default + devenv.

**Tech Stack:** bash (shellcheck-clean, `set -euo pipefail`), mise, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-07-14-mise-daily-bump-design.md`

## Global Constraints

- The bump touches `.config/mise/config.toml` **only**. The repo's root `mise.toml` (dev tooling, `shellcheck = "0.11.0"`) must never be modified by it. Enforced with `MISE_OVERRIDE_CONFIG_FILENAMES=.config/mise/config.toml`.
- The upgrade command is exactly `mise upgrade --bump --yes --minimum-release-age 0s`. (`--pin` is **not** a flag of `mise upgrade` — it belongs to `mise use`. `MISE_PIN=1` is exported instead.)
- All shell scripts live in `scripts/`, start with `#!/usr/bin/env bash` and `set -euo pipefail`, carry a header comment explaining *why*, and must pass `mise run lint` (shellcheck already globs `scripts/*.sh`).
- Tests live in `scripts/tests/*.test.sh`, follow the `PASS`/`FAIL` counter + `ok`/`bad` helper style of `scripts/tests/sync-dotfiles.test.sh`, and must not touch the network or the developer's real `$HOME`.
- Third-party GitHub Actions are SHA-pinned. First-party actions (`actions/*`, `docker/*`, `jdx/mise-action`) stay on their major tag, matching the existing workflows.
- `peter-evans/create-pull-request` is pinned to `5f6978faf089d4d20b00c7766989d076bb2fc7f1` (tag `v8`).

---

## File Structure

| File | Responsibility |
| --- | --- |
| Create: `scripts/mise-bump.sh` | Bump the toolchain config; render the change summary. Two entry points: the bump path, and a pure `--summary <before> <after>` renderer. |
| Create: `scripts/tests/mise-bump.test.sh` | Drives the pure renderer against fixture configs. No mise, no network. |
| Create: `.github/workflows/mise-bump.yaml` | Daily schedule, token handling, PR creation. |
| Modify: `mise.toml` | Add the new test to the `test` task so `mise run check` covers it. |

Task 1 builds the renderer (fully unit-testable). Task 2 adds the mise-driven bump path around it (verified end-to-end against a throwaway copy of the repo). Task 3 wires it to a schedule.

---

### Task 1: The summary renderer

The renderer is a pure function over two config files, which is the only part of the script that can be tested without the network. Build it first, test-driven, and give it its own command-line entry point so the test can reach it.

**Files:**
- Create: `scripts/mise-bump.sh`
- Create: `scripts/tests/mise-bump.test.sh`
- Modify: `mise.toml` (the `[tasks.test]` block)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `scripts/mise-bump.sh --summary <before.toml> <after.toml>` — prints a markdown summary to stdout, exit 0. When at least one pin differs, the output contains a preamble line, then `| Tool | From | To |`, then one `| \`name\` | \`old\` | \`new\` |` row per changed pin. When nothing differs, the sole output line is `No tool updates available.`
  - Internal functions `pins <file>` (emits `tool<TAB>version` for each entry in the `[tools]` table) and `render_summary <before> <after>`, reused by Task 2.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/mise-bump.test.sh`:

```bash
#!/usr/bin/env bash
#
# Tests for the summary renderer in scripts/mise-bump.sh.
#
# The renderer is a pure function over two mise configs -- given the config
# before and after a bump, it produces the markdown table that becomes the PR
# body. That purity is the point: these tests never invoke mise and never touch
# the network, so `mise run test` stays fast and offline.
#
# Run directly, or via `mise run test`.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
BUMP="$REPO_ROOT/scripts/mise-bump.sh"

PASS=0
FAIL=0

# --- tiny assertion helpers -------------------------------------------------
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then ok "$3"; else bad "$3 (missing '$2')"; fi
}
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then bad "$3 (unexpected '$2')"; else ok "$3"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A config shaped like the real .config/mise/config.toml: a [settings] table
# ahead of [tools], a plain tool, and the two quoted-key backends (npm:, github:).
cat > "$WORK/before.toml" <<'EOF'
[settings.npm]
bun = true

[settings]
decoy = "9.9.9"

[tools]
jq = "1.8.0"
ripgrep = "15.1.0"

"npm:skills" = "1.5.0"
"github:rahulmutt/vsync" = "0.6.0"
EOF

# jq, npm:skills and github:rahulmutt/vsync moved; ripgrep did not.
sed -e 's/^jq = .*/jq = "1.8.2"/' \
    -e 's/^"npm:skills" = .*/"npm:skills" = "1.5.17"/' \
    -e 's|^"github:rahulmutt/vsync" = .*|"github:rahulmutt/vsync" = "0.6.1"|' \
    "$WORK/before.toml" > "$WORK/after.toml"

echo "mise-bump summary renderer tests"

# ===========================================================================
echo
echo "test: a bump renders one table row per changed tool"
OUT="$(bash "$BUMP" --summary "$WORK/before.toml" "$WORK/after.toml")"
assert_contains "$OUT" '| Tool | From | To |' "table header is present"
assert_contains "$OUT" '| `jq` | `1.8.0` | `1.8.2` |' "core-backend tool row"
assert_contains "$OUT" '| `npm:skills` | `1.5.0` | `1.5.17` |' "npm-backend tool row, key unquoted"
assert_contains "$OUT" '| `github:rahulmutt/vsync` | `0.6.0` | `0.6.1` |' "github-backend tool row, key unquoted"
assert_contains "$OUT" 'minimum-release-age 0s' "preamble names the command that produced the bump"

# ===========================================================================
echo
echo "test: unchanged pins and non-[tools] keys stay out of the table"
assert_not_contains "$OUT" 'ripgrep' "an unchanged tool is not listed"
assert_not_contains "$OUT" 'decoy' "a quoted value outside [tools] is not mistaken for a tool"

# ===========================================================================
echo
echo "test: identical configs report no updates and render no table"
OUT="$(bash "$BUMP" --summary "$WORK/before.toml" "$WORK/before.toml")"
assert_contains "$OUT" 'No tool updates available.' "says so plainly"
assert_not_contains "$OUT" '| Tool |' "no empty table is emitted"

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$PASS"
    exit 0
else
    printf '\033[31m%d passed, %d FAILED.\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
```

Make it executable:

```bash
chmod +x scripts/tests/mise-bump.test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash scripts/tests/mise-bump.test.sh`

Expected: FAIL — the script does not exist yet, so bash reports something like
`scripts/tests/mise-bump.test.sh: line NN: /workspace/scripts/mise-bump.sh: No such file or directory`
and the run aborts with a non-zero exit under `set -e`.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/mise-bump.sh`. This step writes the renderer and its `--summary` entry point only; Task 2 adds the bump path.

```bash
#!/usr/bin/env bash
#
# Bump the pinned container toolchain in .config/mise/config.toml to the latest
# available releases, and render a markdown summary of what moved.
#
# Usage:
#   scripts/mise-bump.sh --summary <before> <after>   # render a summary only
#
# The --summary form is a pure function over two config files -- it runs no
# mise and touches no network -- which is what scripts/tests/mise-bump.test.sh
# drives.

set -euo pipefail

# The container toolchain. NOT the repo's root mise.toml, which pins the dev
# tooling (shellcheck) and is deliberately left alone.
CONFIG=".config/mise/config.toml"

TAB="$(printf '\t')"

# Emit "<tool><TAB><version>" for every pin in the [tools] table.
#
# Scoped to that table on purpose: a quoted value anywhere else in the file
# (say, under [settings]) is a setting, not a tool, and must not show up in the
# PR body as though a tool had moved.
pins() {
    awk '/^\[tools\]/ { in_tools = 1; next } /^\[/ { in_tools = 0 } in_tools' "$1" |
        sed -nE 's/^[[:space:]]*"?([^"=[:space:]]+)"?[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1\t\2/p'
}

# Markdown table of every pin whose version differs between two configs.
# `join` needs both sides sorted on the join field, hence the sort.
render_summary() {
    local before="$1" after="$2" rows
    rows="$(join -t"$TAB" -j 1 \
        <(pins "$before" | sort -t"$TAB" -k1,1) \
        <(pins "$after" | sort -t"$TAB" -k1,1) |
        awk -F'\t' '$2 != $3 { printf "| `%s` | `%s` | `%s` |\n", $1, $2, $3 }')"

    if [ -z "$rows" ]; then
        echo "No tool updates available."
        return 0
    fi

    echo "\`mise upgrade --bump --minimum-release-age 0s\` found newer releases for the pinned toolchain in \`$CONFIG\`."
    echo
    echo "| Tool | From | To |"
    echo "| --- | --- | --- |"
    echo "$rows"
}

usage() {
    echo "usage: $0 --summary <before> <after>" >&2
    exit 2
}

main() {
    case "${1:-}" in
        --summary)
            [ "$#" -eq 3 ] || usage
            render_summary "$2" "$3"
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
```

Make it executable:

```bash
chmod +x scripts/mise-bump.sh
```

(No `SCRIPT_DIR`/`REPO_ROOT` here on purpose: the `--summary` path takes both configs as arguments and never needs to locate the repo. Task 2 adds them, where they are actually used — defining them now would leave shellcheck complaining about unused variables, SC2034.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash scripts/tests/mise-bump.test.sh`

Expected: PASS — `All 9 checks passed.`

- [ ] **Step 5: Wire the test into the `test` task**

Modify `mise.toml`. Replace:

```toml
[tasks.test]
description = "Run the dotfiles-sync integration tests"
run = "bash scripts/tests/sync-dotfiles.test.sh"
```

with:

```toml
[tasks.test]
description = "Run the shell-script tests"
run = [
  "bash scripts/tests/sync-dotfiles.test.sh",
  "bash scripts/tests/mise-bump.test.sh",
]
```

- [ ] **Step 6: Run the full check to verify lint and both test suites pass**

Run: `mise run check`

Expected: shellcheck reports nothing, then both test suites print `All N checks passed.`

- [ ] **Step 7: Commit**

```bash
git add scripts/mise-bump.sh scripts/tests/mise-bump.test.sh mise.toml
git commit -m "feat(mise-bump): render a markdown summary of pinned-tool changes"
```

---

### Task 2: The bump path

Wrap the renderer in the thing that actually moves the pins. This half cannot be unit-tested — it shells out to mise and hits the network — so it is verified end-to-end against a throwaway copy of the repo with one pin deliberately downgraded.

**Files:**
- Modify: `scripts/mise-bump.sh`

**Interfaces:**
- Consumes: `pins`, `render_summary`, `CONFIG`, `REPO_ROOT` from Task 1.
- Produces: `scripts/mise-bump.sh [--summary-out <file>]` — bumps `.config/mise/config.toml` in place, prints the summary to stdout, and (when `--summary-out` is given) writes the same summary to that file. Exit 0 whether or not anything moved; the workflow decides what to do by looking at the git diff, not at the exit code.

- [ ] **Step 1: Add the bump path**

Modify `scripts/mise-bump.sh`. Extend the header comment's usage block:

```bash
# Usage:
#   scripts/mise-bump.sh [--summary-out <file>]      # bump, then write the summary
#   scripts/mise-bump.sh --summary <before> <after>  # render a summary only
#
# The --summary form is a pure function over two config files -- it runs no
# mise and touches no network -- which is what scripts/tests/mise-bump.test.sh
# drives.
#
# Run daily by .github/workflows/mise-bump.yaml.
```

Add the repo-root lookup immediately above the `CONFIG=` line — the bump path has to `cd` to the repo root, because `MISE_OVERRIDE_CONFIG_FILENAMES` and the `mise trust` argument are both relative paths:

```bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
```

Add these two exports immediately after the `CONFIG=` line:

```bash
# Load ONLY the container-toolchain config. Without this, mise also picks up the
# repo's root mise.toml and would bump the dev tooling (shellcheck) into the same
# PR. This is the same lever check.yaml pulls, pointed the other way.
export MISE_OVERRIDE_CONFIG_FILENAMES="$CONFIG"

# --bump keeps each entry's existing precision, and every entry is already an
# exact three-part version, so bumped entries stay exactly pinned. `mise upgrade`
# has no --pin flag (that belongs to `mise use`); MISE_PIN makes the exactness a
# guarantee rather than a coincidence.
export MISE_PIN=1
```

Replace `usage()` and `main()` with:

```bash
usage() {
    echo "usage: $0 [--summary-out <file>] | --summary <before> <after>" >&2
    exit 2
}

# Bump every pin in $CONFIG to the latest available release.
#
# --minimum-release-age 0s takes releases the moment they land, rather than
# waiting out any configured quarantine: this repo's safety net is the devpod
# matrix that runs on the resulting PR, not a waiting period.
bump() {
    local summary_out="$1" before summary

    cd "$REPO_ROOT"

    before="$(mktemp)"
    # shellcheck disable=SC2064  # expand $before now: it is gone by trap time otherwise
    trap "rm -f '$before'" EXIT
    cp "$CONFIG" "$before"

    # A fresh CI runner has never trusted this config, and mise silently ignores
    # configs it does not trust.
    mise trust --yes "$CONFIG"
    mise upgrade --bump --yes --minimum-release-age 0s

    summary="$(render_summary "$before" "$CONFIG")"
    printf '%s\n' "$summary"
    if [ -n "$summary_out" ]; then
        printf '%s\n' "$summary" > "$summary_out"
    fi
}

main() {
    local summary_out=""

    case "${1:-}" in
        --summary)
            [ "$#" -eq 3 ] || usage
            render_summary "$2" "$3"
            return 0
            ;;
    esac

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --summary-out)
                [ "$#" -ge 2 ] || usage
                summary_out="$2"
                shift 2
                ;;
            *)
                usage
                ;;
        esac
    done

    bump "$summary_out"
}

main "$@"
```

- [ ] **Step 2: Verify the pure renderer still works**

Run: `bash scripts/tests/mise-bump.test.sh`

Expected: PASS — `All 9 checks passed.` (Adding the bump path must not disturb the `--summary` entry point.)

- [ ] **Step 3: Verify the bump path end-to-end against a throwaway copy**

This runs the real thing. It copies the repo's config and scripts into a temp directory, downgrades `jq` there, and lets the script bump it back. `jq` is a tiny download, and nothing under `/workspace` is touched.

```bash
WORK="$(mktemp -d)"
mkdir -p "$WORK/repo"
cp -a .config scripts "$WORK/repo/"
sed -i 's/^jq = .*/jq = "1.8.0"/' "$WORK/repo/.config/mise/config.toml"

"$WORK/repo/scripts/mise-bump.sh" --summary-out "$WORK/body.md"

echo "--- resulting jq pin ---"
grep '^jq = ' "$WORK/repo/.config/mise/config.toml"
echo "--- PR body ---"
cat "$WORK/body.md"
```

Expected:
- The script prints mise's install progress for `jq`, then the summary.
- The `jq` pin is back to an exact three-part version newer than `1.8.0` (`jq = "1.8.2"` at time of writing).
- `$WORK/body.md` contains the preamble, the table header, and a row `` | `jq` | `1.8.0` | `1.8.2` | ``.
- No other tool appears in the table (everything else was already current in the copied config).

Then confirm the real repo was left alone:

```bash
git status --short
```

Expected: only the `scripts/mise-bump.sh` modification from Step 1 — in particular **no** change to `.config/mise/config.toml` or `mise.toml`.

Clean up: `rm -rf "$WORK"`

- [ ] **Step 4: Run lint**

Run: `mise run check`

Expected: shellcheck clean, both test suites pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/mise-bump.sh
git commit -m "feat(mise-bump): bump the pinned toolchain with mise upgrade --bump"
```

---

### Task 3: The scheduled workflow

**Files:**
- Create: `.github/workflows/mise-bump.yaml`

**Interfaces:**
- Consumes: `scripts/mise-bump.sh --summary-out <file>` from Task 2.
- Produces: a daily workflow run; on a change, a PR from branch `mise-bump` into `main`.
- Depends on a repository secret `MISE_BUMP_TOKEN` and a `dependencies` label, both created by hand — see the final step.

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/mise-bump.yaml`:

```yaml
name: Mise Bump

# Daily check for newer releases of the pinned container toolchain in
# .config/mise/config.toml. If anything moved, open -- or refresh -- a single
# rolling PR.
#
# The PR is deliberately opened with a PAT rather than the default GITHUB_TOKEN:
# GitHub does not fire `pull_request` workflows for PRs opened with GITHUB_TOKEN,
# and the entire point of the PR is that check.yaml -> devpod.yaml proves the new
# pins still `mise install` on both architectures before a human merges.

on:
  schedule:
    # 06:17 UTC. Off-the-hour on purpose: GitHub's scheduler is most contended
    # at :00 and delays those runs the longest.
    - cron: "17 6 * * *"
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

# One bump at a time, so a manual run cannot race the nightly one onto the
# same branch.
concurrency:
  group: mise-bump

jobs:
  bump:
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          # A fine-grained PAT scoped to this repo, with contents:write and
          # pull-requests:write. Fine-grained PATs expire (one year maximum);
          # when it does, this workflow starts failing with a 403 rather than
          # quietly doing nothing.
          token: ${{ secrets.MISE_BUMP_TOKEN }}

      - name: Set up mise
        uses: jdx/mise-action@v2
        with:
          # Only the mise CLI is wanted here. The action's default is to run
          # `mise install`, which would install the toolchain's *current* pins
          # for nothing -- the bump installs the new ones itself.
          install: false

      - name: Bump pinned tool versions
        env:
          # The github: backend resolves releases through the API, which is
          # rate-limited when unauthenticated.
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: scripts/mise-bump.sh --summary-out "${RUNNER_TEMP}/mise-bump-body.md"

      # No-ops when the bump changed nothing: no diff, no branch, no PR.
      # Rebuilt from a fresh checkout of main each run and force-pushed, so an
      # open bump PR is always a clean diff against current main rather than an
      # accreting pile.
      - name: Open pull request
        uses: peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1 # v8
        with:
          token: ${{ secrets.MISE_BUMP_TOKEN }}
          branch: mise-bump
          delete-branch: true
          labels: dependencies
          add-paths: .config/mise/config.toml
          commit-message: "chore(mise): bump pinned toolchain versions"
          title: "chore(mise): bump pinned toolchain versions"
          body-path: ${{ runner.temp }}/mise-bump-body.md
```

- [ ] **Step 2: Verify the YAML parses and the SHA pin is right**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/mise-bump.yaml')); print('yaml ok')"
curl -s https://api.github.com/repos/peter-evans/create-pull-request/git/ref/tags/v8 | grep -o '"sha": "[^"]*"'
```

Expected: `yaml ok`, and the printed SHA matches `5f6978faf089d4d20b00c7766989d076bb2fc7f1` in the workflow. If upstream has re-tagged `v8` since this plan was written, update the pin to the SHA the API returns and keep the `# v8` comment.

- [ ] **Step 3: Run the full check**

Run: `mise run check`

Expected: shellcheck clean, both test suites pass. (`check.yaml` will run the same thing on the PR for this change.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/mise-bump.yaml
git commit -m "ci: open a daily PR when the pinned mise toolchain has updates"
```

- [ ] **Step 5: Hand the two manual setup steps to the user**

These cannot be done from the repo and must be done before the first scheduled run, or the workflow fails at checkout with a 403:

1. **Create the token.** GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens. Scope it to this repository only, with repository permissions **Contents: Read and write** and **Pull requests: Read and write**. Add it to the repo as the Actions secret `MISE_BUMP_TOKEN` (Settings → Secrets and variables → Actions).
2. **Create the label.** Add a `dependencies` label to the repo, or drop the `labels: dependencies` line from the workflow — `create-pull-request` fails if the label does not exist.

Then verify the whole thing on demand rather than waiting for 06:17 UTC: Actions → Mise Bump → **Run workflow**. Expect either "No tool updates available." and no PR, or a `mise-bump` PR whose body is the version table and whose checks include the four `devpod up` legs.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
| --- | --- |
| `scripts/mise-bump.sh` steps 1–5 (snapshot, trust, upgrade, diff, render) | Tasks 1 and 2 |
| Config scoping via `MISE_OVERRIDE_CONFIG_FILENAMES` | Task 2, Step 1 |
| Exact pins / `MISE_PIN=1` | Task 2, Step 1 |
| Failure behaviour (`set -euo pipefail`, no PR on error) | Task 1 Step 3 (`set -euo pipefail`); no-PR-on-error follows from the workflow's fail-fast step ordering in Task 3 |
| Workflow triggers, concurrency, permissions | Task 3, Step 1 |
| Steps 1–4 of the workflow (checkout, mise, script, create-pull-request) | Task 3, Step 1 |
| Rolling branch | Task 3, Step 1 (`branch: mise-bump` + `delete-branch`) |
| Token | Task 3, Steps 1 and 5 |
| Testing (`mise-bump.test.sh`, `mise run test` wiring, lint, `workflow_dispatch` verification) | Task 1 Steps 1/5/6; Task 3 Step 5 |
| Setup required (PAT secret, `dependencies` label) | Task 3, Step 5 |

No gaps.

**Placeholder scan:** none — every step carries the full file content or the exact command and its expected output.

**Type consistency:** `CONFIG`, `TAB`, `pins`, `render_summary`, `usage`, `bump`, `main` are defined in Task 1 and used under the same names in Task 2. The `--summary-out` path written by the script in Task 2 is the same `${RUNNER_TEMP}/mise-bump-body.md` that Task 3 reads via `body-path: ${{ runner.temp }}/mise-bump-body.md` (`RUNNER_TEMP` and `runner.temp` are the same directory).
