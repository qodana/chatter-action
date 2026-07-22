# Chatter GitHub Action

This is a bundled `node20` GitHub Action for carrying Chatter attribution from
developer-published notes into pull requests and landed commits.

- On an open pull request it reports factual attribution from real branch notes.
  An opt-in diagnostic preview can additionally evaluate GitHub's temporary
  test-merge commit; it is disabled by default and never published.
- The same factual report is posted both as a sticky PR comment and as a
  `Chatter attribution` GitHub Check by default.
- After a squash or rebase merge it maps authored commits to landed commits, runs
  `chatter compute`, and publishes the resulting trace note.

The native Chatter binary is installed through root-level `install.sh --bin-only`.
That script is the only source of the CDN release URL and SHA-256 checksums, shared
with the local hook installer; the action has no separate version pin to maintain.
When a hook has published a direct JSON trace note, the action normalizes it locally for
the pinned binary. In mainline mode with `push-notes: true`, it publishes that equivalent
gzip representation before `compute`, whose CLI fetches the remote notes ref itself.

## Setup

### 1. Install Local Git Hooks

```bash
cd /path/to/your/repo
curl -fsSL https://raw.githubusercontent.com/qodana/chatter-action/main/install.sh | sh
```

This installs:
- `post-commit` hook - tracks commits locally
- `pre-push` hook - publishes trace notes to `refs/notes/chatter`
- Chatter binary to `~/.chatter/bin/chatter`

### 2. Create GitHub Workflow

Create `.github/workflows/chatter.yml`:

```yaml
name: chatter
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
  checks: write         # publish the detailed Chatter attribution Check
  contents: write       # publish mainline refs/notes/chatter
  pull-requests: write  # update the optional PR report

jobs:
  chatter:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # full history required for mapping and blame
      - uses: qodana/chatter-action@main # pin a commit SHA in production
```

> **⚠️ Requirements:**
>
> - `fetch-depth: 0` is required - mapping and blame need full history
> - Repositories whose rulesets restrict non-branch refs must allow the workflow token to push `refs/notes/*`
> - Requires permissions: `checks: write`, `contents: write`, `pull-requests: write`

### 3. Configure Repository Settings

Ensure `refs/notes/*` is not blocked in GitHub **Settings → Branches → Rulesets**.

## Configuration

You can customize the action behavior with various inputs:

```yaml
- uses: qodana/chatter-action@main
  with:
    mode: auto              # auto | pr | mainline
    filter: rollout         # rollout | wal
    comment: true           # Post PR comment
    check: true             # Create Check run
    push-notes: true        # Push computed notes
    extensions: ''          # Filter by file extensions (e.g., 'js,ts,md')
    predict: false          # Preview test-merge attribution
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `mode` | `auto` | **auto** - detects mode from event<br>**pr** - triggers on pull_request events (opened, synchronize, reopened). Fetches `refs/notes/chatter`, analyzes all commits in PR branch (max 200), runs chatter blame on changed files, publishes report as PR comment and Check run<br>**mainline** - triggers on pull_request.closed.merged or push to main. Maps branch commits to landed commits, runs chatter compute to create trace notes, pushes notes to `refs/notes/chatter` |
| `filter` | `rollout` | Notes namespace: **rollout** uses `refs/notes/chatter`, **wal** uses `refs/notes/wal-chatter`. Use default unless you have specific Chatter infrastructure setup |
| `comment` | `true` | Show PR comment with attribution details |
| `check` | `true` | Create GitHub Check run with attribution details |
| `push-notes` | `true` | Push computed trace notes to origin in mainline mode. When PR is merged using squash or rebase, new commits with different SHAs are created in main branch. Set to false only for testing or dry-run scenarios - otherwise notes for merged commits won't be available in the repository |
| `extensions` | empty | Comma-separated file extensions to analyze (empty = all files). Example: `'js,ts,md'` |
| `github-token` | `${{ github.token }}` | GitHub token for API operations. Uses workflow's default token automatically. Required for posting PR comments (pull-requests: write), creating Check runs (checks: write), and pushing notes (contents: write). Only specify custom token if you need different permissions or cross-repository access |
| `predict` | `false` | Preview attribution on GitHub's temporary test-merge commit before actual merge. Shows additional "Preview of GitHub's test merge" section in PR report. This is diagnostic only - predictions are never published and may differ from actual merge results |
| `base-url` | installer default | Optional full release URL override; its archive must match install.sh checksums |
| `notes-ref` | derived | Optional confirmation of the filter-selected notes ref |

## Supported Commit Mappings

When PR is merged to main, commit SHA hashes often change (squash, rebase), but trace notes remain attached to original branch commit hashes. Chatter needs to find which landed commits in main correspond to which branch commits, so it can create notes for the new SHAs. The action tries different mapping strategies in priority order:

1. **MERGE_PARENTS** - Regular merge commit (2+ parents), skipped because branch commits remain in main's history with their original SHA hashes and existing notes - no new commits created, no compute needed
2. **REBASE_MERGE** - Rebase merge where commits are rewritten with new SHA hashes but same content. Maps branch commits to landed commits 1:1 by comparing patch-id (hash of diff content)
3. **SQUASH_VIA_PR** - Squash merge where all branch commits are combined into a single landed commit. All branch commits map to one new commit in main
4. **CHERRY_TRAILER** - Cherry-pick detected from "cherry picked from commit" trailer in commit message. Action extracts original commit SHA from message and maps it to the new cherry-picked commit
5. **PATCH_ID** - Single commit PR where landed commit has different SHA but identical diff content. Maps by comparing patch-id (hash of changes, ignoring commit metadata)
6. **IDENTITY** - Author email equals committer email, indicating manual commit without AI assistance. Skipped because no AI attribution expected - no notes to map, no compute needed
7. **UNKNOWN** - Cannot determine, warning issued, skipped

## Limits

- Max 200 commits per PR branch
- Max 200 KB per encoded trace note and 2 MB per decoded trace note
- Max 65,000 characters in Check run summary
- Only first 100 PR comments checked for sticky update
- Fork PRs: Check runs and comments not published (security: headRepo must equal baseRepo)

## Known Limitations

### Does Not Work With

- Shallow clones (fetch-depth less than full history)
- PRs from forks (Check runs and comments not published)
- Repositories blocking `refs/notes/*` refs
- Repositories without hooks installed (no trace data)

### Hook Installer Limitations

1. macOS and Linux only (no Windows support)
2. Does not work with `core.hooksPath` (only default `.git/hooks/` directory)
3. Cannot overwrite existing hooks (post-commit and pre-push slots must be empty)
4. Only 'origin' remote supported

### AI Session Tracking

Chatter tracks AI sessions only when the AI agent is launched from within the repository directory. If you start the agent in one directory and ask it to modify files in another repository, the hook will not be able to capture the AI session context correctly.

## Local Usage

Test attribution locally without opening PR using the chatter binary at `~/.chatter/bin/chatter`. Commands include `blame` for analyzing files, with options for JSON output. Manage notes manually using git notes commands with `--ref refs/notes/chatter`, including list, show, push, and fetch operations.

## Uninstall

Remove hooks using the uninstall script:

```bash
curl -fsSL https://raw.githubusercontent.com/qodana/chatter-action/main/uninstall.sh | sh
```

Or manually delete:
- `.git/hooks/post-commit`
- `.git/hooks/pre-push`
- `~/.chatter/` directory

### Delete Notes (Optional, Permanent)

```bash
# Delete local notes
git update-ref -d refs/notes/chatter

# Delete remote notes
git push origin --delete refs/notes/chatter
```

## Development

`install.sh` and `uninstall.sh` are the per-repository POC hook installer. The end-to-end workflow verifies the complete release flow: a static branch trace is published by its real pre-push hook, this bundled action computes and pushes the landed trace, and a fresh clone resolves it through `blame --online`.

For local development:

```bash
npm ci
npm run build
npm test
```
