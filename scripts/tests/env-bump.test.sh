#!/usr/bin/env bash
#
# Tests for scripts/env-bump.sh.
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
BUMP="$REPO_ROOT/scripts/env-bump.sh"

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

echo "env-bump tests"

# ===========================================================================
echo
echo "test: a bump renders one table row per changed tool"
OUT="$(bash "$BUMP" --summary "$WORK/before.toml" "$WORK/after.toml")"
assert_contains "$OUT" '| Tool | From | To |' "table header is present"
# shellcheck disable=SC2016
assert_contains "$OUT" '| `jq` | `1.8.0` | `1.8.2` |' "core-backend tool row"
# shellcheck disable=SC2016
assert_contains "$OUT" '| `npm:skills` | `1.5.0` | `1.5.17` |' "npm-backend tool row, key unquoted"
# shellcheck disable=SC2016
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
echo "test: --partial-bump detects a tool that failed to resolve"
cat > "$WORK/stderr-failed.log" <<'EOF'
mise INFO installing jq 1.8.2
mise WARN Failed to resolve tool version list for npm:skills : some network error
mise INFO installing ripgrep 15.1.0
EOF
if bash "$BUMP" --partial-bump "$WORK/stderr-failed.log"; then
    ok "warning in stderr is detected as a partial bump"
else
    bad "warning in stderr is detected as a partial bump (exited nonzero)"
fi

echo
echo "test: --partial-bump treats clean stderr as a full bump"
cat > "$WORK/stderr-clean.log" <<'EOF'
mise INFO installing jq 1.8.2
mise INFO installing ripgrep 15.1.0
EOF
if bash "$BUMP" --partial-bump "$WORK/stderr-clean.log"; then
    bad "clean stderr is not mistaken for a partial bump (exited zero)"
else
    ok "clean stderr is not mistaken for a partial bump"
fi

echo
echo "test: --partial-bump treats empty stderr as a full bump"
: > "$WORK/stderr-empty.log"
if bash "$BUMP" --partial-bump "$WORK/stderr-empty.log"; then
    bad "empty stderr is not mistaken for a partial bump (exited zero)"
else
    ok "empty stderr is not mistaken for a partial bump"
fi

# ===========================================================================
# Codex hook trust. A config shaped like the real .codex/config.toml: settings,
# a plugin table, then the [hooks.state] tables at the end.
cat > "$WORK/codex-before.toml" <<'EOF'
model = "gpt-5.5"

[plugins."a@m"]
enabled = true

[hooks.state."a@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:aaa"

[hooks.state."b@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:bbb"
EOF

# b changed, a removed, c added.
cat > "$WORK/block.toml" <<'EOF'
[hooks.state."b@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:BBB"

[hooks.state."c@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:ccc"
EOF

echo
echo "test: --rewrite-hooks replaces every hooks table with the block"
OUT="$(bash "$BUMP" --rewrite-hooks "$WORK/codex-before.toml" "$WORK/block.toml")"
EXPECTED='model = "gpt-5.5"

[plugins."a@m"]
enabled = true

[hooks.state."b@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:BBB"

[hooks.state."c@m:hooks.json:stop:0:0"]
trusted_hash = "sha256:ccc"'
if [ "$OUT" = "$EXPECTED" ]; then ok "hooks tables replaced, other tables kept"; else bad "hooks tables replaced, other tables kept (got: $OUT)"; fi
bash "$BUMP" --rewrite-hooks "$WORK/codex-before.toml" "$WORK/block.toml" > "$WORK/rewritten.toml"
if [ "$(tail -c1 "$WORK/rewritten.toml" | od -An -c | tr -d ' ')" = '\n' ]; then ok "output ends with a newline"; else bad "output ends with a newline"; fi

echo
echo "test: --rewrite-hooks keeps a non-hook table that follows the hooks tables"
{ cat "$WORK/codex-before.toml"; printf '\n[plugins."z@m"]\nenabled = true\n'; } > "$WORK/codex-trailing.toml"
OUT="$(bash "$BUMP" --rewrite-hooks "$WORK/codex-trailing.toml" "$WORK/block.toml")"
assert_contains "$OUT" "$(printf '[plugins."z@m"]\nenabled = true')" "trailing plugin table survives"
assert_not_contains "$OUT" 'sha256:aaa' "old hook pins are gone"

echo
echo "test: --rewrite-hooks handles a config with no hooks tables"
OUT="$(bash "$BUMP" --rewrite-hooks "$WORK/before.toml" "$WORK/block.toml")"
EXPECTED="$(cat "$WORK/before.toml")

$(cat "$WORK/block.toml")"
if [ "$OUT" = "$EXPECTED" ]; then ok "block appended after one blank line"; else bad "block appended after one blank line (got: $OUT)"; fi

echo
echo "test: --rewrite-hooks with an empty block drops the hooks tables"
: > "$WORK/empty-block.toml"
OUT="$(bash "$BUMP" --rewrite-hooks "$WORK/codex-before.toml" "$WORK/empty-block.toml")"
assert_not_contains "$OUT" 'hooks.state' "no hooks tables remain"
assert_contains "$OUT" '[plugins."a@m"]' "plugin table kept"

echo
echo "test: --rewrite-hooks round-trips the real config byte for byte"
# The daily run regenerates the same block when nothing changed upstream; any
# byte difference would open a whitespace-only PR every day.
REAL="$REPO_ROOT/.codex/config.toml"
awk '/^\[hooks\.state\./ { on = 1 } on' "$REAL" > "$WORK/real-block.toml"
if bash "$BUMP" --rewrite-hooks "$REAL" "$WORK/real-block.toml" | cmp -s - "$REAL"; then
    ok "unchanged hooks rewrite to an identical file"
else
    bad "unchanged hooks rewrite to an identical file"
fi

echo
echo "test: --hooks-summary lists added, changed and removed hooks"
OUT="$(bash "$BUMP" --hooks-summary "$WORK/codex-before.toml" "$WORK/rewritten.toml")"
assert_contains "$OUT" '### Codex hook trust' "section heading"
# shellcheck disable=SC2016
assert_contains "$OUT" '- removed `a@m:hooks.json:stop:0:0`' "removed hook"
# shellcheck disable=SC2016
assert_contains "$OUT" '- changed `b@m:hooks.json:stop:0:0`' "changed hook"
# shellcheck disable=SC2016
assert_contains "$OUT" '- added `c@m:hooks.json:stop:0:0`' "added hook"

echo
echo "test: --hooks-summary with no hooks before lists every hook as added"
OUT="$(bash "$BUMP" --hooks-summary "$WORK/before.toml" "$WORK/rewritten.toml")"
# shellcheck disable=SC2016
assert_contains "$OUT" '- added `b@m:hooks.json:stop:0:0`' "b added"
# shellcheck disable=SC2016
assert_contains "$OUT" '- added `c@m:hooks.json:stop:0:0`' "c added"

echo
echo "test: --hooks-summary with a zero-byte before file lists every hook as added"
: > "$WORK/empty-before.toml"
OUT="$(bash "$BUMP" --hooks-summary "$WORK/empty-before.toml" "$WORK/rewritten.toml")"
# shellcheck disable=SC2016
assert_contains "$OUT" '- added `b@m:hooks.json:stop:0:0`' "b added from empty file"
# shellcheck disable=SC2016
assert_contains "$OUT" '- added `c@m:hooks.json:stop:0:0`' "c added from empty file"
assert_not_contains "$OUT" 'removed' "nothing removed"

echo
echo "test: --hooks-summary prints nothing when no hook changed"
OUT="$(bash "$BUMP" --hooks-summary "$WORK/codex-before.toml" "$WORK/codex-before.toml")"
if [ -z "$OUT" ]; then ok "empty output"; else bad "empty output (got: $OUT)"; fi

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$PASS"
    exit 0
else
    printf '\033[31m%d passed, %d FAILED.\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
