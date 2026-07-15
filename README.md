# Chatter GitHub Action

This composite action carries AI attribution from developer-published Chatter
trace notes into pull requests and landed commits.

- On an open pull request it reports factual attribution from the real branch
  notes, with an optional prediction for GitHub's test-merge commit.
- After a squash or rebase merge it maps the authored commits to the landed
  commit, runs `chatter compute`, and publishes the resulting trace note.

The action is pinned to Chatter CDN build `37-26e21a` (`v0.0.28` line). That
release stores a single `chatter:gzip:` note in `refs/notes/chatter` (or
`refs/notes/wal-chatter` for `filter: wal`), and supports `blame --online`.

## Usage

```yaml
name: chatter
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]

permissions:
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
| `chatter-version` | `37-26e21a` | checksum-pinned Chatter CDN build |
| `base-url` | JetBrains CDN | CDN mirror override; checksum still applies |
| `filter` | `rollout` | `rollout` or `wal`; selects the matching notes ref |
| `notes-ref` | derived | Optional confirmation of the filter-selected notes ref |
| `comment` | `true` | Update a sticky PR report |
| `predict` | `true` | Include an explicitly labeled test-merge prediction |
| `push-notes` | `true` | Push computed notes in mainline mode |
| `extensions` | empty | Comma-separated extension filter for PR reports |

## Installer scripts

`install.sh` and `uninstall.sh` are the accompanying per-repository POC hook
installer. The end-to-end workflow verifies the full path: a static branch trace
is published by its real pre-push hook, this action computes and pushes the
landed trace, and a fresh clone resolves it through `blame --online`.

Run the same integration check locally with:

```bash
bash test/run-tests.sh
```
