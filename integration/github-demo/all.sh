#!/usr/bin/env bash
# Run every manual qodana/chatter-demo release scenario in sequence.

set -euo pipefail

DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
"$DIR/single-commit.sh"
"$DIR/multi-agent-branch.sh"
"$DIR/merge-strategy.sh" squash
"$DIR/merge-strategy.sh" rebase
"$DIR/merge-strategy.sh" merge
