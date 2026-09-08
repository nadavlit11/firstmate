#!/usr/bin/env bash
# Shared planning-gate primitives (AGENTS.md section 7).
# This library is the single owner of the "Planning gate:" record's syntax, of
# what makes a plan report acceptable, and of what makes an exception reason
# specific enough to be worth recording. bin/fm-brief.sh writes the record,
# bin/fm-spawn.sh and bin/fm-promote.sh re-validate it before mutating anything,
# and neither restates the rules.
#
# The gate enforces PROVENANCE, not semantics: no script can prove a plan is
# good or that firstmate read it. What it can prove is that a separate completed
# report exists in this home, or that an exemption was typed with a reason - so a
# bypass is visible and attributable rather than invisible.

# fm_planning_render_line plan <canonical-report>
# fm_planning_render_line exception <kind> <reason>
# Renders the one machine-readable "Planning gate:" record that bin/fm-brief.sh
# writes into a ship brief, bin/fm-promote.sh writes when it converts a scout,
# and bin/fm-spawn.sh re-validates. It lives here so the syntax has one owner
# and a writer cannot drift from the validator.
fm_planning_render_line() {
  case "${1:-}" in
    plan) printf 'Planning gate: plan=%s\n' "${2:-}" ;;
    exception) printf 'Planning gate: exception=%s reason=%s\n' "${2:-}" "${3:-}" ;;
    *) return 1 ;;
  esac
}

# fm_planning_valid_reason <text>
# A reason is a single non-empty line with at least one non-space character.
fm_planning_valid_reason() {
  local reason=${1:-}
  case "$reason" in
    '') return 1 ;;
    *[$'\n\r']*) return 1 ;;
  esac
  case "$reason" in
    *[![:space:]]*) return 0 ;;
  esac
  return 1
}

# fm_planning_canonical_plan_report <path> <data-dir> <task-id>
# Print the plan report's path relative to <data-dir>, or fail with the exact
# operator refusal. The report must be a non-empty regular file resolving inside
# <data-dir>: that is what makes it a completed deliverable of THIS home rather
# than an arbitrary file the caller pointed at.
fm_planning_canonical_plan_report() {
  local path=${1:-} data=${2:-} id=${3:-} data_real resolved dir base
  data_real=$(CDPATH='' cd -- "$data" 2>/dev/null && pwd -P) || data_real=$data
  case "$path" in
    /*) ;;
    *) path="$data_real/$path" ;;
  esac
  dir=$(dirname -- "$path")
  base=$(basename -- "$path")
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || dir=
  [ -n "$dir" ] && resolved="$dir/$base" || resolved=
  if [ -z "$resolved" ] \
    || [ ! -f "$resolved" ] || [ -L "$resolved" ] || [ ! -s "$resolved" ] \
    || case "$resolved" in "$data_real"/*) false ;; *) true ;; esac; then
    echo "error: planning gate refused $id: plan report '${1:-}' must be a non-empty regular file inside $data_real; complete the scout report and review it before spawning the ship." >&2
    return 1
  fi
  printf '%s\n' "${resolved#"$data_real"/}"
}

# fm_planning_validate_record <meta> <data-dir> <task-id>
# Relaunch-only fallback. A relaunch re-dispatches work whose provenance was
# already proved when the task was first created, and the record is where that
# proof was written. Reading it here is what keeps a task recoverable whose
# brief predates this gate, or whose brief is a scout's; without it fm-control
# stops the agent and then cannot start a replacement, stranding the task.
# A FRESH spawn never reaches this: it must carry the disposition in the brief.
fm_planning_validate_record() {
  local meta=$1 data=$2 id=$3 plan kind reason
  [ -f "$meta" ] || return 1
  plan=$(fm_meta_get "$meta" plan_report)
  if [ -n "$plan" ]; then
    # shellcheck disable=SC2034  # output contract: read by the caller after validation
    PLANNING_PLAN_REPORT=$(fm_planning_canonical_plan_report "$plan" "$data" "$id") || return 1
    # shellcheck disable=SC2034  # output contract: read by the caller after validation
    PLANNING_DISPOSITION=plan
    return 0
  fi
  kind=$(fm_meta_get "$meta" planning_exception)
  if [ -z "$kind" ]; then
    # A ship dispatched before this gate existed carries no disposition at all,
    # in neither its brief nor its record, so no re-run of the original command
    # could produce one. Refusing here would strand it with no agent and no way
    # back, so a relaunch - and only a relaunch - grandfathers it and records
    # the fact as its own distinct marker, never as a forged plan reference.
    # shellcheck disable=SC2034  # output contract: read by the caller after validation
    PLANNING_DISPOSITION=legacy
    echo "PLANNING LEGACY: $id relaunches with no recorded planning disposition and is grandfathered; a fresh spawn of this task still requires --plan-report or --planning-exception" >&2
    return 0
  fi
  case "$kind" in
    one-line|precedent-following) ;;
    *) return 1 ;;
  esac
  reason=$(fm_meta_get "$meta" planning_reason)
  fm_planning_valid_reason "$reason" || return 1
  # shellcheck disable=SC2034  # output contract: read by the caller after validation
  PLANNING_DISPOSITION="exception:$kind"
  # shellcheck disable=SC2034  # output contract: read by the caller after validation
  PLANNING_REASON_RECORD=$reason
  echo "PLANNING EXCEPTION: $id $kind: $reason (from the task record on relaunch)" >&2
  return 0
}
fm_planning_validate_provenance() { # <brief> <data-dir> <task-id> [relaunch-meta]
  local brief=$1 data=$2 id=$3 relaunch_meta=${4:-} count line value kind reason
  count=$(grep -c '^Planning gate: ' "$brief" 2>/dev/null || true)
  [ -n "$count" ] || count=0
  if [ "$count" -eq 0 ]; then
    if [ -n "$relaunch_meta" ] && fm_planning_validate_record "$relaunch_meta" "$data" "$id"; then
      return 0
    fi
    echo "error: planning gate refused $id: ship briefs require either --plan-report <completed scout report> or --planning-exception <one-line|precedent-following> with --planning-reason <why>. Run and review a planning scout before building non-trivial work." >&2
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "error: planning gate refused $id: $brief records $count 'Planning gate:' lines; exactly one disposition is the whole point, so re-scaffold the brief rather than choosing among them" >&2
    return 1
  fi
  line=$(grep -m 1 '^Planning gate: ' "$brief")
  case "$line" in
    'Planning gate: plan='*)
      value=${line#Planning gate: plan=}
      # shellcheck disable=SC2034  # output contract: read by the caller after validation
      PLANNING_PLAN_REPORT=$(fm_planning_canonical_plan_report "$value" "$data" "$id") || return 1
      # shellcheck disable=SC2034  # output contract: read by the caller after validation
      PLANNING_DISPOSITION=plan
      ;;
    'Planning gate: exception='*)
      value=${line#Planning gate: exception=}
      kind=${value%% reason=*}
      reason=${value#* reason=}
      case "$kind" in
        one-line|precedent-following) ;;
        *)
          echo "error: planning gate refused $id: $brief records exception '$kind', which is not one-line or precedent-following; re-scaffold the brief" >&2
          return 1 ;;
      esac
      if [ "$reason" = "$value" ] || ! fm_planning_valid_reason "$reason"; then
        echo "error: planning gate refused $id: exception '$kind' requires a specific single-line --planning-reason; use one-line only for a literal one-line change, or precedent-following with the precedent named." >&2
        return 1
      fi
      # shellcheck disable=SC2034  # output contract: read by the caller after validation
      PLANNING_DISPOSITION="exception:$kind"
      # shellcheck disable=SC2034  # output contract: read by the caller after validation
      PLANNING_REASON_RECORD=$reason
      echo "PLANNING EXCEPTION: $id $kind: $reason" >&2
      ;;
    *)
      echo "error: planning gate refused $id: $brief's planning line is malformed: $line" >&2
      return 1 ;;
  esac
  return 0
}
