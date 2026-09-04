#!/usr/bin/env bash
# fm-jobs.sh - the recurring-job view of this home's backlog, and the one
# command that records a job's completion.
#
# A recurring job is an ordinary backlog work item (docs/configuration.md
# "Recurring jobs" owns the convention): its title starts with `recurring: `,
# its body carries one `last-run: <YYYY-MM-DD|never>` line, and its next due
# date is its dated hold (`tasks-axi hold <id> --until <date>`). An unheld row
# is due now. A job is RUNNING when a task with a state/<id>.meta record either
# has an id that starts with the job id (fm-social-inbound-pass-2026-09-05 runs
# fm-social-inbound-daily) or names `job: <job-id>` in its backlog body.
#
# Usage:
#   fm-jobs.sh [list]
#       One line per recurring job, running first, then due (most overdue
#       first), then upcoming ordered by most recent last-run:
#         <job-id>  RUNNING as <task-id>          last-run <date|never>  <title>
#         <job-id>  DUE <date> (overdue N d)      last-run <date|never>  <title>
#         <job-id>  DUE <date>|DUE now            last-run <date|never>  <title>
#         <job-id>  due <date>                    last-run <date|never>  <title>
#         <job-id>  held (<hold-kind>)            last-run <date|never>  <title>
#       `held (<kind>)` is a job parked without a date (a captain hold, for
#       example); it is never due until that hold clears, so it sorts last.
#       Prints `no recurring jobs` when the backlog holds none. Always exits 0,
#       so the session-start digest that calls it can never be broken by it:
#       an unreadable backlog or an unavailable tasks-axi prints one explanatory
#       line instead.
#   fm-jobs.sh mark <job-id> --ran <YYYY-MM-DD> --next <YYYY-MM-DD>
#       Records one completion: rewrites the row's `last-run:` line to --ran
#       (adding it as the first body line when missing) and re-holds the row
#       until --next in one step. Refuses a job id that is not a `recurring:`
#       row, a malformed date, a manual-backend home (config/backlog-backend =
#       manual owns its file outright), and an incompatible tasks-axi. Exits 0
#       on success and 2 on refusal; a partial update is reported as such.
#
# Every read and write goes through tasks-axi (bin/fm-tasks-axi-lib.sh owns the
# compatibility verdict, bin/fm-backlog-transition-lib.sh the --file addressing),
# never through hand parsing of data/backlog.md. Each tasks-axi call costs a
# node start, so the listing is exactly two calls - the queued and in-flight
# rows with their bodies - and everything else (which rows are jobs, which
# live task runs which job) is decided from those two answers.
#
# Environment:
#   FM_HOME              operational home whose data/, state/, and config/ are read.
#   FM_DATA_OVERRIDE, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE
#                        per-directory overrides, as in the other bin scripts.
#   FM_TASKS_AXI_COMPATIBLE
#                        a caller's already-computed compatibility verdict
#                        (bin/fm-tasks-axi-lib.sh); skips the three-call probe.
#   FM_JOBS_TODAY        YYYY-MM-DD used as "today" instead of the clock
#                        (tests; a malformed value falls back to the clock).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

RECURRING_PREFIX='recurring: '
JOB_FIELDS=held,hold_until,hold_kind,body
# A decoded body keeps its line breaks as this byte so a whole row still fits
# on one line of a pipeline; body_lines turns them back into newlines.
NL=$'\036'

usage() {
  sed -n '/^# Usage:/,/^# Every read/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

date_valid() {  # <YYYY-MM-DD>
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  local m=${1:5:2} d=${1:8:2}
  m=$((10#$m)); d=$((10#$d))
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le 31 ]
}

today() {
  if [ -n "${FM_JOBS_TODAY:-}" ] && date_valid "$FM_JOBS_TODAY"; then
    printf '%s\n' "$FM_JOBS_TODAY"
  else
    date +%Y-%m-%d
  fi
}

# Days since the civil epoch for a YYYY-MM-DD, so two dates subtract to a day
# count without either platform's `date` dialect.
day_number() {  # <YYYY-MM-DD>
  awk -v d="$1" 'BEGIN {
    y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
    if (m <= 2) { y -= 1; m += 12 }
    era = int(y / 400)
    yoe = y - era * 400
    doy = int((153 * (m - 3) + 2) / 5) + dd - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    print era * 146097 + doe
  }'
}

# Split one tasks-axi TOON row into tab-separated fields. Quoted fields carry
# JSON-style escapes (\" \\ \n \t \r); an unquoted field runs to the next comma.
# A newline escape becomes the NL byte, never a real newline.
toon_row_fields() {  # <row>
  printf '%s\n' "$1" | awk -v nl="$NL" '
    {
      s = $0; sub(/^[ \t]+/, "", s)
      n = length(s); i = 1; out = ""; field = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") {
          i++
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == "\\") {
              e = substr(s, i + 1, 1)
              if (e == "n") field = field nl
              else if (e == "t") field = field "\t"
              else if (e == "r") field = field "\r"
              else field = field e
              i += 2
              continue
            }
            if (c == "\"") { i++; break }
            field = field c; i++
          }
          out = out field; field = ""
          while (i <= n && substr(s, i, 1) != ",") i++
          if (i <= n) { out = out "\t"; i++ }
          continue
        }
        if (c == ",") { out = out field "\t"; field = ""; i++; continue }
        field = field c; i++
      }
      out = out field
      print out
    }'
}

body_lines() {  # <body with NL bytes>
  printf '%s\n' "$1" | tr "$NL" '\n'
}

# Every row of one tasks-axi state listing as
# id<TAB>title<TAB>held<TAB>hold_until<TAB>hold_kind<TAB>body, one per line.
# The header row gives the column order, so the fake and real boundaries need
# not agree on it. On failure it prints the one captain-facing unavailable line
# instead and returns 1, so a caller capturing stdout can relay it verbatim.
rows_in_state() {  # <resolved-data-dir> <state>
  local data=$1 state=$2 out line header cols fields
  out=$(fm_backlog_row_list "$data" --state "$state" --fields "$JOB_FIELDS") || {
    printf 'recurring jobs unavailable: tasks-axi list --state %s failed: %s\n' "$state" "$(printf '%s\n' "$out" | head -1)"
    return 1
  }
  if printf '%s\n' "$out" | grep -q '^count: 0$'; then
    return 0
  fi
  header=$(printf '%s\n' "$out" | sed -n 's/^tasks\[[0-9]*\]{\(.*\)}:$/\1/p' | head -1)
  [ -n "$header" ] || {
    printf 'recurring jobs unavailable: tasks-axi list --state %s printed no task table\n' "$state"
    return 1
  }
  cols=$(printf '%s\n' "$header" | tr ',' '\n' | awk '
    $0 == "id" { id = NR } $0 == "title" { title = NR } $0 == "held" { held = NR }
    $0 == "hold_until" { until = NR } $0 == "hold_kind" { kind = NR } $0 == "body" { body = NR }
    END { printf "%d %d %d %d %d %d\n", id, title, held, until, kind, body }')
  printf '%s\n' "$out" | awk '
    /^tasks\[[0-9]*\]\{/ { intable = 1; next }
    /^help\[/ { intable = 0 }
    intable && /^  / { print }
  ' | while IFS= read -r line; do
    fields=$(toon_row_fields "$line")
    printf '%s\n' "$fields" | awk -F'\t' -v spec="$cols" '
      BEGIN { split(spec, c, " ") }
      {
        held = (c[3] > 0) ? $(c[3]) : "no"
        until = (c[4] > 0) ? $(c[4]) : "-"
        kind = (c[5] > 0) ? $(c[5]) : "-"
        body = (c[6] > 0) ? $(c[6]) : ""
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", $(c[1]), $(c[2]), held, until, kind, body
      }'
  done
}

# Body of one backlog row through `tasks-axi show --full`, NL-encoded.
row_body() {  # <resolved-data-dir> <id>
  local data=$1 id=$2 out line
  out=$(fm_backlog_row_show "$data" "$id" --full) || return 1
  line=$(printf '%s\n' "$out" | sed -n 's/^  body: //p' | head -1)
  [ -n "$line" ] || return 1
  toon_row_fields "$line"
}

row_title() {  # <resolved-data-dir> <id>
  local data=$1 id=$2 out line
  out=$(fm_backlog_row_show "$data" "$id") || return 1
  line=$(printf '%s\n' "$out" | sed -n 's/^  title: //p' | head -1)
  toon_row_fields "$line"
}

body_last_run() {  # <body>
  body_lines "$1" | sed -n 's/^last-run:[[:space:]]*//p' | head -1
}

body_job() {  # <body>
  body_lines "$1" | sed -n 's/^job:[[:space:]]*//p' | head -1
}

# Print "<job-id>\t<task-id>" for every live task (state/<id>.meta) that runs
# a recurring job, by id prefix or by a `job:` body line in its own row.
running_tasks() {  # <all rows> <job-ids (one per line)>
  local rows=$1 jobs=$2 meta id job body named
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    while IFS= read -r job; do
      [ -n "$job" ] || continue
      case "$id" in
        "$job"|"$job"-*) printf '%s\t%s\n' "$job" "$id"; continue 2 ;;
      esac
    done <<< "$jobs"
    body=$(printf '%s\n' "$rows" | awk -F'\t' -v t="$id" '$1 == t { print $6; exit }')
    [ -n "$body" ] || continue
    named=$(body_job "$body")
    [ -n "$named" ] || continue
    while IFS= read -r job; do
      [ "$job" = "$named" ] || continue
      printf '%s\t%s\n' "$job" "$id"
      break
    done <<< "$jobs"
  done
}

resolve_data() {
  if [ ! -d "$DATA" ]; then
    printf 'recurring jobs unavailable: data directory missing at %s\n' "$DATA"
    return 1
  fi
  RESOLVED_DATA=$(fm_backlog_data_absolute "$DATA") || {
    printf 'recurring jobs unavailable: %s\n' "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved}"
    return 1
  }
  if [ ! -f "$RESOLVED_DATA/backlog.md" ]; then
    printf 'no recurring jobs (this home keeps no backlog at %s/backlog.md)\n' "$RESOLVED_DATA"
    return 1
  fi
  if ! fm_tasks_axi_compatible; then
    printf 'recurring jobs unavailable: compatible tasks-axi (%s or newer) not on PATH\n' "$FM_TASKS_AXI_MIN"
    return 1
  fi
  return 0
}

cmd_list() {
  local today rows jobs running id title held until kind body last \
    rank key state task tnum unum overdue
  resolve_data || return 0
  today=$(today)
  tnum=$(day_number "$today")
  rows=$(rows_in_state "$RESOLVED_DATA" queued && rows_in_state "$RESOLVED_DATA" in_flight) || {
    printf '%s\n' "$rows" | grep '^recurring jobs unavailable' | head -1
    return 0
  }
  jobs=$(printf '%s\n' "$rows" | awk -F'\t' -v prefix="$RECURRING_PREFIX" 'index($2, prefix) == 1 { print $1 }')
  if [ -z "$jobs" ]; then
    printf 'no recurring jobs\n'
    return 0
  fi
  running=$(running_tasks "$rows" "$jobs")
  # rank: 0 running, 1 due, 2 upcoming, 3 undated hold. key orders within a
  # rank: due date ascending for due rows (an unheld row counts as due today),
  # last-run descending (via a negated day number) for upcoming rows.
  printf '%s\n' "$rows" | while IFS=$'\t' read -r id title held until kind body; do
    [ -n "$id" ] || continue
    case "$title" in "$RECURRING_PREFIX"*) ;; *) continue ;; esac
    last=$(body_last_run "$body")
    [ -n "$last" ] || last=never
    task=$(printf '%s\n' "$running" | awk -F'\t' -v j="$id" '$1 == j { print $2; exit }')
    if [ -n "$task" ]; then
      rank=0; key=0; state="RUNNING as $task"
    elif date_valid "$until"; then
      # tasks-axi reports a dated hold as no longer held once its date passes,
      # so the date itself, not the held flag, decides due versus upcoming.
      unum=$(day_number "$until")
      if [ "$unum" -lt "$tnum" ]; then
        overdue=$((tnum - unum))
        rank=1; key=$unum; state="DUE $until (overdue $overdue d)"
      elif [ "$unum" -eq "$tnum" ]; then
        rank=1; key=$unum; state="DUE $until"
      else
        rank=2
        if date_valid "$last"; then key=$((0 - $(day_number "$last"))); else key=1; fi
        state="due $until"
      fi
    elif [ "$held" = yes ]; then
      rank=3; key=0; state="held (${kind:-unknown})"
    else
      rank=1; key=$tnum; state="DUE now"
    fi
    printf '%s\t%s\t%s\t%s  %s  last-run %s  %s\n' "$rank" "$key" "$id" "$id" "$state" "$last" "$title"
  done | sort -t $'\t' -k1,1n -k2,2n -k3,3 | cut -f4-
}

cmd_mark() {
  local job='' ran='' next='' title body new_body tmp out rc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ran) [ "$#" -gt 1 ] || { printf 'error: --ran needs a date\n' >&2; return 2; }; ran=$2; shift 2 ;;
      --next) [ "$#" -gt 1 ] || { printf 'error: --next needs a date\n' >&2; return 2; }; next=$2; shift 2 ;;
      -h|--help) usage; return 0 ;;
      -*) printf 'error: unknown flag %s\n' "$1" >&2; return 2 ;;
      *) [ -z "$job" ] || { printf 'error: one job id only\n' >&2; return 2; }; job=$1; shift ;;
    esac
  done
  [ -n "$job" ] || { printf 'error: mark needs a job id\n' >&2; return 2; }
  date_valid "$ran" || { printf 'error: --ran must be YYYY-MM-DD, got %s\n' "${ran:-nothing}" >&2; return 2; }
  date_valid "$next" || { printf 'error: --next must be YYYY-MM-DD, got %s\n' "${next:-nothing}" >&2; return 2; }
  if fm_backlog_backend_manual "$CONFIG"; then
    printf 'error: config/backlog-backend selects manual editing; set last-run: %s and (hold-until: %s) on %s by hand\n' "$ran" "$next" "$job" >&2
    return 2
  fi
  if ! resolve_data >&2; then
    return 2
  fi
  title=$(row_title "$RESOLVED_DATA" "$job") || {
    printf 'error: no backlog row %s\n' "$job" >&2
    return 2
  }
  case "$title" in
    "$RECURRING_PREFIX"*) ;;
    *) printf 'error: %s is not a recurring job (title must start with "%s"): %s\n' "$job" "$RECURRING_PREFIX" "$title" >&2; return 2 ;;
  esac
  body=$(row_body "$RESOLVED_DATA" "$job" 2>/dev/null) || body=
  body=$(body_lines "$body")
  if printf '%s\n' "$body" | grep -q '^last-run:'; then
    new_body=$(printf '%s\n' "$body" | awk -v ran="$ran" '
      !done && /^last-run:/ { print "last-run: " ran; done = 1; next }
      { print }')
  elif [ -n "$body" ]; then
    new_body=$(printf 'last-run: %s\n%s\n' "$ran" "$body")
  else
    new_body="last-run: $ran"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-jobs-body.XXXXXX") || { printf 'error: cannot create a temp file\n' >&2; return 2; }
  printf '%s\n' "$new_body" > "$tmp"
  out=$(row_mutate "$RESOLVED_DATA" update "$job" --body-file "$tmp")
  rc=$?
  rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then
    printf 'error: last-run update failed, row untouched: %s\n' "$(printf '%s\n' "$out" | head -1)" >&2
    return 2
  fi
  out=$(row_mutate "$RESOLVED_DATA" hold "$job" --reason "next run" --until "$next" --kind future)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'error: last-run is now %s but the re-hold failed, so %s reads as due now: %s\n' "$ran" "$job" "$(printf '%s\n' "$out" | head -1)" >&2
    return 2
  fi
  printf 'ok: %s last-run %s, next due %s\n' "$job" "$ran" "$next"
}

# One tasks-axi mutation from the backlog root with the same --file addressing
# fm_backlog_row_show uses; stdout and stderr are returned together.
row_mutate() {  # <resolved-data-dir> <verb> <id> [flag...]
  local data=$1 verb=$2 id=$3 file root
  shift 3
  file=$(fm_backlog_file "$data") || return 1
  root=$(fm_backlog_root "$data") || return 1
  if [ "$(fm_tasks_axi_backend "$root")" = markdown ]; then
    (cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" "$@" --file "$file" 2>&1)
  else
    (cd "$root" 2>/dev/null && tasks-axi "$verb" "$id" "$@" 2>&1)
  fi
}

case "${1:-list}" in
  list) cmd_list ;;
  mark) shift; cmd_mark "$@" ;;
  -h|--help) usage ;;
  *) printf 'error: unknown subcommand %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
