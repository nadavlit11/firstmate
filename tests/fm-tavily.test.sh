#!/usr/bin/env bash
# Behavior tests for the optional Tavily web-retrieval capability.
#
# Three guarantees are worth pinning, because each fails differently:
#   - the key never reaches a launch command, a brief, or a diagnostic;
#   - Research is withheld by the launch itself, not by asking the worker;
#   - a home with no key spawns exactly as it did before the capability existed.
# These drive the real spawn and brief paths with a fake pane and read the
# literal launch command the pane was sent.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-tavily-lib.sh
. "$ROOT/bin/fm-tavily-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-tavily)

# A key value no other fixture could produce, so an assertion that it is absent
# is meaningful.
SECRET='tvly-dev-TESTONLYSECRET0123456789'

make_case() {  # <name> <crew-harness> <id>...
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

write_key() {  # <home> [value]
  printf 'TAVILY_API_KEY=%s\n' "${2:-$SECRET}" > "$1/config/tavily.env"
  chmod 0600 "$1/config/tavily.env"
}

run_spawn() {  # <id> [args...]
  local id=$1
  shift
  : > "$LAUNCH_LOG"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --base main "$@"
}

# --- key parsing ------------------------------------------------------------

test_key_file_parsing() {
  local dir out
  dir="$TMP_ROOT/parse"
  mkdir -p "$dir"

  printf 'TAVILY_API_KEY=%s\n' "$SECRET" > "$dir/plain"
  out=$(fm_tavily_read_key "$dir/plain")
  [ "$out" = "$SECRET" ] || fail "a plain assignment did not parse: '$out'"

  printf 'TAVILY_API_KEY=  %s  \n' "$SECRET" > "$dir/padded"
  out=$(fm_tavily_read_key "$dir/padded")
  [ "$out" = "$SECRET" ] || fail "a padded value was not trimmed on both sides: '$out'"

  # Only the documented form is read. Each of these is a spelling nobody is
  # asked to write, and accepting one would either 401 later or widen the
  # parser's surface for no requirement.
  printf 'export TAVILY_API_KEY=%s\n' "$SECRET" > "$dir/exported"
  out=$(fm_tavily_read_key "$dir/exported")
  [ -z "$out" ] || fail "an 'export' prefix was accepted: '$out'"

  printf 'TAVILY_API_KEY="%s"\n' "$SECRET" > "$dir/quoted"
  out=$(fm_tavily_read_key "$dir/quoted")
  [ -z "$out" ] || fail "a quoted value was accepted: '$out'"

  printf 'TAVILY_API_KEY=%s\r\n' "$SECRET" > "$dir/crlf"
  out=$(fm_tavily_read_key "$dir/crlf")
  [ -z "$out" ] || fail "a CR-terminated line was accepted: '$out'"

  printf '  TAVILY_API_KEY=%s\n' "$SECRET" > "$dir/indented"
  out=$(fm_tavily_read_key "$dir/indented")
  [ -z "$out" ] || fail "an indented assignment was accepted: '$out'"

  printf '# comment\nOTHER=x\nTAVILY_API_KEY=%s\n' "$SECRET" > "$dir/mixed"
  out=$(fm_tavily_read_key "$dir/mixed")
  [ "$out" = "$SECRET" ] || fail "an assignment after other lines did not parse: '$out'"

  # A seeded placeholder must not hide a real key appended after it: the value
  # the launch would receive and the status the operator is shown come from one
  # scan, so they cannot disagree about the same file.
  printf 'TAVILY_API_KEY=\nTAVILY_API_KEY=%s\n' "$SECRET" > "$dir/after-placeholder"
  out=$(fm_tavily_read_key "$dir/after-placeholder")
  [ "$out" = "$SECRET" ] || fail "an empty assignment hid the valid key after it: '$out'"

  printf 'TAVILY_API_KEY=\n' > "$dir/empty"
  out=$(fm_tavily_read_key "$dir/empty")
  [ -z "$out" ] || fail "an empty value was treated as a key: '$out'"

  out=$(fm_tavily_read_key "$dir/absent")
  [ -z "$out" ] || fail "an absent file produced a key: '$out'"

  # The file is a credential store, not a script: a command in it must never run.
  printf 'echo PWNED > %s/pwned\nTAVILY_API_KEY=%s\n' "$dir" "$SECRET" > "$dir/hostile"
  out=$(fm_tavily_read_key "$dir/hostile")
  [ "$out" = "$SECRET" ] || fail "a key after a command line did not parse: '$out'"
  [ ! -e "$dir/pwned" ] || fail "the key file was executed instead of parsed"

  pass "the key file is parsed, never sourced, and only a non-empty value counts"
}

# --- the exec wrapper -------------------------------------------------------

test_exec_wrapper_injects_without_printing() {
  local dir out
  dir="$TMP_ROOT/wrapper"
  mkdir -p "$dir"
  printf 'TAVILY_API_KEY=%s\n' "$SECRET" > "$dir/tavily.env"

  # shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands these
  out=$("$ROOT/bin/fm-tavily-exec.sh" "$dir/tavily.env" FOO=bar \
    sh -c 'printf "%s|%s\n" "$FOO" "${TAVILY_API_KEY:-unset}"' 2>&1)
  [ "$out" = "bar|$SECRET" ] \
    || fail "the wrapper did not inject the key alongside a leading assignment: '$out'"

  # shellcheck disable=SC2016  # as above: the child shell expands this, not us
  out=$("$ROOT/bin/fm-tavily-exec.sh" "$dir/missing" \
    sh -c 'printf "%s\n" "${TAVILY_API_KEY:-unset}"' 2>&1)
  case "$out" in
    *unset*) : ;;
    *) fail "a missing key file did not degrade to an unset variable: '$out'" ;;
  esac
  case "$out" in
    *"$SECRET"*) fail "the wrapper printed a key on its degraded path" ;;
  esac
  pass "the wrapper injects the key through the environment and degrades quietly without it"
}

# --- the launch -------------------------------------------------------------

# Every claim about a launch is made against the literal command the pane was
# sent, because that string is what a `ps` listing and a pane capture would show.
assert_launch_carries_tavily() {  # <server-flag-fragment>
  assert_grep "fm-tavily-exec.sh" "$LAUNCH_LOG" \
    "the launch did not go through the key-injecting wrapper"
  assert_grep "$1" "$LAUNCH_LOG" \
    "the launch did not carry the Tavily server configuration"
  assert_grep "tavily_research" "$LAUNCH_LOG" \
    "the launch did not withhold the Research endpoint"
  assert_no_grep "$SECRET" "$LAUNCH_LOG" \
    "the API key reached the launch command"
}

test_claude_launch_wires_tavily_and_withholds_research() {
  local rec id out status
  id=tv-claude-t1
  rec=$(make_case claude claude "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a claude spawn with a Tavily key should succeed"
  assert_launch_carries_tavily "--mcp-config"
  assert_grep "mcp.tavily.com" "$LAUNCH_LOG" \
    "the launch did not name the Tavily endpoint"
  assert_grep "--disallowed-tools" "$LAUNCH_LOG" \
    "claude was not told to withhold a tool"
  assert_grep 'mcp__tavily__tavily_research' "$LAUNCH_LOG" \
    "the withheld tool was not the Research endpoint"
  # The variable reference must survive as a literal for claude to expand; a
  # pane shell that expanded it first would put the key on the command line.
  # shellcheck disable=SC2016  # the unexpanded literal IS what is being asserted
  assert_grep '${TAVILY_API_KEY}' "$LAUNCH_LOG" \
    "the key reference was not passed to claude as a literal"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed claude launch: %s\n' "$(cat "$LAUNCH_LOG")"
  fi
  pass "a claude crewmate launches with Tavily wired and Research withheld"
}

test_codex_launch_wires_tavily_and_withholds_research() {
  local rec id out status
  id=tv-codex-t2
  rec=$(make_case codex codex "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a codex spawn with a Tavily key should succeed"
  assert_launch_carries_tavily 'mcp_servers.tavily.url'
  assert_grep 'bearer_token_env_var' "$LAUNCH_LOG" \
    "codex was not pointed at the environment for its bearer token"
  assert_grep 'disabled_tools' "$LAUNCH_LOG" \
    "codex was not told to disable a tool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed codex launch: %s\n' "$(cat "$LAUNCH_LOG")"
  fi
  pass "a codex crewmate launches with Tavily wired and Research withheld"
}

test_scout_gets_the_same_wiring() {
  local rec id out status
  id=tv-scout-t3
  rec=$(make_case scout claude "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a scout spawn with a Tavily key should succeed"
  assert_launch_carries_tavily "--mcp-config"
  pass "scouts launch with the same Tavily wiring as crewmates"
}

# --- absence ----------------------------------------------------------------

test_absent_key_leaves_the_launch_untouched() {
  local rec id out status
  id=tv-absent-t4
  rec=$(make_case absent claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with no Tavily key should succeed"
  assert_no_grep 'fm-tavily-exec.sh' "$LAUNCH_LOG" \
    "a home with no key still wrapped the launch in the key injector"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" \
    "a home with no key still put the Tavily endpoint on the launch"
  assert_no_grep 'mcp-config' "$LAUNCH_LOG" \
    "a home with no key still loaded an MCP server"
  # An optional capability that is simply not configured must be silent: no
  # warning, no note, nothing for a supervisor to triage.
  case "$out" in
    *Tavily*) fail "an absent optional key produced output: $out" ;;
  esac
  pass "a home with no key spawns exactly as before, and says nothing about it"
}

test_empty_key_file_is_absence_not_failure() {
  local rec id out status
  id=tv-empty-t5
  rec=$(make_case empty claude "$id")
  read_case_record "$rec"
  printf '# no key yet\nTAVILY_API_KEY=\n' > "$HOME_DIR/config/tavily.env"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn with a keyless Tavily file should still succeed"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" \
    "a keyless file still wired a server the credential could not reach"
  assert_no_grep 'fm-tavily-exec.sh' "$LAUNCH_LOG" \
    "a keyless file still wrapped the launch in the key injector"
  pass "a present but keyless file is treated as absence, not as a broken spawn"
}

test_unwired_harness_gets_nothing() {
  local rec id out status
  id=tv-opencode-t6
  rec=$(make_case opencode opencode "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn on an unwired harness should still succeed"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" \
    "a harness with no verified way to withhold Research was wired anyway"
  assert_no_grep 'fm-tavily-exec.sh' "$LAUNCH_LOG" \
    "an unwired harness still had its launch wrapped in the key injector"
  pass "a harness without a verified withholding control is left unwired"
}

# --- the worker-facing lines ------------------------------------------------

# A scaffold happens before the harness is resolved, so brief.md must make no
# claim about harness-provided tooling at all - whatever the home's key state.
test_scaffolded_brief_never_mentions_tavily() {
  local dir home id
  dir="$TMP_ROOT/brief"
  home="$dir/home"
  fm_test_spawn_home "$home" claude

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-off demo --base main --mode no-mistakes >/dev/null \
    || fail "scaffolding a brief without a key failed"
  write_key "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-on demo --base main --mode no-mistakes >/dev/null \
    || fail "scaffolding a brief with a key failed"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-scout demo --base main --scout >/dev/null \
    || fail "scaffolding a scout brief with a key failed"

  # A dispatch profile is no longer a special case for scaffolding, because a
  # brief that makes no harness-specific claim cannot make a wrong one.
  printf '{}\n' > "$home/config/crew-dispatch.json"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-dispatch demo --base main --mode no-mistakes >/dev/null \
    || fail "a dispatch-profile scaffold with a key was refused"

  for id in tv-off tv-on tv-scout tv-dispatch; do
    [ -f "$home/data/$id/brief.md" ] || fail "$id was not scaffolded"
    # Matched on the tool names and the capability sentence rather than the bare
    # word, which also occurs in this suite's own temporary paths.
    assert_no_grep 'tavily_search' "$home/data/$id/brief.md" \
      "$id: a scaffolded brief advertised Tavily before any harness was resolved"
    assert_no_grep 'Tavily web retrieval' "$home/data/$id/brief.md" \
      "$id: a scaffolded brief described a capability no scaffold can vouch for"
    assert_no_grep "$SECRET" "$home/data/$id/brief.md" "$id: the API key was written into a brief"
  done
  pass "a scaffolded brief never mentions Tavily, whatever the home's key or config"
}

# The brief the worker is actually handed is the one named in the launch command.
launched_brief_path() {
  sed -n 's/.*encode launch-brief < \([^ )"]*\).*/\1/p' "$LAUNCH_LOG" | head -1 | tr -d "'"
}

test_launch_brief_carries_tavily_on_a_wired_harness() {
  local rec id out status brief
  id=tv-launchbrief-t9
  rec=$(make_case launchbrief claude "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a claude spawn with a Tavily key should succeed"
  brief=$(launched_brief_path)
  [ -n "$brief" ] && [ -f "$brief" ] || fail "could not find the brief the launch hands the worker: '$brief'"

  # The launch wires the server AND the worker is told so, from one decision.
  assert_grep 'mcp.tavily.com' "$LAUNCH_LOG" "the launch did not wire the server"
  assert_grep 'tavily_search' "$brief" "the launched worker was not told Tavily is available"
  assert_grep 'tavily_research is deliberately withheld' "$brief" \
    "the launched brief did not carry the Research prohibition"
  assert_no_grep "$SECRET" "$brief" "the API key was written into the launched brief"

  # A no-mistakes ship also carries its intent contract: both overlays compose
  # into the one file the worker receives.
  assert_grep '# Current no-mistakes intent contract' "$brief" \
    "the launched brief lost the intent contract overlay"
  # The scaffolded source brief is untouched; only the derived launch brief carries it.
  assert_no_grep 'tavily_search' "$HOME_DIR/data/$id/brief.md" \
    "the Tavily section leaked back into the scaffolded brief"
  pass "a wired launch hands the worker a brief that carries the Tavily contract"
}

# The case that used to drift: the harness the spawn resolves is unwired, so the
# worker must be told nothing - by construction, not by a check.
test_unwired_launch_tells_the_worker_nothing() {
  local rec id out status brief
  id=tv-nodrift-t10
  rec=$(make_case nodrift opencode "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a spawn on an unwired harness should still succeed"
  brief=$(launched_brief_path)
  [ -n "$brief" ] && [ -f "$brief" ] || fail "could not find the brief the launch hands the worker: '$brief'"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" "an unwired harness was wired anyway"
  assert_no_grep 'tavily_search' "$brief" \
    "the worker was told about tools its unwired launch never granted"
  pass "an unwired launch tells the worker nothing about Tavily"
}

# The exact reported sequence: scaffold with no harness input at all, then spawn
# with an explicit --harness the standing configuration did not predict.
test_explicit_harness_override_cannot_drift_from_the_brief() {
  local rec id out status brief
  id=tv-override-t11
  rec=$(make_case override claude "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"
  rm -f "$HOME_DIR/data/$id/brief.md"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" demo --base main --mode no-mistakes >/dev/null \
    || fail "scaffolding the brief failed"
  # Firstmate fills these before dispatch; spawn refuses a brief that still has them.
  sed -e 's/{TASK}/Investigate the thing./' -e 's/{FIRSTMATE_SPEC}/Exercise the spawn behavior under test./' \
    "$HOME_DIR/data/$id/brief.md" > "$HOME_DIR/data/$id/brief.filled" \
    && mv "$HOME_DIR/data/$id/brief.filled" "$HOME_DIR/data/$id/brief.md" \
    || fail "could not fill the scaffolded brief"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off --harness opencode)
  status=$?
  expect_code 0 "$status" "spawning with an explicit unwired harness should succeed: $out"
  brief=$(launched_brief_path)
  [ -n "$brief" ] && [ -f "$brief" ] || fail "could not find the brief the launch hands the worker: '$brief'"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" "the overridden harness was wired anyway"
  assert_no_grep 'tavily_search' "$brief" \
    "a scaffold-then-override sequence still told the worker about Tavily"
  pass "an explicit harness override cannot leave the worker holding a stale Tavily claim"
}

# --- absent vs malformed ----------------------------------------------------

# Absent and malformed are both "no Tavily", but they are different situations
# for the operator: nobody set a key, versus somebody set one that cannot work.
test_key_status_separates_absence_from_a_broken_spelling() {
  local dir home status notice
  dir="$TMP_ROOT/status"
  home="$dir/home"
  fm_test_spawn_home "$home" claude

  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = absent ] || fail "a home with no key file was not absent: '$status'"
  notice=$(fm_tavily_notice "$home/config")
  [ -z "$notice" ] || fail "an absent key file produced a diagnostic: '$notice'"

  printf '# no key yet\nTAVILY_API_KEY=\n' > "$home/config/tavily.env"
  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = absent ] || fail "an empty value was not treated as absence: '$status'"
  notice=$(fm_tavily_notice "$home/config")
  [ -z "$notice" ] || fail "an empty value produced a diagnostic: '$notice'"

  printf 'TAVILY_API_KEY=\nTAVILY_API_KEY=%s\n' "$SECRET" > "$home/config/tavily.env"
  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = ok ] || fail "a valid key after a placeholder was not ok: '$status'"
  fm_tavily_key_present "$home/config" \
    || fail "a valid key after a placeholder did not count as present"

  write_key "$home"
  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = ok ] || fail "a well-formed key was not ok: '$status'"
  notice=$(fm_tavily_notice "$home/config")
  [ -z "$notice" ] || fail "a well-formed key produced a diagnostic: '$notice'"

  local spelling
  for spelling in 'TAVILY_API_KEY="%s"\n' 'export TAVILY_API_KEY=%s\n' '  TAVILY_API_KEY=%s\n' 'TAVILY_API_KEY=%s\r\n' 'TAVILY_API_KEY=%s # captain key\n'; do
    # shellcheck disable=SC2059  # the loop variable IS the format being exercised
    printf "$spelling" "$SECRET" > "$home/config/tavily.env"
    status=$(fm_tavily_key_status "$home/config")
    [ "$status" = malformed ] || fail "a near-miss spelling was not malformed: '$spelling' -> '$status'"
    fm_tavily_key_present "$home/config" \
      && fail "a near-miss spelling still counted as a usable key: '$spelling'"
    notice=$(fm_tavily_notice "$home/config")
    case "$notice" in
      *"$home/config/tavily.env"*) : ;;
      *) fail "the diagnostic did not name the key file: '$notice'" ;;
    esac
    case "$notice" in
      *'TAVILY_API_KEY=<value>'*) : ;;
      *) fail "the diagnostic did not give the accepted form: '$notice'" ;;
    esac
    case "$notice" in
      *"$SECRET"*) fail "the diagnostic printed the key value" ;;
    esac
  done
  pass "an unset key is silent absence while a broken spelling is a named, value-free diagnostic"
}

# A key that exists but cannot be read is its own situation: the contents may be
# perfectly fine and the permissions are wrong, so the remedy is the file rather
# than the key line, and the operator must not be told the opposite.
test_unreadable_key_file_is_reported_as_a_permissions_problem() {
  local rec id out status notice
  id=tv-unreadable-t8
  rec=$(make_case unreadable claude "$id")
  read_case_record "$rec"
  write_key "$HOME_DIR"
  chmod 000 "$HOME_DIR/config/tavily.env"
  if [ -r "$HOME_DIR/config/tavily.env" ]; then
    chmod 0600 "$HOME_DIR/config/tavily.env"
    printf '# skip - mode 000 is still readable as this user (root?); the unreadable verdict cannot be exercised\n'
    return 0
  fi

  status=$(fm_tavily_key_status "$HOME_DIR/config")
  [ "$status" = unreadable ] || fail "an unreadable key file was not its own verdict: '$status'"
  notice=$(fm_tavily_notice "$HOME_DIR/config")
  case "$notice" in
    *"$HOME_DIR/config/tavily.env"*) : ;;
    *) fail "the unreadable notice did not name the key file: '$notice'" ;;
  esac
  case "$notice" in
    *permissions*) : ;;
    *) fail "the unreadable notice did not point at permissions: '$notice'" ;;
  esac
  case "$notice" in
    *"$SECRET"*) fail "the unreadable notice printed the key value" ;;
  esac

  out=$(run_spawn "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "an unreadable key should not break the spawn"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" \
    "an unreadable key file still wired the server"
  assert_no_grep 'fm-tavily-exec.sh' "$LAUNCH_LOG" \
    "an unreadable key file still wrapped the launch in the key injector"
  case "$out" in
    *"config/tavily.env"*) : ;;
    *) fail "the spawn stayed silent about a key file it could not read: $out" ;;
  esac
  case "$out" in
    *"$SECRET"*) fail "the spawn leaked the key value" ;;
  esac

  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" tv-unreadable demo --base main --mode no-mistakes >/dev/null 2>&1 \
    || fail "scaffolding a brief with an unreadable key file failed"
  assert_no_grep 'tavily_search' "$HOME_DIR/data/tv-unreadable/brief.md" \
    "a brief advertised Tavily from a key file that cannot be read"
  chmod 0600 "$HOME_DIR/config/tavily.env"
  pass "a key file that cannot be read is neither wired nor mistaken for absence"
}

test_malformed_key_leaves_the_launch_unwired_and_says_so() {
  local rec id out status
  id=tv-malformed-t7
  rec=$(make_case malformed claude "$id")
  read_case_record "$rec"
  printf 'TAVILY_API_KEY="%s"\n' "$SECRET" > "$HOME_DIR/config/tavily.env"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "a malformed key should not break the spawn"
  assert_no_grep 'mcp.tavily.com' "$LAUNCH_LOG" \
    "a malformed key still wired a server the credential could not authenticate against"
  assert_no_grep 'fm-tavily-exec.sh' "$LAUNCH_LOG" \
    "a malformed key still wrapped the launch in the key injector"
  case "$out" in
    *"config/tavily.env"*) : ;;
    *) fail "the spawn said nothing about an unusable key file: $out" ;;
  esac
  case "$out" in
    *'TAVILY_API_KEY=<value>'*) : ;;
    *) fail "the spawn's diagnostic did not give the accepted form: $out" ;;
  esac
  case "$out" in
    *"$SECRET"*) fail "the spawn's diagnostic printed the key value" ;;
  esac
  pass "a malformed key leaves the launch unwired and is reported without leaking the value"
}

test_key_file_parsing
test_key_status_separates_absence_from_a_broken_spelling
test_unreadable_key_file_is_reported_as_a_permissions_problem
test_exec_wrapper_injects_without_printing
test_claude_launch_wires_tavily_and_withholds_research
test_codex_launch_wires_tavily_and_withholds_research
test_scout_gets_the_same_wiring
test_absent_key_leaves_the_launch_untouched
test_empty_key_file_is_absence_not_failure
test_unwired_harness_gets_nothing
test_malformed_key_leaves_the_launch_unwired_and_says_so
test_scaffolded_brief_never_mentions_tavily
test_launch_brief_carries_tavily_on_a_wired_harness
test_unwired_launch_tells_the_worker_nothing
test_explicit_harness_override_cannot_drift_from_the_brief
