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

# --- the brief --------------------------------------------------------------

test_brief_mentions_tavily_only_when_the_home_has_it() {
  local dir home brief
  dir="$TMP_ROOT/brief"
  home="$dir/home"
  fm_test_spawn_home "$home" claude

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-off demo --base main --mode no-mistakes >/dev/null \
    || fail "scaffolding a brief without a key failed"
  brief="$home/data/tv-off/brief.md"
  # Matched on the tool names and the capability sentence rather than the bare
  # word, which also occurs in this suite's own temporary paths.
  assert_no_grep 'tavily_search' "$brief" "a home with no key advertised Tavily to the worker"
  assert_no_grep 'Tavily web retrieval' "$brief" \
    "a home with no key described a capability it does not have"

  write_key "$home"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-on demo --base main --mode no-mistakes >/dev/null \
    || fail "scaffolding a brief with a key failed"
  brief="$home/data/tv-on/brief.md"
  assert_grep 'tavily_search' "$brief" "the brief did not tell the worker Tavily is available"
  assert_grep 'tavily_research is deliberately withheld' "$brief" \
    "the brief did not carry the Research prohibition"
  assert_no_grep "$SECRET" "$brief" "the API key was written into a brief"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-scout demo --base main --scout >/dev/null \
    || fail "scaffolding a scout brief with a key failed"
  assert_grep 'tavily_search' "$home/data/tv-scout/brief.md" \
    "a scout brief did not tell the worker Tavily is available"
  pass "briefs advertise Tavily only where the home actually has it, and never carry the key"
}

# The key is only half the gate: an unwired harness gets no server at launch, so
# a brief written for one must not describe tools that worker will not have.
test_brief_stays_silent_on_an_unwired_harness() {
  local dir home
  dir="$TMP_ROOT/brief-unwired"
  home="$dir/home"
  fm_test_spawn_home "$home" opencode
  write_key "$home"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-standing demo --base main --mode no-mistakes >/dev/null \
    || fail "scaffolding a brief on an unwired standing harness failed"
  assert_no_grep 'tavily_search' "$home/data/tv-standing/brief.md" \
    "a brief for an unwired standing harness advertised Tavily anyway"
  assert_no_grep 'Tavily web retrieval' "$home/data/tv-standing/brief.md" \
    "a brief for an unwired standing harness described a capability the launch cannot grant"

  # An explicit --harness overrides the standing resolution, in both directions.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-override demo --base main --mode no-mistakes --harness claude >/dev/null \
    || fail "scaffolding a brief with an explicit wired harness failed"
  assert_grep 'tavily_search' "$home/data/tv-override/brief.md" \
    "an explicit wired harness did not get the Tavily lines"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-override-off demo --base main --scout --harness gemini >/dev/null \
    || fail "scaffolding a scout brief with an explicit unwired harness failed"
  assert_no_grep 'tavily_search' "$home/data/tv-override-off/brief.md" \
    "an explicit unwired harness still got the Tavily lines"
  pass "a brief describes Tavily only when the harness it will launch on can be wired for it"
}

# A dispatch profile means config/crew-harness is NOT what the spawn launches on,
# so there is nothing honest to derive from: the scaffold must refuse rather than
# write a brief whose Tavily claim the launch may not honour.
test_brief_refuses_to_guess_under_a_dispatch_profile() {
  local dir home out status
  dir="$TMP_ROOT/brief-dispatch"
  home="$dir/home"
  fm_test_spawn_home "$home" claude
  printf '{}\n' > "$home/config/crew-dispatch.json"
  write_key "$home"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-dispatch demo --base main --mode no-mistakes 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a dispatch-profile scaffold with a key guessed a harness instead of refusing"
  [ ! -e "$home/data/tv-dispatch/brief.md" ] \
    || fail "the refused scaffold still wrote a brief"
  case "$out" in
    *--harness*) : ;;
    *) fail "the refusal did not name --harness: $out" ;;
  esac

  # The explicit harness the dispatch rules resolved to is accepted, and decides.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-dispatch-ok demo --base main --mode no-mistakes --harness opencode >/dev/null \
    || fail "a dispatch-profile scaffold with an explicit harness failed"
  assert_no_grep 'tavily_search' "$home/data/tv-dispatch-ok/brief.md" \
    "a dispatch-resolved unwired harness still got the Tavily lines"

  # With no usable key there are no Tavily lines to get wrong, so an unrelated
  # caller on a dispatch-profile home must not start needing --harness.
  rm -f "$home/config/tavily.env"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" tv-dispatch-nokey demo --base main --mode no-mistakes >/dev/null \
    || fail "a dispatch-profile scaffold with no key was refused"
  [ -e "$home/data/tv-dispatch-nokey/brief.md" ] || fail "the keyless dispatch scaffold wrote no brief"
  pass "a dispatch-profile home refuses to guess a harness only when a key makes the guess matter"
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
  notice=$(fm_tavily_malformed_notice "$home/config")
  [ -z "$notice" ] || fail "an absent key file produced a diagnostic: '$notice'"

  printf '# no key yet\nTAVILY_API_KEY=\n' > "$home/config/tavily.env"
  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = absent ] || fail "an empty value was not treated as absence: '$status'"
  notice=$(fm_tavily_malformed_notice "$home/config")
  [ -z "$notice" ] || fail "an empty value produced a diagnostic: '$notice'"

  printf 'TAVILY_API_KEY=\nTAVILY_API_KEY=%s\n' "$SECRET" > "$home/config/tavily.env"
  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = ok ] || fail "a valid key after a placeholder was not ok: '$status'"
  fm_tavily_key_present "$home/config" \
    || fail "a valid key after a placeholder did not count as present"

  write_key "$home"
  status=$(fm_tavily_key_status "$home/config")
  [ "$status" = ok ] || fail "a well-formed key was not ok: '$status'"
  notice=$(fm_tavily_malformed_notice "$home/config")
  [ -z "$notice" ] || fail "a well-formed key produced a diagnostic: '$notice'"

  local spelling
  for spelling in 'TAVILY_API_KEY="%s"\n' 'export TAVILY_API_KEY=%s\n' '  TAVILY_API_KEY=%s\n' 'TAVILY_API_KEY=%s\r\n'; do
    # shellcheck disable=SC2059  # the loop variable IS the format being exercised
    printf "$spelling" "$SECRET" > "$home/config/tavily.env"
    status=$(fm_tavily_key_status "$home/config")
    [ "$status" = malformed ] || fail "a near-miss spelling was not malformed: '$spelling' -> '$status'"
    fm_tavily_key_present "$home/config" \
      && fail "a near-miss spelling still counted as a usable key: '$spelling'"
    notice=$(fm_tavily_malformed_notice "$home/config")
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
test_exec_wrapper_injects_without_printing
test_claude_launch_wires_tavily_and_withholds_research
test_codex_launch_wires_tavily_and_withholds_research
test_scout_gets_the_same_wiring
test_absent_key_leaves_the_launch_untouched
test_empty_key_file_is_absence_not_failure
test_unwired_harness_gets_nothing
test_malformed_key_leaves_the_launch_unwired_and_says_so
test_brief_mentions_tavily_only_when_the_home_has_it
test_brief_stays_silent_on_an_unwired_harness
test_brief_refuses_to_guess_under_a_dispatch_profile
