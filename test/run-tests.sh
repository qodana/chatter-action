#!/usr/bin/env bash
# End-to-end release test for the standalone action and installer.
#
# It deliberately uses the CDN-pinned binary rather than a locally built CLI:
#
#   branch commit + static JSON note
#     -> installer pre-push hook publishes that note
#     -> action computes/pushes a note for the squash commit
#     -> fresh clone obtains attribution through `blame --online`.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
CHECK_SERVER_PID=''
cleanup() {
    if [ -n "$CHECK_SERVER_PID" ]; then
        kill "$CHECK_SERVER_PID" 2>/dev/null || true
        wait "$CHECK_SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

for tool in git jq; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

# Download through the one authoritative installer pin. The bundled action invokes
# the same `install.sh --bin-only` path when it runs on GitHub.
if [ -n "${CHATTER_BIN:-}" ] && [ -x "$CHATTER_BIN" ]; then
    BIN=$CHATTER_BIN
else
    if ! CHATTER_HOME="$tmp/release-home" sh "$ROOT/install.sh" --bin-only \
        >"$tmp/action-install.log" 2>&1; then
        sed -n '1,200p' "$tmp/action-install.log" >&2
        fail "release binary installation failed"
    fi
    BIN="$tmp/release-home/bin/chatter"
fi
[ -x "$BIN" ] || fail "installer did not provide an executable chatter binary"
"$BIN" blame --help | grep -Fq -- '--online' || fail "pinned binary lacks blame --online"

ORIGIN="$tmp/origin.git"
PRODUCER="$tmp/producer"
PR_RUNNER="$tmp/pr-runner"
RUNNER="$tmp/action-runner"
CONSUMER="$tmp/consumer"
PRODUCER_HOME="$tmp/producer-home"
PR_HOME="$tmp/pr-home"
ACTION_HOME="$tmp/action-home"
CONSUMER_HOME="$tmp/consumer-home"
mkdir -p "$PRODUCER_HOME" "$PR_HOME" "$ACTION_HOME" "$CONSUMER_HOME"

CHECK_PORT_FILE="$tmp/check-api-port"
CHECK_REQUEST_FILE="$tmp/check-api-request.json"
node "$ROOT/test/checks-api-server.js" "$CHECK_PORT_FILE" "$CHECK_REQUEST_FILE" &
CHECK_SERVER_PID=$!
for _ in {1..50}; do
    [ -s "$CHECK_PORT_FILE" ] && break
    sleep 0.1
done
[ -s "$CHECK_PORT_FILE" ] || fail "checks API test server did not start"
CHECK_API_URL="http://127.0.0.1:$(cat "$CHECK_PORT_FILE")"

producer_git() {
    HOME="$PRODUCER_HOME" CHATTER_HOME="$PRODUCER_HOME/.chatter" git -C "$PRODUCER" "$@"
}

configure_repo() {
    git -C "$1" config user.name "chatter e2e"
    git -C "$1" config user.email "chatter-e2e@example.test"
}

# Hooks can publish a direct JSON trace note. A static payload keeps this e2e
# independent of local agent transcripts while covering that real transport shape.
static_note() {
    local revision=$1
    printf '{"version":"0.1","id":"static-e2e","timestamp":"2026-07-15T00:00:00Z","vcs":{"type":"git","revision":"%s"},"tool":{"name":"e2e","version":"1"},"files":[{"path":"app.txt","conversations":[{"url":"CHAT:static-e2e","agent":"claude","contributor":{"type":"ai","model_id":"e2e-model"},"ranges":[{"start_line":3,"end_line":3}]}]}],"metadata":null}' "$revision"
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
# verified binary downloaded through the authoritative installer path above.
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

echo '=== bundled action reports branch attribution ==='
git clone -q "$ORIGIN" "$PR_RUNNER"
configure_repo "$PR_RUNNER"
cat > "$tmp/pr-event.json" <<EOF
{"action":"synchronize","number":1,
 "pull_request":{"number":1,"merged":false,
   "head":{"sha":"$FEATURE","repo":{"full_name":"local/test"}},"base":{"ref":"main"}},
 "repository":{"full_name":"local/test","default_branch":"main"}}
EOF
: > "$tmp/pr-output"
: > "$tmp/pr-summary.md"
(
    cd "$PR_RUNNER"
    HOME="$PR_HOME" CHATTER_HOME="$PR_HOME/.chatter" CHATTER_BIN="$BIN" \
        GITHUB_EVENT_NAME=pull_request GITHUB_EVENT_PATH="$tmp/pr-event.json" \
        GITHUB_OUTPUT="$tmp/pr-output" GITHUB_STEP_SUMMARY="$tmp/pr-summary.md" \
        GITHUB_ACTION_PATH="$ROOT" RUNNER_TEMP="$tmp/pr-runner-temp" \
        GITHUB_API_URL="$CHECK_API_URL" INPUT_GITHUB_TOKEN=check-test-token \
        node "$ROOT/dist/index.js"
)
grep -Fxq 'notes-coverage=1/1' "$tmp/pr-output" || fail "pr mode did not read the branch note"
grep -Fxq 'ai-lines=1' "$tmp/pr-output" || fail "pr mode did not report attribution"
case "$(git -C "$PR_RUNNER" notes --ref=refs/notes/chatter show "$FEATURE")" in
    chatter:gzip:*) ;;
    *) fail "pr mode did not normalize the fetched plain note for the pinned binary" ;;
esac
assert_eq "$SOURCE_NOTE" "$(git --git-dir="$ORIGIN" notes --ref=refs/notes/chatter show "$FEATURE")" \
    "pr mode must not publish its local note normalization"
if grep -Fq "Preview of GitHub's test merge" "$tmp/pr-summary.md"; then
    fail "test-merge preview must be opt-in"
fi
test -s "$CHECK_REQUEST_FILE" || fail "action did not call the GitHub API"
check_record=$(jq -s -e '.[] | select(.method == "POST" and .url == "/repos/local/test/check-runs")' "$CHECK_REQUEST_FILE") \
    || fail "action did not publish a GitHub Check"
comment_record=$(jq -s -e '.[] | select(.method == "POST" and .url == "/repos/local/test/issues/1/comments")' "$CHECK_REQUEST_FILE") \
    || fail "action did not post the PR comment"
assert_eq 'Chatter attribution' "$(printf '%s' "$check_record" | jq -r '.body.name')" "check name"
assert_eq "$FEATURE" "$(printf '%s' "$check_record" | jq -r '.body.head_sha')" "check head SHA"
assert_eq 'success' "$(printf '%s' "$check_record" | jq -r '.body.conclusion')" "check conclusion"
assert_eq 'Bearer check-test-token' "$(printf '%s' "$check_record" | jq -r '.headers.authorization')" "check authorization"
if printf '%s' "$check_record" | jq -r '.body.output.summary' | grep -Fq "Preview of GitHub's test merge"; then
    fail "Check summary must not include the opt-in preview by default"
fi
if ! printf '%s' "$comment_record" | jq -r '.body.body' | grep -Fq 'chatter: agent attribution of this branch'; then
    fail "PR comment did not retain the factual attribution report"
fi

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
        GITHUB_ACTION_PATH="$ROOT" RUNNER_TEMP="$tmp/action-runner-temp" \
        INPUT_COMMENT=false INPUT_PUSH_NOTES=true \
        node "$ROOT/dist/index.js"
)
test -x "$tmp/action-runner-temp/chatter-action/bin/chatter" \
    || fail "bundled action did not install its binary through install.sh --bin-only"
grep -Fxq 'computed-commits=1' "$tmp/action-output" || fail "action did not compute a landed note"
grep -Fxq 'notes-coverage=1/1' "$tmp/action-output" || fail "action did not read the branch note"
MAPPED_NOTE=$(git --git-dir="$ORIGIN" notes --ref=refs/notes/chatter show "$SQUASH")
case "$MAPPED_NOTE" in chatter:gzip:*) ;; *) fail "action did not push a compressed landed note" ;; esac

echo '=== installer merges a CI-published notes ref before the next push ==='
# The action just changed the remote notes ref, while PRODUCER still has only its
# branch-side ref. Its next ordinary push must retain that landed note and publish
# the new local note instead of silently swallowing a non-fast-forward rejection.
printf 'follow-up after CI\n' > "$PRODUCER/follow-up.txt"
producer_git add follow-up.txt
producer_git commit -qm 'follow-up after CI'
FOLLOWUP=$(producer_git rev-parse HEAD)
FOLLOWUP_NOTE=$(static_note "$FOLLOWUP")
printf '%s\n' "$FOLLOWUP_NOTE" | producer_git notes --ref=refs/notes/chatter add -F - "$FOLLOWUP"
producer_git push -qu origin main
assert_eq "$MAPPED_NOTE" "$(git --git-dir="$ORIGIN" notes --ref=refs/notes/chatter show "$SQUASH")" \
    "pre-push did not preserve the CI-published landed note"
assert_eq "$FOLLOWUP_NOTE" "$(git --git-dir="$ORIGIN" notes --ref=refs/notes/chatter show "$FOLLOWUP")" \
    "pre-push did not publish its new note after CI changed the notes ref"

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
