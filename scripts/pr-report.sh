#!/usr/bin/env bash
# PR mode: report the branch's AI attribution.
#
# Two clearly separated sections:
#   FACTUAL    — blame of the changed files at the real PR head, driven only by the
#                notes that exist on the real branch SHAs. No synthetic notes.
#   PREDICTION — optional (CHATTER_PREDICT), computed ONLY on GitHub's real
#                test-merge commit (refs/pull/N/merge): the branch notes replayed
#                onto that SHA show what mainline attribution will look like after
#                the merge. Explicitly labeled; skipped when the ref is absent
#                (merge conflict / feature disabled).
#
# Never pushes anything: prediction notes stay local to the runner.
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_full_history
ensure_git_identity
fetch_notes

PR=$(evt .pull_request.number)
HEAD_SHA=$(evt .pull_request.head.sha)
BASE_REF=$(evt .pull_request.base.ref)
BASE_REPO=$(evt .repository.full_name)
HEAD_REPO=$(evt .pull_request.head.repo.full_name)

git rev-parse -q --verify "$HEAD_SHA^{commit}" >/dev/null \
    || git fetch --no-tags origin "$HEAD_SHA" \
    || die "PR head $HEAD_SHA is not fetchable"
git fetch --no-tags --quiet origin "+refs/heads/$BASE_REF:refs/remotes/origin/$BASE_REF" || true

branch=$(git rev-list "$HEAD_SHA" --not "refs/remotes/origin/$BASE_REF" --max-count="$MAX_BRANCH_COMMITS")
report=$(mktemp -t chatter-report-XXXXXX).md

# Changed files of the PR, one per line, honoring the extension filter. quotePath off so
# non-ASCII names come out verbatim instead of quoted-and-escaped.
changed_files() {
    local merge_base files
    merge_base=$(git merge-base "refs/remotes/origin/$BASE_REF" "$HEAD_SHA")
    files=$(git -c core.quotePath=false diff --name-only "$merge_base" "$HEAD_SHA")
    if [ -n "${CHATTER_EXTENSIONS:-}" ]; then
        local pattern
        pattern=$(printf '%s' "$CHATTER_EXTENSIONS" | tr ',' '\n' | sed 's/^ *\.*/\\./; s/$/$/' | paste -sd'|' -)
        files=$(printf '%s\n' "$files" | grep -E "$pattern" || true)
    fi
    printf '%s\n' "$files"
}

# blame the changed files at $1; prints "<ai> <total>", appends per-file rows to $2.
blame_changed_at() {
    local rev=$1 rows_file=$2 f json ai lines total_ai=0 total_lines=0
    # read -r per line: a path with spaces must reach git/blame whole, not word-split.
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        git cat-file -e "$rev:$f" 2>/dev/null || continue # deleted at that revision
        json=$("$CHATTER_BIN" blame "$f" --commit "$rev" --json --filter "$FILTER" --repo "$PWD" 2>/dev/null) || continue
        ai=$(printf '%s' "$json" | jq '.[0].attributedLines // 0')
        lines=$(printf '%s' "$json" | jq '.[0].totalLines // 0')
        total_ai=$((total_ai + ai)); total_lines=$((total_lines + lines))
        [ "$ai" -gt 0 ] && printf '| `%s` | %s / %s |\n' "$f" "$ai" "$lines" >> "$rows_file"
    done < <(changed_files)
    echo "$total_ai $total_lines"
}

# markdown agent/model/lines table from the (readable) traces of the given commits.
agent_table() {
    local c agents
    agents=$(mktemp)
    for c in "$@"; do
        read_trace_json "$c" | jq -r '.files[]?.conversations[]?
            | select((.url // "") != "" or (.agent // "") != "")
            | "\(.agent // "?")\t\(.contributor.model_id // "-")\t\([.ranges[] | (.end_line - .start_line + 1)] | add)"' \
            2>/dev/null || true
    done > "$agents"
    if [ -s "$agents" ]; then
        echo ""
        echo "| agent | model | lines |"
        echo "|---|---|---|"
        sort "$agents" | awk -F'\t' '{a[$1"\t"$2]+=$3} END {for (k in a) print k"\t"a[k]}' \
            | sort -t$'\t' -k3 -rn | awk -F'\t' '{print "| "$1" | "$2" | "$3" |"}'
    fi
}

if [ -z "$branch" ]; then
    printf '<!-- chatter-action-report -->\n### chatter: agent trace\n\nNo branch commits to attribute.\n' > "$report"
else
    # shellcheck disable=SC2086
    coverage=$(note_coverage $branch)
    out "notes-coverage=$coverage"

    rows=$(mktemp)
    read -r total_ai total_lines <<< "$(blame_changed_at "$HEAD_SHA" "$rows")"
    pct=0
    [ "$total_lines" -gt 0 ] && pct=$((100 * total_ai / total_lines))

    {
        echo '<!-- chatter-action-report -->'
        echo "### chatter: agent attribution of this branch"
        echo ""
        echo "**$total_ai of $total_lines** lines in changed files are AI-attributed (${pct}%), from the trace notes of the real branch commits. Readable notes on **$coverage** branch commits."
        if [ "${coverage%%/*}" = "0" ]; then
            echo ""
            echo "> No branch commit has a readable published trace note. Either no agent touched this branch, or note publication from the author's machine is broken (\`chatter status\`)."
        fi
        if [ -s "$rows" ]; then
            echo ""
            echo "| file | AI lines |"
            echo "|---|---|"
            cat "$rows"
        fi
        # shellcheck disable=SC2086
        agent_table $branch
    } > "$report"

    out "ai-lines=$total_ai"
    out "total-lines=$total_lines"

    # --- prediction: only on GitHub's REAL test-merge commit; never pushed ---
    if [ "${CHATTER_PREDICT:-true}" = "true" ]; then
        if git fetch --no-tags --quiet origin "+refs/pull/$PR/merge:refs/chatter-action/pr-merge" 2>/dev/null; then
            merge_sha=$(git rev-parse refs/chatter-action/pr-merge)
            mapfile_path=$(mktemp)
            for c in $branch; do
                [ "$c" != "$merge_sha" ] && echo "$c $merge_sha"
            done > "$mapfile_path"
            if [ ! -s "$mapfile_path" ]; then
                log "prediction needs no replay: branch already is the test-merge commit"
            elif "$CHATTER_BIN" compute --filter "$FILTER" --repo "$PWD" --mapping "$mapfile_path"; then
                prows=$(mktemp)
                read -r p_ai p_lines <<< "$(blame_changed_at "$merge_sha" "$prows")"
                p_pct=0
                [ "$p_lines" -gt 0 ] && p_pct=$((100 * p_ai / p_lines))
                {
                    echo ""
                    echo "#### Prediction (not history)"
                    echo ""
                    echo "Computed on GitHub's test-merge commit \`${merge_sha:0:10}\` (\`refs/pull/$PR/merge\`): the attribution mainline will carry after this PR lands — **$p_ai of $p_lines** lines (${p_pct}%). The real note is written by the mainline job after the actual merge; nothing from this preview is published."
                    if [ -s "$prows" ]; then
                        echo ""
                        echo "| file | AI lines |"
                        echo "|---|---|"
                        cat "$prows"
                    fi
                    agent_table "$merge_sha"
                } >> "$report"
                out "predicted-ai-lines=$p_ai"
            else
                log "prediction compute failed; the factual section stands alone"
            fi
        else
            log "refs/pull/$PR/merge not available (conflict or disabled); no prediction section"
        fi
    fi
fi

summary < "$report"
out "report-path=$report"

if [ "${CHATTER_COMMENT:-true}" = "true" ]; then
    if [ "$HEAD_REPO" != "$BASE_REPO" ]; then
        log "fork PR: token is read-only, skipping the comment (report is in the job summary)"
    elif [ -z "${GH_TOKEN:-}" ]; then
        log "no GH_TOKEN; skipping the comment"
    else
        existing=$(gh api "repos/$BASE_REPO/issues/$PR/comments" --paginate \
            -q '[.[] | select(.body | startswith("<!-- chatter-action-report -->"))][0].id' 2>/dev/null || true)
        if [ -n "$existing" ] && [ "$existing" != "null" ]; then
            gh api -X PATCH "repos/$BASE_REPO/issues/comments/$existing" -F body=@"$report" >/dev/null \
                && log "updated PR comment $existing" || warn "failed to update the PR comment"
        else
            gh api -X POST "repos/$BASE_REPO/issues/$PR/comments" -F body=@"$report" >/dev/null \
                && log "posted PR comment" || warn "failed to post the PR comment (needs pull-requests: write)"
        fi
    fi
fi
