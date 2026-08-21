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
BEGIN { open = -1; last_stop = -1; bstart = -1; active = 0; last_emit_end = 0; if (grace == "" || grace + 0 <= 0) grace = 120 }

function emit_bracket(s, e) {
  if (mode == "brackets") {
    # No engagement was ever opened (log starts with S/SF — e.g. the plugin
    # was installed mid-response): there is no bracket, and clamping -1 up to
    # last_emit_end would invent one starting at epoch 0.
    if (s < 0) return
    if (s < last_emit_end) s = last_emit_end
    if (e > s) {
      printf "%d %d\n", s, e
      last_emit_end = e
    }
  }
}

{ kind = $1; ts = $2 + 0 }
kind == "P" || kind == "T" || kind == "D" || kind == "DF" {
  if (last_stop >= 0) {
    gap = ts - last_stop
    if (gap < 0) gap = 0
    credit = (gap < grace ? gap : grace)
    active += credit
    emit_bracket(bstart, last_stop + credit)
    bstart = -1
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
    emit_bracket(bstart, last_stop + credit)
  }
  if (active < 0) active = 0
  if (mode != "brackets") printf "%d", active
}
