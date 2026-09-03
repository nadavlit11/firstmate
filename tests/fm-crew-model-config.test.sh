#!/usr/bin/env bash
# Behavior tests for config/crew-model, the standing crewmate/scout model pin.
#
# The pin exists because a per-spawn model that lives only in firstmate's memory
# is a preference that survives exactly until the next session. These tests drive
# the real spawn path with a fake tmux pane, then read the model back out of the
# task record and the literal launch command the pane was sent.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-model-config)

# make_case <name> <crew-harness> <id>...
# A home, a real worktree with an origin, and a brief per task. Echoes the record.
make_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog"
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<REC
$1
REC
}

run_spawn() {
  local id=$1
  shift
  : > "$LAUNCH_LOG"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --base main "$@"
}

test_standing_pin_reaches_the_launch() {
  local rec id out status
  id=crew-model-pinned-m1
  rec=$(make_case pinned codex "$id")
  read_case_record "$rec"
  printf 'gpt-5\n' > "$HOME_DIR/config/crew-model"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with a standing model pin should succeed"
  assert_grep 'model=gpt-5' "$HOME_DIR/state/$id.meta" \
    "the task record did not keep the standing model pin"
  assert_grep "--model 'gpt-5'" "$LAUNCH_LOG" \
    "the launch command did not carry the standing model pin"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed pinned launch: %s\n' "$(cat "$LAUNCH_LOG")"
  fi
  pass "config/crew-model reaches the crewmate launch with no per-spawn flag"
}

test_scout_spawn_uses_the_same_pin() {
  local rec id out status
  id=crew-model-scout-m2
  rec=$(make_case scout codex "$id")
  read_case_record "$rec"
  printf 'gpt-5\n' > "$HOME_DIR/config/crew-model"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a scout spawn with a standing model pin should succeed"
  assert_grep 'model=gpt-5' "$HOME_DIR/state/$id.meta" \
    "a scout did not pick up the standing model pin"
  pass "scouts launch on the same standing model as crewmates"
}

test_explicit_model_wins_over_the_pin() {
  local rec id out status
  id=crew-model-explicit-m3
  rec=$(make_case explicit codex "$id")
  read_case_record "$rec"
  printf 'gpt-5\n' > "$HOME_DIR/config/crew-model"

  out=$(run_spawn "$id" --model gpt-5-codex --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an explicit model alongside a pin should succeed"
  assert_grep 'model=gpt-5-codex' "$HOME_DIR/state/$id.meta" \
    "the explicit per-spawn model did not win over the standing pin"
  assert_grep "--model 'gpt-5-codex'" "$LAUNCH_LOG" \
    "the launch command did not carry the explicit per-spawn model"
  pass "an explicit --model wins over the standing pin"
}

test_absent_and_default_pin_leave_the_harness_default() {
  local rec id out status
  id=crew-model-absent-m4
  rec=$(make_case absent codex "$id" crew-model-default-m4)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with no model pin should succeed"
  assert_grep 'model=default' "$HOME_DIR/state/$id.meta" \
    "an absent pin did not leave the harness default"
  assert_no_grep '--model' "$LAUNCH_LOG" \
    "an absent pin still put a model flag on the launch"

  id=crew-model-default-m4
  printf 'default\n' > "$HOME_DIR/config/crew-model"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with a default model pin should succeed"
  assert_grep 'model=default' "$HOME_DIR/state/$id.meta" \
    "a default pin was treated as a literal model name"
  assert_no_grep '--model' "$LAUNCH_LOG" \
    "a default pin still put a model flag on the launch"
  pass "an absent or default pin launches on the harness own default model"
}

test_explicit_harness_skips_the_pin_out_loud() {
  local rec id out status
  id=crew-model-foreign-harness-m5
  rec=$(make_case foreign-harness codex "$id")
  read_case_record "$rec"
  printf 'gpt-5\n' > "$HOME_DIR/config/crew-model"

  out=$(run_spawn "$id" --harness claude --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an explicit harness alongside a pin should still launch"
  assert_contains "$out" "config/crew-model pins 'gpt-5'" \
    "skipping the standing pin for an explicitly selected harness was silent"
  assert_grep 'model=default' "$HOME_DIR/state/$id.meta" \
    "another harness model name was borrowed for an explicitly selected harness"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed skip notice: %s\n' "$(printf '%s\n' "$out" | grep crew-model | head -n 1)"
  fi
  pass "an explicitly selected harness skips the standing pin and says so"
}

# The pin is a bare model name. Surrounding whitespace is noise, but internal
# whitespace is a malformed value (a secondmate-style "<model> <effort>" line),
# which must reach the harness as written so it is refused there, not be
# collapsed into a plausible name that was never configured.
test_pin_trims_only_surrounding_whitespace() {
  local rec id out status
  id=crew-model-padded-m6
  rec=$(make_case padded codex "$id" crew-model-malformed-m6)
  read_case_record "$rec"
  printf '  gpt-5  \n\n' > "$HOME_DIR/config/crew-model"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with a whitespace-padded model pin should succeed"
  assert_grep "--model 'gpt-5'" "$LAUNCH_LOG" \
    "surrounding whitespace was not trimmed from the standing model pin"

  id=crew-model-malformed-m6
  printf 'claude-opus-5 high\n' > "$HOME_DIR/config/crew-model"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with a malformed model pin should still reach the launch"
  assert_grep "--model 'claude-opus-5 high'" "$LAUNCH_LOG" \
    "a malformed model pin did not reach the harness as written"
  assert_no_grep 'claude-opus-5high' "$LAUNCH_LOG" \
    "internal whitespace in the model pin was collapsed into a name that was never configured"
  pass "config/crew-model trims surrounding whitespace only and passes a malformed value through"
}

test_standing_pin_reaches_the_launch
test_scout_spawn_uses_the_same_pin
test_explicit_model_wins_over_the_pin
test_absent_and_default_pin_leave_the_harness_default
test_explicit_harness_skips_the_pin_out_loud
test_pin_trims_only_surrounding_whitespace
