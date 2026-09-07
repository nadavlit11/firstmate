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
