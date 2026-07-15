#!/usr/bin/env bash
# Entry point: one action, mode picked by the calling context.
#   pull_request closed+merged  -> mainline (compute real notes, push)
#   pull_request opened/sync/…  -> pr       (predictive report, never pushes)
#   push                        -> mainline
# CHATTER_ACTION_MODE=pr|mainline overrides the autodetect.
set -euo pipefail
. "$(dirname "$0")/common.sh"

command -v jq >/dev/null || die "jq is required on the runner"
[ -n "${CHATTER_BIN:-}" ] && [ -x "$CHATTER_BIN" ] || die "chatter binary not available (install step failed?)"
git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository — run actions/checkout first"

mode="${CHATTER_ACTION_MODE:-auto}"
if [ "$mode" = "auto" ]; then
    case "$GITHUB_EVENT_NAME" in
        pull_request|pull_request_target)
            if [ "$(evt .action)" = "closed" ]; then
                [ "$(evt .pull_request.merged)" = "true" ] && mode=mainline || { log "PR closed without merge; nothing to do"; exit 0; }
            else
                mode=pr
            fi ;;
        push) mode=mainline ;;
        *) die "unsupported event '$GITHUB_EVENT_NAME' (use mode: pr|mainline explicitly)" ;;
    esac
fi
log "mode: $mode (event: $GITHUB_EVENT_NAME)"

case "$mode" in
    pr)       exec "$(dirname "$0")/pr-report.sh" ;;
    mainline) exec "$(dirname "$0")/mainline.sh" ;;
    *)        die "unknown mode '$mode'" ;;
esac
