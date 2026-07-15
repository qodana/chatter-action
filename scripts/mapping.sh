#!/usr/bin/env bash
# Old->new mapping for one mainline commit — signal ladder:
#
#   1. MERGE_PARENTS  — true merge: branch commits keep their SHAs, notes are in place.
#   2. CHERRY_TRAILER — "cherry picked from commit <sha>" in the body, object present.
#   3. SQUASH_VIA_PR  — PR known (argument or "(#N)" at the end of the subject);
#                       refs/pull/N/head has >=2 commits -> map each onto the mainline sha.
#   4. PATCH_ID       — single-commit PR, patch-id(mainline) == patch-id(branch commit).
#   5. PR_CONTENT     — single-commit PR, patch-id differs (conflict resolution etc.);
#                       empty branch rev-list falls back to the PR head itself.
#   6. IDENTITY       — no PR signal, author == committer: not rewritten on landing.
#   7. UNKNOWN        — cannot map.
#
# Usage: mapping.sh <mainline-sha> <mapping-out-file> [pr-number]
# Prints the METHOD on stdout; writes "old new" pairs (possibly none) to the out file.
set -euo pipefail
. "$(dirname "$0")/common.sh"

H=$1
OUT=$2
PR=${3:-}
: > "$OUT"

patch_id() { # empty on merge/root/empty-diff, like the python original
    # `|| true`: under pipefail a root commit's failing `$1^` diff would kill the whole
    # script from inside the command substitution instead of falling through to SQUASH.
    { git diff --full-index "$1^" "$1" 2>/dev/null || true; } | git patch-id --stable | cut -d' ' -f1
}

parents=$(git rev-list --parents -n1 "$H" | cut -d' ' -f2- -s)
set -- $parents
if [ $# -ge 2 ]; then
    echo "MERGE_PARENTS"
    exit 0
fi
first_parent=${1:-$H}

body=$(git show -s --pretty=%b "$H")
cherry=$(printf '%s' "$body" | grep -oiE 'cherry picked from commit [0-9a-f]{7,40}' | head -1 | grep -oE '[0-9a-f]{7,40}' || true)
if [ -n "$cherry" ] && git cat-file -e "$cherry^{commit}" 2>/dev/null; then
    echo "$cherry $H" > "$OUT"
    echo "CHERRY_TRAILER"
    exit 0
fi

if [ -z "$PR" ]; then
    PR=$(git show -s --pretty=%s "$H" | grep -oE '\(#[0-9]+\)[[:space:]]*$' | grep -oE '[0-9]+' || true)
fi

if [ -n "$PR" ]; then
    if git fetch --no-tags --quiet origin "refs/pull/$PR/head" 2>/dev/null; then
        ph=$(git rev-parse FETCH_HEAD)
        excl=$(git merge-base "$first_parent" "$ph" 2>/dev/null || true)
        [ -n "$excl" ] || excl=$first_parent
        branch=$(git rev-list "$ph" --not "$excl" --max-count="$MAX_BRANCH_COMMITS")
        n=$(printf '%s' "$branch" | grep -c . || true)
        if [ "$n" -ge 2 ]; then
            # REBASE_MERGE first: walk from H down the first-parent line; when the
            # next n commits' patch-ids all belong to the branch set, the PR landed
            # as a rebase — map each landed commit 1:1 to its authored counterpart
            # (patch-id match, consuming duplicates in order). Any mismatch falls
            # through to squash (H's combined diff never matches a branch patch-id,
            # so a genuine squash exits this walk on the very first step).
            pool=$(mktemp); pairs=$(mktemp); complete=1
            for c in $branch; do
                pid=$(patch_id "$c")
                [ -n "$pid" ] || { complete=0; break; }
                printf '%s %s\n' "$pid" "$c" >> "$pool"
            done
            if [ "$complete" = 1 ]; then
                cur=$H; matched=0
                while [ "$matched" -lt "$n" ]; do
                    pid=$(patch_id "$cur")
                    [ -n "$pid" ] || break
                    old=$(awk -v p="$pid" '$1==p {print $2; exit}' "$pool")
                    [ -n "$old" ] || break
                    grep -v "^$pid $old\$" "$pool" > "$pool.new" || true
                    mv "$pool.new" "$pool"
                    printf '%s %s\n' "$old" "$cur" >> "$pairs"
                    matched=$((matched + 1))
                    cur=$(git rev-parse -q --verify "$cur^" 2>/dev/null) || break
                done
                if [ "$matched" -eq "$n" ]; then
                    cp -f "$pairs" "$OUT"
                    echo "REBASE_MERGE"
                    exit 0
                fi
            fi
            for c in $branch; do echo "$c $H"; done > "$OUT"
            echo "SQUASH_VIA_PR"
            exit 0
        elif [ "$n" -eq 1 ]; then
            b=$(printf '%s' "$branch" | head -1)
            pc=$(patch_id "$H"); pb=$(patch_id "$b")
            echo "$b $H" > "$OUT"
            if [ -n "$pc" ] && [ "$pc" = "$pb" ]; then echo "PATCH_ID"; else echo "PR_CONTENT"; fi
            exit 0
        else
            echo "$ph $H" > "$OUT"
            echo "PR_CONTENT"
            exit 0
        fi
    fi
fi

ids=$(git show -s --pretty='%ae%x1f%ce' "$H")
ae=${ids%%$'\x1f'*}; ce=${ids##*$'\x1f'}
if [ -n "$ae" ] && [ "$ae" = "$ce" ]; then
    echo "IDENTITY"
else
    echo "UNKNOWN"
fi
