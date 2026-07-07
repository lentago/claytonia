# Provisioning a bullpen worker

A worker is a `pct create` from the **kalmia runner image**
(`neptune:vztmpl/claytonia-runner-*`, built by kalmia's forge —
[kalmia#36](https://github.com/lentago/kalmia/issues/36)) plus its NAS mount and
secrets. The image already carries the OS substrate **and** this repo's gitops
loop, so a fresh worker self-converges to `main` on first boot.

**The `NN-*.sh` scripts here are legacy / reference** — the hand-run bootstrap
they document is superseded by the image (adopted 2026-07-07,
[#54](https://github.com/lentago/claytonia/issues/54)). The forge split their two
roles: the OS **substrate** (packages, `claude` user, Claude Code, gh, secret
placeholders) moved into kalmia's `forge/runner/substrate.sh`, and the runner
**software** (`bin/`/`systemd/`/`cron/`/`etc/`) was always the gitops loop's job.
`06` is the exception — it stays the documented way to activate the transcript
shipper (below).

| Script | What it did | Now |
|---|---|---|
| `01-create-container.sh` | base pkgs, `claude` user, ssh key, Claude Code | baked → kalmia `forge/runner/substrate.sh` |
| `02-install-runner.sh` | runner core + poller + cron | gitops-deployed (`bin/`/`systemd/`/`cron/`) |
| `03-github-app.sh` | gh CLI + App token plumbing + git identity | gh + identity baked; `gh-token`/helper gitops-deployed |
| `04-project-layer.sh` | project registry + project-aware run-job | gitops-deployed (`bin/`); registry lives on the NAS |
| `05-reaper-heartbeat.sh` | heartbeat + reaper | gitops-deployed (`bin/`/`systemd/`) |
| `06-transcript-shipper.sh` | transcript shipper (drosera-canonical) | **current** — see § Transcript shipper |

## New worker, from the image

1. **Create the LXC** — add a map entry in
   [`terraform/main.tf`](../terraform/main.tf) and apply, then add the VMID to the
   `claytonia` PVE pool. The image supplies the substrate + an enabled gitops
   loop; sizing defaults live in the module. See
   [`terraform/README.md`](../terraform/README.md) § Scale-out.
2. **Bind-mount the NAS job dir** (root@pam-only, so not baked): `pct set <id>
   -mp0 <hostpath>/claude-jobs,mp=/srv/jobs`, plus a `RequiresMountsFor=` drop-in
   on `pve-container@<id>.service` so the CT starts after the mount.
3. **Inject the secrets** — the image ships empty placeholders; real values are
   never baked:
   - OAuth: `claude setup-token` → `claude-set-token` → `/etc/claude-runner/token.env`.
   - GitHub App: write `/etc/claude-runner/gh-app.env` (`APP_ID`, `INSTALLATION_ID`)
     and the App private key to `/etc/claude-runner/gh-app.pem` (640 root:claude);
     install the App on the repos this worker should touch.
4. **First boot** — `bullpen-gitops.timer` (baked, enabled) pulls `main`, the
   pollers start, and the worker begins claiming jobs. There are no scripts to
   run: it is live once it has its NAS mount and token.

### Transcript shipper (optional, per worker)

The transcript-shipper units ride in the image (gitops-deployed from `systemd/` +
`bin/`), but the initial `drosera` checkout, the Alloy install, and the Grafana
Cloud LOGS push token are **not** baked. To activate on a worker, run `06` with
the token:

```bash
sudo env GRAFANA_CLOUD_LOGS_URL=… GRAFANA_CLOUD_LOGS_USER=… GRAFANA_CLOUD_LOGS_TOKEN=… \
  provision/06-transcript-shipper.sh
```

It lands in `/etc/default/alloy-transcript` (640 root:claude) and is inherited by
clones. Skip it if this worker shouldn't ship reasoning; safe to re-run later.

## Additional worker (clone an existing one)

Cloning is still handy for a quick add — a clone inherits the secrets and the
transcript token, so it's a working worker immediately (creating from the image
instead means re-injecting secrets). `pct clone` refuses to copy a bind mount, so:

```bash
pct set <src> -delete mp0
pct clone <src> <new> --hostname claude-runner-N --full --storage local-lvm
pct set <src> -mp0 <hostpath>/claude-jobs,mp=/srv/jobs   # re-attach to source
pct set <new> -mp0 <hostpath>/claude-jobs,mp=/srv/jobs   # and the clone
pct set <new> -net0 name=eth0,bridge=vmbr0,ip=<new-ip>/24,gw=<gw>
# add the RequiresMountsFor drop-in for pve-container@<new>, then start both
```

Give the clone a unique IP + hostname (the hostname becomes its metrics `worker`
label). Co-locate clones on the same host so they share one CIFS mount
(kernel-arbitrated claims). Whichever path you use, record the guest in
`terraform/main.tf` so its existence stays codified.

The **transcript shipper** comes along for free on a clone: its Alloy service, the
`/opt/homelab-observability` checkout, the sync timer, and the
`/etc/default/alloy-transcript` push token are all copied. Because the shipper
labels its stream with `constants.hostname` (not a baked value), the clone
self-labels with its own new hostname — no per-clone reconfiguration needed.
