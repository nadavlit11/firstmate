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

`tests/fm-tavily.test.sh` (15 assertions) needs no harness and no credentials, and runs in ordinary CI.
It drives the real `bin/fm-spawn.sh` and `bin/fm-brief.sh` with a fake pane and a real isolated worktree, then reads the literal launch command the pane was sent - the same string a `ps` listing or a pane capture would show - and the brief file that command actually hands the worker.

It pins: the key file is parsed and never sourced, so a command line in it does not execute, and only the documented exact form counts, with a seeded empty placeholder never hiding a real key added after it; the unavailable states stay distinguishable, so an unset key is silent absence while a near-miss spelling - quoted value, `export` prefix, indentation, CRLF, or a value carrying internal whitespace such as a trailing inline comment - and a file that exists but cannot be read each leave the launch unwired and produce their own diagnostic, naming the file and the remedy that actually applies (rewrite the line, or fix the permissions) and never the value; the injector delivers the key through the environment alongside a leading `NAME=VALUE` assignment and degrades quietly, without printing it, when the file is gone; claude and codex crewmates and scouts launch with the server configured, the Research endpoint withheld, and no key anywhere in the command; claude's `${TAVILY_API_KEY}` reference survives as a literal rather than being expanded by the pane shell into the command line; a home with no key, or with a present-but-keyless file, launches exactly as before and says nothing; an unwired harness gets no wiring even with a key present; and the worker-facing web-retrieval section reaches the worker only when its own launch is wired for it: a scaffolded `brief.md` never mentions Tavily whatever the home's key or config, while a wired launch hands the worker a derived launch brief carrying that section (composed with the no-mistakes intent contract when both apply), and an unwired harness - including one named by an explicit `--harness` after the scaffold was written - leaves both the launch and the worker's brief with no mention of it at all.

```console
$ bash tests/fm-tavily.test.sh | tail -4
ok - a scaffolded brief never mentions Tavily, whatever the home's key or config
ok - a wired launch hands the worker a brief that carries the Tavily contract
ok - an unwired launch tells the worker nothing about Tavily
ok - an explicit harness override cannot leave the worker holding a stale Tavily claim
```
