# ADR-0004: GitHub App identity minting short-lived tokens

**Status:** Accepted (2026-07-05; reconstructed 2026-08-13)

> Dated to issue #49 (2026-07-05), which framed the problem and drove the move off
> the shared personal PAT. The issue proposed a machine-account *PAT*; the landed
> implementation is a GitHub **App** (`lentago-claude-runner`) minting short-lived
> installation tokens — recorded here as the evolution, not as what #49 literally
> asked for.

## Context

Originally every worker authenticated to GitHub with a maintainer's personal PAT,
so **every fleet PR was authored by that person** (`cpitzi`). Issue #49 ("Grant
the runner App workflows+issues write", 2026-07-05) laid out the concrete costs:

- **No notifications for agent PRs** — GitHub never notifies you about your own
  activity, so fleet PRs authored as you generate no email; the Grafana "Open
  agent PRs" panel was the only review signal.
- **Muddled attribution** — human-authored and agent-authored PRs were
  indistinguishable by author, weakening the review queue, the audit trail, and any
  per-author automation.
- **Least privilege** — a long-lived personal PAT on every worker is a broad,
  static credential; the fix should scope what a dispatched job can do.

## Decision

**Workers authenticate as a GitHub App (`lentago-claude-runner`), not as a
person.** `gh-token` mints **short-lived installation tokens** from the App key;
`gh-credential-helper` feeds git per-operation so no token is persisted to disk.
Workers open branches and PRs and never merge (see ADR-0002).

**The App's granted scopes are documented as the permission ceiling.** The org
installation grants `contents: write`, `issues: write`, `pull_requests: write`,
`workflows: write`, `metadata: read`. Installation tokens inherit exactly these,
so the documented list *is* the ceiling on a dispatched job's blast radius —
recorded inline in the README (PR #70) rather than left to an API query.

**`workflows: write` was a deliberate two-step posture change.** It was withheld
at first: without it the remote rejects any create/update under
`.github/workflows/**`, so issues touching workflow files had to be routed to a
local session. It was **granted on 2026-07-25** (PR #70), lifting that routing
constraint. The withholding was protecting against an escalation: a bot able to
rewrite CI could in principle rewrite the checks gating its own PR — the honest,
partial answer to which is the ruleset-plus-never-merge backstop discussed in
ADR-0002.

## Alternatives

### Recorded at the time

- **Keep the shared personal PAT** (status quo before #49). Rejected for the three
  costs above: no agent-PR notifications, muddled attribution, and a broad static
  credential on every box.
- **A machine-account fine-grained PAT** — the literal proposal in issue #49
  (create `lentago-runner`, invite it to the org, mint it a fine-grained PAT).
  This fixes attribution and notifications, but a PAT is still a long-lived
  credential distributed to each host. The landed design went further to a GitHub
  App with per-run short-lived tokens and a credential helper, so nothing durable
  is persisted — strictly better on the least-privilege axis the issue itself named.
- **Withhold `workflows: write` indefinitely.** Held for a period as the
  conservative posture, then deliberately reversed on 2026-07-25 once the escalation
  question had an honest answer (PR #70). Recorded as a dated change of posture, not
  a permanent stance.

### Retrospective — not considered at the time

- **OIDC / short-lived cloud-federated identity for the GitHub side** (as the
  Terraform path already uses for AWS, ADR-0005) — *lateral / not applicable.*
  GitHub App installation tokens are already the short-lived, least-privilege
  primitive for acting *on GitHub*; OIDC federation solves the analogous problem for
  a *cloud* API, not for GitHub-native actions. It would not improve this credential
  and doesn't map onto it. Lateral.
- **Per-repo deploy keys instead of an org App** (as the context ledger uses for
  `myosotis`, ADR-0008) — *worse for this use.* A deploy key is a good fit for a
  single repo living outside the fleet's trust domain, but the fleet operates across
  many org repos and needs PR/issue write plus attribution as a distinct actor — an
  org App delivers per-installation scoping, short-lived tokens, and a real bot
  identity that a fleet of deploy keys cannot. Worse fit here; correct for the
  deliberately-isolated ledger repo.

## Consequences

- **Agent PRs are attributable and notifiable.** They are authored by the App, so
  they are distinguishable from human PRs and can drive watch notifications,
  CODEOWNERS, and per-author automation.
- **The blast radius is written down.** The granted-scopes list is the explicit
  ceiling on what any dispatched job can do; reasoning about worst case means reading
  that list, not spelunking the installations API.
- **No durable GitHub credential on a worker.** Tokens are minted short-lived and
  fed per-op; a rebuilt or cloned worker holds no persisted token (only the App key,
  which is a worker secret documented as living on the box, never in this repo).
- The `workflows: write` grant means workflow-file changes no longer have to be
  routed to a local session — but the App still gets **no branch-protection bypass**,
  so required checks and human review continue to gate every merge.
