#!/bin/sh
# chatter POC uninstaller. Symmetric to install.sh:
#   cd /path/to/repo && sh uninstall.sh          # unregister this repo
#   sh uninstall.sh --repo /path/to/repo         # unregister a specific repo
#   sh uninstall.sh --all                        # unregister everything
# Removes only hooks owned by this installer; it never overwrites or deletes another
# tool's hook. The registry is used only to locate hooks for `--all`.
# Binary/DB/notes are kept (notes live in the repo's own refs; remove manually if required).
set -eu

HOME_DIR="${CHATTER_HOME:-$HOME/.chatter}"
REGISTRY="$HOME_DIR/enabled-repos"

ALL=0; REPO_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --all) ALL=1; shift ;;
        --repo) REPO_ARG="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

is_our_hook() {
    [ -f "$1" ] && grep -Fq '# chatter-poc-hook:' "$1" 2>/dev/null
}

remove_repo_hooks() {
    common_dir=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    hooks_dir=$(git -C "$1" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || return 0
    default_hooks_dir="$common_dir/hooks"
    if [ "$hooks_dir" != "$default_hooks_dir" ]; then
        echo "chatter: leaving hooks under active core.hooksPath ($hooks_dir)" >&2
        return 0
    fi
    for hook_name in post-commit post-rewrite pre-push; do
        hook_path="$hooks_dir/$hook_name"
        if { [ -e "$hook_path" ] || [ -L "$hook_path" ]; }; then
            if is_our_hook "$hook_path"; then
                rm -f "$hook_path"
                echo "chatter: removed $hook_name hook from $1"
            else
                echo "chatter: leaving non-chatter $hook_name hook in $hooks_dir" >&2
            fi
        fi
    done
}

if [ "$ALL" = 1 ]; then
    if [ -f "$REGISTRY" ]; then
        while IFS= read -r registered_repo; do
            [ -n "$registered_repo" ] && [ -d "$registered_repo" ] || continue
            remove_repo_hooks "$registered_repo"
        done < "$REGISTRY"
    fi
    : > "$REGISTRY" 2>/dev/null || true
    echo "chatter: all repos unregistered"
    exit 0
fi

repo_cwd="${REPO_ARG:-$PWD}"
repo_is_git=1
if common_dir=$(git -C "$repo_cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    repo_root=$(dirname "$common_dir")
else
    # the repo dir was deleted (or is not a repo any more): still allow unregistering
    # the literal --repo path; there is no git config left to clean up
    [ -n "$REPO_ARG" ] || { echo "error: $repo_cwd is not a git repository (pass --repo <registered path>)" >&2; exit 1; }
    repo_root=$REPO_ARG
    repo_is_git=0
fi

if [ -f "$REGISTRY" ] && grep -Fxq "$repo_root" "$REGISTRY"; then
    grep -Fxv "$repo_root" "$REGISTRY" > "$REGISTRY.tmp" || true
    mv -f "$REGISTRY.tmp" "$REGISTRY"
    echo "chatter: unregistered $repo_root"
else
    echo "chatter: $repo_root was not registered"
fi
if [ "$repo_is_git" = 1 ]; then
    # The installer never writes repository config; remove only marker-owned hooks.
    remove_repo_hooks "$repo_root"
fi
