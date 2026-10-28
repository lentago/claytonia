# ADR-0009: Policy-gated auto-merge for scheduled routine PRs

**Status:** Accepted (2026-10-28). Amends [ADR-0002](0002-workers-branch-and-pr-never-merge.md).

## Context

ADR-0002 keeps a human between every runner-bot PR and `main`. That rule was
written for directed work: a job changes code, and someone should read the diff.

The fleet now also runs **scheduled routines**: jobs that fire on a clock (see
`bin/cr-schedule`) and record what they found as data files in a repository, for
example a twice-daily report and the follow-up job that files its findings. Those
routines previously ran as hosted cloud agents that armed squash auto-merge on
their own PRs, and the schedule depends on it: each run reads what the previous
run merged. Moved onto the fleet under ADR-0002, every one of those PRs would wait
for a human click, several times a day, and a missed click stalls the next run
(the same failure the routine's repository already recorded once, when a single
unarmed PR sat for 13 hours and the following run deferred to it).

The maintainer decided on 2026-10-28 to run these routines on the fleet, for its
LAN reach and residential egress, and accepted an exception to ADR-0002 as the cost.

## Decision

**A deterministic gate, not the agent, may arm squash auto-merge on a runner-bot
PR, and only when the target repository has opted that kind of PR in.**

- `run-job` already ran a post-job step on every PR a project job opened (the
  ADR-0002 disarm). That step is now `bin/cr-automerge`. Its default is
  unchanged: disarm and leave the PR for a human.
- It arms squash auto-merge only when **all** of these hold:
  1. the job spec names a rule (`"automerge": "<rule>"`) and the job succeeded;
  2. the repository's **default branch** holds `.claytonia/automerge.json`
     defining that rule. The file is read from the base branch through the API,
     never from the PR head, so a PR cannot grant itself permission, and adding
     or widening a rule takes a PR a human merges in that repository;
  3. the PR is open, not a draft, targets the default branch, comes from a branch
     in the same repository, and is authored by the runner App;
  4. its title matches the rule's `title` regex in full;
  5. it changes between one and `max_files` (default 50) paths, and every path,
     including a rename's old path, matches one of the rule's `paths` globs.
- Any error, missing field or doubt disarms. The decision is written to the
  job's `.meta` as `automerge=armed rule=<rule>` or `automerge=disarmed: <reason>`.
- The standing prompt is unchanged: the agent itself still never arms or merges.
  Required status checks still gate the merge; auto-merge only removes the click.
- `run-job` now takes only a PR in the project's own repository as the job's PR
  (the last one its output names). Before this, the first `github.com/…/pull/N`
  anywhere in the output was disarmed, which could have disarmed a human's PR in
  another repository that a report merely linked to.

The opt-in lives in the target repository because that repository's owner is the
one accepting unreviewed merges into it, and because its git history is then the
audit trail of who allowed what.

## Alternatives

- **Keep ADR-0002 unchanged and click merge.** Rejected by the maintainer: the
  routines exist to run unattended, and their cadence breaks on a missed click.
- **Leave the routines on hosted cloud agents.** Rejected: they can't reach the LAN,
  and several public sites the routines read block cloud addresses but answer a
  residential one.
- **Let the agent arm auto-merge, as the cloud agents did.** Worse: a prompt is
  advisory, and ADR-0002 exists because an agent once followed a repository's
  human-oriented convention. The gate keeps the decision in code.
- **Put the policy in this repository or on the NAS.** Worse: this repository is
  public and shouldn't describe other repositories' data, and the NAS is writable
  by every job, so a job could widen its own rule.
- **A GitHub Actions workflow in the target repository that arms on PR open.**
  Lateral: it keeps the policy local too, but it races `run-job`'s disarm at job
  end, and it splits one decision across two systems.

## Consequences

- `main` of an opted-in repository can advance without a human reading the diff,
  but only for PRs whose shape the repository itself declared: one title pattern,
  a fixed set of paths. A misbehaving agent can still write anything into those
  paths; the bound is on where, not what. CI and any required review check stay in
  force.
- The README's governance line ("the only way anything reaches `main` is a human
  clicking merge") now carries this exception, and so does the `CLAUDE.md`
  invariant.
- Issue #117 (a required check that blocks runner-App PRs without a human
  approval) would block these PRs too. If it lands, an opted-in repository either
  stays outside it or the check must pass PRs whose head SHA `cr-automerge` armed
  under a rule.
- `gh-token` now resolves the installation per repository (from its argument or
  `GH_REPO`, which `run-job` exports for project jobs), so a project can live under
  a different owner than the org installation.
