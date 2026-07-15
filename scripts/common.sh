# shellcheck shell=bash
# Shared helpers. Scripts read all GitHub context from GITHUB_* env vars and the
# event payload file, so every entry point runs locally against a fake event.json.
set -euo pipefail

FILTER="${CHATTER_FILTER:-rollout}"
# chatter blame/compute derive their refs from --filter alone (no notes-ref flag), so
# the scripts must fetch/push exactly the ref the CLI reads and writes: an explicit
# CHATTER_NOTES_REF may only confirm the filter-derived one, never diverge from it.
case "$FILTER" in
    rollout) filter_notes_ref="refs/notes/chatter" ;;
    wal)     filter_notes_ref="refs/notes/wal-chatter" ;;
    *) echo "::error::chatter-action: unsupported filter '$FILTER' (want rollout|wal)"; exit 1 ;;
esac
NOTES_REF="${CHATTER_NOTES_REF:-$filter_notes_ref}"
if [ "$NOTES_REF" != "$filter_notes_ref" ]; then
    echo "::error::chatter-action: notes-ref '$NOTES_REF' contradicts filter '$FILTER' (chatter uses $filter_notes_ref); drop the notes-ref input or align it"
    exit 1
fi
# CDN release 37 stores one bounded gzip+Base64 JSON note per commit. Keep the
# decoder here because CI runners do not have a local Chatter database to enrich
# the agent table in a PR report.
MAX_ENCODED_NOTE_BYTES=200000
MAX_BRANCH_COMMITS=200

log()    { echo "chatter-action: $*" >&2; }
warn()   { echo "::warning::chatter-action: $*"; }
die()    { echo "::error::chatter-action: $*"; exit 1; }

evt() { jq -r "$1" "$GITHUB_EVENT_PATH"; }

out() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT" || true; }

summary() { [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat >> "$GITHUB_STEP_SUMMARY" || cat > /dev/null; }

require_full_history() {
    [ "$(git rev-parse --is-shallow-repository)" = "false" ] \
        || die "shallow checkout: add 'fetch-depth: 0' to actions/checkout"
}

# Notes commits/merges need an identity; runners have none configured.
ensure_git_identity() {
    git config user.email >/dev/null 2>&1 || git config user.email "chatter-action@jetbrains.com"
    git config user.name  >/dev/null 2>&1 || git config user.name  "chatter-action"
}

fetch_notes() {
    git fetch --no-tags origin "+$NOTES_REF:$NOTES_REF" 2>/dev/null \
        || log "no $NOTES_REF on origin yet"
}

base64_decode() {
    if base64 --decode </dev/null >/dev/null 2>&1; then
        base64 --decode
    else
        base64 -D
    fi
}

# Full trace JSON of a commit's compressed note; empty when unreadable.
read_trace_json() {
    local raw payload
    raw=$(git notes --ref "$NOTES_REF" show "$1" 2>/dev/null) || return 0
    case "$raw" in
        chatter:gzip:*)
            [ "${#raw}" -le "$MAX_ENCODED_NOTE_BYTES" ] || return 0
            payload=${raw#chatter:gzip:}
            printf '%s' "$payload" | base64_decode | gzip -dc 2>/dev/null || true
            ;;
    esac
}

# A note counts only when it has the current release's decodable trace payload.
note_readable() {
    read_trace_json "$1" | jq -e 'type == "object"' >/dev/null 2>&1
}

# "X/Y" — how many of the given commits carry a readable trace (rollout health signal).
note_coverage() {
    local total=0 noted=0 c
    for c in "$@"; do
        total=$((total + 1))
        note_readable "$c" && noted=$((noted + 1))
    done
    echo "$noted/$total"
}
