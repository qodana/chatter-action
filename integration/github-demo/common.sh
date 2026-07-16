#!/usr/bin/env bash
# Shared helpers for manual, real-GitHub Chatter Action release checks.
#
# These scenarios deliberately operate on qodana/chatter-demo. They create only
# unique docs/chatter-demo/manual-integration/<run-id>/ files, and merge through
# GitHub PRs for the merge-strategy tests. They never push directly to main.

set -euo pipefail

ROOT=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
INSTALL="$ROOT/install.sh"
UNINSTALL="$ROOT/uninstall.sh"
DEMO_REPOSITORY="${DEMO_REPOSITORY:-qodana/chatter-demo}"
DEMO_GIT_URL="${DEMO_GIT_URL:-git@github.com:qodana/chatter-demo.git}"
DEMO_WORKFLOW="${DEMO_WORKFLOW:-.github/workflows/chatter.yml}"
ACTION_REF="${ACTION_REF:-update}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d%H%M%S)-$$}"
WORK_ROOT="${WORK_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/chatter-action-github-demo.${RUN_ID}.XXXXXX")}"
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-false}"
KEEP_REMOTE_BRANCHES="${KEEP_REMOTE_BRANCHES:-false}"
CHATTER_EXEC=""

log() { printf '\n=== %s ===\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ] || [ "$KEEP_ARTIFACTS" = true ]; then
        printf 'chatter action demo artifacts retained at %s\n' "$WORK_ROOT" >&2
    else
        rm -rf "$WORK_ROOT"
    fi
    exit "$status"
}

require_tools() {
    local tool
    for tool in git gh jq gzip base64 node; do
        command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
    done
    gh auth status >/dev/null 2>&1 || fail "run gh auth login first"
    [ "$DEMO_REPOSITORY" = "qodana/chatter-demo" ] || fail "manual release checks are restricted to qodana/chatter-demo"
    gh repo view "$DEMO_REPOSITORY" --json nameWithOwner >/dev/null
}

resolve_chatter() {
    if [ -n "${CHATTER_BIN:-}" ]; then
        [ -x "$CHATTER_BIN" ] || fail "CHATTER_BIN is not executable: $CHATTER_BIN"
        CHATTER_EXEC="$CHATTER_BIN"
    else
        local home="$WORK_ROOT/release-home"
        CHATTER_HOME="$home" sh "$INSTALL" --bin-only >/dev/null
        CHATTER_EXEC="$home/bin/chatter"
    fi
    [ -x "$CHATTER_EXEC" ] || fail "installer did not provide chatter"
    local blame_help
    blame_help=$("$CHATTER_EXEC" blame --help)
    case "$blame_help" in
        *'--online'*) ;;
        *) fail "release binary lacks blame --online" ;;
    esac
}

assert_demo_action_ref() {
    [ -n "$ACTION_REF" ] || return
    local workflow expected
    workflow=$(git -C "$REPO" show "origin/main:$DEMO_WORKFLOW")
    expected="uses: qodana/chatter-action@$ACTION_REF"
    case "$workflow" in
        *"$expected"*) ;;
        *) fail "$DEMO_WORKFLOW on demo main does not use $expected" ;;
    esac
}

prepare_repo() {
    local scenario="$1"
    REPO="$WORK_ROOT/repo"
    BRANCH="manual/chatter-${scenario}-${RUN_ID}"
    git clone -q "$DEMO_GIT_URL" "$REPO"
    git -C "$REPO" config user.name "Chatter Action manual integration"
    git -C "$REPO" config user.email "chatter-action-manual-integration@example.test"
    git -C "$REPO" switch -c "$BRANCH" origin/main
    assert_demo_action_ref
    mkdir -p "$WORK_ROOT/user-home" "$WORK_ROOT/hook-home"
}

install_hooks() {
    HOME="$WORK_ROOT/user-home" CHATTER_HOME="$WORK_ROOT/hook-home" \
        CHATTER_BIN="$CHATTER_EXEC" CHATTER_HOOK_OBSERVE_BUDGET_SEC=5 \
        sh "$INSTALL" --repo "$REPO" >/dev/null
    test -x "$REPO/.git/hooks/post-commit" || fail "post-commit hook was not installed"
    test -x "$REPO/.git/hooks/pre-push" || fail "pre-push hook was not installed"
}

uninstall_hooks() {
    HOME="$WORK_ROOT/user-home" CHATTER_HOME="$WORK_ROOT/hook-home" \
        sh "$UNINSTALL" --repo "$REPO" >/dev/null
    test ! -e "$REPO/.git/hooks/post-commit" || fail "post-commit hook remained after uninstall"
    test ! -e "$REPO/.git/hooks/pre-push" || fail "pre-push hook remained after uninstall"
}

provider_label() {
    case "$1" in
        codex) printf 'Codex CLI' ;;
        junie) printf 'Junie' ;;
        claude) printf 'Claude Code' ;;
        *) fail "unsupported test provider: $1" ;;
    esac
}

write_trace_note() {
    # $1 commit, $2 file path, $3 chat id, $4 canonical agent, $5 model, $6 start, $7 end
    local commit="$1" file="$2" chat_id="$3" agent="$4" model="$5" start="$6" end="$7"
    local trace
    trace=$(jq -cn \
        --arg revision "$commit" --arg path "$file" --arg chatId "$chat_id" \
        --arg agent "$agent" --arg model "$model" --argjson start "$start" --argjson end "$end" \
        '{version:"0.1", id:$chatId, timestamp:"2026-07-16T00:00:00Z",
          vcs:{type:"git", revision:$revision}, tool:{name:"chatter-action-manual-integration", version:"1"},
          files:[{path:$path, conversations:[{url:$chatId, agent:$agent,
            contributor:{type:"ai", model_id:$model}, ranges:[{start_line:$start, end_line:$end}]}]}]}')
    {
        printf 'chatter:gzip:'
        printf '%s' "$trace" | gzip -c | base64 | tr -d '\n'
        printf '\n'
    } | git -C "$REPO" notes --ref=refs/notes/chatter add -f -F - "$commit"
}

commit_file() {
    # $1 repo-relative file, $2 commit subject; stdin is file content.
    local file="$1" subject="$2"
    mkdir -p "$REPO/$(dirname "$file")"
    cat > "$REPO/$file"
    git -C "$REPO" add "$file"
    git -C "$REPO" commit -qm "$subject"
    git -C "$REPO" rev-parse HEAD
}

push_branch() {
    git -C "$REPO" push -u origin "$BRANCH"
}

fresh_online_json() {
    # $1 commit, $2 file. The clone starts without notes and has an empty Chatter home.
    local commit="$1" file="$2" consumer
    consumer=$(mktemp -d "$WORK_ROOT/consumer.XXXXXX")
    git clone -q --no-tags "$DEMO_GIT_URL" "$consumer/repo"
    if git -C "$consumer/repo" show-ref --verify --quiet refs/notes/chatter; then
        fail "consumer unexpectedly started with refs/notes/chatter"
    fi
    mkdir -p "$consumer/home" "$consumer/chatter-home"
    local json
    json=$(HOME="$consumer/home" CHATTER_HOME="$consumer/chatter-home" \
        "$CHATTER_EXEC" blame "$file" --commit "$commit" --online --json --filter rollout --repo "$consumer/repo")
    git -C "$consumer/repo" show-ref --verify --quiet refs/notes/chatter \
        || fail "blame --online did not fetch refs/notes/chatter"
    printf '%s' "$json"
}

assert_online_agent() {
    # $1 commit, $2 file, $3 chat id, $4 canonical agent, $5 model, $6 exact line count
    local commit="$1" file="$2" chat_id="$3" agent="$4" model="$5" lines="$6"
    local expected_provider json
    expected_provider=$(provider_label "$agent")
    json=$(fresh_online_json "$commit" "$file")
    printf '%s' "$json" | jq -e \
        --arg chatId "$chat_id" --arg provider "$expected_provider" --arg model "$model" --argjson lines "$lines" '
          .[0] as $report |
          [$report.lines[] | select(.chatId == $chatId)] as $matched |
          [$report.chatCounts[] | select(.chatId == $chatId)] as $counts |
          ($matched | length == $lines) and
          ($matched | all(.providerName == $provider and .model == $model)) and
          ($counts | length == 1 and .[0].lineCount == $lines and .[0].providerName == $provider and .[0].model == $model)
        ' >/dev/null || fail "online blame did not preserve $agent/$model for $file"
    printf 'online blame: %s %s (%s lines)\n' "$expected_provider" "$model" "$lines"
}

assert_online_human() {
    # $1 commit, $2 file.
    local json
    json=$(fresh_online_json "$1" "$2")
    printf '%s' "$json" | jq -e '.[0] | (.attributedLines == 0 and ([.lines[].chatId] | all(. == null)))' >/dev/null \
        || fail "manual file unexpectedly has AI attribution: $2"
    printf 'online blame: manual file remains unattributed\n'
}

create_pr() {
    # $1 title. Echoes the PR number.
    local title="$1" url
    url=$(gh pr create --repo "$DEMO_REPOSITORY" --base main --head "$BRANCH" --title "$title" \
        --body "Manual Chatter Action release integration: $RUN_ID (action ref: $ACTION_REF)")
    gh pr view "$url" --repo "$DEMO_REPOSITORY" --json number --jq '.number'
}

latest_action_run() {
    # $1 exact PR title, prints a run id or nothing.
    gh run list --repo "$DEMO_REPOSITORY" --workflow 'Chatter attribution' --event pull_request --limit 50 \
        --json databaseId,status,conclusion,displayTitle,createdAt |
        jq -r --arg title "$1" '[.[] | select(.displayTitle == $title)] | sort_by(.createdAt) | last | .databaseId // empty'
}

wait_for_action() {
    # $1 exact PR title, $2 prior run ID (empty for initial PR run), $3 expected mapping token (optional).
    local title="$1" prior="${2:-}" expected_mapping="${3:-}" deadline=$((SECONDS + 600)) run status conclusion log_text log_attempt
    while [ "$SECONDS" -lt "$deadline" ]; do
        run=$(latest_action_run "$title")
        if [ -n "$run" ] && [ "$run" != "$prior" ]; then
            status=$(gh run view "$run" --repo "$DEMO_REPOSITORY" --json status --jq '.status')
            if [ "$status" = completed ]; then
                conclusion=$(gh run view "$run" --repo "$DEMO_REPOSITORY" --json conclusion --jq '.conclusion')
                [ "$conclusion" = success ] || fail "GitHub action run $run failed: $conclusion"
                log_text=''
                for log_attempt in {1..12}; do
                    log_text=$(gh run view "$run" --repo "$DEMO_REPOSITORY" --log 2>&1 || true)
                    case "$log_text" in
                        *'chatter-action: mode:'*) break ;;
                    esac
                    sleep 2
                done
                case "$log_text" in
                    *'chatter-action: mode:'*) ;;
                    *) fail "run $run did not execute chatter-action" ;;
                esac
                if [ -n "$expected_mapping" ]; then
                    case "$log_text" in
                        *"$expected_mapping"*) ;;
                        *) fail "run $run did not report $expected_mapping" ;;
                    esac
                fi
                printf '%s\n' "$run"
                return
            fi
        fi
        sleep 5
    done
    fail "timed out waiting for GitHub action for $title"
}

merge_pr() {
    # $1 PR number, $2 squash|rebase|merge.
    local pr="$1" strategy="$2"
    case "$strategy" in
        squash) gh pr merge "$pr" --repo "$DEMO_REPOSITORY" --squash --delete-branch ;;
        rebase) gh pr merge "$pr" --repo "$DEMO_REPOSITORY" --rebase --delete-branch ;;
        merge) gh pr merge "$pr" --repo "$DEMO_REPOSITORY" --merge --delete-branch ;;
        *) fail "unknown merge strategy: $strategy" ;;
    esac
}

merged_main_sha() {
    git ls-remote "$DEMO_GIT_URL" refs/heads/main | awk '{print $1}'
}

remove_branch() {
    [ "$KEEP_REMOTE_BRANCHES" = true ] || git -C "$REPO" push origin --delete "$BRANCH" >/dev/null 2>&1 || true
}
