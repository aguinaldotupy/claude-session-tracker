# active-time.awk — active (working) seconds from an events.log.
#
# Event lines (whitespace-separated, time-ordered):
#   P <ts>          prompt submitted  (engagement begins)
#   T <ts> <tool>   tool started      (keeps engagement open)
#   D <ts> <tool>   tool done         (keeps engagement open)
#   S <ts>          Claude stopped    (engagement ends; reading tail begins)
#
# Pass with -v:
#   grace  reading-tail cap in seconds (credited after a Stop before the next
#          engagement is treated as idle)
#   t_end  terminal epoch — `now` for a live session, `end_ts` at SessionEnd
#
# Prints active seconds (integer) to stdout.
BEGIN { open = -1; last_stop = -1; active = 0 }
{ kind = $1; ts = $2 + 0 }
kind == "P" || kind == "T" || kind == "D" {
  if (last_stop >= 0) {
    gap = ts - last_stop
    if (gap < 0) gap = 0
    active += (gap < grace ? gap : grace)
    last_stop = -1
  }
  if (open < 0) open = ts
  next
}
kind == "S" {
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
  } else if (last_stop >= 0) {
    gap = t_end - last_stop
    if (gap < 0) gap = 0
    active += (gap < grace ? gap : grace)
  }
  if (active < 0) active = 0
  printf "%d", active
}
