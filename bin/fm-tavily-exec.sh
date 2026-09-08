#!/usr/bin/env bash
# Inject the Tavily API key into a launch command's environment, then exec it.
#
# Usage: fm-tavily-exec.sh <key-file> <command> [args...]
#        <command> may begin with NAME=VALUE assignments; they are applied too.
#
# This exists so the key reaches a spawned agent WITHOUT ever appearing in a
# launch command, a process argument list, or a pane capture. The only thing
# rendered in the crewmate's pane is this script's path and the key file's path;
# the value is read here, at exec time, from the file. bin/fm-tavily-lib.sh owns
# the parse and the rest of the wiring contract.
#
# It is deliberately non-fatal. An unreadable or keyless file means the agent
# still launches, without Tavily - the capability is optional, and a spawn must
# never fail because an optional credential went missing between the decision
# and the exec. The diagnostic names the file, never its contents.
#
# It never prints the key on any path, including failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ "$#" -lt 2 ]; then
  echo "usage: fm-tavily-exec.sh <key-file> <command> [args...]" >&2
  exit 2
fi

KEY_FILE=$1
shift

# shellcheck source=bin/fm-tavily-lib.sh
. "$SCRIPT_DIR/fm-tavily-lib.sh"

KEY=$(fm_tavily_read_key "$KEY_FILE" 2>/dev/null || true)
if [ -n "$KEY" ]; then
  export "$FM_TAVILY_KEY_VAR=$KEY"
else
  echo "note: no usable Tavily key in $KEY_FILE; continuing without Tavily" >&2
fi
KEY=

# exec through env so leading NAME=VALUE assignments in the launch command are
# honoured exactly as they would be in a shell, and so the surviving process
# argv is the harness's own - this wrapper leaves no trace in it.
exec env "$@"
