#!/bin/bash
# Wrapper for cron: runs the full podcast pipeline
export PATH="/Users/marcellobattista/.rbenv/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/Users/marcellobattista"
export RBENV_ROOT="/Users/marcellobattista/.rbenv"
eval "$("$RBENV_ROOT/bin/rbenv" init - bash 2>/dev/null)"

cd "/Users/marcellobattista/vc-signal-tools" || exit 1
LIMIT=3 /Users/marcellobattista/.rbenv/versions/3.3.6/bin/ruby bin/run_podcast_pipeline \
  >> /Users/marcellobattista/Library/Logs/vc-signal-tools/pipeline.log 2>&1