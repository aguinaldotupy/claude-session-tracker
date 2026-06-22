#!/usr/bin/env bash
# Run every *.test.sh in this directory; exit non-zero if any fail.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
rc=0
for f in "$DIR"/*.test.sh; do
  bash "$f" || rc=1
done
exit "$rc"
