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
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32mAll %d checks passed.\033[0m\n' "$PASS"
    exit 0
else
    printf '\033[31m%d passed, %d FAILED.\033[0m\n' "$PASS" "$FAIL"
    exit 1
fi
