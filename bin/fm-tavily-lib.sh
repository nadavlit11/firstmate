#!/usr/bin/env bash
# Optional Tavily web-retrieval wiring for spawned crewmates and scouts.
#
# Usage: . bin/fm-tavily-lib.sh   (sourced; no FM_* setup required)
#
# Tavily is a hosted web-access API with an official remote MCP server. This
# library is the ONE owner of how that server is wired into a spawned worker:
# where the key lives, which harnesses can take it, the exact launch flags, and
# the worker-facing contract. bin/fm-spawn.sh and bin/fm-brief.sh call in here
# rather than restating any of it; docs/configuration.md owns the operator-facing
# setup, credit ceiling, and privacy note.
#
# The capability is PRESENCE-GATED and OPTIONAL. A home with no readable
# config/tavily.env spawns exactly as it did before this file existed: no flags,
# no wrapper, no warning, no failure. Absence is a configuration choice, not a
# fault, so nothing here ever reports it.
#
# Key handling, in one place because it is the whole security surface:
#   - The key lives ONLY in the gitignored config/tavily.env (config/ is
#     gitignored wholesale; see the repo .gitignore).
#   - It never reaches a launch command, a brief, a status line, or an error
#     message. The composed launch flags below carry the server URL and a
#     variable NAME only, so `ps` on the crewmate's machine shows no secret and
#     the pane never renders one.
#   - It reaches the agent through the environment, injected by
#     bin/fm-tavily-exec.sh at exec time from the file path alone.
#   - Nothing in this file prints the value, on any path.
#
# Budget discipline. The free tier is 1,000 credits a month and the Research
# endpoint costs up to 250 credits PER CALL, so a worker with Research could
# drain a month in four calls. Research is withheld MECHANICALLY, per harness,
# not by asking the worker not to call it:
#   - claude: --disallowed-tools mcp__tavily__tavily_research, which removes the
#     tool from the session's tool list entirely (verified under
#     --dangerously-skip-permissions; docs/verification/tavily.md).
#   - codex:  mcp_servers.tavily.disabled_tools, same effect.
# The remote server itself exposes no tool filter (no tools= query parameter),
# so client-side withholding is the only enforcement point there is. A harness
# that cannot withhold one tool must not be added to the supported set below:
# the worker-facing prohibition in the brief is a reminder, never the control.
set -u

# The remote streamable-HTTP endpoint. Deliberately WITHOUT the documented
# ?tavilyApiKey=<key> query form: the key would then live in a URL that lands in
# a launch command, a process argument, and a pane capture. Bearer-header auth
# against this same endpoint is verified equivalent (docs/verification/tavily.md).
FM_TAVILY_URL="https://mcp.tavily.com/mcp/"
# MCP server name, and therefore the mcp__<server>__<tool> prefix claude uses.
FM_TAVILY_SERVER="tavily"
# The one endpoint workers do not get to spend.
FM_TAVILY_FORBIDDEN_TOOL="tavily_research"
# config-dir-relative key file. Deliberately NOT in FM_INHERITABLE_CONFIG
# (bin/fm-config-inherit-lib.sh): a secondmate home that should have Tavily gets
# its own file, so a credential is never pushed across a home boundary,
# including a remote one.
FM_TAVILY_ITEM="tavily.env"
# The variable the key file must set, and the variable name the launch flags
# reference. One name, so the file, the wrapper, and both harnesses agree.
FM_TAVILY_KEY_VAR="TAVILY_API_KEY"

# Absolute path of the key file under <config-dir>.
fm_tavily_key_file() {  # <config-dir>
  printf '%s/%s\n' "${1%/}" "$FM_TAVILY_ITEM"
}

# Print the key from <key-file>, or nothing. The ONE parser, used by
# bin/fm-tavily-exec.sh. The file is parsed, never sourced: it is a credential
# store, not a script, and sourcing it would execute whatever it contains.
# Accepts `TAVILY_API_KEY=value`, an optional `export` prefix, and optional
# surrounding single or double quotes. The first assignment wins.
fm_tavily_read_key() {  # <key-file>
  local file=$1 line value
  [ -f "$file" ] && [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      "export "*) line=${line#export }; line="${line#"${line%%[![:space:]]*}"}" ;;
    esac
    case "$line" in
      "$FM_TAVILY_KEY_VAR"=*) value=${line#*=} ;;
      *) continue ;;
    esac
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    [ -n "$value" ] || return 0
    printf '%s\n' "$value"
    return 0
  done < "$file"
  return 0
}

# True when <config-dir> holds a usable key. Silent either way: an absent file
# is the ordinary no-Tavily home.
fm_tavily_key_present() {  # <config-dir>
  local key
  key=$(fm_tavily_read_key "$(fm_tavily_key_file "$1")") || return 1
  [ -n "$key" ]
}

# True when <harness> has a verified way to load the server AND withhold
# Research. Every other harness is unwired on purpose; docs/configuration.md
# says so plainly rather than half-wiring one.
fm_tavily_harness_supported() {  # <harness>
  case "$1" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

# Single-quote one token for a shell command line. Every flag value below
# carries JSON braces, quotes, brackets, or a ${...} reference, so an unquoted
# splice into the launch command would be mangled by the pane shell - and the
# ${TAVILY_API_KEY} reference would be expanded by that shell instead of
# reaching the harness, putting the secret straight into the command line.
fm_tavily_quote() {  # <token>
  printf "'%s' " "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# Print the launch flags for <harness>, already shell-quoted and with a trailing
# space, ready to splice into a launch template. Carries no secret: claude
# expands ${TAVILY_API_KEY} itself when it reads the MCP config, and codex reads
# the named variable for its bearer token.
fm_tavily_launch_flags() {  # <harness>
  case "$1" in
    claude)
      fm_tavily_quote "--mcp-config"
      fm_tavily_quote "{\"mcpServers\":{\"$FM_TAVILY_SERVER\":{\"type\":\"http\",\"url\":\"$FM_TAVILY_URL\",\"headers\":{\"Authorization\":\"Bearer \${$FM_TAVILY_KEY_VAR}\"}}}}"
      fm_tavily_quote "--disallowed-tools"
      fm_tavily_quote "mcp__${FM_TAVILY_SERVER}__${FM_TAVILY_FORBIDDEN_TOOL}"
      ;;
    codex)
      fm_tavily_quote "-c"
      fm_tavily_quote "mcp_servers.$FM_TAVILY_SERVER.url=\"$FM_TAVILY_URL\""
      fm_tavily_quote "-c"
      fm_tavily_quote "mcp_servers.$FM_TAVILY_SERVER.bearer_token_env_var=\"$FM_TAVILY_KEY_VAR\""
      fm_tavily_quote "-c"
      fm_tavily_quote "mcp_servers.$FM_TAVILY_SERVER.disabled_tools=[\"$FM_TAVILY_FORBIDDEN_TOOL\"]"
      ;;
    *) return 1 ;;
  esac
}

# The worker-facing contract, as brief lines. Kept here rather than in
# bin/fm-brief.sh so the tools a worker is told about and the tools the launch
# actually grants cannot drift apart.
fm_tavily_brief_lines() {
  cat <<'TXT'
   Tavily web retrieval is available to you as MCP tools: tavily_search for current
   information, tavily_extract for the full text of specific URLs, tavily_map and
   tavily_crawl for a site's structure. Prefer them over ad-hoc fetching when you
   need to read the web. They spend a small shared monthly credit budget, so search
   deliberately rather than in bulk. tavily_research is deliberately withheld - it
   can cost up to 250 credits in one call, a quarter of the fleet's month; do not
   look for another route to it.
TXT
}
