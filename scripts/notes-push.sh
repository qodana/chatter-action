#!/usr/bin/env bash
# Push the local notes ref to origin, tolerating races with concurrent mainline
# jobs: on non-fast-forward, fetch the remote notes, merge them into ours
# (compute results are deterministic, so same-sha conflicts cannot diverge —
# `-s ours` keeps our freshly computed side), and retry. This loop is what makes
# concurrent mainline runs safe — do NOT serialize them with a `concurrency` group
# (GitHub keeps one pending run per group and silently cancels the rest).
set -euo pipefail
. "$(dirname "$0")/common.sh"

INCOMING="${NOTES_REF}-chatter-action-incoming"

push_err=""
for attempt in 1 2 3 4 5; do
    if push_err=$(git push --no-verify origin "$NOTES_REF:$NOTES_REF" 2>&1); then
        log "notes pushed (attempt $attempt)"
        git update-ref -d "$INCOMING" 2>/dev/null || true
        exit 0
    fi
    log "notes push rejected (attempt $attempt); merging remote notes and retrying"
    git fetch --no-tags origin "+$NOTES_REF:$INCOMING"
    git notes --ref "$NOTES_REF" merge -s ours "$INCOMING" \
        || warn "notes merge reported conflicts; kept local (deterministic) side"
    sleep "$attempt"
done
die "failed to push $NOTES_REF after 5 attempts; last rejection: $push_err"
