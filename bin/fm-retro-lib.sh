#!/usr/bin/env bash
# Retro receipt validation (AGENTS.md section 13's `retro` trigger).
#
# This library is the single owner of the receipt's format and of when a ship
# task may skip a retro. The `retro` skill owns the judgment - which tier
# applies, which lessons are worth keeping, and where each one belongs - because
# shell cannot decide any of that without guessing. What shell can do is insist
# that the receipt EXISTS, that it names a tier from a closed set, that a skip
# carries a reason, and that a skip is available only to a task whose RECORDED
# planning disposition was an exception. Whether a branch outgrew that exemption
# is a judgment the skill makes, not one shell infers from commit or file counts.
#
# Receipt path: <data>/<task-id>/retro.md
# Receipt shape:
#   Retro: quick|full|skip
#   Reason: <one line saying why this tier applies>
#   Routes:
#   - project-change: <path committed in this branch, or none: reason>
#   - home-learning: <candidate text for firstmate, or none: reason>
#   - captain-preference: <candidate text for firstmate, or none: reason>
#   - shared-firstmate: <follow-up needed, or none: reason>

# fm_retro_receipt_path <data-dir> <task-id>
fm_retro_receipt_path() {
  printf '%s/%s/retro.md\n' "${1%/}" "$2"
}

# fm_retro_receipt_tier <receipt>
# Print the declared tier, or nothing when the receipt names none.
fm_retro_receipt_tier() {
  local receipt=$1 tier
  tier=$(sed -n 's/^Retro:[[:space:]]*\([A-Za-z]*\).*$/\1/p' "$receipt" 2>/dev/null | head -n 1)
  case "$tier" in
    quick|full|skip) printf '%s\n' "$tier" ;;
  esac
}

# fm_retro_validate <data-dir> <task-id> <planning-disposition>
# <planning-disposition> is "plan" when the task named a plan report, or the
# exception kind, or empty when the record predates the planning gate.
# Prints the operator refusal and returns 1 when the receipt is missing or its
# skip is not available to this task; prints the skip notice and returns 0 when
# a reasoned skip is legitimate.
fm_retro_validate() {
  local data=$1 id=$2 planning=$3 receipt tier reason
  receipt=$(fm_retro_receipt_path "$data" "$id")
  if [ ! -f "$receipt" ] || [ ! -s "$receipt" ]; then
    echo "REFUSED: ship task $id has no retro receipt at $receipt." >&2
    echo "Run the retro skill before validation/landing, route project lessons into this task branch, and retry teardown." >&2
    return 1
  fi
  tier=$(fm_retro_receipt_tier "$receipt")
  case "$tier" in
    quick|full) return 0 ;;
    skip) ;;
    *)
      echo "REFUSED: ship task $id's retro receipt at $receipt names no tier." >&2
      echo "Its first line must read 'Retro: quick', 'Retro: full', or 'Retro: skip' with a reason." >&2
      return 1 ;;
  esac
  reason=$(sed -n 's/^Reason:[[:space:]]*//p' "$receipt" 2>/dev/null | head -n 1)
  case "$reason" in
    *[![:space:]]*) ;;
    *)
      echo "REFUSED: ship task $id's retro receipt skips the retro with no reason." >&2
      echo "A skip is a claim about this task; state it on the receipt's Reason: line." >&2
      return 1 ;;
  esac
  if [ "$planning" = plan ] || [ -z "$planning" ]; then
    echo "REFUSED: ship task $id cannot skip retro: it was planned, so it was already classified as non-trivial." >&2
    echo "Complete a quick retro and retry teardown." >&2
    return 1
  fi
  echo "RETRO SKIPPED: $id: $reason" >&2
  return 0
}
