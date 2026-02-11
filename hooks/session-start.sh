#!/usr/bin/env bash
set -euo pipefail

echo "$(date +%s)" > "/tmp/claude-session-$PPID"
