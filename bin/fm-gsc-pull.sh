#!/usr/bin/env bash
# fm-gsc-pull.sh - read-only Google Search Console pull, written to the same
# on-disk export shape the recurring SEO review already reads.
#
# This is a producer, not an analysis layer. The `seo-review` skill owns the
# review procedure and the target-term lists; this script only replaces the
# manual "export" click in the Search Console web UI with a deterministic
# call, so query strings arrive as UTF-8 data rather than as something read
# off a screenshot.
#
# READ-ONLY BY CONSTRUCTION: the only Search Console endpoints reached are
# `sites.list` and `searchanalytics.query`, both GET/POST reads. Nothing here
# submits a sitemap, requests indexing, or changes any property state.
#
# Absent credentials mean an absent feature. Nothing calls this script from
# the session-start path, so a home with no config/gsc.env behaves exactly as
# it did before this script existed: no warning, no failure, no output.
#
# Usage:
#   fm-gsc-pull.sh status
#       Say whether this home is configured, without making a network call.
#       Prints `not configured` and exits 0 when config/gsc.env is absent, so
#       a caller can branch on the feature without treating absence as an
#       error. Never prints a credential.
#
#   fm-gsc-pull.sh sites
#       List the properties the configured credential can actually read, as
#       `<permissionLevel><TAB><siteUrl>`. This is the check to run first
#       after the captain grants access: a property missing from this list is
#       one the credential cannot see, whatever the console shows.
#
#   fm-gsc-pull.sh pull --site <property> --start <YYYY-MM-DD> --end <YYYY-MM-DD>
#                       [--out <dir>] [--data-state final|all]
#                       [--max-rows <n>] [--config <file>] [--refresh]
#       Pull search analytics for one property and write an export directory.
#       --site takes the property exactly as Search Console names it, such as
#       `sc-domain:clickbateva.co.il`; run `sites` to see the exact strings.
#       --out defaults to `gsc-<end-date>` under the current directory.
#
#   fm-gsc-pull.sh cache-path --site <property>
#       Print the cache directory used for that property, so a review can say
#       where its history lives. Makes no network call.
#
# Output directory contents:
#   שאילתות.csv   top queries      - header `השאילתות המובילות,קליקים,הופעות,שיעור קליקים,מקום`
#   דפים.csv      top pages        - header `הדפים המובילים,קליקים,הופעות,שיעור קליקים,מקום`
#   תרשים.csv     per-day totals   - header `תאריך,קליקים,הופעות,שיעור קליקים,מקום`
#   manifest.json   provenance: property, range, data state, row counts,
#                   whether any dimension hit --max-rows, and the API's own
#                   first_incomplete_date when it reported one.
# The three Hebrew-named CSVs match the column order and the `NN.NN%` /
# `NN.NN` formatting of a Search Console UI export, so the review's existing
# reader needs no change. Device and country tables are deliberately NOT
# produced: the API returns `MOBILE` and `isr` where the UI export returns
# `נייד` and `ישראל`, and inventing that translation here would put made-up
# vocabulary into a file the review reads as if it came from Google.
#
# Freshness. Search Console data is incomplete for roughly the last two to
# three days. `--data-state final` is the default and asks Google for
# finalized data only, so a review never reports a still-moving day as
# settled. `--data-state all` includes fresh data and is recorded as such in
# manifest.json; whenever the API reports a first incomplete date, that date
# is carried into the manifest and printed on stderr rather than swallowed.
#
# Cost and the row cap. A pull asks for one day at a time, which is what
# Google recommends over long ranges, and caches each day's rows under
# `data/gsc-cache/`, so re-running a review over an overlapping range re-reads
# disk instead of re-querying history. Pass `--refresh` to re-query days
# already cached (needed only when a day was first pulled before it
# finalized). Each day/dimension is paged with `rowLimit` 25000 - the
# documented per-request maximum - and stops at `--max-rows` (default 25000)
# per dimension per day. On reaching that ceiling one more row is requested to
# settle whether anything was actually left behind - a result of exactly
# `--max-rows` rows is complete - and only a real overflow is recorded as
# `truncated` in the manifest and warned on stderr, never silently dropped. The cache is
# keyed by that cap too, so a day first pulled under a low `--max-rows` is
# never re-served as if it were the full set under a higher one.
#
# A range is composed from those cached daily pulls: clicks and impressions
# sum, CTR is recomputed as clicks/impressions, and position is averaged
# weighted by impressions, which is how Search Console itself combines a
# range.
#
# Credentials live in config/gsc.env (gitignored, like every other local
# operating choice) and are never printed, logged, written into an export, or
# passed on a command line where `ps` could read them. See docs/configuration.md
# "Search Console pull (config/gsc.env)" for the setup the captain performs
# once and for the exact contents of that file.
#
# Exit codes: 0 success; 2 usage or configuration refusal; 3 authorization
# expired, revoked, or never granted for this property; 4 quota rejected;
# 5 network failure; 6 Search Console API not enabled for the project.

set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_HOME=${FM_HOME:-$(cd -- "$SELF_DIR/.." && pwd -P)}
CONFIG_FILE=${FM_GSC_CONFIG:-$FM_HOME/config/gsc.env}

API_BASE=https://searchconsole.googleapis.com/webmasters/v3
OAUTH_TOKEN_URL=https://oauth2.googleapis.com/token

# Test-only endpoint redirection, used by tests/fm-gsc-pull.test.sh to drive
# the paging, aggregation, and error-classification logic against a local
# stub. Only one shape is accepted - the whole value, anchored end to end, must
# be `http://` then the literal 127.0.0.1, localhost or [::1], then a colon and
# a port. Nothing may follow the port: no userinfo, path, query or fragment.
# Matching a prefix says nothing about the host curl finally resolves, so no
# spelling is enumerated as bad; anything but that one form is refused, and no
# setting of this variable can send a live credential to another host.
if [ -n "${FM_GSC_TEST_ENDPOINT:-}" ]; then
  if [[ ! $FM_GSC_TEST_ENDPOINT =~ ^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+$ ]]; then
    printf 'fm-gsc-pull: FM_GSC_TEST_ENDPOINT must be exactly http://<loopback-host>:<port>\n' >&2
    exit 2
  fi
  API_BASE="$FM_GSC_TEST_ENDPOINT/webmasters/v3"
  OAUTH_TOKEN_URL="$FM_GSC_TEST_ENDPOINT/token"
fi
SCOPE=https://www.googleapis.com/auth/webmasters.readonly
# The documented per-request maximum for searchAnalytics.query.
PAGE_LIMIT=25000
# The recurring SEO review is about web search; no other search type is pulled.
SEARCH_TYPE=web

die() { printf 'fm-gsc-pull: %s\n' "$1" >&2; exit "${2:-2}"; }
warn() { printf 'fm-gsc-pull: %s\n' "$1" >&2; }

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
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

# Days since the civil epoch, so two dates subtract without either platform's
# `date` dialect. Same construction as bin/fm-jobs.sh.
day_number() {  # <YYYY-MM-DD>
  awk -v d="$1" 'BEGIN {
    y = substr(d, 1, 4) + 0; m = substr(d, 6, 2) + 0; dd = substr(d, 9, 2) + 0
    if (m <= 2) { y -= 1; m += 12 }
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m - 3) + 2) / 5) + dd - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    print era * 146097 + doe
  }'
}

# Inverse of day_number, so a range can be walked one day at a time.
day_date() {  # <day-number>
  awk -v z="$1" 'BEGIN {
    # day_number counts from the era origin, not from the Unix epoch, so this
    # inverse must not re-apply the 719468-day epoch shift.
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe/1460) + int(doe/36524) - int(doe/146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe/4) - int(yoe/100))
    mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1
    m = mp + (mp < 10 ? 3 : -9)
    if (m <= 2) y += 1
    printf "%04d-%02d-%02d\n", y, m, d
  }'
}

site_slug() {  # <property> -> a filesystem-safe directory name
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# ── Configuration ───────────────────────────────────────────────────────

load_config() {
  [ -f "$CONFIG_FILE" ] || return 1
  # Read as data, not as script: only NAME=VALUE lines are honoured, so a
  # stray line in a credential file can never execute.
  local line name value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    name=${line%%=*}
    value=${line#*=}
    name=${name#"${name%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    case "$name" in
      GSC_AUTH|GSC_SA_ACCOUNT|GSC_CLIENT_ID|GSC_CLIENT_SECRET|GSC_REFRESH_TOKEN) ;;
      *) continue ;;
    esac
    # Strip one layer of matching quotes, as an env file usually carries.
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf -v "$name" '%s' "$value"
  done < "$CONFIG_FILE"
  GSC_AUTH=${GSC_AUTH:-gcloud-sa}
  return 0
}

# ── Access token ────────────────────────────────────────────────────────
# The token is held in a shell variable and written only into a mode-600
# curl config file. It is never echoed, never passed as an argument, and
# never reaches a log or an export.

TOKEN=""

mint_token() {
  case "$GSC_AUTH" in
    gcloud-sa)
      [ -n "${GSC_SA_ACCOUNT:-}" ] || die "GSC_AUTH=gcloud-sa needs GSC_SA_ACCOUNT in $CONFIG_FILE"
      need_tool gcloud
      local out
      if ! out=$(gcloud auth print-access-token \
            --account="$GSC_SA_ACCOUNT" --scopes="$SCOPE" 2>&1); then
        # gcloud's own diagnostic is the useful one; it names a revoked or
        # never-authorized service account explicitly.
        printf 'fm-gsc-pull: could not mint an access token for %s\n' "$GSC_SA_ACCOUNT" >&2
        printf '%s\n' "$out" >&2
        exit 3
      fi
      TOKEN=$out
      ;;
    refresh-token)
      for v in GSC_CLIENT_ID GSC_CLIENT_SECRET GSC_REFRESH_TOKEN; do
        [ -n "${!v:-}" ] || die "GSC_AUTH=refresh-token needs $v in $CONFIG_FILE"
      done
      need_tool curl
      local body status
      local form
      form=$(mktemp); chmod 600 "$form"
      # The secret goes through a file, never through argv.
      {
        printf 'data-urlencode = "client_id=%s"\n' "$GSC_CLIENT_ID"
        printf 'data-urlencode = "client_secret=%s"\n' "$GSC_CLIENT_SECRET"
        printf 'data-urlencode = "refresh_token=%s"\n' "$GSC_REFRESH_TOKEN"
        printf 'data-urlencode = "grant_type=refresh_token"\n'
      } > "$form"
      if ! body=$(curl -sS --config "$form" -w '\n%{http_code}' \
            --max-time 60 "$OAUTH_TOKEN_URL" 2>&1); then
        rm -f "$form"
        printf 'fm-gsc-pull: could not reach Google to refresh the access token\n' >&2
        printf '%s\n' "$body" >&2
        exit 5
      fi
      rm -f "$form"
      status=${body##*$'\n'}
      body=${body%$'\n'*}
      if [ "$status" != 200 ]; then
        # invalid_grant is the signal that the captain revoked access or the
        # token aged out; say so instead of reporting an empty result.
        printf 'fm-gsc-pull: the stored authorization was rejected (HTTP %s).\n' "$status" >&2
        printf 'Re-authorize and replace GSC_REFRESH_TOKEN in %s.\n' "$CONFIG_FILE" >&2
        printf '%s\n' "$(printf '%s' "$body" | jq -r '.error_description // .error // empty' 2>/dev/null)" >&2
        exit 3
      fi
      TOKEN=$(printf '%s' "$body" | jq -r '.access_token // empty')
      [ -n "$TOKEN" ] || die "Google returned no access token" 3
      ;;
    *)
      die "unknown GSC_AUTH '$GSC_AUTH' in $CONFIG_FILE (expected gcloud-sa or refresh-token)"
      ;;
  esac
}

CURL_CFG=""
# Must end in a success status: this runs on EXIT, where a failing last
# command would silently become the script's exit code.
cleanup() { if [ -n "$CURL_CFG" ]; then rm -f "$CURL_CFG"; fi; return 0; }
trap cleanup EXIT

auth_config_file() {
  if [ -z "$CURL_CFG" ]; then
    CURL_CFG=$(mktemp)
    chmod 600 "$CURL_CFG"
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$CURL_CFG"
  fi
  printf '%s' "$CURL_CFG"
}

# Perform one API call and classify every failure mode explicitly. Prints the
# response body on stdout; exits with the code the failure deserves.
api_call() {  # <method> <url> [<json-body>]
  local method=$1 url=$2 payload=${3:-}
  local cfg out status body
  cfg=$(auth_config_file)
  local -a args=(-sS --config "$cfg" -w '\n%{http_code}' --max-time 120 -X "$method" "$url")
  if [ -n "$payload" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$payload")
  fi
  if ! out=$(curl "${args[@]}" 2>&1); then
    printf 'fm-gsc-pull: network failure reaching the Search Console API.\n' >&2
    printf '%s\n' "$out" >&2
    exit 5
  fi
  status=${out##*$'\n'}
  body=${out%$'\n'*}
  case "$status" in
    200) printf '%s' "$body"; return 0 ;;
  esac

  local reason message
  reason=$(printf '%s' "$body" | jq -r '.error.details[]?.reason // .error.errors[0].reason // empty' 2>/dev/null | head -1)
  message=$(printf '%s' "$body" | jq -r '.error.message // empty' 2>/dev/null)
  [ -n "$message" ] || message=$body

  case "$status:$reason" in
    403:SERVICE_DISABLED|403:accessNotConfigured)
      printf 'fm-gsc-pull: the Search Console API is not enabled for this Google Cloud project.\n' >&2
      printf '%s\n' "$message" >&2
      exit 6
      ;;
    429:*|403:rateLimitExceeded|403:quotaExceeded|403:userRateLimitExceeded|403:dailyLimitExceeded|403:RESOURCE_EXHAUSTED)
      # Quota must be matched before the general 403 below, or a rate-limit
      # rejection would be reported as a revoked authorization.
      printf 'fm-gsc-pull: Search Console rejected the request for exceeding a quota.\n' >&2
      printf '%s\n' "$message" >&2
      exit 4
      ;;
    401:*|403:*)
      printf 'fm-gsc-pull: the credential is not authorized for this request.\n' >&2
      printf 'Either the authorization expired or was revoked, or this account is not a user on the property.\n' >&2
      printf '%s\n' "$message" >&2
      exit 3
      ;;
  esac
  printf 'fm-gsc-pull: Search Console returned HTTP %s.\n' "$status" >&2
  printf '%s\n' "$message" >&2
  exit 3
}

# ── Search analytics ────────────────────────────────────────────────────

# One dimension set, one date range, paged to completion or to max_rows.
# Emits a JSON object: {rows:[...], truncated:bool, firstIncompleteDate:string|null}
query_rows() {  # <property> <start> <end> <dimensions-json> <data-state> <max-rows>
  local site=$1 start=$2 end=$3 dims=$4 state=$5 max=$6
  local url start_row=0 total_rows=0 truncated=false hit_cap=false first_incomplete=null aggregation=null
  local acc='[]' payload page page_rows page_count want
  url="$API_BASE/sites/$(jq -rn --arg s "$site" '$s|@uri')/searchAnalytics/query"

  while :; do
    want=$(( max - total_rows ))
    [ "$want" -gt "$PAGE_LIMIT" ] && want=$PAGE_LIMIT
    if [ "$want" -le 0 ]; then hit_cap=true; break; fi
    payload=$(jq -cn \
      --arg start "$start" --arg end "$end" --arg type "$SEARCH_TYPE" --arg state "$state" \
      --argjson dims "$dims" --argjson limit "$want" --argjson startRow "$start_row" \
      '{startDate:$start, endDate:$end, dimensions:$dims, type:$type,
        dataState:$state, rowLimit:$limit, startRow:$startRow}')
    # `exit` inside a command substitution ends only that subshell, so the
    # failure code has to be carried out by hand at every nesting level or an
    # API error would come back as an empty page and loop forever.
    page=$(api_call POST "$url" "$payload") || exit $?
    page_rows=$(printf '%s' "$page" | jq -c '.rows // []')
    page_count=$(printf '%s' "$page_rows" | jq 'length')
    case "$page_count" in
      ''|*[!0-9]*) die "unreadable row count in the Search Console response" 3 ;;
    esac
    if [ "$first_incomplete" = null ]; then
      first_incomplete=$(printf '%s' "$page" | jq -c '.metadata.first_incomplete_date // .metadata.firstIncompleteDate // null')
    fi
    if [ "$aggregation" = null ]; then
      aggregation=$(printf '%s' "$page" | jq -c '.responseAggregationType // null')
    fi
    acc=$(jq -cn --argjson a "$acc" --argjson b "$page_rows" '$a + $b')
    total_rows=$(( total_rows + page_count ))
    # A short page means the result set is exhausted.
    [ "$page_count" -lt "$want" ] && break
    start_row=$(( start_row + page_count ))
    if [ "$total_rows" -ge "$max" ]; then hit_cap=true; break; fi
  done

  # Reaching the cap is not itself evidence that rows were dropped: a result
  # set of exactly max rows is complete. Ask for the row after the cap and
  # call the dimension truncated only if one comes back.
  if [ "$hit_cap" = true ]; then
    payload=$(jq -cn \
      --arg start "$start" --arg end "$end" --arg type "$SEARCH_TYPE" --arg state "$state" \
      --argjson dims "$dims" --argjson startRow "$max" \
      '{startDate:$start, endDate:$end, dimensions:$dims, type:$type,
        dataState:$state, rowLimit:1, startRow:$startRow}')
    page=$(api_call POST "$url" "$payload") || exit $?
    page_count=$(printf '%s' "$page" | jq '.rows // [] | length')
    case "$page_count" in
      ''|*[!0-9]*) die "unreadable row count in the Search Console response" 3 ;;
    esac
    if [ "$page_count" -gt 0 ]; then truncated=true; fi
  fi

  jq -cn --argjson rows "$acc" --argjson t "$truncated" --argjson f "$first_incomplete" \
    --argjson a "$aggregation" \
    '{rows:$rows, truncated:$t, firstIncompleteDate:$f, aggregation:$a}'
}

# ── Aggregation and rendering ───────────────────────────────────────────

# Combine many per-day result objects into one ranked table the way Search
# Console combines a range: clicks and impressions sum, CTR is recomputed from
# those sums, and position is averaged weighted by impressions.
aggregate() {  # reads a stream of {rows:[...]} objects on stdin
  jq -s '
    [ .[].rows[] ]
    | group_by(.keys)
    | map({
        keys: .[0].keys,
        clicks: (map(.clicks) | add),
        impressions: (map(.impressions) | add),
        posWeighted: (map(.position * .impressions) | add)
      })
    | map(. + {
        ctr: (if .impressions > 0 then .clicks / .impressions else 0 end),
        position: (if .impressions > 0 then .posWeighted / .impressions else 0 end)
      })
    | sort_by(-.clicks, -.impressions)
  '
}

# Two fixed decimal places, the way a Search Console export writes a
# percentage. jq has no width-aware formatter, so the integer and fractional
# halves are composed by hand; every value here is non-negative.
# shellcheck disable=SC2016  # jq program text; $n/$i/$f are jq bindings
JQ_FMT='def fmt2: (. * 100 | round) as $n | ($n / 100 | floor) as $i
  | ($n - $i * 100) as $f
  | "\($i).\(if $f < 10 then "0" else "" end)\($f)";
'

# Render a ranked table as a Search Console style CSV. The key column keeps
# the API string byte for byte, so a Hebrew query survives as the UTF-8 it
# arrived as; jq's @csv does the quoting.
render_csv() {  # <header-first-column> ; reads the aggregated array on stdin
  local first=$1
  {
    printf '%s,קליקים,הופעות,שיעור קליקים,מקום\n' "$first"
    jq -r "$JQ_FMT"'
      .[] | [
        (.keys | join(" ")),
        (.clicks | round),
        (.impressions | round),
        ((.ctr * 100) | fmt2) + "%",
        (.position | fmt2)
      ] | @csv'
  }
}

# ── Commands ────────────────────────────────────────────────────────────

cmd_status() {
  if [ ! -f "$CONFIG_FILE" ]; then
    printf 'not configured\n'
    printf 'No %s, so the Search Console pull is off in this home.\n' "$CONFIG_FILE"
    printf 'See docs/configuration.md "Search Console pull (config/gsc.env)" to turn it on.\n'
    return 0
  fi
  load_config
  printf 'configured\n'
  printf 'config: %s\n' "$CONFIG_FILE"
  printf 'auth:   %s\n' "$GSC_AUTH"
  case "$GSC_AUTH" in
    gcloud-sa) printf 'account: %s\n' "${GSC_SA_ACCOUNT:-<unset>}" ;;
    refresh-token)
      # Report presence only. A credential is never printed.
      printf 'client id set: %s\n' "$([ -n "${GSC_CLIENT_ID:-}" ] && echo yes || echo no)"
      printf 'refresh token set: %s\n' "$([ -n "${GSC_REFRESH_TOKEN:-}" ] && echo yes || echo no)"
      ;;
  esac
  printf 'cache:  %s\n' "$FM_HOME/data/gsc-cache"
}

require_config() {
  load_config || die "no $CONFIG_FILE, so the Search Console pull is not configured in this home.
See docs/configuration.md \"Search Console pull (config/gsc.env)\"."
}

cmd_sites() {
  need_tool curl; need_tool jq
  require_config
  mint_token
  local body count
  body=$(api_call GET "$API_BASE/sites") || exit $?
  count=$(printf '%s' "$body" | jq '.siteEntry // [] | length')
  if [ "$count" = 0 ]; then
    # An authorized credential with no properties returns 200 and an empty
    # body. Printing nothing would be indistinguishable from a broken call,
    # so say which of the two this is.
    printf 'fm-gsc-pull: the credential works, but no Search Console property is shared with it yet.\n' >&2
    printf 'Add it as a user on the property (Settings > Users and permissions > Add user).\n' >&2
    return 0
  fi
  printf '%s' "$body" \
    | jq -r '.siteEntry | .[] | [.permissionLevel, .siteUrl] | @tsv'
}

cmd_cache_path() {
  local site=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --site) site=${2:-}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$site" ] || die "cache-path needs --site <property>"
  printf '%s/data/gsc-cache/%s\n' "$FM_HOME" "$(site_slug "$site")"
}

cmd_pull() {
  need_tool curl; need_tool jq; need_tool awk
  local site="" start="" end="" out="" state=final
  local max=$PAGE_LIMIT refresh=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --site) site=${2:-}; shift 2 ;;
      --start) start=${2:-}; shift 2 ;;
      --end) end=${2:-}; shift 2 ;;
      --out) out=${2:-}; shift 2 ;;
      --data-state) state=${2:-}; shift 2 ;;
      --max-rows) max=${2:-}; shift 2 ;;
      --config) CONFIG_FILE=${2:-}; shift 2 ;;
      --refresh) refresh=true; shift ;;
      *) die "unexpected argument: $1" ;;
    esac
  done

  [ -n "$site" ] || die "pull needs --site <property> (run 'sites' to list them)"
  date_valid "$start" || die "pull needs --start <YYYY-MM-DD>"
  date_valid "$end" || die "pull needs --end <YYYY-MM-DD>"
  case "$state" in final|all) ;; *) die "--data-state must be final or all" ;; esac
  case "$max" in ''|*[!0-9]*) die "--max-rows must be a positive integer" ;; esac
  [ "$max" -ge 1 ] || die "--max-rows must be at least 1"

  local d0 d1
  d0=$(day_number "$start"); d1=$(day_number "$end")
  [ "$d0" -le "$d1" ] || die "--start is after --end"

  require_config
  mint_token

  [ -n "$out" ] || out="gsc-$end"
  mkdir -p "$out"

  local cache_root
  # The cap is part of the key: a day pulled under a low --max-rows is a
  # top-N, not that day, and must not be re-served as if it were complete.
  cache_root="$FM_HOME/data/gsc-cache/$(site_slug "$site")/$SEARCH_TYPE/$state/max-$max"
  local first_incomplete=null truncated_dims=""
  local -a dim_keys=(query page date)

  # `date` is fetched as its own dimension so the per-day totals table is the
  # API's own answer rather than something re-derived from the query table,
  # which would be short by every anonymised row.
  dims_for() {
    case "$1" in
      query) printf '["query"]' ;;
      page) printf '["page"]' ;;
      date) printf '["date"]' ;;
    esac
  }

  local tmp; tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; cleanup" EXIT

  local dim day n result cache_file fresh_days=0 cached_days=0
  local aggregations='{}'
  for dim in "${dim_keys[@]}"; do
    : > "$tmp/$dim.ndjson"
    mkdir -p "$cache_root/$dim"
    for (( n = d0; n <= d1; n++ )); do
      day=$(day_date "$n")
      cache_file="$cache_root/$dim/$day.json"
      if [ -s "$cache_file" ] && [ "$refresh" = false ]; then
        cached_days=$(( cached_days + 1 ))
      else
        result=$(query_rows "$site" "$day" "$day" "$(dims_for "$dim")" "$state" "$max") || exit $?
        # Write through a temp file so an interrupted run never leaves a
        # half-written day that a later run would trust as complete.
        printf '%s\n' "$result" > "$cache_file.partial"
        mv "$cache_file.partial" "$cache_file"
        fresh_days=$(( fresh_days + 1 ))
      fi
      cat "$cache_file" >> "$tmp/$dim.ndjson"
      printf '\n' >> "$tmp/$dim.ndjson"
    done
    if [ "$(jq -se '[.[] | select(.truncated)] | length' < "$tmp/$dim.ndjson")" -gt 0 ]; then
      truncated_dims="$truncated_dims $dim"
      warn "$dim hit the --max-rows ceiling of $max; the table is a top-N, not the full set"
    fi
    if [ "$first_incomplete" = null ]; then
      first_incomplete=$(jq -sc '[.[] | .firstIncompleteDate | select(. != null)] | (sort | first) // null' < "$tmp/$dim.ndjson")
    fi
    # Google aggregates a page-dimension result byPage and the others
    # byProperty, so the page table's totals are NOT comparable with the query
    # or date tables'"'"'. Record which one produced each table rather than
    # leaving a reader to assume one property-wide baseline.
    aggregations=$(jq -c --arg d "$dim" \
      --argjson a "$(jq -sc '[.[] | .aggregation | select(. != null)] | first // null' < "$tmp/$dim.ndjson")" \
      '. + {($d): $a}' <<< "$aggregations")
  done

  aggregate < "$tmp/query.ndjson" > "$tmp/query.agg.json"
  aggregate < "$tmp/page.ndjson" > "$tmp/page.agg.json"
  aggregate < "$tmp/date.ndjson" > "$tmp/date.agg.json"

  render_csv 'השאילתות המובילות' < "$tmp/query.agg.json" > "$out/שאילתות.csv"
  render_csv 'הדפים המובילים' < "$tmp/page.agg.json" > "$out/דפים.csv"
  # The per-day table reads chronologically, not by clicks.
  jq 'sort_by(.keys[0])' < "$tmp/date.agg.json" \
    | render_csv 'תאריך' > "$out/תרשים.csv"

  if [ "$first_incomplete" != null ]; then
    warn "Search Console reports data from $(printf '%s' "$first_incomplete" | jq -r .) onward is still incomplete"
  fi

  jq -n \
    --arg site "$site" --arg start "$start" --arg end "$end" \
    --arg state "$state" --arg type "$SEARCH_TYPE" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg truncated "${truncated_dims# }" \
    --argjson maxRows "$max" \
    --argjson firstIncompleteDate "$first_incomplete" \
    --argjson aggregation "$aggregations" \
    --argjson freshDays "$fresh_days" --argjson cachedDays "$cached_days" \
    --argjson queryRows "$(jq length < "$tmp/query.agg.json")" \
    --argjson pageRows "$(jq length < "$tmp/page.agg.json")" \
    '{
      source: "Google Search Console API (searchAnalytics.query), read-only",
      property: $site, startDate: $start, endDate: $end,
      searchType: $type, dataState: $state,
      maxRowsPerDimension: $maxRows,
      truncatedDimensions: (if $truncated == "" then [] else ($truncated | split(" ")) end),
      firstIncompleteDate: $firstIncompleteDate,
      responseAggregationType: $aggregation,
      dayDimensionsQueried: $freshDays, dayDimensionsReadFromCache: $cachedDays,
      queryRows: $queryRows, pageRows: $pageRows,
      generatedAt: $generated
    }' > "$out/manifest.json"

  printf '%s\n' "$out"
}

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift || true
  case "$cmd" in
    status) cmd_status "$@" ;;
    sites) cmd_sites "$@" ;;
    pull) cmd_pull "$@" ;;
    cache-path) cmd_cache_path "$@" ;;
    -h|--help|help|'') usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
