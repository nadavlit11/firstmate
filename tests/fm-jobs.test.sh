#!/usr/bin/env bash
# tests/fm-jobs.test.sh - behavior tests for bin/fm-jobs.sh, the recurring-job
# view of the backlog and its one-step completion record.
#
# Every case drives the real tasks-axi CLI against a real backlog file, because
# the script's whole contract is "never parse backlog.md by hand where tasks-axi
# can answer": a fake would only confirm the column order written into the fake.
#
# Coverage:
#   - list: running (by id prefix and by a `job:` body line) sorts first, then
#     due (most overdue first, `DUE now` for an unheld row), then upcoming by
#     most recent last-run, then an undated hold; non-recurring rows and rows
#     with a running task but no live record are never RUNNING
#   - list: a title with quotes and commas and a multi-line body survive the
#     tasks-axi quoting; a body without last-run reads as never
#   - list: exit 0 and one explanatory line for no jobs, no backlog, no
#     tasks-axi
#   - mark: rewrites last-run and re-holds in one step, adds a missing last-run
#     line, keeps the rest of the body, and refuses a non-recurring row, an
#     unknown row, a malformed date, and a manual-backend home
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# tasks-axi resolves its backend from TASKS_AXI_BACKEND before .tasks.toml.
unset TASKS_AXI_BACKEND || :

JOBS="$ROOT/bin/fm-jobs.sh"
TMP_ROOT=$(fm_test_tmproot fm-jobs)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

command -v tasks-axi >/dev/null 2>&1 || {
  printf 'ok - skipped (tasks-axi is not installed; fm-jobs.sh reads the backlog only through it)\n'
  exit 0
}

# make_home <name>: a home with a real, empty backlog and the tracked
# .tasks.toml shape so tasks-axi addresses data/backlog.md the way firstmate's
# own home does. Echoes the home path.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## Queued' '' '## In flight' '' '## Done' \
    > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

axi() {  # <home> <verb> [args...]
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@" --file data/backlog.md >/dev/null 2>&1) \
    || fail "fixture: tasks-axi $* failed in $home"
}

add_job() {  # <home> <id> <title> <body>
  if [ -n "$4" ]; then
    axi "$1" add "$2" "$3" --body "$4"
  else
    axi "$1" add "$2" "$3"
  fi
}

jobs() {  # <home> <today> [args...]
  local home=$1 today=$2
  shift 2
  FM_HOME="$home" FM_JOBS_TODAY="$today" "$JOBS" "$@" 2>&1
}

body_of() {  # <home> <id>
  (cd "$1" && tasks-axi show "$2" --full --file data/backlog.md 2>/dev/null | sed -n 's/^  body: //p')
}

hold_until_of() {  # <home> <id>
  (cd "$1" && tasks-axi show "$2" --file data/backlog.md 2>/dev/null | sed -n 's/^  hold_until: //p')
}

# --- list ---------------------------------------------------------------------

test_list_orders_running_due_upcoming_and_held() {
  local home out
  home=$(make_home order)
  add_job "$home" fm-inbound-daily 'recurring: meta DMs and comments' $'last-run: 2026-09-03\nnotes'
  axi "$home" hold fm-inbound-daily --reason 'next run' --until 2026-09-05 --kind future
  add_job "$home" fm-linkedin-posts 'recurring: linkedin posts' 'last-run: 2026-08-30'
  axi "$home" hold fm-linkedin-posts --reason 'next run' --until 2026-09-01 --kind future
  add_job "$home" fm-seo-weekly 'recurring: SEO weekly' 'last-run: 2026-08-28'
  axi "$home" hold fm-seo-weekly --reason 'next run' --until 2026-09-04 --kind future
  add_job "$home" fm-weekly-report 'recurring: weekly report' 'last-run: never'
  add_job "$home" fm-alerts-daily 'recurring: sentry and gcp alerts' 'last-run: 2026-09-02'
  axi "$home" hold fm-alerts-daily --reason 'next run' --until 2026-09-06 --kind future
  add_job "$home" fm-meta-posts 'recurring: meta posts' 'last-run: 2026-09-01'
  axi "$home" hold fm-meta-posts --reason 'next run' --until 2026-09-10 --kind future
  add_job "$home" fm-parked 'recurring: parked job' 'last-run: 2026-07-01'
  axi "$home" hold fm-parked --reason 'captain decision pending' --kind captain
  add_job "$home" other-work 'unrelated ship task' 'job: fm-weekly-report'
  # A live task by id prefix, and one by body line.
  add_job "$home" fm-inbound-daily-pass-2026-09-04 'inbound pass' ''
  axi "$home" start fm-inbound-daily-pass-2026-09-04
  fm_write_meta "$home/state/fm-inbound-daily-pass-2026-09-04.meta" window=fm-x:1 kind=ship
  add_job "$home" seo-run-42 'SEO measurement' $'job: fm-seo-weekly\nmore'
  axi "$home" start seo-run-42
  fm_write_meta "$home/state/seo-run-42.meta" window=fm-x:2 kind=scout
  # A task that names a job but has no live record is not running.
  add_job "$home" fm-meta-posts-pass-2026-08-20 'old meta pass' ''

  out=$(jobs "$home" 2026-09-04)
  expected='fm-inbound-daily  RUNNING as fm-inbound-daily-pass-2026-09-04  last-run 2026-09-03  recurring: meta DMs and comments
fm-seo-weekly  RUNNING as seo-run-42  last-run 2026-08-28  recurring: SEO weekly
fm-linkedin-posts  DUE 2026-09-01 (overdue 3 d)  last-run 2026-08-30  recurring: linkedin posts
fm-weekly-report  DUE now  last-run never  recurring: weekly report
fm-alerts-daily  due 2026-09-06  last-run 2026-09-02  recurring: sentry and gcp alerts
fm-meta-posts  due 2026-09-10  last-run 2026-09-01  recurring: meta posts
fm-parked  held (captain)  last-run 2026-07-01  recurring: parked job'
  [ "$out" = "$expected" ] || fail "list order or shape is wrong:"$'\n'"--- got ---"$'\n'"$out"$'\n'"--- want ---"$'\n'"$expected"
  assert_not_contains "$out" other-work "a non-recurring row leaked into the job list"
  pass "list: running first, then due with the most overdue first, then upcoming by last-run, then undated holds"
}

test_list_survives_quoting_and_missing_last_run() {
  local home out
  home=$(make_home quoting)
  add_job "$home" fm-quoted 'recurring: has "quotes", commas' $'last-run: 2026-09-01\nsay "hi" back\\slash, comma'
  add_job "$home" fm-bare 'recurring: body without last-run' 'just a note'
  add_job "$home" fm-empty 'recurring: empty body' ''
  out=$(jobs "$home" 2026-09-04)
  assert_contains "$out" 'fm-quoted  DUE now  last-run 2026-09-01  recurring: has "quotes", commas' \
    "a quoted title or body broke the row"
  assert_contains "$out" 'fm-bare  DUE now  last-run never  recurring: body without last-run' \
    "a body without last-run should read as never"
  assert_contains "$out" 'fm-empty  DUE now  last-run never  recurring: empty body' \
    "an empty body should read as never"
  [ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] || fail "expected exactly 3 lines:"$'\n'"$out"
  pass "list: tasks-axi quoting and a missing last-run line are handled"
}

test_list_is_never_fatal() {
  local home out rc
  home=$(make_home empty)
  out=$(jobs "$home" 2026-09-04); rc=$?
  expect_code 0 "$rc" "empty backlog"
  [ "$out" = 'no recurring jobs' ] || fail "empty backlog should print 'no recurring jobs', got: $out"

  add_job "$home" plain 'no jobs here' ''
  out=$(jobs "$home" 2026-09-04); rc=$?
  expect_code 0 "$rc" "backlog without recurring rows"
  [ "$out" = 'no recurring jobs' ] || fail "backlog without recurring rows should print 'no recurring jobs', got: $out"

  rm "$home/data/backlog.md"
  out=$(jobs "$home" 2026-09-04); rc=$?
  expect_code 0 "$rc" "missing backlog"
  assert_contains "$out" 'no recurring jobs (this home keeps no backlog at' "a missing backlog should explain itself"

  home=$(make_home no-axi)
  add_job "$home" fm-job 'recurring: something' 'last-run: never'
  out=$(PATH="$BASE_PATH" FM_HOME="$home" "$JOBS" 2>&1); rc=$?
  expect_code 0 "$rc" "tasks-axi absent"
  assert_contains "$out" 'recurring jobs unavailable: compatible tasks-axi' "an absent tasks-axi should be named, not crash"
  pass "list: no jobs, no backlog, and no tasks-axi each exit 0 with one explanatory line"
}

# --- mark ---------------------------------------------------------------------

test_mark_records_completion_in_one_step() {
  local home out rc
  home=$(make_home mark)
  add_job "$home" fm-weekly-report 'recurring: weekly report' $'last-run: 2026-08-28\nkeep this note\nlast-run: decoy'
  axi "$home" hold fm-weekly-report --reason 'next run' --until 2026-09-04 --kind future

  out=$(jobs "$home" 2026-09-04 mark fm-weekly-report --ran 2026-09-04 --next 2026-09-11); rc=$?
  expect_code 0 "$rc" "mark"
  assert_contains "$out" 'ok: fm-weekly-report last-run 2026-09-04, next due 2026-09-11' "mark did not report its result"
  [ "$(body_of "$home" fm-weekly-report)" = '"last-run: 2026-09-04\nkeep this note\nlast-run: decoy"' ] \
    || fail "mark should rewrite only the first last-run line and keep the body: $(body_of "$home" fm-weekly-report)"
  [ "$(hold_until_of "$home" fm-weekly-report)" = 2026-09-11 ] \
    || fail "mark should re-hold until --next, got: $(hold_until_of "$home" fm-weekly-report)"
  assert_contains "$(jobs "$home" 2026-09-04)" 'fm-weekly-report  due 2026-09-11  last-run 2026-09-04' \
    "the listing does not reflect the marked completion"

  add_job "$home" fm-fresh 'recurring: fresh job' 'a note only'
  out=$(jobs "$home" 2026-09-04 mark fm-fresh --ran 2026-09-04 --next 2026-09-05); rc=$?
  expect_code 0 "$rc" "mark on a body without last-run"
  [ "$(body_of "$home" fm-fresh)" = '"last-run: 2026-09-04\na note only"' ] \
    || fail "mark should add last-run as the first body line: $(body_of "$home" fm-fresh)"
  pass "mark: rewrites last-run and re-holds in one step, adding the line when missing"
}

test_mark_refuses_bad_input() {
  local home out rc
  home=$(make_home refuse)
  add_job "$home" plain 'not a job' 'last-run: 2026-01-01'
  add_job "$home" fm-job 'recurring: real job' 'last-run: 2026-01-01'

  out=$(jobs "$home" 2026-09-04 mark plain --ran 2026-09-04 --next 2026-09-05); rc=$?
  expect_code 2 "$rc" "non-recurring row"
  assert_contains "$out" 'plain is not a recurring job' "a non-recurring row must be refused by name"
  [ "$(hold_until_of "$home" plain)" = '"-"' ] || fail "a refused mark must not hold the row"

  out=$(jobs "$home" 2026-09-04 mark nope --ran 2026-09-04 --next 2026-09-05); rc=$?
  expect_code 2 "$rc" "unknown row"
  assert_contains "$out" 'no backlog row nope' "an unknown row must be refused"

  out=$(jobs "$home" 2026-09-04 mark fm-job --ran 2026-9-4 --next 2026-09-05); rc=$?
  expect_code 2 "$rc" "malformed --ran"
  assert_contains "$out" '--ran must be YYYY-MM-DD' "a malformed date must be refused"
  out=$(jobs "$home" 2026-09-04 mark fm-job --ran 2026-09-04); rc=$?
  expect_code 2 "$rc" "missing --next"
  [ "$(body_of "$home" fm-job)" = '"last-run: 2026-01-01"' ] || fail "a refused mark must not touch the body"

  printf 'manual\n' > "$home/config/backlog-backend"
  out=$(jobs "$home" 2026-09-04 mark fm-job --ran 2026-09-04 --next 2026-09-05); rc=$?
  expect_code 2 "$rc" "manual backend"
  assert_contains "$out" 'config/backlog-backend selects manual editing' "a manual home must be told to edit by hand"
  [ "$(body_of "$home" fm-job)" = '"last-run: 2026-01-01"' ] || fail "a manual home's row must not be written"
  assert_contains "$(jobs "$home" 2026-09-04)" 'fm-job  DUE now  last-run 2026-01-01' \
    "a manual home should still get the read-only listing"
  pass "mark: non-recurring, unknown, malformed, and manual-backend requests are refused without writing"
}

test_list_orders_running_due_upcoming_and_held
test_list_survives_quoting_and_missing_last_run
test_list_is_never_fatal
test_mark_records_completion_in_one_step
test_mark_refuses_bad_input
