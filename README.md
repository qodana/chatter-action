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

## Usage

```yaml
name: chatter
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
  checks: write         # publish the detailed Chatter attribution Check
  contents: write        # publish mainline refs/notes/chatter
  pull-requests: write   # update the optional PR report

jobs:
  chatter:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: qodana/chatter-action@main # pin a commit SHA in production
```

`fetch-depth: 0` is required: mapping and blame need full history. Repositories
whose rulesets restrict non-branch refs must allow the workflow token to push
`refs/notes/*`.

## Inputs

| Input | Default | Purpose |
|---|---|---|
| `mode` | `auto` | `pr` or `mainline`; auto-selects from the event |
| `base-url` | installer default | Optional full release URL override; its archive must match install.sh checksums |
| `filter` | `rollout` | `rollout` or `wal`; selects the matching notes ref |
| `notes-ref` | derived | Optional confirmation of the filter-selected notes ref |
| `comment` | `true` | Update a sticky PR report |
| `check` | `true` | Publish the detailed `Chatter attribution` GitHub Check |
| `github-token` | `${{ github.token }}` | Token used for the optional PR report comment and Check |
| `predict` | `false` | Opt-in diagnostic preview of GitHub's temporary test merge; never published |
| `push-notes` | `true` | Push computed notes in mainline mode |
| `extensions` | empty | Comma-separated extension filter for PR reports |

## Local hook installer

`install.sh` and `uninstall.sh` are the per-repository POC hook installer. The
end-to-end workflow verifies the complete release flow: a static branch trace is
published by its real pre-push hook, this bundled action computes and pushes the
landed trace, and a fresh clone resolves it through `blame --online`.

For development:

```bash
npm ci
npm run build
npm test
```
