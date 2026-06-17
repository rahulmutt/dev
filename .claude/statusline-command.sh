#!/usr/bin/env bash
# Claude Code status line: context usage | git remote | git branch | PR number

input=$(cat)

# Context usage
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Git remote (owner/repo from JSON)
repo=$(echo "$input" | jq -r '.workspace.repo | if . then .owner + "/" + .name else empty end')

# Git branch (from cwd)
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // empty')
branch=""
if [ -n "$cwd" ]; then
    branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
fi

# PR number
pr_number=$(echo "$input" | jq -r '.pr.number // empty')
pr_state=$(echo "$input" | jq -r '.pr.review_state // empty')

# Build output
parts=()

if [ -n "$repo" ] && [ -n "$branch" ]; then
    parts+=("${repo}:${branch}")
elif [ -n "$repo" ]; then
    parts+=("$repo")
elif [ -n "$branch" ]; then
    parts+=("$branch")
fi

if [ -n "$pr_number" ]; then
    if [ -n "$pr_state" ]; then
        parts+=("PR #${pr_number} (${pr_state})")
    else
        parts+=("PR #${pr_number}")
    fi
fi

if [ -n "$used" ]; then
    printf_used=$(printf "%.0f" "$used")
    parts+=("ctx: ${printf_used}% used")
else
    parts+=("ctx: --")
fi

# Join with separator
output=""
for part in "${parts[@]}"; do
    if [ -z "$output" ]; then
        output="$part"
    else
        output="$output | $part"
    fi
done

echo "$output"
