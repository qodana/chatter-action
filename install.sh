#!/bin/sh
# chatter POC installer (macOS + Linux).
#
# Per-repo opt-in. A direct post-commit hook observes commits locally; the pre-push
# hook runs the same observe with --push-trace=true, which completes any pending work
# and publishes the Git trace refs using the developer's normal Git credentials.
#
#   cd /path/to/repo && curl -fsSL https://<host>/chatter/install.sh | sh
#   # or: sh install.sh --repo /path/to/repo
#   # or: CHATTER_HOME=/tmp/chatter sh install.sh --bin-only
#
# What it does (idempotent):
#   1. Downloads the chatter native binary into ~/.chatter/bin (skipped if present,
#      or symlinks $CHATTER_BIN when set — useful for testing).
#   2. Registers the repo's MAIN worktree in ~/.chatter/enabled-repos solely so
#      `uninstall --all` can find installer-owned hooks. Nothing reads it at runtime.
#   3. Installs direct post-commit and pre-push hooks when their slots are empty
#      (or already owned by this installer). It never overwrites another hook.
#   4. Runs a first local observe for the repo immediately, seeding its baseline.
#
# Hook guarantees:
#   * Hooks call chatter with a 20 s soft observe budget by default and (unless strict)
#     never fail Git. post-commit skips rebase-internal commits; a completed rewrite is
#     resolved by the next observe from lineage evidence.
#   * pre-push observes the local repository, merges the latest remote notes into its
#     local notes ref, then explicitly publishes the main agent-trace notes ref plus
#     its chunk-object refs to the build's built-in origin remote. Git has no post-push
#     hook, so publication is non-interactive and explicit.
set -eu

# --- pinned release (from the CI/CD CDN manifest; update these on new builds) ---
# sourceBuild: StaticAnalysis_Base_chatter_github_releases #38, seed 11763b
BASE_URL="${CHATTER_BASE_URL:-https://download.jetbrains.com/qodana/chatter/38-11763b}"
SHA_LINUX_AARCH64="57ec62050f5145aae5ad03616c78b157fd9c0d6be896a5b7d07ae9c16573b22e"
SHA_LINUX_X86_64="e267b58b9fdcb44dfb0562b565b49bc147fbfde31ecf868b20f8c061eebbbc2a"
SHA_MACOS_AARCH64="472c8c1072051222ae817bf8f95e2abd9493ae59800dca32e2207bf2bf401a7d"
SHA_MACOS_X86_64="42c2e33cded9ee21dee86139fa2884891f0a47467f9de0fc887fe1b57f4996cf"

HOME_DIR="${CHATTER_HOME:-$HOME/.chatter}"
BIN_DIR="$HOME_DIR/bin"
BIN="$BIN_DIR/chatter"
REGISTRY="$HOME_DIR/enabled-repos"
HOOK_BUDGET_SEC="${CHATTER_HOOK_OBSERVE_BUDGET_SEC:-20}"
FILTER="${CHATTER_FILTER:-rollout}"
STRICT_PUSH="${CHATTER_STRICT_PUSH:-false}"
TRACE_REMOTE="${CHATTER_TRACE_REMOTE:-origin}"
LOG_DIR="$HOME_DIR/logs"

REPO_ARG=""
BIN_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO_ARG="$2"; shift 2 ;;
        --bin-only) BIN_ONLY=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ "$BIN_ONLY" = 0 ] || [ -z "$REPO_ARG" ] || {
    echo "error: --bin-only cannot be combined with --repo" >&2; exit 2; }

case "$HOOK_BUDGET_SEC" in
    ''|*[!0-9]*) echo "error: CHATTER_HOOK_OBSERVE_BUDGET_SEC must be a positive integer" >&2; exit 2 ;;
esac
[ "$HOOK_BUDGET_SEC" -gt 0 ] || { echo "error: CHATTER_HOOK_OBSERVE_BUDGET_SEC must be a positive integer" >&2; exit 2; }
case "$FILTER" in
    rollout)
        NOTES_REF="refs/notes/chatter"
        CHUNK_REF_PATTERN="refs/notes/chatter-trace-objects"
        ;;
    wal)
        NOTES_REF="refs/notes/wal-chatter"
        CHUNK_REF_PATTERN="refs/notes/wal-chatter-trace-objects"
        ;;
    *) echo "error: CHATTER_FILTER must be rollout or wal" >&2; exit 2 ;;
esac
case "$STRICT_PUSH" in
    true|false) ;;
    *) echo "error: CHATTER_STRICT_PUSH must be true or false" >&2; exit 2 ;;
esac
case "$TRACE_REMOTE" in
    origin) ;;
    *)
        echo "error: the pinned chatter build supports only CHATTER_TRACE_REMOTE=origin" >&2
        echo "       it has no per-invocation trace-remote option" >&2
        exit 2
        ;;
esac

if [ "$BIN_ONLY" = 0 ]; then
    # --- resolve the repo's main worktree (registry stores roots for uninstall only) ---
    repo_cwd="${REPO_ARG:-$PWD}"
    git -C "$repo_cwd" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "error: $repo_cwd is not a git repository" >&2; exit 1; }
    common_dir=$(git -C "$repo_cwd" rev-parse --path-format=absolute --git-common-dir)
    repo_root=$(dirname "$common_dir")
    [ -d "$repo_root" ] || { echo "error: cannot resolve main worktree of $repo_cwd" >&2; exit 1; }
    hooks_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks)
    default_hooks_dir="$common_dir/hooks"
    [ "$hooks_dir" = "$default_hooks_dir" ] || {
        echo "error: core.hooksPath is active for $repo_root ($hooks_dir)" >&2
        echo "       this POC only supports the repository's own $default_hooks_dir" >&2
        exit 1
    }

    # Do not replace or wrap another tool's hooks. A POC can opt in only where these
    # slots are free; composable hook dispatching is intentionally out of scope here.
    is_our_hook() {
        [ -f "$1" ] && grep -Fq '# chatter-poc-hook:' "$1" 2>/dev/null
    }
    for hook_name in post-commit pre-push; do
        hook_path="$hooks_dir/$hook_name"
        if { [ -e "$hook_path" ] || [ -L "$hook_path" ]; } && ! is_our_hook "$hook_path"; then
            echo "error: $hook_path already exists and is not managed by chatter" >&2
            echo "       refusing to overwrite an existing Git hook" >&2
            exit 1
        fi
    done
fi

mkdir -p "$BIN_DIR" "$LOG_DIR"
[ "$BIN_ONLY" = 1 ] || mkdir -p "$hooks_dir"
chmod 700 "$HOME_DIR" "$BIN_DIR" "$LOG_DIR" 2>/dev/null || true

# --- 1. binary (zip asset from the CDN, sha256-verified against the pinned manifest) ---
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
extract_zip() { # $1=zip $2=destdir
    if command -v unzip >/dev/null 2>&1; then unzip -oq "$1" -d "$2"
    elif command -v bsdtar >/dev/null 2>&1; then bsdtar -xf "$1" -C "$2"
    else python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$1" "$2"
    fi
}
if [ -n "${CHATTER_BIN:-}" ] && [ -x "$CHATTER_BIN" ]; then
    ln -sf "$CHATTER_BIN" "$BIN"
    echo "chatter: using local binary $CHATTER_BIN"
elif [ ! -x "$BIN" ]; then
    case "$(uname -s)" in
        Darwin) os=macos ;;
        Linux)  os=linux ;;
        *) echo "error: unsupported OS $(uname -s) (POC covers macOS/Linux)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) arch=aarch64 ;;
        x86_64|amd64)  arch=x86_64 ;;
        *) echo "error: unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    asset="chatter-$os-$arch.zip"
    case "$os-$arch" in
        linux-aarch64) want_sha="$SHA_LINUX_AARCH64" ;;
        linux-x86_64)  want_sha="$SHA_LINUX_X86_64" ;;
        macos-aarch64) want_sha="$SHA_MACOS_AARCH64" ;;
        macos-x86_64)  want_sha="$SHA_MACOS_X86_64" ;;
    esac
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    echo "chatter: downloading $BASE_URL/$asset"
    curl -fSL -o "$tmp/$asset" "$BASE_URL/$asset"
    got_sha=$(sha256_of "$tmp/$asset")
    if [ -n "$want_sha" ] && [ "$got_sha" != "$want_sha" ]; then
        echo "error: sha256 mismatch for $asset" >&2
        echo "  expected $want_sha" >&2
        echo "  got      $got_sha" >&2
        exit 1
    fi
    extract_zip "$tmp/$asset" "$tmp/x"
    # locate the executable inside the archive: prefer a file named `chatter*`, else the single file
    bin_path=$(find "$tmp/x" -type f -name 'chatter*' ! -name '*.sha256' | head -1)
    [ -n "$bin_path" ] || bin_path=$(find "$tmp/x" -type f | head -1)
    [ -n "$bin_path" ] || { echo "error: no binary found inside $asset" >&2; exit 1; }
    chmod +x "$bin_path"
    mv -f "$bin_path" "$BIN"
    echo "chatter: installed $BIN (sha256 verified)"
fi

if [ "$BIN_ONLY" = 1 ]; then
    echo "chatter: binary ready at $BIN"
    exit 0
fi

# --- 2. register repo (dedup; used only by uninstall --all) ---
touch "$REGISTRY"
if ! grep -Fxq "$repo_root" "$REGISTRY"; then
    printf '%s\n' "$repo_root" >> "$REGISTRY"
    echo "chatter: registered $repo_root"
else
    echo "chatter: already registered $repo_root"
fi
# Each hook is self-contained: values selected at install time are embedded directly in it.
shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

# $1: --push-trace value — false for the local-only post-commit observe, true for the
# publishing pre-push one (observe then ends by pushing the trace notes). Callers
# append the line tail (`|| true`, or the strict failure handler).
write_observe_command() {
    printf '%s\n' 'GIT_TERMINAL_PROMPT=0 \'
    printf '  %s observe \\\n' "$(shell_quote "$BIN")"
    printf '  --filter %s \\\n' "$(shell_quote "$FILTER")"
    printf '  --push-trace=%s \\\n' "$1"
    printf '%s\n' '  --analytics=false \'
    printf '  --budget-sec %s \\\n' "$(shell_quote "$HOOK_BUDGET_SEC")"
    printf '  --log-basedir %s \\\n' "$(shell_quote "$HOME_DIR")"
    printf '  --repo %s </dev/null >> %s 2>&1' \
        "$(shell_quote "$repo_root")" "$(shell_quote "$LOG_DIR/hooks.log")"
}

# First contact deliberately seeds baseline before hooks become active, so the first
# post-install commit is observed rather than absorbed as existing history.
echo "chatter: seeding local observer for $repo_root ..."
GIT_TERMINAL_PROMPT=0 "$BIN" observe \
    --filter "$FILTER" \
    --push-trace=false \
    --analytics=false \
    --budget-sec 90 \
    --log-basedir "$HOME_DIR" \
    --repo "$repo_root" >> "$LOG_DIR/install.log" 2>&1 || {
        echo "error: initial chatter observe failed; see $LOG_DIR/install.log" >&2
        exit 1
    }

# --- 4. direct hook installation ---
install_post_commit_hook() {
    {
        printf '%s\n' '#!/bin/sh' '# chatter-poc-hook: post-commit'
        cat <<'POST_COMMIT_GUARD'
# A rebase runs post-commit for each picked commit; skip those. The completed rewrite
# is resolved by the next observe (next post-commit or pre-push) from lineage evidence.
if [ -e "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] || \
   [ -e "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
    exit 0
fi
POST_COMMIT_GUARD
        write_observe_command false
        printf ' || true\n'
    } > "$hooks_dir/post-commit"
    chmod +x "$hooks_dir/post-commit"
}

install_pre_push_hook() {
    {
        printf '%s\n' '#!/bin/sh' '# chatter-poc-hook: pre-push'
        printf '%s\n' '# Git has no post-push hook. Observe first, then explicitly publish the' \
            '# prepared notes ref. The nested notes push is guarded against recursion.'
        printf 'TRACE_REMOTE=%s\n' "$(shell_quote "$TRACE_REMOTE")"
        printf 'NOTES_REF=%s\n' "$(shell_quote "$NOTES_REF")"
        printf 'CHUNK_REF_PATTERN=%s\n' "$(shell_quote "$CHUNK_REF_PATTERN")"
        printf 'HOOK_LOG=%s\n' "$(shell_quote "$LOG_DIR/hooks.log")"
        cat <<'PRE_PUSH_GUARD'
# The explicit notes push below invokes this hook too. Do not recursively observe/publish.
[ "${CHATTER_INTERNAL_TRACE_PUSH:-}" = 1 ] && exit 0
# $1 = remote name ($2 = destination URL); a push straight to a URL puts it in both.
# Publish when either identifies the trace remote.
trace_url=$(git config --get "remote.$TRACE_REMOTE.pushurl" 2>/dev/null \
    || git config --get "remote.$TRACE_REMOTE.url" 2>/dev/null || true)
[ "${1:-}" = "$TRACE_REMOTE" ] || { [ -n "$trace_url" ] && [ "${2:-}" = "$trace_url" ]; } || exit 0
PRE_PUSH_GUARD
        cat <<'PRE_PUSH_PUBLISH'
publish_trace_notes() {
    # Agent-less commits have no trace note, so there is nothing to publish.
    git show-ref --verify --quiet "$NOTES_REF" || return 0

    # CI may have published a landed note since this checkout last fetched notes.
    # Merge that remote side first: a plain push would be non-fast-forward and the
    # default non-strict hook would otherwise silently leave this branch note local.
    incoming="${NOTES_REF}-chatter-poc-incoming"
    git update-ref -d "$incoming" >/dev/null 2>&1 || true
    GIT_TERMINAL_PROMPT=0 git fetch --no-tags "$TRACE_REMOTE" \
        "+$NOTES_REF:$incoming" >> "$HOOK_LOG" 2>&1 || true
    if git show-ref --verify --quiet "$incoming"; then
        GIT_AUTHOR_NAME=chatter-hook GIT_AUTHOR_EMAIL=chatter-hook@localhost \
        GIT_COMMITTER_NAME=chatter-hook GIT_COMMITTER_EMAIL=chatter-hook@localhost \
            git notes --ref="$NOTES_REF" merge -s ours "$incoming" >> "$HOOK_LOG" 2>&1 || {
                git update-ref -d "$incoming" >/dev/null 2>&1 || true
                return 1
            }
    fi
    git update-ref -d "$incoming" >/dev/null 2>&1 || true

    set -- "$NOTES_REF:$NOTES_REF"
    for trace_ref in $(git for-each-ref --format='%(refname)' "$CHUNK_REF_PATTERN"); do
        set -- "$@" "$trace_ref:$trace_ref"
    done
    GIT_TERMINAL_PROMPT=0 CHATTER_INTERNAL_TRACE_PUSH=1 \
        git push "$TRACE_REMOTE" "$@" >> "$HOOK_LOG" 2>&1
}
PRE_PUSH_PUBLISH
        write_observe_command true
        if [ "$STRICT_PUSH" = true ]; then
            printf ' || {\n    echo %s >&2\n    exit 1\n}\n' \
                "$(shell_quote "chatter: agent-trace publication failed (see $LOG_DIR/hooks.log)")"
            printf 'publish_trace_notes || {\n    echo %s >&2\n    exit 1\n}\n' \
                "$(shell_quote "chatter: agent-trace publication failed (see $LOG_DIR/hooks.log)")"
        else
            printf ' || true\n'
            printf 'publish_trace_notes || true\n'
        fi
    } > "$hooks_dir/pre-push"
    chmod +x "$hooks_dir/pre-push"
}

install_post_commit_hook
install_pre_push_hook
echo "chatter: installed direct hooks in $hooks_dir"

echo "chatter: done. Local trace observation uses post-commit;"
echo "         pre-push completes it and publishes $NOTES_REF and its trace chunks to $TRACE_REMOTE."
echo "         Try: $BIN blame --repo $repo_root <file>"
