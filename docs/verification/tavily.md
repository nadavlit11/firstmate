# Tavily wiring verification

Repeatable evidence for the optional Tavily web-retrieval capability.
Current behavior, the credit ceiling, and the privacy consequence are owned by [`../configuration.md`](../configuration.md) ("Tavily web retrieval"), and the wiring contract by `bin/fm-tavily-lib.sh`'s header; this page records evidence only.

Date: 2026-09-08.
Shell: GNU bash 3.2.57 (macOS 22.6.0).
Harnesses: `claude` 2.1.263, `codex-cli` 0.153.4.
Server: `https://mcp.tavily.com/mcp/`, MCP protocol `2025-06-18`.

## What had to be measured rather than assumed

Three facts decide the whole design, and none of them can be read off a document.

**Bearer-header authentication works against the documented endpoint.**
Tavily documents only `https://mcp.tavily.com/mcp/?tavilyApiKey=<key>`, which would put the key into a launch command, a process argument list, and a pane capture.
An `initialize` call with the key in an `Authorization: Bearer` header against the same URL returned HTTP 200 and a normal server capability payload, identical to the query-parameter form, so the key never has to appear in a URL.

**The server exposes no tool filter.**
`tools/list` on that session returned exactly five tools - `tavily_search`, `tavily_extract`, `tavily_crawl`, `tavily_map`, `tavily_research` - and the documentation describes no `tools=` parameter or equivalent.
Withholding Research therefore has to happen client-side, which is why only harnesses with a verified withholding control are wired at all.

**Each harness's withholding control actually removes the tool, under the autonomy flags a crewmate launches with.**
This is the fact most likely to break on a vendor upgrade, so it is what the live guard re-measures.

## Live evidence

`tests/fm-tavily-live-e2e.test.sh` is the guard that refreshes this page.
It is opt-in and credentialed, composes its flags from `bin/fm-tavily-lib.sh` rather than restating them, launches through the production key injector `bin/fm-tavily-exec.sh`, asks one live turn to both name its Tavily tools and use search, reports an absent harness explicitly, and refuses to pass having checked nothing.

```console
$ FM_TAVILY_LIVE_E2E=1 bash tests/fm-tavily-live-e2e.test.sh
ok - claude 2.1.263 (Claude Code) loads Tavily and withholds tavily_research
ok - codex codex-cli 0.153.4 loads Tavily and withholds tavily_research
# fm-tavily-live-e2e: 2 wired harness(es) verified
```

The withholding controls that produced those verdicts:

- claude: `--disallowed-tools mcp__tavily__tavily_research`.
  Measured under `--dangerously-skip-permissions`, the flag a crewmate launches with: the tool is not merely refused on call, it is absent from the session's tool list, and the model reported the four remaining Tavily tools.
- codex: `-c 'mcp_servers.tavily.disabled_tools=["tavily_research"]'`, with `bearer_token_env_var` supplying the credential from the environment.
  The same measurement under `--dangerously-bypass-approvals-and-sandbox`: the model listed `tavily_crawl`, `tavily_extract`, `tavily_map`, `tavily_search` and nothing else, then completed a live search.

No other harness has a verified control, so none is wired; adding one means proving both halves here first.

## Portable regression

`tests/fm-tavily.test.sh` (13 assertions) needs no harness and no credentials, and runs in ordinary CI.
It drives the real `bin/fm-spawn.sh` and `bin/fm-brief.sh` with a fake pane and a real isolated worktree, then reads the literal launch command the pane was sent - the same string a `ps` listing or a pane capture would show - and the generated brief.

It pins: the key file is parsed and never sourced, so a command line in it does not execute, and only the documented exact form counts, with a seeded empty placeholder never hiding a real key added after it; the two unavailable states stay distinguishable, so an unset key is silent absence while a near-miss spelling - quoted value, `export` prefix, indentation, CRLF - leaves the launch unwired and produces one diagnostic naming the file and the accepted form and never the value; the injector delivers the key through the environment alongside a leading `NAME=VALUE` assignment and degrades quietly, without printing it, when the file is gone; claude and codex crewmates and scouts launch with the server configured, the Research endpoint withheld, and no key anywhere in the command; claude's `${TAVILY_API_KEY}` reference survives as a literal rather than being expanded by the pane shell into the command line; a home with no key, or with a present-but-keyless file, launches exactly as before and says nothing; an unwired harness gets no wiring even with a key present; and a brief advertises Tavily only when the harness the task will actually launch on can be wired for it - derived from the standing crewmate resolution, overridden by `--harness`, and refused outright rather than guessed on a `config/crew-dispatch.json` home that has a usable key - always with the Research prohibition and never with the key.

```console
$ bash tests/fm-tavily.test.sh | tail -4
ok - a malformed key leaves the launch unwired and is reported without leaking the value
ok - briefs advertise Tavily only where the home actually has it, and never carry the key
ok - a brief describes Tavily only when the harness it will launch on can be wired for it
ok - a dispatch-profile home refuses to guess a harness only when a key makes the guess matter
```
