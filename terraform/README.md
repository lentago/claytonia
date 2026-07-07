# Worker-pool guest lifecycle — Terraform

This layer owns **guest existence and shape for the bullpen worker pool** —
the five `claude-runner` LXCs (VMIDs 110–112, 116–117 on pve4) and any future
workers — via the [`bpg/proxmox`](https://github.com/bpg/terraform-provider-proxmox)
provider. Nothing else: every other guest on `homelab-cluster` belongs to
[kalmia](https://github.com/lentago/kalmia)'s guest layer.

Adopted from kalmia on 2026-07-07 (#51; kalmia-side release:
[kalmia#37](https://github.com/lentago/kalmia/issues/37)). The rationale:
products own their capacity, and the suite boundary (kalmia = local infra,
solidago = cloud platform) leaves a non-Proxmox worker with no home in
either. Proxmox is the **first platform client** behind the
`modules/proxmox` seam (#47) — a second platform lands as a sibling module,
touching nothing here.

In-guest content is explicitly not this layer's job: `provision/` bootstraps
a worker, the gitops loop converges it. This layer stops at the container
boundary.

## Auth — the `claytonia-tf@pve` identity

A dedicated PVE user + API token, ACL-scoped to the `claytonia` resource
pool so it **cannot mutate non-pool guests**. Creating it is a one-time,
operator-run step (an RBAC grant on shared infra — deliberately not
automated, same posture as kalmia's identity):

```bash
ssh root@pve.local

# The pool: membership is the permission boundary AND the ownership marker.
pvesh create /pools --poolid claytonia \
  --comment "claytonia worker pool — guest lifecycle owned by lentago/claytonia terraform"

pveum user add claytonia-tf@pve --comment "claytonia worker-pool terraform provider (bpg/proxmox)"

# Reuses the cluster's existing custom `Terraform` role (created by kalmia,
# see its terraform/README.md § Auth) — the priv set is shared, the SCOPE is
# not: full guest management only inside the pool, read-only elsewhere.
pveum aclmod /pool/claytonia -user claytonia-tf@pve -role Terraform
pveum aclmod / -user claytonia-tf@pve -role PVEAuditor
pveum aclmod /storage/local-lvm -user claytonia-tf@pve -role PVEDatastoreUser
pveum aclmod /storage/local     -user claytonia-tf@pve -role PVEDatastoreUser
pveum aclmod /sdn/zones/localnetwork -user claytonia-tf@pve -role PVESDNUser

# --privsep=0: the token inherits the user's ACLs. Prints the secret ONCE.
pveum user token add claytonia-tf@pve terraform --privsep=0
```

Local runs source `~/.config/claytonia/proxmox.env` (never committed):

```bash
export PROXMOX_VE_API_TOKEN='claytonia-tf@pve!terraform=<uuid>'
export SSL_CERT_DIR=/etc/ssl/certs
export SSL_CERT_FILE=$HOME/.config/claytonia/pve-root-ca.pem
```

TLS follows kalmia's pattern: the committed [`pve-root-ca.pem`](pve-root-ca.pem)
(a public trust anchor) is added to Go's cert pool via `SSL_CERT_FILE`, with
`SSL_CERT_DIR` keeping the system roots for the S3 backend — so
`insecure = false`.

**Pool membership is substrate, not Terraform-reconciled** (`pool_id` is in
`ignore_changes`): guests are placed in the pool with `pvesh set
/pools/claytonia --vms <ids>` alongside the other root-side steps. The
membership is what scopes the token, so it can't be owned by the token.

## State

Remote state in the shared tfstate bucket (`foundry-tfstate-365184644049`,
key `claytonia/terraform.tfstate`, DynamoDB locking) — see `backend.tf`.
Local runs use the `cpitzi-iac` IAM credentials already on the workstation.

## CI / apply-on-merge

[`.github/workflows/terraform.yml`](../.github/workflows/terraform.yml) runs on
changes under `terraform/**`:

- **pull request** → `validate` (fmt + `init -backend=false` + validate on a
  GitHub-hosted runner) then `plan` on the LAN runner, posted as a PR comment.
- **push to `main`** → `validate` then **`apply -auto-approve`** — merging a
  pool change deploys it. This directory is a fleet **enforced surface**
  (live-state vs. code discipline: never mutate pool guests via `pvesh`/UI
  without codifying here in the same session). The `apply` job serializes under
  a `terraform-apply` concurrency group.

`plan` and `apply` run on the **LAN self-hosted runner** (`runs-on:
[self-hosted, lan]`) because the PVE API is LAN-only. CI reaches AWS (S3 state)
via GitHub OIDC assuming
`arn:aws:iam::365184644049:role/claytonia-github-actions-terraform` (this state
key + the lock table only), and reaches PVE via the `PROXMOX_VE_API_TOKEN` repo
secret (the `claytonia-tf@pve!terraform` token — see § Auth).

### Runner notes (LXC 115, second agent)

The LAN runner is a **second actions-runner agent** on LXC 115 `gha-runner`
(pve4), alongside kalmia's. LXC 115 itself stays kalmia-owned, and claytonia's
apply path deliberately does not depend on claytonia's own workers (bootstrap
cycle). The agent is repo-scoped to claytonia with label `lan`, in its own
install dir with its own systemd service.

- Re-register after a rebuild: `gh api -X POST
  repos/lentago/claytonia/actions/runners/registration-token -q .token`, then
  `config.sh --unattended --url https://github.com/lentago/claytonia --token …
  --name gha-runner-claytonia --labels lan`.
- **Public-repo hardening**: workflow approval required for all external
  contributors (repo Actions setting); secrets not exposed to fork-PR runs; the
  OIDC role trusts only `repo:lentago/claytonia:*` subs, and the `plan` job
  gates on same-repo PRs.

## Scale-out — adding a worker

1. Add a map entry in [`main.tf`](main.tf): next free VMID (118+ — 113–115
   are non-pool guests), next free IP, `mac` pinned after first boot (or
   pre-assigned). Plan + apply.
2. Root-side substrate on the PVE host: add the VMID to the pool
   (`pvesh set /pools/claytonia --vms <id>`), attach the NAS bind mount
   (`pct set <id> -mp0 /mnt/neptune-lentago/claude-jobs,mp=/srv/jobs` — see
   `provision/README.md` step 2, including the `RequiresMountsFor=` drop-in).
3. In-guest: nothing to run — workers are cut from the kalmia runner image
   (substrate + gitops baked; `template_file_id` in the module), so first boot
   just needs the injected secrets and the gitops loop converges from `main`.
   See `provision/README.md` § New worker.
4. Firewalla: a brand-new MAC lands in Device Access Protection `learning`
   state (default-block); classify it or force FireMain re-evaluation if the
   worker can't reach the internet.

## Import gotchas inherited from kalmia

- `operating_system.template_file_id` is required but create-only — set real
  values, `ignore_changes` carries them.
- No explicit `console` block: the provider keeps state blockless; an
  explicit block plans as a perpetual add.
- Bind mounts are root@pam-only at create (HTTP 403 for API tokens) — hence
  no `mount_point` block, and `mount_point` in `ignore_changes`.
- Read the full plan before declaring a diff benign.
