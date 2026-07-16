#!/usr/bin/env bash
# Manual release check: real GitHub PR merge and post-compute online attribution.
# Usage: merge-strategy.sh squash|rebase|merge

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap cleanup EXIT

strategy="${1:-}"
case "$strategy" in squash|rebase|merge) ;; *) echo "usage: $0 squash|rebase|merge" >&2; exit 2 ;; esac

require_tools
resolve_chatter
prepare_repo "merge-$strategy"
install_hooks

base="docs/chatter-demo/manual-integration/$RUN_ID/$strategy"

codex_file="$base/codex.md"
codex_commit=$(commit_file "$codex_file" "docs: add Codex $strategy merge sample" <<'EOF'
# Codex merge sample

Codex content survives the selected GitHub merge strategy.
The fresh consumer must resolve its agent and model from notes.
EOF
)
codex_chat="manual-$RUN_ID-$strategy-codex"
write_trace_note "$codex_commit" "$codex_file" "$codex_chat" codex gpt-5.6-terra 1 4

junie_file="$base/junie.md"
junie_commit=$(commit_file "$junie_file" "docs: add Junie $strategy merge sample" <<'EOF'
# Junie merge sample

Junie content survives the selected GitHub merge strategy.
The fresh consumer must resolve its agent and model from notes.
EOF
)
junie_chat="manual-$RUN_ID-$strategy-junie"
write_trace_note "$junie_commit" "$junie_file" "$junie_chat" junie nemotron-ultra 1 4

claude_file="$base/claude.md"
claude_commit=$(commit_file "$claude_file" "docs: add Claude $strategy merge sample" <<'EOF'
# Claude merge sample

Claude content survives the selected GitHub merge strategy.
The fresh consumer must resolve its agent and model from notes.
EOF
)
claude_chat="manual-$RUN_ID-$strategy-claude"
write_trace_note "$claude_commit" "$claude_file" "$claude_chat" claude claude-opus-4-8 1 4

manual_file="$base/manual.md"
commit_file "$manual_file" "docs: add manual $strategy merge control" <<'EOF' >/dev/null
# Manual merge control

This human-only file must remain without Chatter attribution after the merge.
EOF

log "push source notes, open the real GitHub PR, and wait for its factual report"
push_branch
title="test: Chatter Action $strategy release integration $RUN_ID"
pr=$(create_pr "$title")
initial_run=$(wait_for_action "$title" "")

log "merge PR #$pr with $strategy"
merge_pr "$pr" "$strategy"
case "$strategy" in
    squash) mapping="SQUASH_VIA_PR" ;;
    rebase) mapping="REBASE_MERGE" ;;
    merge) mapping="MERGE_PARENTS" ;;
esac
closed_run=$(wait_for_action "$title" "$initial_run" "$mapping")
landing=$(merged_main_sha)
printf 'landing=%s action-run=%s mapping=%s\n' "$landing" "$closed_run" "$mapping"

log "fresh consumers fetch post-compute notes only through blame --online"
assert_online_agent "$landing" "$codex_file" "$codex_chat" codex gpt-5.6-terra 4
assert_online_agent "$landing" "$junie_file" "$junie_chat" junie nemotron-ultra 4
assert_online_agent "$landing" "$claude_file" "$claude_chat" claude claude-opus-4-8 4
assert_online_human "$landing" "$manual_file"

uninstall_hooks
printf '\nPASS: %s merge -> action compute -> fresh online blame (%s)\n' "$strategy" "$RUN_ID"
