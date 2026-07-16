#!/usr/bin/env bash
# Manual release check: one hook-published agent commit, then fresh online blame.

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap cleanup EXIT

require_tools
resolve_chatter
prepare_repo single
install_hooks

file="docs/chatter-demo/manual-integration/$RUN_ID/single-commit.md"
commit=$(commit_file "$file" "docs: add single-agent integration sample" <<'EOF'
# Single-agent release check

This text was authored by the manual Chatter Action integration scenario.
It must remain attributed after a fresh consumer fetches notes online.
EOF
)
chat_id="manual-$RUN_ID-claude"
write_trace_note "$commit" "$file" "$chat_id" claude claude-opus-4-8 1 4

log "publish the branch and its hook-owned trace note"
push_branch
assert_online_agent "$commit" "$file" "$chat_id" claude claude-opus-4-8 4

uninstall_hooks
remove_branch
printf '\nPASS: single commit hook -> push -> fresh online blame (%s)\n' "$RUN_ID"
