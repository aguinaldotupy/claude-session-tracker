# active-time.awk — active (working) seconds from an events.log.
#
# Event lines (whitespace-separated, time-ordered):
#   P <ts>          prompt submitted  (engagement begins)
#   T <ts> <tool>   tool started      (keeps engagement open)
#   D <ts> <tool>   tool done         (keeps engagement open)
#   DF <ts> <tool>  tool failed       (keeps engagement open; counts like D)
#   S <ts>          Claude stopped    (engagement ends; reading tail begins)
#   SF <ts>         turn failed (API)  (engagement ends; counts like S)
#
# Pass with -v:
#   grace  reading-tail cap in seconds (credited after a Stop before the next
#          engagement is treated as idle)
#   t_end  terminal epoch — `now` for a live session, `end_ts` at SessionEnd
#   mode   output format: "scalar" (default) or "brackets" (start/end pairs per
#          engagement bracket, one pair per line)
#
# Prints active seconds (integer, scalar mode) or start/end pairs (brackets mode).
BEGIN { open = -1; last_stop = -1; bstart = -1; bstop = -1; active = 0; last_emit_end = 0; if (grace == "" || grace + 0 <= 0) grace = 120 }

function emit_bracket(s, e) {
  if (mode == "brackets") {
    # No engagement was ever opened (log starts with S/SF — the plugin was
    # installed mid-response, or reset-session truncated the log mid-turn).
    # The scalar still credits the reading grace after that orphan stop, so the
    # bracket must exist too or the two disagree; anchor it at the stop itself,
    # never at -1 (which would clamp to epoch 0 and post a 55-year entry).
    if (s < 0) s = bstop
    if (s < 0) return
    if (s < last_emit_end) s = last_emit_end
    if (e > s) {
      printf "%d %d\n", s, e
      last_emit_end = e
    }
  }
}

{ kind = $1; ts = $2 + 0 }
# A line whose timestamp is missing or non-numeric yields ts 0 — a truncated
# append, or a hook that ran without `date` on PATH. Both accountings must drop
# it: scalar would open an engagement at the epoch (a 55-year "active" span the
# SessionEnd clamp then hides), and brackets mode would post that span verbatim
# as a Solidtime time entry, which nothing clamps.
ts <= 0 { next }
kind == "P" || kind == "T" || kind == "D" || kind == "DF" {
  if (last_stop >= 0) {
    gap = ts - last_stop
    if (gap < 0) gap = 0
    credit = (gap < grace ? gap : grace)
    active += credit
    # bstop, not last_stop: on back-to-back stops (SF then S) the engagement
    # closed at the first one, and only the grace tail after the last one is
    # credited to `active` -- ending the bracket at last_stop would bill the
    # dead span between the two stops that `active` never counted.
    emit_bracket(bstart, bstop + credit)
    bstart = -1
    bstop = -1
    last_stop = -1
  }
  if (open < 0) open = ts
  if (bstart < 0) bstart = ts
  next
}
kind == "S" || kind == "SF" {
  if (open >= 0) {
    d = ts - open
    if (d > 0) active += d
    open = -1
  }
  if (bstop < 0) bstop = ts
  last_stop = ts
  next
}
END {
  if (open >= 0) {
    d = t_end - open
    if (d > 0) active += d
    emit_bracket(bstart, t_end)
  } else if (last_stop >= 0) {
    gap = t_end - last_stop
    if (gap < 0) gap = 0
    credit = (gap < grace ? gap : grace)
    active += credit
    emit_bracket(bstart, bstop + credit)
  }
  if (active < 0) active = 0
  if (mode != "brackets") printf "%d", active
}
