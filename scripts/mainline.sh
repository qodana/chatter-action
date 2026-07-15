#!/usr/bin/env bash
# Mainline mode: rebuild trace notes on landed commits.
#
# pull_request(closed, merged) — the primary trigger: the payload names the PR and
# merge_commit_sha, so the mapping ladder starts with an exact PR signal.
# push — fallback for direct pushes: every new first-parent commit goes through the
# full ladder (PR number recovered from the "(#N)" subject suffix, cherry trailer, ...).
set -euo pipefail
. "$(dirname "$0")/common.sh"

require_full_history
ensure_git_identity
fetch_notes

targets=() # "sha[:pr]" pairs to map
case "$GITHUB_EVENT_NAME" in
    pull_request)
        [ "$(evt .pull_request.merged)" = "true" ] || { log "PR not merged; nothing to do"; exit 0; }
        sha=$(evt .pull_request.merge_commit_sha)
        pr=$(evt .pull_request.number)
        [ -n "$sha" ] && [ "$sha" != "null" ] || die "merged PR without merge_commit_sha"
        git rev-parse -q --verify "$sha^{commit}" >/dev/null || git fetch --no-tags origin "$sha"
        targets+=("$sha:$pr")
        ;;
    push)
        before=$(evt .before); after=$(evt .after)
        [ "$after" != "0000000000000000000000000000000000000000" ] || exit 0
        range="$before..$after"
        [ "$before" = "0000000000000000000000000000000000000000" ] && range="$after -n $MAX_BRANCH_COMMITS"
        for c in $(git rev-list --first-parent $range); do targets+=("$c:"); done
        ;;
    *) die "mainline mode cannot run on event '$GITHUB_EVENT_NAME'" ;;
esac

computed=0
declare -a methods=()
for t in "${targets[@]}"; do
    sha=${t%%:*}; pr=${t#*:}
    mapfile_path=$(mktemp)
    method=$("$(dirname "$0")/mapping.sh" "$sha" "$mapfile_path" "$pr")
    methods+=("$method")
    log "mapping for ${sha:0:10}: $method ($(grep -c . "$mapfile_path" || true) pair(s))"

    case "$method" in
        MERGE_PARENTS|IDENTITY)
            log "notes already sit on the original SHAs; no compute needed"
            continue ;;
        UNKNOWN)
            warn "cannot map ${sha:0:10} back to authored commits; skipping"
            continue ;;
    esac

    # Release 37 rejects identity pairs. They require no replay anyway: the note
    # already belongs to the landed commit, so leave it in place and avoid a
    # whole mapping batch failing because of one deterministic cherry-pick.
    compute_map=$(mktemp)
    awk '$1 != $2' "$mapfile_path" > "$compute_map"
    if [ ! -s "$compute_map" ]; then
        log "all mapped commits already have their landed SHA; no compute needed"
        continue
    fi

    olds=$(cut -d' ' -f1 "$compute_map")
    # shellcheck disable=SC2086
    coverage=$(note_coverage $olds)
    out "notes-coverage=$coverage"
    if [ "${coverage%%/*}" = "0" ]; then
        warn "no branch commit of ${sha:0:10} has a readable published note ($coverage) — nothing to replay. Developers' note publication may be broken (see chatter status)."
        continue
    fi

    "$CHATTER_BIN" compute --filter "$FILTER" --repo "$PWD" --mapping "$compute_map" \
        || die "chatter compute failed for ${sha:0:10}"
    computed=$((computed + 1))

    {
        echo "### chatter: trace notes for \`${sha:0:10}\`"
        echo ""
        echo "- mapping method: \`$method\`, branch-note coverage: $coverage"
    } | summary
done

out "method=${methods[0]:-}"
out "computed-commits=$computed"

if [ "$computed" -gt 0 ] && [ "${CHATTER_PUSH_NOTES:-true}" = "true" ]; then
    "$(dirname "$0")/notes-push.sh"
elif [ "$computed" -gt 0 ]; then
    log "push-notes=false: computed notes left local only"
fi
