#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib.sh"
AWK="$DIR/../hooks/lib/active-time.awk"

active() { awk -v grace="$1" -v t_end="$2" -f "$AWK"; }

# Empty log → 0
assert_eq "empty log is zero" "0" "$(printf '' | active 120 1000)"

# One prompt→stop interval of 60s
assert_eq "one working interval" "60" "$(printf 'P 1000\nS 1060\n' | active 120 1060)"

# Parked after stop: only grace (120) credited on top of the 60s of work
assert_eq "parked credits only grace" "180" "$(printf 'P 1000\nS 1060\n' | active 120 5000)"

# Short reading gap (<grace) fully credited: 60 + 40 + 60
assert_eq "short reading gap credited" "160" "$(printf 'P 1000\nS 1060\nP 1100\nS 1160\n' | active 120 1160)"

# Long reading gap capped at grace: 60 + 120 + 60
assert_eq "long gap capped at grace" "240" "$(printf 'P 1000\nS 1060\nP 1300\nS 1360\n' | active 120 1360)"

# Live mid-response: open bracket runs to t_end
assert_eq "live mid-response" "100" "$(printf 'P 1000\n' | active 120 1100)"

# Tool events hold the bracket open when Stop is missing (crash)
assert_eq "tools hold open bracket" "200" "$(printf 'P 1000\nT 1010 Read\nD 1050 Read\n' | active 120 1200)"

# Tools inside a bracket do not change the working total
assert_eq "tools inside bracket" "60" "$(printf 'P 1000\nT 1005 Edit\nD 1040 Edit\nS 1060\n' | active 120 1060)"

# Out-of-order / negative gaps are guarded: 60 + 0 + 20
assert_eq "negative gap guarded" "80" "$(printf 'P 1000\nS 1060\nP 1050\nS 1070\n' | active 120 1070)"

# grace self-defaults to 120 when not provided
assert_eq "grace self-defaults to 120" "180" "$(printf 'P 1000\nS 1060\n' | awk -v t_end=5000 -f "$AWK")"

# DF (tool failed) holds the bracket open just like D
assert_eq "DF holds open bracket" "200" "$(printf 'P 1000\nT 1010 Read\nDF 1050 Read\n' | active 120 1200)"

# DF inside a bracket does not change the working total (counts like D)
assert_eq "DF counts like D" "60" "$(printf 'P 1000\nT 1005 Bash\nDF 1040 Bash\nS 1060\n' | active 120 1060)"

# SF (turn failed on API error) closes the bracket just like S
assert_eq "SF closes like S" "60" "$(printf 'P 1000\nSF 1060\n' | active 120 1060)"

# SF then parked: only grace credited after the failed stop (60 + 120)
assert_eq "SF then parked credits grace" "180" "$(printf 'P 1000\nSF 1060\n' | active 120 5000)"

brackets() { awk -v grace="$1" -v t_end="$2" -v mode=brackets -f "$AWK" | tr '\n' ';'; }

# One interval, parked: single bracket includes the grace tail
assert_eq "brackets: parked" "1000 1180;" "$(printf 'P 1000\nS 1060\n' | brackets 120 5000)"

# Short gap: first bracket ends where the next begins
assert_eq "brackets: short gap" "1000 1100;1100 1160;" "$(printf 'P 1000\nS 1060\nP 1100\nS 1160\n' | brackets 120 1160)"

# Long gap capped: first bracket ends at stop+grace
assert_eq "brackets: capped gap" "1000 1180;1300 1360;" "$(printf 'P 1000\nS 1060\nP 1300\nS 1360\n' | brackets 120 1360)"

# Open bracket runs to t_end
assert_eq "brackets: live open" "1000 1100;" "$(printf 'P 1000\n' | brackets 120 1100)"

# Empty log: no output
assert_eq "brackets: empty" "" "$(printf '' | brackets 120 1000)"

# Sum of brackets equals scalar output on a mixed scenario
mixed='P 1000\nT 1005 Edit\nD 1040 Edit\nS 1060\nP 1300\nSF 1360\n'
scalar_out="$(printf "$mixed" | active 120 5000)"
sum_out="$(printf "$mixed" | awk -v grace=120 -v t_end=5000 -v mode=brackets -f "$AWK" | awk '{s+=$2-$1} END{printf "%d", s+0}')"
assert_eq "brackets sum equals scalar" "$scalar_out" "$sum_out"

finish
