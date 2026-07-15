#!/usr/bin/env bash
# End-to-end release test for the standalone action and installer.
#
# It deliberately uses the CDN-pinned binary rather than a locally built CLI:
#
#   branch commit + static gzip note
#     -> installer pre-push hook publishes that note
#     -> action computes/pushes a note for the squash commit
#     -> fresh clone obtains attribution through `blame --online`.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

for tool in git jq gzip base64; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

# Download through the action installer so this test verifies the public CDN pin
# and checksum used by consumers. CHATTER_BIN remains a local-only speed override.
if [ -n "${CHATTER_BIN:-}" ] && [ -x "$CHATTER_BIN" ]; then
    BIN=$CHATTER_BIN
else
    : > "$tmp/action-output"
    if ! GITHUB_OUTPUT="$tmp/action-output" RUNNER_TEMP="$tmp/runner" \
        "$ROOT/scripts/install-chatter.sh" >"$tmp/action-install.log" 2>&1; then
        sed -n '1,200p' "$tmp/action-install.log" >&2
        fail "action binary installation failed"
    fi
    BIN=$(sed -n 's/^bin=//p' "$tmp/action-output")
fi
[ -x "$BIN" ] || fail "action did not provide an executable chatter binary"
"$BIN" blame --help | grep -Fq -- '--online' || fail "pinned binary lacks blame --online"

ORIGIN="$tmp/origin.git"
PRODUCER="$tmp/producer"
RUNNER="$tmp/action-runner"
CONSUMER="$tmp/consumer"
PRODUCER_HOME="$tmp/producer-home"
ACTION_HOME="$tmp/action-home"
CONSUMER_HOME="$tmp/consumer-home"
mkdir -p "$PRODUCER_HOME" "$ACTION_HOME" "$CONSUMER_HOME"

producer_git() {
    HOME="$PRODUCER_HOME" CHATTER_HOME="$PRODUCER_HOME/.chatter" git -C "$PRODUCER" "$@"
}

configure_repo() {
    git -C "$1" config user.name "chatter e2e"
    git -C "$1" config user.email "chatter-e2e@example.test"
}

# The release's on-ref transport is exactly chatter:gzip:<base64(gzip(JSON))>.
# A static payload keeps this e2e independent of local agent transcripts.
static_note() {
    local revision=$1
    printf '{"version":"0.1","id":"static-e2e","timestamp":"2026-07-15T00:00:00Z","vcs":{"type":"git","revision":"%s"},"tool":{"name":"e2e","version":"1"},"files":[{"path":"app.txt","conversations":[{"url":"CHAT:static-e2e","agent":"claude","contributor":{"type":"ai","model_id":"e2e-model"},"ranges":[{"start_line":3,"end_line":3}]}]}],"metadata":null}' "$revision" \
        | gzip -c | base64 | tr -d '\n' | sed 's/^/chatter:gzip:/'
}

echo '=== installer hook publishes a branch trace ==='
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$PRODUCER"
configure_repo "$PRODUCER"
printf 'human line one\nhuman line two\n' > "$PRODUCER/app.txt"
producer_git add app.txt
producer_git commit -qm base
producer_git remote add origin "$ORIGIN"
producer_git push -qu origin main

# The POC installer creates real post-commit/pre-push hooks. It reuses the same
# verified binary downloaded by the composite action above.
if ! HOME="$PRODUCER_HOME" CHATTER_HOME="$PRODUCER_HOME/.chatter" \
    CHATTER_BIN="$BIN" CHATTER_HOOK_OBSERVE_BUDGET_SEC=1 \
    sh "$ROOT/install.sh" --repo "$PRODUCER" >"$tmp/installer.log" 2>&1; then
    sed -n '1,240p' "$tmp/installer.log" >&2
    fail "installer failed"
fi
test -x "$PRODUCER/.git/hooks/post-commit" || fail "post-commit hook was not installed"
test -x "$PRODUCER/.git/hooks/pre-push" || fail "pre-push hook was not installed"

producer_git checkout -qb feature
printf 'human line one\nhuman line two\nagent contribution line\n' > "$PRODUCER/app.txt"
producer_git add app.txt
producer_git commit -qm 'agent change'
FEATURE=$(producer_git rev-parse HEAD)
test -f "$PRODUCER_HOME/.chatter/logs/hooks.log" \
    || fail "post-commit hook did not invoke the observer"
SOURCE_NOTE=$(static_note "$FEATURE")
printf '%s\n' "$SOURCE_NOTE" | producer_git notes --ref=refs/notes/chatter add -F - "$FEATURE"

# The ordinary branch push invokes the installed pre-push hook. The hook must
# publish refs/notes/chatter in addition to the branch/refspecs requested here.
producer_git push -qu origin feature 'feature:refs/pull/1/head'
REMOTE_SOURCE_NOTE=$(git --git-dir="$ORIGIN" notes --ref=refs/notes/chatter show "$FEATURE")
assert_eq "$SOURCE_NOTE" "$REMOTE_SOURCE_NOTE" "pre-push hook did not publish the branch note"

echo '=== action computes and publishes the landed trace ==='
producer_git checkout -q main
producer_git merge --squash feature >/dev/null
producer_git commit -qm 'agent change (#1)'
SQUASH=$(producer_git rev-parse HEAD)
producer_git push -qu origin main

git clone -q "$ORIGIN" "$RUNNER"
configure_repo "$RUNNER"
cat > "$tmp/merged-pr-event.json" <<EOF
{"action":"closed","number":1,
 "pull_request":{"number":1,"merged":true,"merge_commit_sha":"$SQUASH",
   "head":{"sha":"$FEATURE","repo":{"full_name":"local/test"}},"base":{"ref":"main"}},
 "repository":{"full_name":"local/test","default_branch":"main"}}
EOF
: > "$tmp/action-output"
: > "$tmp/action-summary.md"
(
    cd "$RUNNER"
    HOME="$ACTION_HOME" CHATTER_HOME="$ACTION_HOME/.chatter" \
        GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$tmp/merged-pr-event.json" \
        GITHUB_OUTPUT="$tmp/action-output" GITHUB_STEP_SUMMARY="$tmp/action-summary.md" \
        CHATTER_BIN="$BIN" CHATTER_COMMENT=false CHATTER_PUSH_NOTES=true \
        "$ROOT/scripts/run.sh"
)
grep -Fxq 'computed-commits=1' "$tmp/action-output" || fail "action did not compute a landed note"
grep -Fxq 'notes-coverage=1/1' "$tmp/action-output" || fail "action did not read the branch note"
MAPPED_NOTE=$(git --git-dir="$ORIGIN" notes --ref=refs/notes/chatter show "$SQUASH")
case "$MAPPED_NOTE" in chatter:gzip:*) ;; *) fail "action did not push a compressed landed note" ;; esac

echo '=== fresh clone resolves attribution through blame --online ==='
git clone -q "$ORIGIN" "$CONSUMER"
if git -C "$CONSUMER" show-ref --verify --quiet refs/notes/chatter; then
    fail "consumer unexpectedly started with a local notes ref"
fi
blame_json=$(HOME="$CONSUMER_HOME" CHATTER_HOME="$CONSUMER_HOME/.chatter" \
    "$BIN" blame app.txt --commit "$SQUASH" --online --json --filter rollout --repo "$CONSUMER")
assert_eq 1 "$(printf '%s' "$blame_json" | jq -r '.[0].attributedLines // 0')" "online blame attribution"
git -C "$CONSUMER" show-ref --verify --quiet refs/notes/chatter \
    || fail "blame --online did not fetch refs/notes/chatter"

echo '=== uninstall removes installer-owned hooks ==='
HOME="$PRODUCER_HOME" CHATTER_HOME="$PRODUCER_HOME/.chatter" \
    sh "$ROOT/uninstall.sh" --repo "$PRODUCER" >/dev/null
test ! -e "$PRODUCER/.git/hooks/post-commit" || fail "post-commit hook remained after uninstall"
test ! -e "$PRODUCER/.git/hooks/pre-push" || fail "pre-push hook remained after uninstall"

echo 'E2E: PASS'
