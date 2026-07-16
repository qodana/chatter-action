#!/usr/bin/env bash
# Manual release check: three provider commits plus a human-only control on a branch.

set -euo pipefail
source "$(dirname "$0")/common.sh"
trap cleanup EXIT

require_tools
resolve_chatter
prepare_repo multi-agent-branch
install_hooks

base="docs/chatter-demo/manual-integration/$RUN_ID"

codex_file="$base/codex.md"
codex_commit=$(commit_file "$codex_file" "docs: add Codex integration sample" <<'EOF'
# Codex integration sample

Codex writes this first verification sentence.
Codex writes this second verification sentence.
EOF
)
codex_chat="manual-$RUN_ID-codex"
write_trace_note "$codex_commit" "$codex_file" "$codex_chat" codex gpt-5.6-terra 1 4

junie_file="$base/junie.md"
junie_commit=$(commit_file "$junie_file" "docs: add Junie integration sample" <<'EOF'
# Junie integration sample

Junie writes this first verification sentence.
Junie writes this second verification sentence.
EOF
)
junie_chat="manual-$RUN_ID-junie"
write_trace_note "$junie_commit" "$junie_file" "$junie_chat" junie nemotron-ultra 1 4

claude_file="$base/claude.md"
claude_commit=$(commit_file "$claude_file" "docs: add Claude integration sample" <<'EOF'
# Claude integration sample

Claude writes this first verification sentence.
Claude writes this second verification sentence.
EOF
)
claude_chat="manual-$RUN_ID-claude"
write_trace_note "$claude_commit" "$claude_file" "$claude_chat" claude claude-opus-4-8 1 4

manual_file="$base/manual.md"
manual_commit=$(commit_file "$manual_file" "docs: add manual integration control" <<'EOF'
# Manual integration control

This text is intentionally created without an agent trace note.
It must remain unattributed in a fresh clone.
EOF
)

log "publish all three provider notes through the installed pre-push hook"
push_branch
assert_online_agent "$codex_commit" "$codex_file" "$codex_chat" codex gpt-5.6-terra 4
assert_online_agent "$junie_commit" "$junie_file" "$junie_chat" junie nemotron-ultra 4
assert_online_agent "$claude_commit" "$claude_file" "$claude_chat" claude claude-opus-4-8 4
assert_online_human "$manual_commit" "$manual_file"

uninstall_hooks
remove_branch
printf '\nPASS: multi-agent branch -> fresh online blame (%s)\n' "$RUN_ID"
