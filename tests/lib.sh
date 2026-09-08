# Minimal test helpers. Source from *.test.sh files.

# Pin the reading-grace to its default so tests are deterministic regardless of
# the runner's environment. Tests that need a non-default grace can re-export it.
unset SESSION_IDLE_THRESHOLD_SECONDS

# Unset harness session variables so tests run clean regardless of runner environment.
unset ANTIGRAVITY_CONVERSATION_ID CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_TRACKER_SESSION_ID

# Same reason: SOLIDTIME_* are a documented config path (the env-var mode for
# ephemeral hosts), so a developer who actually uses sync would otherwise fail
# every "sync unconfigured" / "no config" assertion in the suite. Tests that
# need them export their own.
unset SOLIDTIME_URL SOLIDTIME_TOKEN SOLIDTIME_ORG_ID SOLIDTIME_MEMBER_ID

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
