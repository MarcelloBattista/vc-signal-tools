#!/bin/bash
export PATH="/Users/marcellobattista/.rbenv/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export HOME="/Users/marcellobattista"
export RBENV_ROOT="/Users/marcellobattista/.rbenv"
eval "$("$RBENV_ROOT/bin/rbenv" init - bash 2>/dev/null || rbenv init - bash 2>/dev/null)"
cd "/Users/marcellobattista/vc-signal-tools" || exit 1
echo "[Wrapper] Starting at $(date)" >> /Users/marcellobattista/Library/Logs/vc-signal-tools/wrapper_debug.log 2>&1
exec /Users/marcellobattista/.rbenv/versions/3.3.6/bin/ruby bin/scheduler