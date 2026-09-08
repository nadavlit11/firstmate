# Model and effort

Load this with the selected tool reference before choosing, validating, or changing either axis.
Add `references/common/dispatch.md` for configured profile precedence.

## Axes and precedence

`../../../bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values selected at intake; scripts never parse natural-language dispatch rules.
The tool reference records verified flags, accepted values, omission behavior, and discovery.

Model precedence is a per-task captain instruction, then the applicable dispatch profile or secondmate pin, then the harness default.
Never replace a higher-precedence model value.

Effort has no such precedence chain, and there is no complexity-proportional fallback to apply.
Every spawn runs at `low` unless the captain makes an explicit current exception, and only `AGENTS.md` section 4 and `../../../bin/fm-spawn.sh --help` own that rule and its flags.
A dispatch profile or secondmate pin may confirm `low` and may not raise it; a configured higher level is refused at startup and at spawn rather than obeyed.
Select a harness whose verified launch axis can carry the level you are asking for, because the spawn refuses an adapter that cannot prove it unless the captain's exception says the adapter has no enforceable axis.
The question is asked about the level requested, not about `low`: grok's `--reasoning-effort` accepts only `low|medium|high` and codex stops at `xhigh`, so `--effort xhigh` on grok is refused and the refusal names the levels that adapter does accept.
That replaces the older record-and-omit behavior: a level the launch command never carried is never recorded as a plain level, because a recorded level the CLI never received is a false guarantee. Where an exception deliberately accepts an adapter with no axis, the task record marks it `effort=unenforced:<level>` so the record still describes what was actually sent.

## Harness and provider identity

Harness identity is independent of model provider.
`harness=pi` with `model=xai/grok-*` is Pi using xAI, not standalone Grok Build, and does not require Grok CLI login.
`harness=cursor` with `model=cursor-grok-4.5-*` is Cursor routing a Grok model, not `harness=grok`.

No script resolves credential provenance for you.
Establish it from the tool's discovery surface and `quota-axi auth --json` per-provider sources, and show the reasoning rather than inferring it from a name.

## Discovery

Treat model and provider knowledge as current discovery, not a permanent namespace or mapping.
Use the selected tool reference's authoritative surface in the current authenticated environment because availability changes by version, account, and configuration.

For an unfamiliar namespace, establish support and provider identity from that harness's CLI help, model listing, or current documentation.
An account-reaching listing that omits a model is concrete unsupported evidence; block the candidate and quote it.
An unreachable surface establishes nothing; report uncertainty instead of a verdict.

For a matched profile array, return to `quota-array-dispatch` only after establishing every candidate's harness support, provider relationship, and uncertainty.
