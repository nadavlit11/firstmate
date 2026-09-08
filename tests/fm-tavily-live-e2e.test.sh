#!/usr/bin/env bash
# Opt-in credentialed guard for the Tavily wiring.
#
# Everything this checks is HARNESS-DEPENDENT: whether a vendor's flag really
# loads the remote MCP server, and whether its withholding control really keeps
# the Research endpoint out of an autonomous worker's hands. A stub cannot
# answer either question - it would only confirm the assumption written into the
# stub - so this runs the installed harnesses for real against the live server,
# with the launch flags composed by bin/fm-tavily-lib.sh rather than restated
# here. Run it after a claude or codex upgrade, and refresh
# docs/verification/tavily.md from its output.
#
# It refuses to pass having checked nothing, and reports an absent harness
# explicitly rather than skipping over it silently.
set -u

if [ "${FM_TAVILY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_TAVILY_LIVE_E2E=1 to run the live Tavily guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() {
  printf 'ok - %s\n' "$1"
}

# shellcheck source=bin/fm-tavily-lib.sh
. "$ROOT/bin/fm-tavily-lib.sh"

KEY_FILE=${FM_TAVILY_LIVE_KEY_FILE:-$(fm_tavily_key_file "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$ROOT}/config}")}
[ -n "$(fm_tavily_read_key "$KEY_FILE")" ] \
  || fail "no usable Tavily key at $KEY_FILE; this guard needs real credentials"

CHECKED=0

# run_live <harness> <version> <output>
# One live turn is asked for two things at once: name the Tavily tools you can
# see, and use search. That makes a single run prove the server loaded AND that
# the withheld endpoint is not in the tool list.
assert_live_output() {  # <harness> <output>
  local harness=$1 out=$2
  case "$out" in
    *tavily_search*) : ;;
    *) fail "$harness: the Tavily search tool never appeared" ;;
  esac
  case "$out" in
    *tavily_research*) fail "$harness: the withheld Research endpoint was visible to the worker" ;;
  esac
  case "$out" in
    *TAVILY_SEARCH_OK*) : ;;
    *) fail "$harness: a live Tavily search did not return a usable result" ;;
  esac
}

PROMPT='List the names of the tavily tools available to you. Then call the tavily search tool for "Tavily MCP server". If it returned results, print the line TAVILY_SEARCH_OK followed by the first result title. Keep the whole reply under 6 lines.'

if command -v claude >/dev/null 2>&1; then
  version=$(claude --version 2>&1 | head -n 1)
  flags=$(fm_tavily_launch_flags claude)
  # Launched through the real injector, so this also proves the production key
  # path works - and so no key is ever composed into a command line here.
  out=$(cd "$ROOT" && printf '%s\n' "$PROMPT" \
    | eval "$(printf '%q' "$ROOT/bin/fm-tavily-exec.sh") $(printf '%q' "$KEY_FILE") claude -p --dangerously-skip-permissions $flags" 2>&1) \
    || fail "claude ($version): the live run failed: $out"
  assert_live_output "claude $version" "$out"
  CHECKED=$((CHECKED + 1))
  pass "claude $version loads Tavily and withholds $FM_TAVILY_FORBIDDEN_TOOL"
else
  echo "# claude is not installed here; its Tavily guarantee is UNCHECKED"
fi

if command -v codex >/dev/null 2>&1; then
  version=$(codex --version 2>&1 | head -n 1)
  flags=$(fm_tavily_launch_flags codex)
  out=$(cd "$ROOT" && eval "$(printf '%q' "$ROOT/bin/fm-tavily-exec.sh") $(printf '%q' "$KEY_FILE") codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check $flags $(printf '%q' "$PROMPT")" 2>&1) \
    || fail "codex ($version): the live run failed: $out"
  assert_live_output "codex $version" "$out"
  CHECKED=$((CHECKED + 1))
  pass "codex $version loads Tavily and withholds $FM_TAVILY_FORBIDDEN_TOOL"
else
  echo "# codex is not installed here; its Tavily guarantee is UNCHECKED"
fi

[ "$CHECKED" -gt 0 ] || fail "no wired harness was installed; this guard proved nothing"
printf '# fm-tavily-live-e2e: %s wired harness(es) verified\n' "$CHECKED"
