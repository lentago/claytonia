# ADR-0005: Products own their capacity — the worker pool's Terraform adopted from kalmia

**Status:** Accepted (2026-07-07; reconstructed 2026-08-13)

## Context

Until 2026-07-07, the worker LXCs existed as guests but their *lifecycle* — that
they exist at all, and their shape — was owned by kalmia's guest layer, alongside
every other guest on the Proxmox cluster. Issue #51 ("Own runner capacity: adopt
the worker-pool guest layer from kalmia", 2026-07-07) reframed this: **a product
should own the capacity it runs on.** The suite boundary (kalmia = local infra,
solidago = cloud platform) left a future non-Proxmox worker with no natural home
in either — so claytonia should own its pool directly.

## Decision

**This repo's `terraform/` owns guest existence and shape for the worker pool** —
the five `claude-runner` LXCs in the `claytonia` Proxmox resource pool
(VMIDs 110–112, 116–117) — and nothing else; every other guest on the cluster
stays kalmia's. Three sub-decisions, all corroborated in PR #52 ("Adopt the
worker-pool guest layer", merged 2026-07-07) and `terraform/README.md`:

- **Adopted, not rebuilt.** The state was moved from kalmia in paired state-move
  PRs (claytonia PR #52 alongside `kalmia#37`/`kalmia#40`). The shape mirrors
  kalmia's proven config attribute-for-attribute; the pre-cutover plan against live
  showed **"5 to import, 0 real changes"** — **no guest was recreated**.
- **Proxmox is the first platform client behind a module seam.** The provider sits
  behind a `modules/proxmox` seam so "a second platform lands as a sibling module
  without touching this one." Both `terraform/README.md` and PR #52 cite **#47** for
  this — framing the seam as an expression of the fleet's platform-agnostic /
  portability principle (issue #47), even though #47 is nominally about
  platform-agnostic *workers* rather than the Terraform layer. The connection is the
  repo's own, and it is recorded that way here.
- **The apply path is deliberately independent of the workers it manages.** PR #53
  ("Add terraform CI: plan-on-PR / apply-on-merge on the LAN runner", 2026-07-07)
  wires CI to a LAN runner (LXC 115) — *not* one of the pool workers — because the
  Proxmox API is not reachable from GitHub-hosted runners, and, per `CLAUDE.md`, so
  the loop that manages the workers can't be crippled by the workers it manages (the
  bootstrap-cycle concern). Apply runs `terraform apply -auto-approve` only on merge
  to `main`, serialized by a concurrency group so two merges can't race on state.

Authentication is a dedicated `claytonia-tf@pve` identity, ACL-scoped to the
`claytonia` resource pool so it cannot mutate non-pool guests — an operator-run
RBAC grant, deliberately not automated (`terraform/README.md` § Auth).

## Alternatives

### Recorded at the time

- **Leave the pool in kalmia's guest layer** (status quo). Rejected in #51: it
  violates "products own their capacity," and the suite boundary leaves a future
  non-Proxmox worker homeless in kalmia's local-infra scope.
- **Recreate the guests under the new root** rather than importing state. Rejected
  in PR #52 by adopting kalmia's config attribute-for-attribute and importing (5 to
  import, 0 real changes) so no running worker is destroyed during the cutover.
- **Run Terraform CI on a pool worker** rather than a separate LAN runner. Rejected
  (#53): the Proxmox API isn't reachable from GitHub-hosted runners, and the apply
  path is kept independent of the workers it manages to avoid a bootstrap cycle.

### Retrospective — not considered at the time

- **Keep provisioning fully hand-run** (`provision/01–05` as the only path, no
  Terraform for guest existence) — *worse.* It leaves guest lifecycle as tribal
  operator knowledge with no plan/apply record and no drift detection; "how many
  workers exist and of what shape" would live only in someone's head and the live
  cluster. Codifying existence in Terraform makes capacity a reviewed, merge-gated
  change (the same change-management posture as everything else here). Worse.
- **A single shared Terraform root for the whole homelab** (claytonia's pool and
  kalmia's guests in one state) — *worse / rejected in spirit.* It would remove the
  paired state-move dance, but it re-couples every product's capacity into one blast
  radius and one state file, which is exactly the ownership boundary #51 set out to
  draw. Products owning their own capacity — separate roots, separate state,
  pool-scoped credentials — is the deliberate opposite. Worse.

## Consequences

- **Capacity is a reviewed change.** Adding or resizing the pool is a Terraform PR:
  plan-on-PR posts the plan as a comment, a human merges, apply-on-merge runs on the
  LAN runner. New workers self-converge from `main` on first boot.
- **The ownership boundary is explicit and enforced by RBAC.** The `claytonia-tf@pve`
  token is pool-scoped, so this root literally cannot mutate kalmia's guests — the
  "products own their capacity" line is a permission boundary, not just a convention.
- **A second platform is a sibling module.** The `modules/proxmox` seam means adding,
  say, a cloud worker platform lands as a new module without disturbing the Proxmox
  path — the structural payoff of treating Proxmox as the first client rather than
  the only one.
- **Root-side substrate stays external.** The NAS bind mount and PVE-pool membership
  remain operator/substrate-managed (`ignore_changes` on `mount_point`/`pool_id`),
  never token-reconciled — so Terraform owns guest shape without reaching into shared
  infrastructure it shouldn't touch.
