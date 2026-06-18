# Provisioning a bullpen worker

The scripts here stand up a worker from scratch. They were authored incrementally
during the initial build; run them in order on a fresh unprivileged LXC. Numbers are
the intended sequence.

| Script | What it does |
|---|---|
| `01-create-container.sh` | Base packages, the `claude` service user, SSH key, Claude Code (native installer). *(Run inside the new LXC.)* |
| `02-install-runner.sh` | The job-runner core: `run-job`, `process-inbox`, `cr-submit`, the poll timer, cron surface, README on the share. |
| `03-github-app.sh` | `gh` CLI + GitHub App token plumbing (`gh-token`, credential helper, git identity). |
| `04-project-layer.sh` | Project registry + per-project context layer + project-aware `run-job` + `cr-newproject`. |
| `05-reaper-heartbeat.sh` | Heartbeat timer + reaper (stranded-job recovery) wired into `process-inbox`. |
| `06-transcript-shipper.sh` | Live fleet **transcript shipper**: checks out `homelab-observability`, runs its `deploy-runner-transcript-alloy.sh`, and enables a drift-sync timer. Ships each running job's scrubbed reasoning to Grafana Cloud Loki (`job="claude_transcript"`) for the fleet dashboard's *"stream of consciousness"* panel. Config is canonical in [homelab-observability#71](https://github.com/PitziLabs/homelab-observability/issues/71) — nothing is vendored here. |

> These are the bootstrap history. Once a worker is up and `gitops/install.sh` is run,
> further changes to `bin/`/`systemd/`/`cron/`/`etc/` come from `main` via the gitops
> loop — you don't re-run these to update.

## New worker, from zero

1. **Create the LXC** (unprivileged, static IP on the LAN, `vmbr0`). See the homelab
   inventory for sizing (2 cores / 4 GiB / 20 GB is plenty).
2. **Bind-mount the NAS job dir.** On the PVE host: CIFS-mount the `PitziLabs` share
   with `uid/gid` mapped to the in-container `claude` user (uid 1000 → host 101000 for
   an unprivileged CT), then `pct set <id> -mp0 <hostpath>/claude-jobs,mp=/srv/jobs`.
   Add a `RequiresMountsFor=` drop-in on `pve-container@<id>.service` so the CT starts
   after the mount.
3. **Run `01`–`05`** inside the container (pipe each via `pct exec <id> -- bash -s`).
4. **Set the secrets** (never in git):
   - `claude setup-token` → store with `claude-set-token` → `/etc/claude-runner/token.env`
   - GitHub App: write `/etc/claude-runner/gh-app.env` (APP_ID, INSTALLATION_ID) and
     pipe the App private key to `/etc/claude-runner/gh-app.pem` (mode 640 root:claude).
   - Install the App on the repos this worker should touch.
   - **Transcript shipper (optional):** the Grafana Cloud LOGS push token. Provide it
     when you run `06` (below); it lands in `/etc/default/alloy-transcript` (640
     root:claude) and is inherited by clones.
5. **Run `06`** with the push token to install the transcript shipper:
   `sudo env GRAFANA_CLOUD_LOGS_URL=… GRAFANA_CLOUD_LOGS_USER=… GRAFANA_CLOUD_LOGS_TOKEN=… provision/06-transcript-shipper.sh`
   (Skip if this worker shouldn't ship reasoning. Safe to re-run later with the token.)
6. **Bootstrap gitops:** `gitops/install.sh` — from then on the worker self-updates from `main`.

## Additional worker (clone an existing one)

`pct clone` refuses to copy a bind mount, so:

```bash
pct set <src> -delete mp0
pct clone <src> <new> --hostname claude-runner-N --full --storage local-lvm
pct set <src> -mp0 <hostpath>/claude-jobs,mp=/srv/jobs   # re-attach to source
pct set <new> -mp0 <hostpath>/claude-jobs,mp=/srv/jobs   # and the clone
pct set <new> -net0 name=eth0,bridge=vmbr0,ip=<new-ip>/24,gw=<gw>
# add the RequiresMountsFor drop-in for pve-container@<new>, then start both
```

The clone inherits the auth secrets and code — it's a working worker immediately. Give
it a unique IP + hostname (the hostname becomes its metrics `worker` label). Co-locate
clones on the same host so they share one CIFS mount (kernel-arbitrated claims).

The **transcript shipper** comes along for free on a clone: its Alloy service, the
`/opt/homelab-observability` checkout, the sync timer, and the
`/etc/default/alloy-transcript` push token are all copied. Because the shipper labels
its stream with `constants.hostname` (not a baked value), the clone self-labels with
its own new hostname — no per-clone reconfiguration needed.
