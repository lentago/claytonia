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
| `01-create-container.sh` | base pkgs, Node 22 LTS, `claude` user and its one sudoers rule (#177), ssh key, Claude Code (pinned, checksummed) | baked → kalmia `forge/runner/substrate.sh` (Node 22 not yet in the image build: lentago/kalmia#156; the reference step here is what the running workers got by hand on 2026-10-13) |
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
   -mp0 /mnt/neptune-lentago/claude-jobs,mp=/srv/jobs`, plus a drop-in on
   `pve-container@<id>.service` so the CT starts after the mount:
   `/etc/systemd/system/pve-container@<id>.service.d/wait-for-nas.conf` holding
   `[Unit]` and `RequiresMountsFor=/mnt/neptune-lentago`. The path must be the
   bind source's mount on pve4. An older drop-in that named
   `/mnt/neptune-pitzilabs` ordered against nothing; #65's rebuilds replaced all
   of them.
3. **Inject the secrets** — the image ships empty placeholders; real values are
   never baked:
   - OAuth: `claude setup-token` → `claude-set-token` (as root:
     `ssh root@<worker> claude-set-token`) → `/etc/claude-runner/token.env`.
   - GitHub App: write `/etc/claude-runner/gh-app.env` (`APP_ID`, `INSTALLATION_ID`)
     and the App private key to `/etc/claude-runner/gh-app.pem`, both `600 root:root`
     (#177; `cr-harden` sets them so within a minute if they land otherwise);
     install the App on the repos this worker should touch.
4. **First boot** — the image's baked, enabled gitops timer
   (`claytonia-gitops.timer`, runner image v3) pulls `main`, the
   pollers start, and the worker begins claiming jobs. There are no scripts to
   run: it is live once it has its NAS mount and token. Within a minute of that
   first pull, `cr-harden` (cron, as root) replaces whatever sudoers rule the image
   carries with the one claytonia allows, and sets the App key to `600 root:root`
   (#177).

### Transcript shipper (optional, per worker)

The transcript-shipper units ride in the image (gitops-deployed from `systemd/` +
`bin/`), but the initial `drosera` checkout, the Alloy install, and the Grafana
Cloud LOGS push token are **not** baked. To activate on a worker, run `06` with
the token, as root (the `claude` user has no sudo beyond the token broker, #177):

```bash
env GRAFANA_CLOUD_LOGS_URL=… GRAFANA_CLOUD_LOGS_USER=… GRAFANA_CLOUD_LOGS_TOKEN=… \
  provision/06-transcript-shipper.sh
```

It lands in `/etc/default/alloy-transcript` (640 root:claude) and is inherited by
clones. Skip it if this worker shouldn't ship reasoning; safe to re-run later.

### Context ledger — RETIRED 2026-09-21

The context ledger (step `07`, the `context-snapshot` / `context-ledger-commit`
units and their `bin/` scripts) was decommissioned on 2026-09-21 and removed from
this repo. A new worker gets nothing to do here. The decision record and the
teardown note are in
[`../docs/adr/0008-context-ledger-lives-outside-the-fleet.md`](../docs/adr/0008-context-ledger-lives-outside-the-fleet.md);
the operational doc it cites lives in git history.

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
`/opt/drosera` checkout, the sync timer, and the
`/etc/default/alloy-transcript` push token are all copied. Because the shipper
labels its stream with `constants.hostname` (not a baked value), the clone
self-labels with its own new hostname — no per-clone reconfiguration needed.

## Rebuilding a worker

A rebuild recreates one worker from the current runner image through its
Terraform trigger ([`terraform/README.md`](../terraform/README.md) § Rebuilding
a worker). The scripts are in [`rebuild/`](rebuild/). They run from the
workstation, one VMID at a time, through pve4:

```bash
ssh root@pve.local "ssh pve4 bash -s -- <vmid>" < provision/rebuild/<script>
```

They read no secret values and print none. Each refuses a VMID that is not a
`claude-runner*` worker in the `claytonia` pool. One worker at a time, in this order:

| Step | Script | What it does |
|---|---|---|
| R-1 | `r1-unpushed.sh` | Read-only, as `claude`: list clones under `~/work` and `~/private` with dirty files, unpushed commits or stashes. Gitignored files are counted as `INFO`, not flagged. Archive anything worth keeping as `git format-patch` files plus a `NOTE.md` under `/srv/jobs/archive/rebuild-<host>/` before going on. |
| R-2 | `r2-stage-secrets.sh` | Copy `token.env`, `gh-app.env`, `gh-app.pem`, `google.env` and `/etc/default/alloy-transcript` into `/root/rebuild-<vmid>` on pve4 (root-only). Also copy the peer-runtime files `gemini.env`, `gemini-sa.json` and `codex.env` when the worker has them (#166). Stops on an empty file. |
| R-3 | `r3-drain.sh` | Stop `claude-inbox.timer`, then wait until the worker holds no job (heartbeat kept on). If the service state can't be read, the worker does not count as drained. |
| — | the rebuild PR | Arm it only after R-3 prints `DRAINED`. Merging it is the rebuild. |
| R-4–R-6 | `r4-r6-restore.sh` | Restore the secrets: `token.env`, `google.env` and the runtime files `640 root:claude`; `gh-app.*` `600 root:root`. Wait until `cr-harden` has narrowed sudoers to the broker. Only then attach the NAS (mp0 and the drop-in above), reboot, reinstall the transcript shipper, and shred the staging copy. If it stops part-way, it says so and keeps the staging copy: fix the cause and rerun it. A rerun repeats every step, including the reboot. |
| R-7 | on the workstation | Remove the worker's old host key: `ssh-keygen -R <ip>`. Compare the new key's fingerprint inside the CT with `ssh-keyscan <ip>` before accepting it. The `ssh claude-runner` alias needs nothing else, because the image ships the operator key. |
| verify | `verify.sh` | After the first gitops pass logs `deploy complete`: shape, pool, mount, drop-in, units, loop, secret modes, broker-only sudo, CLIs. It must end `ALL OK`. Runtime secrets not yet installed are reported as `INFO … absent`. |
| gate | `gate.sh` | Queue one read-only Haiku job and start this worker's poller at once. It prints `GATE OK` only when the job is `DONE` and this worker's journal shows the run. Another worker can win the claim race, so on `GATE FAIL` rerun it. The next worker starts only after `GATE OK`. |

The runtime secrets are installed by hand on every worker, `root:claude 0640`,
and R-2/R-4 carry them across a rebuild. A worker rebuilt before they exist
simply has none to carry.

## Masked first-boot units

`proxmox-regenerate-snakeoil.service` and `first-boot-complete.target` are PVE-template
artifacts that never run in these LXCs; left unmasked, systemd logs a condition-skip
line for each on every timer activation ([#120](https://github.com/lentago/claytonia/issues/120)).
They are masked by zero-length files in `systemd/` (deployed by gitops, so image-built
and live workers both get them) and by `systemctl mask` in `02-install-runner.sh`.

**Verify on a worker after deploy:**

```bash
systemctl is-enabled proxmox-regenerate-snakeoil.service first-boot-complete.target   # → masked, masked
journalctl --since -3min | grep -E 'snakeoil|first-boot-complete'                     # → no output
```
