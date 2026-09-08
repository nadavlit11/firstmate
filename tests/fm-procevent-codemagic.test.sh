#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-codemagic.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-codemagic.XXXXXX")
HOME_DIR="$LAB/home"
FAKEBIN="$LAB/fakebin"
COUNT="$LAB/count"
ARGV_LOG="$LAB/curl-argv"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$HOME_DIR/config" "$FAKEBIN"
printf 'CODEMAGIC_API_TOKEN=super-secret-test-token\n' > "$HOME_DIR/config/codemagic.env"
chmod 0600 "$HOME_DIR/config/codemagic.env"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
body=
url=
printf '%s\n' "$@" > "$CODEMAGIC_ARGV_LOG"
IFS= read -r auth_config || exit 9
case "$auth_config" in 'header = "x-auth-token: super-secret-test-token"') ;; *) exit 8 ;; esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) body=$2; shift 2 ;;
    http*://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  https://codemagic.io/api/v3/builds/build_123/actions*)
    case "${CODEMAGIC_ACTION_CASE:-success}" in
      network) exit 7 ;;
      http) printf '{}' > "$body"; printf '503'; exit 0 ;;
      invalid) printf '{}' > "$body"; printf '200'; exit 0 ;;
      many) printf '{"data":[],"total_pages":2}' > "$body"; printf '200'; exit 0 ;;
      post) printf '{"data":[{"type":"building_ios","status":"success"},{"type":"post_publish","status":"failed"}],"total_pages":1}' > "$body"; printf '200'; exit 0 ;;
      early) printf '{"data":[{"type":"building_ios","status":"failed"}],"total_pages":1}' > "$body"; printf '200'; exit 0 ;;
      *) printf '{"data":[{"type":"building_ios","status":"success"}],"total_pages":1}' > "$body"; printf '200'; exit 0 ;;
    esac
    ;;
  https://codemagic.io/api/v3/builds/build_123) ;;
  *) exit 6 ;;
esac
case "${CODEMAGIC_TEST_CASE:-finished}" in
  network) exit 7 ;;
  auth) printf '{"message":"unauthorized"}' > "$body"; printf '401'; exit 0 ;;
  forbidden) printf '{}' > "$body"; printf '403'; exit 0 ;;
  missing) printf '{}' > "$body"; printf '404'; exit 0 ;;
  rate) printf '{}' > "$body"; printf '429'; exit 0 ;;
  server) printf '{}' > "$body"; printf '503'; exit 0 ;;
  transient)
    count=0
    [ ! -f "$CODEMAGIC_COUNT" ] || read -r count < "$CODEMAGIC_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CODEMAGIC_COUNT"
    case "$count" in
      1) exit 7 ;;
      2) printf '{}' > "$body"; printf '429'; exit 0 ;;
      3) printf '{}' > "$body"; printf '503'; exit 0 ;;
      *) printf '{"data":{"status":"finished"}}' > "$body"; printf '200'; exit 0 ;;
    esac
    ;;
  malformed) printf '{"status":"finished"}' > "$body"; printf '200'; exit 0 ;;
  missing_spa) printf '<!doctype html><title>Codemagic</title>' > "$body"; printf '200'; exit 0 ;;
  unknown) printf '{"data":{"status":"new-status"}}' > "$body"; printf '200'; exit 0 ;;
  sequence)
    count=0
    [ ! -f "$CODEMAGIC_COUNT" ] || read -r count < "$CODEMAGIC_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" > "$CODEMAGIC_COUNT"
    if [ "$count" -eq 1 ]; then status=building; else status=failed; fi
    printf '{"data":{"status":"%s"}}' "$status" > "$body"
    printf '200'
    ;;
  finished_appstore) printf '{"data":{"status":"finished","app_store_connect_status":"failed"}}' > "$body"; printf '200' ;;
  *) printf '{"data":{"status":"%s"}}' "$CODEMAGIC_TEST_CASE" > "$body"; printf '200' ;;
esac
SH
chmod +x "$FAKEBIN/curl"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }
run_poll() {
  FM_HOME="$HOME_DIR" CODEMAGIC_ARGV_LOG="$ARGV_LOG" CODEMAGIC_COUNT="$COUNT" \
    FM_CODEMAGIC_POLL_RETRY_DELAY=0 CODEMAGIC_TEST_CASE="$1" CODEMAGIC_ACTION_CASE="${2:-success}" PATH="$FAKEBIN:$PATH" \
    "$BIN/fm-procevent-codemagic.sh" poll build_123 --interval 0.01 --request-timeout 1
}

if help=$("$BIN/fm-procevent-codemagic.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-codemagic.sh arm <build-id>' \
  || fail "help omitted arm usage"
ok "help renders the public commands"

for expected in finished failed canceled timeout skipped; do
  out=$(run_poll "$expected")
  printf '%s\n' "$out" | grep -qx "status: $expected" \
    || fail "$expected response did not produce its real terminal outcome"
  printf '%s\n' "$out" | grep -qx 'condition_polls: 1' \
    || fail "$expected terminal response was polled more than once"
done
ok "documented terminal statuses stop immediately"

out=$(run_poll finished post)
printf '%s\n' "$out" | grep -qx 'status: post-processing-failed' \
  || fail "failed post-publish action was flattened into the build status"
printf '%s\n' "$out" | grep -qx 'raw_status: finished' \
  || fail "post-processing failure omitted the exact raw build status"
printf '%s\n' "$out" | grep -qx 'failed_action: post_publish' \
  || fail "post-processing failure omitted the failed action type"
out=$(run_poll finished_appstore)
printf '%s\n' "$out" | grep -qx 'status: post-processing-failed' \
  || fail "failed App Store Connect processing was flattened into finished"
ok "finished builds preserve post-processing failure distinctions"

out=$(run_poll finished early)
printf '%s\n' "$out" | grep -qx 'status: post-processing-failed' \
  || fail "a failed non-publishing action on a finished build was not reported as a failure"
printf '%s\n' "$out" | grep -qx 'failed_action: building_ios' \
  || fail "a failed non-publishing action lost its real action type"
printf '%s\n' "$out" | grep -qx 'raw_status: finished' \
  || fail "a failed non-publishing action lost the raw terminal status"
ok "a failed action of any phase reports its real action name"

for action_case in network http invalid many; do
  out=$(run_poll finished "$action_case")
  printf '%s\n' "$out" | grep -qx 'status: action-detail-error' \
    || fail "$action_case action lookup did not fail explicitly"
  printf '%s\n' "$out" | grep -qx 'raw_status: finished' \
    || fail "$action_case action lookup lost the raw terminal status"
done
ok "action-detail failures stay explicit without losing raw status"

rm -f "$COUNT"
out=$(run_poll transient)
printf '%s\n' "$out" | grep -qx 'status: finished' \
  || fail "transient network, 429, and 5xx responses ended the watch instead of being retried"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' \
  || fail "bounded transient retries were counted as separate condition polls"
rm -f "$COUNT"
out=$(run_poll server)
printf '%s\n' "$out" | grep -qx 'status: api-error' \
  || fail "a persistent 5xx did not end the watch once the retry bound was spent"
ok "transient failures retry within a bound and stay terminal past it"

rm -f "$COUNT"
out=$(run_poll sequence)
printf '%s\n' "$out" | grep -qx 'status: failed' \
  || fail "in-progress build did not continue to its terminal result"
printf '%s\n' "$out" | grep -qx 'condition_polls: 2' \
  || fail "in-progress build did not make exactly two requests"
ok "in-progress status keeps polling until a terminal status"

for fixture in auth forbidden missing missing_spa rate network server malformed unknown; do
  case "$fixture" in
    auth|forbidden) expected=auth-error ;;
    missing|missing_spa) expected=not-found ;;
    rate) expected=rate-limited ;;
    network) expected=network-error ;;
    server) expected=api-error ;;
    malformed|unknown) expected=schema-error ;;
  esac
  out=$(run_poll "$fixture")
  printf '%s\n' "$out" | grep -qx "status: $expected" \
    || fail "$fixture did not produce $expected"
done
ok "lookup failures produce explicit terminal diagnostics"

if grep -Fq 'super-secret-test-token' "$ARGV_LOG"; then
  fail "API key was exposed in curl argv"
fi
out=$(run_poll auth)
if printf '%s\n' "$out" | grep -Fq 'super-secret-test-token'; then
  fail "API key was exposed in result output"
fi
ok "API key stays out of process argv and result output"

mv "$HOME_DIR/config/codemagic.env" "$HOME_DIR/config/codemagic.env.saved"
if err=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-codemagic.sh" arm build_123 2>&1); then
  fail "unconfigured home unexpectedly armed Codemagic"
fi
printf '%s\n' "$err" | grep -Fq 'Codemagic build watching is not configured' \
  || fail "unconfigured explicit arm lacked a clear setup diagnostic"
printf 'CODEMAGIC_API_TOKEN=tok\n# a comment\n' > "$HOME_DIR/config/codemagic.env"
if err=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-codemagic.sh" arm build_123 2>&1); then
  fail "malformed Codemagic config unexpectedly armed"
fi
printf '%s\n' "$err" | grep -Fq 'is malformed' \
  || fail "malformed Codemagic config was reported as unconfigured"
rm -f "$HOME_DIR/config/codemagic.env"
mv "$HOME_DIR/config/codemagic.env.saved" "$HOME_DIR/config/codemagic.env"
ok "an unconfigured home has no implicit Codemagic behavior, and a malformed one says so"

for build_id in '../escape' 'bad/id' 'space id'; do
  if "$BIN/fm-procevent-codemagic.sh" source-id "$build_id" >/dev/null 2>&1; then
    fail "unsafe build id was accepted: $build_id"
  fi
done
[ "$("$BIN/fm-procevent-codemagic.sh" source-id build_123)" = codemagic-build_123 ] \
  || fail "canonical source id was not stable"
ok "build ids are path-safe"

result="$LAB/result"
for expected in finished post-processing-failed rate-limited schema-error action-detail-error; do
  printf 'build: build_123\nstatus: %s\n' "$expected" > "$result"
  [ "$("$BIN/fm-procevent-codemagic.sh" classify "$result")" = "$expected" ] \
    || fail "classify lost $expected"
  "$BIN/fm-procevent-codemagic.sh" terminal "$result" \
    || fail "$expected was not terminal"
done
ok "captured outcomes classify as terminal"

STATE_DIR="$HOME_DIR/state"
CLAIM_ROOT="$LAB/claims"
arm_out=$(FM_HOME="$HOME_DIR" FM_PROCEVENT_CLAIM_ROOT="$CLAIM_ROOT" \
  CODEMAGIC_ARGV_LOG="$ARGV_LOG" CODEMAGIC_COUNT="$COUNT" CODEMAGIC_TEST_CASE=finished \
  PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent-codemagic.sh" arm build_123 --interval 1 --request-timeout 1)
printf '%s\n' "$arm_out" | grep -qx 'armed: codemagic-build_123' \
  || fail "arm did not register the canonical source"
registration="$STATE_DIR/procevent/codemagic-build_123.source"
[ -f "$registration" ] || fail "arm did not publish a process-event registration"
if grep -Fq 'super-secret-test-token' "$registration"; then
  fail "API key was stored in the process-event registration"
fi
FM_HOME="$HOME_DIR" FM_PROCEVENT_CLAIM_ROOT="$CLAIM_ROOT" \
  CODEMAGIC_ARGV_LOG="$ARGV_LOG" CODEMAGIC_COUNT="$COUNT" CODEMAGIC_TEST_CASE=finished \
  PATH="$FAKEBIN:$PATH" "$BIN/fm-procevent.sh" reconcile >/dev/null
result=
for _attempt in $(seq 1 50); do
  result=$(find "$STATE_DIR/procevent-inbox" -name 'codemagic-build_123.*.result' -type f -print -quit 2>/dev/null)
  [ -z "$result" ] || break
  sleep 0.1
done
[ -n "$result" ] || fail "generic process-event runner did not capture the build result"
[ "$("$BIN/fm-procevent-codemagic.sh" classify "$result")" = finished ] \
  || fail "captured process-event did not retain the build outcome"
for _attempt in $(seq 1 50); do
  [ -e "$registration" ] || break
  sleep 0.1
done
[ ! -e "$registration" ] || fail "terminal result did not retire the source"
grep -Fq 'procevent codemagic codemagic-build_123 1' "$STATE_DIR/.wake-queue" \
  || fail "terminal result did not publish the durable wake"
ok "adapter registers, captures, wakes, and retires through process-event"

printf '# all fm-procevent-codemagic tests passed\n'
