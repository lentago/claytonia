# ADR-0008: The context ledger lives outside the fleet it audits

**Status:** Accepted (2026-08-09; reconstructed 2026-08-13)

> Dated to PR #72 (2026-08-09), which shipped the context ledger. This entry is a
> **pointer**: the ledger's own architecture decisions belong in its data repo,
> not here. It records only the decision that couples it to — and separates it
> from — this fleet.

## Context

The context ledger is a fleet-wide, host-side tracker of Claude context drift: it
records what context each host carries and surfaces divergence. An auditor that
lives *inside* the thing it audits shares that thing's failure domains and trust
boundary — if the fleet's identity or storage is compromised or broken, so is the
record of what the fleet was doing. The ledger is documented in
`docs/context-ledger.md` and shipped in PR #72 ("feat: context ledger —
fleet-wide host-side Claude context drift tracking", 2026-08-09).

## Decision

**The ledger's data lives outside the fleet, in a repo the fleet does not own,
reached by a dedicated credential that is never the fleet's identity.**
Specifically (all from `docs/context-ledger.md` and the cited PRs):

- **The data repo is external and personal, not org-owned.** It lived at
  `lentago/myosotis` until 2026-08-12, when it was **transferred out of the org** to
  `cpitzi/myosotis` (PR #93 repointed the ledger; PR #94 caught a straggling
  `provision/07` reference the relocation sweep missed).
- **A dedicated deploy key, never the fleet App.** The committer authenticates to
  `git@github.com:cpitzi/myosotis.git` with a dedicated ed25519 deploy key at
  `/root/.ssh/myosotis_deploy` (comment `myosotis-ledger-committer@claude-runner`),
  pinned via `GIT_SSH_COMMAND` — deliberately **not** the `lentago-claude-runner`
  GitHub App that the rest of the fleet uses (ADR-0004).
- **`myosotis` is never a bullpen project.** `docs/context-ledger.md` states it
  outright: it must never be registered in the project registry — so the fleet cannot
  be dispatched to modify its own audit record.

`git log` in `myosotis` is the ledger's source of truth; Loki/Grafana is a
projection. If they disagree, git wins — and the disagreement is itself a signal.

## Alternatives

### Recorded at the time

- **Keep the ledger data in-org / in-fleet.** Superseded by the 2026-08-12 transfer
  out of the org (#93/#94): moving it to a personal repo puts the audit record
  outside the org's — and the fleet's — control surface.
- **Reuse the fleet's GitHub App for the committer.** Rejected by design: the
  committer uses a dedicated deploy key scoped to the one ledger repo, so the auditor's
  write path does not ride the identity of the systems it audits.

### Retrospective — not considered at the time

- **Fold the ledger into the fleet as just another project** (register `myosotis`,
  let dispatched jobs maintain it) — *worse, and explicitly forbidden.* It would reuse
  all the existing machinery, but it destroys the property this decision exists for:
  the fleet could then be told to rewrite its own audit trail, and the auditor would
  share the fleet's trust boundary and failure domain. `docs/context-ledger.md` names
  this as a hard "never." Worse.
- **A managed audit-log service** (ship the drift record to an external SaaS audit/log
  store instead of a git repo) — *lateral.* It would give retention policies and
  tamper-evidence features out of the box, but at the cost of a third-party dependency
  and a data model less legible than "one commit per changed host, `git log` is truth."
  For a homelab lab exhibit, a plain external git repo with a scoped deploy key is
  simpler and inspectable; a SaaS store trades that for features this scale doesn't
  need. Lateral.

## Consequences

- **The auditor and the audited don't share a trust boundary.** A compromise or
  outage of the fleet's identity/storage does not by itself corrupt or silence the
  ledger, because the ledger writes to a separate repo with a separate credential.
- **`git` is the source of truth; observability is projection.** A Loki/Grafana gap
  is itself diagnosable against the committed tree — the ledger degrades legibly.
- **This ADR stays a pointer.** The ledger's substantive design decisions (signal
  model, committer/reaper behavior, alert runbook) live with its data, not in this
  repo's ADR set — recorded here only is the coupling decision: it audits the fleet
  precisely by living outside it.
- The repo transfer means external references must track `cpitzi/myosotis`, not
  `lentago/myosotis`; the #93/#94 sweep is the precedent for keeping those pointers
  correct.
