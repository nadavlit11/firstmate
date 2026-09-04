---
name: seo-review
description: >-
  Agent-only procedure for the recurring Search Console review firstmate runs for click-bateva and bateva-shelanu, whose only captain-facing output is a set of decisions.
  Load before filing, dispatching, running, or relaying one of those reviews, when its backlog time gate comes due, and before answering any question about SEO cadence, the Search Console pull, or where the target-term lists live.
user-invocable: false
metadata:
  internal: true
---

# SEO review

The recurring Search Console review is agent work.
The captain does not open Search Console and does not read the numbers.
His words, 2026-09-03, correcting an earlier firstmate relay that said he did: *"seo - no, i dont open the search console and decide. an agent should do it for me, and just prompt me with decisions. that how i did it in the old setup."*

That correction is the whole point of this skill.
An earlier investigation read the old design's saved artifacts, saw a person's judgment in them, and inferred the person had done the reading.
He had not.
Treat every artifact that records a decision as evidence of who decided, never as evidence of who measured.

A run does the pull, does the analysis, and surfaces decisions.
A run that finds nothing worth deciding is a successful run and says so in one line.

## The only captain-facing output is decisions

Each decision names what to change, what to write, or what to leave, carries the evidence that forces it, and ends in a recommendation.
Not a dashboard, not a data dump, not "here is the export", and never a completion notice standing in for findings.
`AGENTS.md` section 9 owns the phrasing and `captain-hold-lifecycle` owns recording the answer.

Reinforcement at the point where this is most often lost: the worker running the review never addresses the captain, and its report is evidence firstmate reads and translates, not captain-facing prose (`AGENTS.md` hard rule 4).

⛔ **A review that has to justify itself by producing work will produce work.**
Both businesses' most recent reviews produced a *cancelled* plan plus at most a copy edit, and neither produced a page.
bateva-shelanu's 2026-08-29 export refuted the sitewide retitle the session opened by proposing.
click-bateva's 2026-09-01 audit found six of eight allegedly page-less terms already had a page, and returned a code ticket instead of a new page axis.
Cancelling a plan is a full result; report it as one.

## The pull: decided

**The review starts from the export already on disk.
The saved export directory is the loop's input contract.
Do not build a Search Console API client.**

The reasoning, so it is not relitigated every run:

- It works today on both sites with no new credential and no dependency on a third party.
- bateva-shelanu's `scripts/gsc_report.py` already reads exactly that on-disk shape, and firstmate cannot change it (hard rule 1) - a project worker would have to.
  Keeping the on-disk contract is what makes an API a drop-in *producer* later rather than a rewrite of the analysis.
- Every recorded loss on this surface came from not saving a pull, never from how the pull was fetched.

So the pull half stays a class-B identity-bound read: an agent driving the captain's logged-in Chrome, never a headless process.
Where a site's own records already own the pull procedure, follow them rather than restating one here.

### What the API would buy, and the exact credential that gates it

State this when the captain asks whether to automate the pull, and stop there.
Do not half-build around a credential that does not exist.

It would buy three things and only three:

- The export click disappears, and the pull becomes mechanical.
- The row cap disappears: the API pages to 25,000 rows against a UI export capped near 1,000.
- ⭐ **The query-by-page join becomes reachable.**
  A two-dimension query answers "which pages earn impressions for this phrase" in one call.
  That is precisely the limitation `scripts/README.md` records as having no shell route, so it is the strongest single argument for paying the setup cost.

It would buy none of the following, and saying otherwise oversells it:

- Security issues and manual actions have no API at all; that stays a browser look.
- Search volume is a different product (Keyword Planner) on a spend-gated account.
- Rare queries stay anonymised, so every non-brand bucket remains a lower bound.
- The survivorship trap is structural and no access method touches it (see below).

The credential, exactly:

- **click-bateva is the short path, because the pattern already exists.**
  `scripts/ga4-query.mjs` on `origin/develop` mints an ephemeral token with `gcloud auth print-access-token --account=ga4-admin@click-bateva.iam.gserviceaccount.com --scopes=<scope>`.
  The same call with `https://www.googleapis.com/auth/webmasters.readonly` is the entire auth story.
  What the captain must do: enable `searchconsole.googleapis.com` in the existing `click-bateva` cloud project, then add that service account as a user on `sc-domain:clickbateva.co.il` under the property's users-and-permissions settings, read access being enough.
  Granting a user requires owner access on the property.
- **bateva-shelanu is the longer path and is not the captain's to grant alone.**
  Its property is `sc-domain:batevashelanu.co.il` under the `batevashelanu@gmail.com` identity, and that project has no cloud project of its own.
  It needs either its own service account or a grant of click-bateva's onto that property, and either way an owner of that Google account has to make the grant.
  Name that dependency rather than assuming the captain can clear it.

## What the loop cannot answer without him

Say these plainly in any review that runs into them, rather than answering around them.

- **Attributing a phrase to pages.** The export's page and query tables are independent margins; joining them needs a filter in the Search Console UI, and there is no shell route until the API above exists.
- **Security issues and manual actions.** No API, and a reputational standing is the captain's call even when the fix is code.
- **Search volume.** Search Console cannot size demand; volumes come from Keyword Planner on an existing Ads account, and a fresh account cannot reach the tool.
- **Anything needing his commercial judgment**, such as whether demand the business does not sell into is worth chasing.
  Demand is not opportunity.

## click-bateva - weekly, and it already has a home

Weekly, as the SEO section of the Saturday digest that already exists.
Do not build a second weekly SEO job beside it.
The gap the research actually found is that Saturday does not announce itself, so firstmate's due item is the *trigger* the digest lacks, not a parallel loop.

⚠️ **Reconcile the project's standing "no cron, ever" ruling instead of tripping over it or breaking it.**
What the founder retired was an automated weekly report *email*, a data dump that nobody decided anything from.
An agent that does the analysis and returns decisions is the thing he asked for, not the thing he retired.
So: no project-side cron, no re-armed session cron, no automated digest email, and the firstmate item stays the trigger.

Its records live on `origin/develop` only, and firstmate's clone sits on the prod line, so a brief pointing at them resolves to nothing without saying so.
Work item `cb-seo-social-records-unreachable` owns that defect; coordinate with it rather than solving it again inside a review.

Its own skills own the mechanics, and both are on `develop`: targeting decisions in the `seo` skill, and the numbers, the brand split and the digest's SEO section in `measurement`.
A review that finds itself recomputing what those own is in the wrong place.

## bateva-shelanu - monthly-ish and event-keyed

⛔ **Do not make this weekly, and do not re-derive the cadence.**
The site averages position 20.2 with 75% of impressions at position 21 or deeper.
Position at that depth moves on a monthly timescale, so a weekly read returns wobble with no signal, and the honest response to each wobble is "wait" - which is a loop that trains its reader to ignore it.
Monthly here is the correct sampling interval, not laziness.

The next pull is already dated **on or after 2026-09-26**, and it is a comparison, not a fresh look: ODT queries against positions 10.1, 10.6, 9.4 and 13.5, and post 2446 on the head term against 11.5.
Compare **position**, not CTR, on the terms a shipped change actually targeted.

Save the export, every time.
The 2026-08-25 pull was lost by being quoted into a session transcript instead of saved, and only its procedure doc survives.

⭐ **This site has no running table, and that is the one genuine structural gap between the two setups.**
The first review from 2026-09-26 onward starts `docs/gsc-baseline.md` with one row per pull, in the same shape as click-bateva's running baseline.
It costs one paste per pull and it is the difference between "did it move" and "I think it moved".

## The target lists exist - read them, never invent one

The review reads the site's own list and reports against it.
A run that assembles its own list has silently changed what the business is chasing.

- **click-bateva:** `docs/seo-target-terms.md` on `origin/develop` is the working list, 51 terms in three tiers, each row carrying a real measured volume and bid.
  It supersedes the earlier corpus-sized proposal artifact.
  The running table it feeds is `docs/social-seo-baseline.md`.
- **bateva-shelanu:** two lists that do not agree, and the disagreement is itself a standing captain call.
  Gilad's own 41 unique phrases are analysed in `docs/keyword-map-2026-08-23.md`; the measured population is the parsed Keyword Planner exports.
  That analysis records that not one of the top ten earning queries appears in Gilad's list, concludes the list is an aspiration rather than a description, and its open question - whether abandoning the family and small-team traffic is deliberate - has never been answered.
  Surface it as a decision when a review touches it; do not quietly pick a list.

## What a run may commit

Data only: the saved export, and one appended baseline row.
That is the whole diff, and keeping it that small is what stops the review inventing work to justify itself.

Every change the review recommends is a separate task, filed and authorized on its own.
A report recommending implementation is not authorization to implement (`AGENTS.md` section 7).

The delivery mode, merge authority and per-project standing instructions come from `data/projects.md` and section 7 as for any other work; a review is not exempt from them and does not get its own path.

## Analysis rules already encoded - do not re-derive them

Each of these cost a wrong answer once and is already written down where the work happens.
Point at the owner and use its tool rather than hand-rolling the sweep again.

- **A rate quoted without its baseline is a number pretending to be a finding.**
  `scripts/gsc_report.py` refuses to print a CTR without the expected CTR at that position, because a 0.45% CTR was once presented as the site's biggest fixable defect when the page ranked at position 33, where 0.45% is normal.
  Run it; do not recompute CTR by hand.
- **Never quote a blended average position as progress.**
  Brand is around 86% of click-bateva's clicks on around 14% of its impressions at position 1, so the blend improves whenever paid manufactures brand searches.
  Report brand and non-brand separately, every time.
- ⛔ **Search Console only shows terms you already rank for.**
  A term you rank nowhere for produces zero impressions and is invisible, so a target list derived from Search Console is a survivorship sample of what you already touch.
  Measured on click-bateva: a tidy top-ten read looked complete while the company's own core business term returned no data at all.
  The list comes from the corpus and from measured volume; Search Console only says where you stand on it.
- ⚠️ **A plain Hebrew substring filter silently under-counts.**
  Five letters change form word-finally and are different codepoints, so a stem in its standalone spelling cannot match its own inflections; one measured filter matched two rows where five existed.
  Grep the stem without its last letter, or alternate both forms, and state the control you ran.
- ⚠️ **Audit any claim of absence before building against it.**
  An entry asserting no page, no ranking or no coverage records what someone believed the day they wrote it.
  Falsifying it is cheap, and doing so is the only reason a false premise was caught before a whole page axis shipped against it.
- **Read the rendered title, never the slug or the category id**, and verify a name-keyed mapping against the live names rather than against the map's own key.
  A shipped override missed on a one-character key difference and did nothing for two months with no log, no error and a green test asserting the same wrong literal.

## Re-arming

A review is one occurrence of a standing loop, so the run is not finished until the next one is dated.
Before closing, file the next occurrence with its due date and its comparison targets, held on its time gate.
`AGENTS.md` section 10 owns the backlog mechanics and `captain-hold-lifecycle` owns anything the captain still has to answer.

A due date that passes with no review is the failure mode worth watching here.
A review that finds nothing to decide is not.
