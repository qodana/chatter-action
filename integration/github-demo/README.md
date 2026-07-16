# Manual GitHub demo release checks

These scripts exercise the real private
[`qodana/chatter-demo`](https://github.com/qodana/chatter-demo) repository using
this Action's root-level [`install.sh`](../../install.sh). They are deliberately
manual: merge scenarios create and merge real pull requests and leave unique
fixture files on `main` as inspection evidence.

The demo workflow must already use the action revision under test. By default
the scripts require `qodana/chatter-action@update`; set `ACTION_REF` to an
immutable commit SHA after a release PR is merged.

The scenarios cover:

- `single-commit.sh` — install real hooks, publish one trace note through
  `pre-push`, then verify a fresh clone obtains agent and model through
  `blame --online --json`.
- `multi-agent-branch.sh` — Codex, Junie, and Claude commits plus a human-only
  control; every fresh consumer gets the correct provider/model while the
  manual file remains unattributed.
- `merge-strategy.sh squash|rebase|merge` — the same three-agent history is
  merged by GitHub; the closed-PR action must report the corresponding
  `SQUASH_VIA_PR`, `REBASE_MERGE`, or `MERGE_PARENTS` mapping, and fresh
  consumers fetch the post-merge note only through `blame --online --json`.
- `all.sh` — runs the complete matrix sequentially.

## Run

`gh auth login` needs access to the private demo repository. These tests create
and merge real demo pull requests, so they are not part of the regular CI job.

```bash
./integration/github-demo/single-commit.sh
./integration/github-demo/multi-agent-branch.sh
./integration/github-demo/merge-strategy.sh squash
./integration/github-demo/merge-strategy.sh rebase
./integration/github-demo/merge-strategy.sh merge

# Entire matrix against the candidate branch:
ACTION_REF=update ./integration/github-demo/all.sh

# After merge, verify the immutable production pin:
ACTION_REF=<action-commit-sha> ./integration/github-demo/all.sh
```

Each run uses a unique `manual/chatter-*` branch and
`docs/chatter-demo/manual-integration/<run-id>/` directory. Branch-only
scenarios delete their remote branch on success; merged-PR scenarios
intentionally retain their files on `main`. Set `KEEP_ARTIFACTS=true` to retain
local logs/clones after a successful run, or `KEEP_REMOTE_BRANCHES=true` to
retain a branch-only scenario's remote branch for inspection.
