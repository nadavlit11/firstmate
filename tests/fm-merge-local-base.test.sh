#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh's recorded-base refusal: the landing must
# refuse work dispatched from a genuinely different line, but must NOT refuse a
# task whose recorded base is just another spelling of the default branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-base-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q -b main "$case_dir/project"
  printf 'base\n' > "$case_dir/project/feature.txt"
  git -C "$case_dir/project" add feature.txt
  git -C "$case_dir/project" commit -qm "baseline"

  git -C "$case_dir/project" branch -q "fm/task-b1"
  git -C "$case_dir/project" worktree add -q "$case_dir/wt" "fm/task-b1"
  printf 'task work\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "task work"

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-b1.meta" \
    "window=fm-task-b1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "mode=local-only" \
    "$@"
}

run_merge_local() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" task-b1
}

test_equivalent_base_name_lands() {
  local case_dir out
  case_dir=$(make_case equivalent-name)
  write_meta "$case_dir" "base=refs/heads/main"

  set +e
  out=$(run_merge_local "$case_dir" 2>&1)
  local rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "equivalent-name: landing refused a base that is the default branch: $out"
  assert_contains "$out" "merged fm/task-b1 into local main" \
    "equivalent-name: expected the fast-forward to land"
  assert_contains "$(cat "$case_dir/project/feature.txt")" "task work" \
    "equivalent-name: default branch did not advance to the task's work"
  pass "fm-merge-local lands a task whose recorded base is another spelling of the default branch"
}

test_other_line_is_still_refused() {
  local case_dir out before
  case_dir=$(make_case other-line)
  git -C "$case_dir/project" worktree add -q -b prod "$case_dir/prod-wt" main
  printf 'prod-line\n' > "$case_dir/prod-wt/prod.txt"
  git -C "$case_dir/prod-wt" add prod.txt
  git -C "$case_dir/prod-wt" commit -qm "production line"
  write_meta "$case_dir" "base=prod"
  before=$(git -C "$case_dir/project" rev-parse main)

  set +e
  out=$(run_merge_local "$case_dir" 2>&1)
  local rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "other-line: landing accepted work dispatched from another line"
  assert_contains "$out" "REFUSED: task task-b1 was dispatched from base 'prod'" \
    "other-line: expected the loud base refusal"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "other-line: default branch moved despite the refusal"
  pass "fm-merge-local still refuses a task dispatched from a genuinely different line"
}

# Two DISTINCT ref names that happen to sit on the same commit are still two
# lines: a release branch cut at the default branch's tip and dispatched as
# --base release must never be fast-forwarded into the default branch, or work
# aimed at the release line lands where it was not aimed.
test_coincident_second_line_is_still_refused() {
  local case_dir out before
  case_dir=$(make_case coincident-line)
  git -C "$case_dir/project" branch -q release main
  write_meta "$case_dir" "base=release"
  before=$(git -C "$case_dir/project" rev-parse main)
  [ "$(git -C "$case_dir/project" rev-parse release)" = "$before" ] \
    || fail "coincident-line: fixture did not put release and main on the same commit"

  set +e
  out=$(run_merge_local "$case_dir" 2>&1)
  local rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "coincident-line: landing accepted release work because release happened to equal main"
  assert_contains "$out" "REFUSED: task task-b1 was dispatched from base 'release'" \
    "coincident-line: expected the loud base refusal"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "coincident-line: default branch moved despite the refusal"
  pass "fm-merge-local refuses a distinct base line even when it currently points at the default branch's commit"
}

test_equivalent_base_name_lands
test_other_line_is_still_refused
test_coincident_second_line_is_still_refused
