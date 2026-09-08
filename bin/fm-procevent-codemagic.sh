#!/usr/bin/env bash
# Read-only Codemagic build-status process-event adapter.
#
# Usage:
#   fm-procevent-codemagic.sh arm <build-id> [--interval <secs>] [--request-timeout <secs>]
#   fm-procevent-codemagic.sh poll <build-id> [--interval <secs>] [--request-timeout <secs>]
#   fm-procevent-codemagic.sh classify <result-file>
#   fm-procevent-codemagic.sh terminal <result-file>
#   fm-procevent-codemagic.sh source-id <build-id>
#   fm-procevent-codemagic.sh retire <build-id>
#
# arm        Register a read-only poll of Codemagic's pinned v3 build endpoint.
#            The API token is read from config/codemagic.env in the effective
#            FM_HOME and is never placed in registration argv or output.
# poll       The blocking child the generic runner executes; never run this
#            directly in a conversational turn. It stops on any terminal build
#            status or explicit lookup failure, after a bounded quiet retry of
#            the transient request classes only (pre-response failure, HTTP 429,
#            any 5xx).
# classify   Print finished, post-processing-failed, failed, canceled, timeout,
#            skipped, auth-error, not-found, rate-limited, network-error,
#            api-error, action-detail-error, or schema-error.
# terminal   Every captured result is terminal and retires its source.
# source-id  Print the canonical process-event source id for a build.
# retire     Stop and retire the watch for the named build.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_FILE="$FM_HOME/config/codemagic.env"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_INTERVAL=30
DEFAULT_REQUEST_TIMEOUT=20
API_BASE=https://codemagic.io/api/v3
BUILD_ID=
SOURCE_ID=

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
positive_number() {
  local n=${1-} LC_ALL=C
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  [ "$n" != 0 ] && [[ ! "$n" =~ ^0+(\.0+)?$ ]]
}
positive_int() { case "${1-}" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }

resolve_build() {
  BUILD_ID=${1-}
  [ "${#BUILD_ID}" -ge 1 ] && [ "${#BUILD_ID}" -le 54 ] || die "invalid Codemagic build id"
  case "$BUILD_ID" in *[!A-Za-z0-9_-]*) die "invalid Codemagic build id" ;; esac
  SOURCE_ID="codemagic-$BUILD_ID"
  fm_procevent_source_id_valid "$SOURCE_ID" || die "Codemagic build id is not path-safe"
}

# Exit 1 means "no Codemagic configuration at all"; exit 2 means the file is
# there but unusable, which is a different operator action.
read_api_key() {
  local line extra
  [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 1
  IFS= read -r line < "$CONFIG_FILE" || true
  [ -n "$line" ] || return 2
  case "$line" in CODEMAGIC_API_TOKEN=?*) CODEMAGIC_API_TOKEN=${line#CODEMAGIC_API_TOKEN=} ;; *) return 2 ;; esac
  while IFS= read -r extra; do
    [ -z "$extra" ] || return 2
  done < <(sed -n '2,$p' "$CONFIG_FILE")
  case "$CODEMAGIC_API_TOKEN" in *[!A-Za-z0-9._-]*) return 2 ;; esac
  [ -n "$CODEMAGIC_API_TOKEN" ] || return 2
}

require_api_key() {
  local rc=0
  read_api_key || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) die "Codemagic build watching is not configured; write CODEMAGIC_API_TOKEN to $CONFIG_FILE" ;;
    *) die "$CONFIG_FILE is malformed; it must hold exactly one CODEMAGIC_API_TOKEN=<token> line whose token uses only [A-Za-z0-9._-]" ;;
  esac
}

emit_result() {
  printf 'build: %s\n' "$BUILD_ID"
  printf 'status: %s\n' "$1"
  printf 'detail: %s\n' "$2"
  printf 'api: v3 data.status\n'
  printf 'condition_polls: %s\n' "$3"
}

emit_build_result() {
  emit_result "$1" "$2" "$4"
  printf 'raw_status: %s\n' "$3"
  [ -z "${5-}" ] || printf 'failed_action: %s\n' "$5"
}

# Bounded quiet retry for the transient request classes only: a pre-response
# curl failure, HTTP 429, and any 5xx. The bound is a constant because it is a
# property of the transient response, not an operator choice; only the delay
# takes a bounded test override. Authentication rejection and a missing build
# stay immediate loud terminal outcomes.
POLL_RETRY_LIMIT=5
POLL_RETRY_DELAY_DEFAULT=5
POLL_RETRY_DELAY_MAX=60

poll_retry_delay() {
  local delay=${FM_CODEMAGIC_POLL_RETRY_DELAY-}
  if [ -z "$delay" ]; then
    printf '%s\n' "$POLL_RETRY_DELAY_DEFAULT"
    return 0
  fi
  case "$delay" in
    *[!0-9]*) die "FM_CODEMAGIC_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay" ;;
  esac
  [ "$delay" -le "$POLL_RETRY_DELAY_MAX" ] \
    || die "FM_CODEMAGIC_POLL_RETRY_DELAY must be whole seconds from 0 to $POLL_RETRY_DELAY_MAX: $delay"
  printf '%s\n' "$delay"
}

fetch_build() {
  local body=$1 key=$2 timeout=$3 url=${4:-$API_BASE/builds/$BUILD_ID} http_code
  http_code=$(printf 'header = "x-auth-token: %s"\n' "$key" |
    curl --silent --show-error --output "$body" --write-out '%{http_code}' \
      --connect-timeout "$timeout" --max-time "$timeout" --config - \
      "$url" 2>/dev/null) || return 10
  printf '%s\n' "$http_code"
}

emit_finished_result() {
  local build_body=$1 key=$2 timeout=$3 polls=$4 actions_body=$5 delay=$6 http_code failed_action app_store_status total_pages
  app_store_status=$(jq -r '.data.app_store_connect_status // ""' "$build_body" 2>/dev/null)
  if [ "$app_store_status" = failed ]; then
    emit_build_result post-processing-failed "Codemagic build finished, but App Store Connect post-processing failed" finished "$polls" app_store_connect
    return
  fi
  http_code=$(fetch_build_status "$actions_body" "$key" "$timeout" "$delay" "$API_BASE/builds/$BUILD_ID/actions?page_size=100&page=1")
  if [ "$http_code" = 000 ]; then
    emit_build_result action-detail-error "Codemagic build status is finished, but build actions could not be retrieved" finished "$polls"
    return
  fi
  if [ "$http_code" != 200 ]; then
    emit_build_result action-detail-error "Codemagic build status is finished, but build actions returned HTTP $http_code" finished "$polls"
    return
  fi
  total_pages=$(jq -er 'if (.total_pages | type) == "number" then .total_pages else error("missing total_pages") end' "$actions_body" 2>/dev/null) || {
    emit_build_result action-detail-error "Codemagic build status is finished, but the v3 actions response was invalid" finished "$polls"
    return
  }
  if [ "$total_pages" -gt 1 ]; then
    emit_build_result action-detail-error "Codemagic build status is finished, but more than 100 build actions require inspection" finished "$polls"
    return
  fi
  failed_action=$(jq -er '
    if (.data | type) != "array" then error("missing actions")
    else ([.data[] | select(.status == "failed")] | last) as $f
      | if $f == null then "" else ($f.type // $f.name // "unknown") end
    end
  ' "$actions_body" 2>/dev/null) || {
    emit_build_result action-detail-error "Codemagic build status is finished, but the v3 actions response was invalid" finished "$polls"
    return
  }
  if [ -n "$failed_action" ]; then
    emit_build_result post-processing-failed "Codemagic build finished, but its $failed_action action failed" finished "$polls" "$failed_action"
  else
    emit_build_result finished "Codemagic build completed successfully" finished "$polls"
  fi
}

# Print the HTTP code for one build request, or 000 when curl failed before an
# HTTP response, retrying the transient classes up to the bound.
fetch_build_status() {
  local body=$1 key=$2 timeout=$3 delay=$4 url=${5-} attempt=0 http_code
  while :; do
    http_code=$(fetch_build "$body" "$key" "$timeout" ${url:+"$url"}) || http_code=000
    case "$http_code" in
      000|429|5[0-9][0-9])
        if [ "$attempt" -lt "$POLL_RETRY_LIMIT" ]; then
          attempt=$((attempt + 1))
          sleep "$delay"
          continue
        fi
        ;;
    esac
    printf '%s\n' "$http_code"
    return 0
  done
}

cmd_poll() {
  local interval=$DEFAULT_INTERVAL timeout=$DEFAULT_REQUEST_TIMEOUT key body actions_body http_code status retry_delay polls=0
  resolve_build "${1-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --request-timeout) positive_int "${2-}" || die "--request-timeout needs a positive integer"; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  require_api_key
  key=$CODEMAGIC_API_TOKEN
  retry_delay=$(poll_retry_delay) || exit 1
  body=$(mktemp "${TMPDIR:-/tmp}/fm-codemagic-response.XXXXXX") || die "could not prepare Codemagic response storage"
  actions_body=$(mktemp "${TMPDIR:-/tmp}/fm-codemagic-actions.XXXXXX") || { rm -f -- "$body"; die "could not prepare Codemagic action storage"; }
  chmod 0600 "$body" "$actions_body" || { rm -f -- "$body" "$actions_body"; die "could not secure Codemagic response storage"; }
  trap 'rm -f -- "$body" "$actions_body"' EXIT HUP INT TERM
  while :; do
    polls=$((polls + 1))
    http_code=$(fetch_build_status "$body" "$key" "$timeout" "$retry_delay")
    case "$http_code" in
      200) ;;
      000) emit_result network-error "Codemagic request failed before an HTTP response" "$polls"; exit 0 ;;
      401|403) emit_result auth-error "Codemagic rejected the configured API key (HTTP $http_code)" "$polls"; exit 0 ;;
      404) emit_result not-found "Codemagic build does not exist or is not visible to this API key (HTTP 404)" "$polls"; exit 0 ;;
      429) emit_result rate-limited "Codemagic rate-limited the request (HTTP 429)" "$polls"; exit 0 ;;
      *) emit_result api-error "Codemagic returned HTTP $http_code" "$polls"; exit 0 ;;
    esac
    if ! jq -e . "$body" >/dev/null 2>&1; then
      if LC_ALL=C grep -Eiq '^[[:space:]]*<!doctype html|^[[:space:]]*<html' "$body"; then
        emit_result not-found "Codemagic returned its application page instead of build data (HTTP 200)" "$polls"
      else
        emit_result schema-error "Codemagic v3 response was not JSON" "$polls"
      fi
      exit 0
    fi
    status=$(jq -er 'if (.data | type) == "object" and (.data.status | type) == "string" then .data.status else error("missing data.status") end' "$body" 2>/dev/null) || {
      emit_result schema-error "Codemagic v3 response did not contain a string at data.status" "$polls"
      exit 0
    }
    case "$status" in
      initializing|queued|preparing|fetching|testing|building|publishing|finishing) sleep "$interval" ;;
      finished) emit_finished_result "$body" "$key" "$timeout" "$polls" "$actions_body" "$retry_delay"; exit 0 ;;
      failed) emit_build_result failed "Codemagic build failed" failed "$polls"; exit 0 ;;
      canceled) emit_build_result canceled "Codemagic build was canceled" canceled "$polls"; exit 0 ;;
      timeout) emit_build_result timeout "Codemagic build timed out" timeout "$polls"; exit 0 ;;
      skipped) emit_build_result skipped "Codemagic build was skipped" skipped "$polls"; exit 0 ;;
      *) emit_result schema-error "Codemagic v3 returned an undocumented build status" "$polls"; exit 0 ;;
    esac
  done
}

cmd_arm() {
  local interval=$DEFAULT_INTERVAL timeout=$DEFAULT_REQUEST_TIMEOUT
  resolve_build "${1-}"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) positive_number "${2-}" || die "--interval needs a positive number"; interval=$2; shift 2 ;;
      --request-timeout) positive_int "${2-}" || die "--request-timeout needs a positive integer"; timeout=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  require_api_key
  command -v curl >/dev/null 2>&1 || die "curl is required for Codemagic build watching"
  command -v jq >/dev/null 2>&1 || die "jq is required for Codemagic build watching"
  "$SCRIPT_DIR/fm-procevent.sh" register codemagic "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-codemagic.sh" poll "$BUILD_ID" \
    --interval "$interval" --request-timeout "$timeout" || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
  printf 'build: %s\n' "$BUILD_ID"
  printf 'interval: %ss\n' "$interval"
}

cmd_classify() {
  local file=${1-} status
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '$0 == "output:" { exit } /^status: / { sub(/^status: /, ""); print; exit }' "$file")
  case "$status" in
    finished|post-processing-failed|failed|canceled|timeout|skipped|auth-error|not-found|rate-limited|network-error|api-error|action-detail-error|schema-error) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_terminal() {
  [ "$(cmd_classify "${1-}")" != unknown ]
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;;
  poll) shift; cmd_poll "$@" ;;
  classify) shift; cmd_classify "${1-}" ;;
  terminal) shift; cmd_terminal "${1-}" ;;
  source-id) shift; resolve_build "${1-}"; printf '%s\n' "$SOURCE_ID" ;;
  retire) shift; resolve_build "${1-}"; "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
