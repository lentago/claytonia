# Architecture decision records

These entries were **reconstructed on 2026-08-13** from this repo's commit
history, issues and pull requests, `CLAUDE.md`, `docs/roadmap.md`, and Lentago
Labs fleet records — the fleet-wide ADR reconstruction pass. They were not
written at the time each decision was made; they recover decisions the fleet had
already been living by. The **Status date on each entry is the original decision
date** (the earliest firm evidence in the repo), and each is tagged
`reconstructed 2026-08-13`. Where a decision is a standing invariant with no
single dated commit, the date is the earliest recorded evidence and is marked as
such in the entry. Every issue/PR number, file, and date cited below was checked
against this repo during the reconstruction; anything that could not be
corroborated is hedged or omitted in the entry itself.

Each entry follows the fleet ADR style (`# ADR-NNNN: <title>`, `**Status:**`,
then **Context**, **Decision**, **Alternatives**, **Consequences**). The
**Alternatives** section separates options that were *actually recorded in the
evidence* from *retrospective* options explicitly marked
*"retrospective — not considered at the time"* — the retrospective ones are
assessed honestly (worse, better, or lateral) and are **not** presented as if
they were weighed historically.

| ADR | Decision | Original date |
| --- | --- | --- |
| [0001](0001-queue-is-plain-files-atomic-rename.md) | The queue is plain files on the NAS; claims are atomic `rename`; no broker, no lock service | 2026-06 (inception) |
| [0002](0002-workers-branch-and-pr-never-merge.md) | Workers branch + PR and never merge | 2026-06-16 |
| [0003](0003-three-planes-control-cattle-nas.md) | Three planes: control / cattle workers / NAS artifacts | 2026-06-15 |
| [0004](0004-github-app-identity-scoped-tokens.md) | GitHub App identity minting short-lived tokens; granted scopes are the permission ceiling | 2026-07-05 |
| [0005](0005-products-own-capacity-terraform-from-kalmia.md) | Products own their capacity: the worker pool's Terraform adopted from kalmia | 2026-07-07 |
| [0006](0006-at-least-once-delivery-not-idempotent.md) | Crash-safe at-least-once delivery, one retry, deliberately not idempotent | 2026-06 (inception) |
| [0007](0007-observability-log-event-native-no-pushgateway.md) | Observability is log-event-native; Pushgateway explicitly rejected | 2026-06-15 |
| [0008](0008-context-ledger-lives-outside-the-fleet.md) | The context ledger lives outside the fleet it audits | 2026-08-09 |
