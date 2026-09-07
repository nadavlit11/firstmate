#!/usr/bin/env bash
# Behavior tests for the ship planning gate at bin/fm-spawn.sh's dispatch door.
#
# bin/fm-brief.sh writes one machine-readable "Planning gate:" line into every
# ship brief; the spawn re-reads it and revalidates the referenced report before
# it creates or mutates anything. These tests drive that through the spawn's own
# interface with a fake tmux and a real isolated worktree, so what they pin is
# the refusal, the record, and the ordering - never the script's source text.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-planning-gate)

make_case() { # <name> <task-id>...
  local name=$1 case_dir home proj wt fakebin launchlog id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/plan-scout"
  printf 'a completed investigation with implementation-ready findings\n' \
    > "$home/data/plan-scout/report.md"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id" "brief for $id" "Planning gate: plan=plan-scout/report.md"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

read_case() {
  # shellcheck disable=SC2034  # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

run_ship() {
  run_spawn "$@" --base main --mode no-mistakes --yolo off
}

test_ship_spawn_refuses_missing_planning_line() {
  local rec id out status
  id='planning-missing-p1'
  rec=$(make_case planning-missing)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" "brief for $id" ""

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a ship brief with no planning line must refuse"
  assert_contains "$out" "planning gate refused $id: ship briefs require either --plan-report" \
    "the refusal did not name both alternatives"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal must precede any task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "the refusal must precede any launch"
  pass "a ship spawn refuses a brief with no planning disposition"
}

test_ship_spawn_revalidates_plan_report_before_mutation() {
  local rec id out status
  id='planning-vanished-p2'
  rec=$(make_case planning-vanished "$id")
  read_case "$rec"
  # The report existed when the brief was scaffolded and is gone now: the spawn
  # must notice at dispatch rather than launching an unplanned build.
  rm -f "$HOME_DIR/data/plan-scout/report.md"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a plan report deleted since scaffolding must refuse"
  assert_contains "$out" "must be a non-empty regular file inside" \
    "the refusal did not say what the report must be"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal must precede any task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "the refusal must precede any launch"
  pass "a ship spawn revalidates the plan report at dispatch, not only at scaffold time"
}

test_ship_spawn_refuses_duplicate_or_malformed_planning_line() {
  local rec id out status
  id='planning-dup-p3'
  rec=$(make_case planning-dup "$id")
  read_case "$rec"
  printf '%s\n' "Planning gate: exception=one-line reason=second opinion" \
    >> "$HOME_DIR/data/$id.brief-extra" 2>/dev/null || true
  printf '%s\n' "Planning gate: exception=one-line reason=second opinion" \
    >> "$HOME_DIR/data/$id/brief.md"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "two planning lines must refuse"
  assert_contains "$out" "records 2 'Planning gate:' lines" "the refusal did not name the duplication"
  assert_absent "$HOME_DIR/state/$id.meta" "the refusal must precede any task record"

  id='planning-malformed-p3b'
  rec=$(make_case planning-malformed)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" "brief for $id" "Planning gate: whatever"
  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a malformed planning line must refuse"
  assert_contains "$out" "planning line is malformed" "the refusal did not name the malformed line"
  pass "a ship spawn refuses a duplicated or malformed planning line"
}

test_ship_spawn_accepts_completed_prior_scout_report() {
  local rec id out status
  id='planning-ok-p4'
  rec=$(make_case planning-ok "$id")
  read_case "$rec"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a ship naming a completed report should launch"
  assert_grep "plan_report=plan-scout/report.md" "$HOME_DIR/state/$id.meta" \
    "the plan report was not recorded on the task"
  assert_no_grep "planning_exception=" "$HOME_DIR/state/$id.meta" \
    "a planned ship must record no exception"
  pass "a ship spawn accepts an earlier completed scout report as its plan"
}

test_ship_spawn_surfaces_and_records_planning_exception() {
  local rec id out status
  id='planning-exc-p5'
  rec=$(make_case planning-exc)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" "brief for $id" \
    "Planning gate: exception=precedent-following reason=follows bin/fm-lease-lib.sh"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "a typed, reasoned exception should launch"
  assert_contains "$out" "PLANNING EXCEPTION: $id precedent-following: follows bin/fm-lease-lib.sh" \
    "the accepted exception was not printed for the operator"
  assert_grep "planning_exception=precedent-following" "$HOME_DIR/state/$id.meta" \
    "the exception kind was not recorded"
  assert_grep "planning_reason=follows bin/fm-lease-lib.sh" "$HOME_DIR/state/$id.meta" \
    "the exception reason was not recorded"
  assert_no_grep "plan_report=" "$HOME_DIR/state/$id.meta" \
    "an exempt ship must record no plan report"
  pass "an accepted planning exception is printed and recorded with its reason"
}

test_scout_and_secondmate_spawns_are_not_planning_gated() {
  local rec id out status
  id='planning-scout-p6'
  rec=$(make_case planning-scout)
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" "brief for $id" ""

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --base main)
  status=$?
  expect_code 0 "$status" "a scout spawn must not be planning-gated"
  assert_no_grep "plan_report=" "$HOME_DIR/state/$id.meta" "a scout must record no planning disposition"
  assert_no_grep "planning_exception=" "$HOME_DIR/state/$id.meta" "a scout must record no planning disposition"
  pass "scout spawns produce the plan and are not planning-gated themselves"
}

test_relaunch_revalidates_recorded_planning_provenance() {
  local rec id out status
  id='planning-relaunch-p7'
  rec=$(make_case planning-relaunch "$id")
  read_case "$rec"

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the first launch should succeed"

  rm -f "$HOME_DIR/data/plan-scout/report.md"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" --relaunch)
  status=$?
  expect_code 1 "$status" "a relaunch must revalidate the plan the brief names"
  assert_contains "$out" "must be a non-empty regular file inside" \
    "the relaunch refusal did not name the missing report"
  pass "a relaunch revalidates the planning provenance rather than trusting the old record"
}

test_batch_checks_every_brief_independently() {
  local rec id1 id2 out status
  id1='planning-batch-a-p8'
  id2='planning-batch-b-p8'
  rec=$(make_case planning-batch "$id1")
  read_case "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id2" "brief for $id2" ""

  out=$(run_ship "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a batch with one ungated brief must report a failure"
  assert_contains "$out" "spawned $id1" "the planned pair should still launch"
  assert_contains "$out" "planning gate refused $id2" "the ungated pair was not refused by name"
  assert_absent "$HOME_DIR/state/$id2.meta" "the refused pair must leave no task record"
  pass "batch dispatch applies the planning gate to every brief independently"
}

test_ship_spawn_refuses_missing_planning_line
test_ship_spawn_revalidates_plan_report_before_mutation
test_ship_spawn_refuses_duplicate_or_malformed_planning_line
test_ship_spawn_accepts_completed_prior_scout_report
test_ship_spawn_surfaces_and_records_planning_exception
test_scout_and_secondmate_spawns_are_not_planning_gated
test_relaunch_revalidates_recorded_planning_provenance
test_batch_checks_every_brief_independently

echo "# all fm-spawn-planning-gate tests passed"
