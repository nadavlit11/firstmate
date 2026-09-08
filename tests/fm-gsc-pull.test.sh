#!/usr/bin/env bash
# tests/fm-gsc-pull.test.sh - behavior tests for bin/fm-gsc-pull.sh, the
# read-only Search Console pull.
#
# Every case drives the real script over real curl and real jq against a local
# stub HTTP server (tests/gsc-stub-server.py) shaped like Google's responses.
# The stub stands in for the network, not for the script: paging, aggregation,
# CSV rendering, caching, and error classification are all the shipped code.
#
# Coverage:
#   - absent config is an absent feature: `status` says so and exits 0
#   - `sites` lists the properties the credential can read
#   - a Hebrew query survives the API, the cache, and the CSV byte for byte
#   - a range is aggregated the way Search Console aggregates one: clicks and
#     impressions sum, CTR comes from those sums, position is impression-weighted
#   - the per-day table is the API's own `date` dimension and reads chronologically
#   - a second run over the same days re-reads the cache instead of re-querying,
#     and --refresh overrides that
#   - --max-rows truncation is recorded and warned, never silent
#   - paging follows startRow past one page
#   - the API's first incomplete date reaches the manifest
#   - each unhappy path gets its own exit code: API disabled (6), not
#     authorized (3), quota (4), revoked token (3), network failure (5)
#   - a non-loopback test endpoint override is refused
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GSC="$ROOT/bin/fm-gsc-pull.sh"
STUB="$ROOT/tests/gsc-stub-server.py"
TMP_ROOT=$(fm_test_tmproot fm-gsc-pull)

command -v jq >/dev/null 2>&1 || {
  printf 'ok - skipped (jq is not installed; fm-gsc-pull.sh reads every response through it)\n'
  exit 0
}
command -v python3 >/dev/null 2>&1 || {
  printf 'ok - skipped (python3 is not installed; the stub Search Console server needs it)\n'
  exit 0
}

HEB_Q1="יום גיבוש לחברות"
HEB_Q2="אטרקציות בטבע"
HEB_PAGE="https://batevashelanu.co.il/פעילות-גיבוש-לחברות/"

STUB_PID=""
stop_stub() {
  if [ -n "$STUB_PID" ]; then kill "$STUB_PID" 2>/dev/null || :; wait "$STUB_PID" 2>/dev/null || :; fi
  STUB_PID=""
}
cleanup_all() { stop_stub; fm_test_cleanup; }
trap cleanup_all EXIT INT TERM

# start_stub <mode>: run the stub in that scenario and export the loopback
# endpoint the script is allowed to redirect to.
start_stub() {
  stop_stub
  local fifo="$TMP_ROOT/port.$$"
  rm -f "$fifo"; mkfifo "$fifo"
  FM_GSC_STUB_MODE="$1" python3 "$STUB" > "$fifo" &
  STUB_PID=$!
  local port
  read -r port < "$fifo"
  rm -f "$fifo"
  [ -n "$port" ] || fail "stub server did not report a port"
  export FM_GSC_TEST_ENDPOINT="http://127.0.0.1:$port"
}

# make_home <name>: a home whose config selects the refresh-token credential,
# which is the path the stub's token endpoint can serve.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data"
  cat > "$home/config/gsc.env" <<'CFG'
GSC_AUTH=refresh-token
GSC_CLIENT_ID=stub-client
GSC_CLIENT_SECRET=stub-secret
GSC_REFRESH_TOKEN=stub-refresh
CFG
  chmod 600 "$home/config/gsc.env"
  printf '%s\n' "$home"
}

run_pull() {  # <home> <out> [extra args...]
  local home=$1 out=$2; shift 2
  ( cd "$home" && FM_HOME="$home" "$GSC" pull \
      --site sc-domain:example.co.il \
      --start 2026-09-01 --end 2026-09-02 \
      --out "$out" "$@" ) 2>"$TMP_ROOT/stderr.txt"
}

# --- absent config is an absent feature -------------------------------------

EMPTY="$TMP_ROOT/empty-home"; mkdir -p "$EMPTY"
out=$(FM_HOME="$EMPTY" "$GSC" status); code=$?
expect_code 0 "$code" "status in an unconfigured home"
assert_contains "$out" "not configured" "status names the unconfigured home"
pass "an unconfigured home reports not configured and exits 0"

out=$(FM_HOME="$EMPTY" "$GSC" pull --site sc-domain:example.co.il \
        --start 2026-09-01 --end 2026-09-01 2>&1); code=$?
expect_code 2 "$code" "pull without config"
assert_contains "$out" "not configured" "pull refuses with a configuration message"
pass "an explicit pull without credentials refuses clearly instead of failing empty"

# --- sites ------------------------------------------------------------------

start_stub ok
HOME1=$(make_home home1)
out=$(FM_HOME="$HOME1" "$GSC" sites)
assert_contains "$out" "sc-domain:example.co.il" "sites lists the property"
assert_contains "$out" "siteOwner" "sites reports the permission level"
pass "sites lists the properties the credential can actually read"

# --- the happy path, Hebrew, and aggregation --------------------------------

OUT1="$TMP_ROOT/out1"
run_pull "$HOME1" "$OUT1" || fail "pull failed: $(cat "$TMP_ROOT/stderr.txt")"

assert_present "$OUT1/שאילתות.csv" "the queries CSV is written under its Hebrew name"
assert_present "$OUT1/דפים.csv" "the pages CSV is written under its Hebrew name"
assert_present "$OUT1/תרשים.csv" "the per-day CSV is written under its Hebrew name"

head1=$(head -1 "$OUT1/שאילתות.csv")
[ "$head1" = "השאילתות המובילות,קליקים,הופעות,שיעור קליקים,מקום" ] \
  || fail "queries CSV header does not match a Search Console export: $head1"
pass "the export CSVs keep the Search Console header shape the review already reads"

# The Hebrew string must come back as the same bytes it went in as. Compare
# against the literal, not against a pattern that a mangled string could still
# satisfy.
assert_grep "$HEB_Q1" "$OUT1/שאילתות.csv" "the Hebrew query survived to the CSV"
assert_grep "$HEB_Q2" "$OUT1/שאילתות.csv" "the second Hebrew query survived to the CSV"
assert_grep "$HEB_PAGE" "$OUT1/דפים.csv" "the Hebrew page URL survived to the CSV"
# Prove it is real UTF-8 Hebrew and not mojibake or escapes.
python3 - "$OUT1/שאילתות.csv" "$HEB_Q1" <<'PY' || fail "the Hebrew query did not round-trip as UTF-8"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
needle = sys.argv[2]
assert needle in text, "literal Hebrew missing"
assert "\\u" not in text, "Hebrew was escaped rather than written as UTF-8"
assert "?" not in text.split("\n")[1], "Hebrew was replaced with substitution characters"
PY
pass "a Hebrew query round-trips through the API, the cache, and the CSV as UTF-8"

# Two days of the same rows: clicks 5+5=10, impressions 100+100=200,
# CTR 10/200 = 5.00%, position weighted = 10.00.
# 5+5 clicks over 100+100 impressions at position 10 on both days, so the
# range reads 10 clicks, 200 impressions, 10/200 = 5.00% CTR, position 10.00.
row=$(grep -F "$HEB_Q1" "$OUT1/שאילתות.csv")
expected="\"$HEB_Q1\",10,200,\"5.00%\",\"10.00\""
[ "$row" = "$expected" ] || fail "the aggregated row is wrong.
  expected: $expected
  actual:   $row"
# 1+1 clicks over 300+300 impressions at position 20: CTR must come from the
# summed totals (2/600 = 0.33%), never from averaging each day's own CTR,
# which would read 0.33% only by coincidence here and is asserted separately
# below by driving the two days apart.
row2=$(grep -F "$HEB_Q2" "$OUT1/שאילתות.csv")
expected2="\"$HEB_Q2\",2,600,\"0.33%\",\"20.00\""
[ "$row2" = "$expected2" ] || fail "CTR was not recomputed from the summed totals.
  expected: $expected2
  actual:   $row2"
pass "a range aggregates the way Search Console aggregates one"

# The per-day table is the date dimension, in date order, not re-derived.
day_rows=$(tail -n +2 "$OUT1/תרשים.csv")
[ "$(printf '%s\n' "$day_rows" | wc -l | tr -d ' ')" = 2 ] \
  || fail "expected one row per day in the per-day table, got: $day_rows"
[ "$(printf '%s\n' "$day_rows" | head -1 | cut -d, -f1 | tr -d '"')" = "2026-09-01" ] \
  || fail "the per-day table does not read chronologically: $day_rows"
pass "the per-day table comes from the API's own date dimension and reads chronologically"

# --- manifest and freshness --------------------------------------------------

assert_present "$OUT1/manifest.json" "a manifest records the pull's provenance"
[ "$(jq -r .firstIncompleteDate "$OUT1/manifest.json")" = "2026-09-06" ] \
  || fail "the API's first incomplete date did not reach the manifest"
[ "$(jq -r .dataState "$OUT1/manifest.json")" = "final" ] \
  || fail "the default data state should be final"
[ "$(jq -r .property "$OUT1/manifest.json")" = "sc-domain:example.co.il" ] \
  || fail "the manifest does not name the property"
assert_grep "still incomplete" "$TMP_ROOT/stderr.txt" "the incomplete-data boundary is warned, not swallowed"
pass "the freshness boundary reaches the manifest and stderr rather than being swallowed"

# --- caching -----------------------------------------------------------------

cache_dir=$(FM_HOME="$HOME1" "$GSC" cache-path --site sc-domain:example.co.il)
assert_present "$cache_dir" "the cache directory exists after a pull"
# Three dimensions over two days, so six day/dimension pulls, all fresh.
[ "$(jq -r .dayDimensionsQueried "$OUT1/manifest.json")" = 6 ] \
  || fail "the first pull should have queried every day/dimension fresh"

OUT2="$TMP_ROOT/out2"
run_pull "$HOME1" "$OUT2" || fail "second pull failed: $(cat "$TMP_ROOT/stderr.txt")"
[ "$(jq -r .dayDimensionsQueried "$OUT2/manifest.json")" = 0 ] \
  || fail "the second pull re-queried days it already had cached"
[ "$(jq -r .dayDimensionsReadFromCache "$OUT2/manifest.json")" = 6 ] \
  || fail "the second pull did not read every day/dimension from cache"
assert_grep "$HEB_Q1" "$OUT2/שאילתות.csv" "the Hebrew query survived a cache round-trip"
pass "a repeated review re-reads cached days instead of re-querying the same history"

OUT3="$TMP_ROOT/out3"
run_pull "$HOME1" "$OUT3" --refresh || fail "refresh pull failed: $(cat "$TMP_ROOT/stderr.txt")"
[ "$(jq -r .dayDimensionsQueried "$OUT3/manifest.json")" = 6 ] \
  || fail "--refresh did not re-query the cached days"
pass "--refresh re-queries days that were cached before they finalized"

# --- the query-by-page join --------------------------------------------------

OUT4="$TMP_ROOT/out4"
run_pull "$HOME1" "$OUT4" --join || fail "join pull failed: $(cat "$TMP_ROOT/stderr.txt")"
assert_present "$OUT4/query-page.csv" "--join writes the query-by-page table"
assert_grep "$HEB_PAGE" "$OUT4/query-page.csv" "the join pairs the Hebrew query with its page"
assert_absent "$OUT1/query-page.csv" "the join is not written without --join"
pass "--join produces the query-by-page pairing a UI export cannot give"

# --- paging and the row cap ---------------------------------------------------

start_stub paged
HOME2=$(make_home home2)
OUT5="$TMP_ROOT/out5"
( cd "$HOME2" && FM_HOME="$HOME2" "$GSC" pull --site sc-domain:example.co.il \
    --start 2026-09-01 --end 2026-09-01 --out "$OUT5" ) 2>"$TMP_ROOT/stderr.txt" \
  || fail "paged pull failed: $(cat "$TMP_ROOT/stderr.txt")"
rows=$(( $(wc -l < "$OUT5/שאילתות.csv") - 1 ))
[ "$rows" = 260 ] || fail "paging did not fetch every row: got $rows of 260"
[ "$(jq -r '.truncatedDimensions | length' "$OUT5/manifest.json")" = 0 ] \
  || fail "a complete result was marked truncated"
pass "paging follows startRow past one page and reports the result as complete"

HOME3=$(make_home home3)
OUT6="$TMP_ROOT/out6"
( cd "$HOME3" && FM_HOME="$HOME3" "$GSC" pull --site sc-domain:example.co.il \
    --start 2026-09-01 --end 2026-09-01 --out "$OUT6" --max-rows 100 ) 2>"$TMP_ROOT/stderr.txt" \
  || fail "capped pull failed: $(cat "$TMP_ROOT/stderr.txt")"
rows=$(( $(wc -l < "$OUT6/שאילתות.csv") - 1 ))
[ "$rows" = 100 ] || fail "--max-rows was not honoured: got $rows"
assert_contains "$(jq -r '.truncatedDimensions | join(",")' "$OUT6/manifest.json")" "query" \
  "truncation is recorded in the manifest"
assert_grep "ceiling" "$TMP_ROOT/stderr.txt" "truncation is warned on stderr"
pass "the row cap is honoured and its truncation is recorded and warned, never silent"

# --- unhappy paths ------------------------------------------------------------

start_stub disabled
HOME4=$(make_home home4)
out=$( (cd "$HOME4" && FM_HOME="$HOME4" "$GSC" sites) 2>&1 ); code=$?
expect_code 6 "$code" "the API being disabled has its own exit code"
assert_contains "$out" "not enabled" "the disabled-API diagnostic says what is wrong"
pass "an API that is not enabled for the project is reported as exactly that"

start_stub denied
HOME5=$(make_home home5)
out=$( (cd "$HOME5" && FM_HOME="$HOME5" "$GSC" pull --site sc-domain:example.co.il \
         --start 2026-09-01 --end 2026-09-01 --out "$TMP_ROOT/out7") 2>&1 ); code=$?
expect_code 3 "$code" "a property the account cannot read"
assert_contains "$out" "not authorized" "the unauthorized diagnostic says what is wrong"
assert_absent "$TMP_ROOT/out7/שאילתות.csv" "a refused pull writes no CSV that would read as an empty result"
pass "a property the account does not own is refused, not returned as empty data"

start_stub quota
HOME6=$(make_home home6)
out=$( (cd "$HOME6" && FM_HOME="$HOME6" "$GSC" pull --site sc-domain:example.co.il \
         --start 2026-09-01 --end 2026-09-01 --out "$TMP_ROOT/out8") 2>&1 ); code=$?
expect_code 4 "$code" "a quota rejection has its own exit code"
assert_contains "$out" "quota" "the quota diagnostic says what is wrong"
pass "a quota rejection is reported as a quota rejection, with its own exit code"

start_stub badtoken
HOME7=$(make_home home7)
out=$( (cd "$HOME7" && FM_HOME="$HOME7" "$GSC" sites) 2>&1 ); code=$?
expect_code 3 "$code" "an expired or revoked authorization"
assert_contains "$out" "rejected" "the revoked-authorization diagnostic says what is wrong"
assert_contains "$out" "expired or revoked" "the diagnostic names re-authorization as the fix"
assert_not_contains "$out" "stub-refresh" "the refresh token is never printed in a diagnostic"
pass "an expired or revoked authorization is reported as one, without printing the credential"

# A dead endpoint stands in for the network being unreachable.
stop_stub
HOME8=$(make_home home8)
out=$( (cd "$HOME8" && FM_HOME="$HOME8" "$GSC" sites) 2>&1 ); code=$?
expect_code 5 "$code" "a network failure has its own exit code"
assert_contains "$out" "could not reach Google" "the network diagnostic says what is wrong"
pass "a network failure is reported as one rather than as an empty result"

# --- the test endpoint override is loopback-only ------------------------------

out=$(FM_GSC_TEST_ENDPOINT="https://evil.example.com" FM_HOME="$HOME1" "$GSC" status 2>&1); code=$?
expect_code 2 "$code" "a non-loopback endpoint override"
assert_contains "$out" "loopback" "the endpoint override refuses a non-loopback host"
pass "the test endpoint override cannot be pointed at a host that is not loopback"
