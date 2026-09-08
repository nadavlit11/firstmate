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

# Scan <key-file> once and print its verdict: a first line of `ok`, `absent`, or
# `malformed`, followed by the key itself on a second line when the verdict is
# ok. This is the ONE scan, so the key a launch receives and the status an
# operator is shown can never disagree about the same file.
#
# The file is parsed, never sourced: it is a credential store, not a script, and
# sourcing it would execute whatever it contains.
#
# The ONLY accepted form is the documented one: a line `TAVILY_API_KEY=<value>`
# starting at column one, with whitespace trimmed from both ends of the value.
# No `export` prefix, no quoting, no indentation, no CR line ending. A line that
# is not an assignment of this variable at all - a comment, another variable -
# is simply skipped, and so is an assignment whose value is empty, so a seeded
# placeholder never hides a real key added after it. The first accepted
# assignment wins.
#
# A near-miss spelling yields no key rather than a key that cannot authenticate,
# and is remembered as `malformed` so the two unavailable states stay
# distinguishable: absent means nobody set a key, which is the ordinary optional
# state and stays silent, while malformed means somebody did and it will not
# work, which is worth saying out loud rather than leaving as an untraceable 401.
fm_tavily_scan() {  # <key-file>
  local file=$1 line probe value malformed=0
  [ -f "$file" ] && [ -r "$file" ] || { printf 'absent\n'; return 0; }
  while IFS= read -r line || [ -n "$line" ]; do
    probe=${line%$'\r'}
    probe="${probe#"${probe%%[![:space:]]*}"}"
    case "$probe" in
      "export "*) probe=${probe#export }; probe="${probe#"${probe%%[![:space:]]*}"}" ;;
    esac
    case "$probe" in
      "$FM_TAVILY_KEY_VAR"=*) ;;
      *) continue ;;
    esac
    value=${probe#*=}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [ -n "$value" ] || continue
    if [ "$probe" = "$line" ]; then
      case "$value" in
        \"*|\'*) malformed=1; continue ;;
      esac
      printf 'ok\n%s\n' "$value"
      return 0
    fi
    malformed=1
  done < "$file"
  if [ "$malformed" -eq 1 ]; then printf 'malformed\n'; else printf 'absent\n'; fi
  return 0
}

# Print the key from <key-file>, or nothing. Used by bin/fm-tavily-exec.sh.
fm_tavily_read_key() {  # <key-file>
  local scan
  scan=$(fm_tavily_scan "$1")
  [ "${scan%%$'\n'*}" = ok ] || return 0
  printf '%s\n' "${scan#*$'\n'}"
}

# Classify <config-dir>'s key file for an operator: `ok`, `absent`, or
# `malformed`.
fm_tavily_key_status() {  # <config-dir>
  local scan
  scan=$(fm_tavily_scan "$(fm_tavily_key_file "$1")")
  printf '%s\n' "${scan%%$'\n'*}"
}

# The operator-facing diagnostic for a malformed key file, or nothing at all for
# any other state. Rendered here so both callers print the same sentence; they
# send it to stderr. It names the file and the accepted form and NEVER prints the
# value or any part of it - the whole point of the file is that the value does
# not leak into output.
fm_tavily_malformed_notice() {  # <config-dir>
  [ "$(fm_tavily_key_status "$1")" = malformed ] || return 0
  printf 'warning: %s sets %s but not in the accepted form, so Tavily is unavailable; write it as exactly `%s=<value>` at the start of a line, with no quotes, no `export` prefix, no leading whitespace, and no CR line ending.\n' \
    "$(fm_tavily_key_file "$1")" "$FM_TAVILY_KEY_VAR" "$FM_TAVILY_KEY_VAR"
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

# True when a worker spawned from <config-dir> onto <harness> will actually be
# handed the server: both the key and the harness wiring must be there. This is
# the ONE owner of "does this worker get Tavily"; bin/fm-spawn.sh gates its
# launch flags on the same two facts.
fm_tavily_available() {  # <config-dir> <harness>
  fm_tavily_harness_supported "$2" && fm_tavily_key_present "$1"
}

# The worker-facing contract, as brief lines, for a worker spawned from
# <config-dir> onto <harness>; nothing at all when that worker gets no Tavily.
# Kept here rather than in bin/fm-brief.sh so the tools a worker is told about
# and the tools the launch actually grants cannot drift apart - on the harness
# axis as much as the key axis.
fm_tavily_brief_lines() {  # <config-dir> <harness>
  fm_tavily_available "$1" "$2" || return 0
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
