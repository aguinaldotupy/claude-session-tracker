# Minimal test helpers. Source from *.test.sh files.

# Pin the reading-grace to its default so tests are deterministic regardless of
# the runner's environment. Tests that need a non-default grace can re-export it.
unset SESSION_IDLE_THRESHOLD_SECONDS

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
  # assert_eq <description> <expected> <actual>
  TESTS_RUN=$((TESTS_RUN + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
  fi
}

finish() {
  printf '\n%s: %d run, %d failed\n' "${0##*/}" "$TESTS_RUN" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
