# One bullpen worker per map entry. Shape mirrors the kalmia guest layer the
# pool was adopted from (lentago/kalmia#37) attribute-for-attribute, so the
# brownfield import landed on a clean plan. In-guest content is NOT this
# layer's job: provision/ bootstraps it, the gitops loop converges it.

# Changing a worker's `rebuild` input rebuilds that worker through the
# container's replace_triggered_by. Terraform fires the trigger only when this
# resource is updated, never when it is first created, so the triggers landed
# alone first (#65). It lives in this module because replace_triggered_by can
# reference only resources in the same module.
resource "terraform_data" "rebuild" {
  for_each = var.workers

  input = each.value.rebuild
}

resource "proxmox_virtual_environment_container" "worker" {
  for_each = var.workers

  node_name     = var.node_name
  vm_id         = each.value.vm_id
  pool_id       = var.pool_id
  description   = "Claude Code headless runner — scheduled (cron) + triggered (inbox watcher) jobs. Code in /opt/claude-runner; inbox on NAS at /srv/jobs.\n"
  unprivileged  = true
  started       = true
  start_on_boot = true

  features {
    nesting = true
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_gb
  }

  # No mount_point block: the NAS queue bind mount (/srv/jobs) is root@pam-only
  # at create time (a terraform token gets HTTP 403 "mount point type bind is
  # only allowed for root@pam" — learned in lentago/kalmia#34/#35), so it is
  # attached host-side via `pct set` during provisioning (provision/README.md
  # step 2) and ignored below.

  network_interface {
    name        = "eth0"
    bridge      = var.bridge
    mac_address = each.value.mac
  }

  initialization {
    hostname = each.key

    dns {
      domain  = "local"
      servers = [var.gateway]
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    }
  }

  operating_system {
    # Create-only: the template new workers are cut from. Cannot be
    # reconciled on imported guests — ignored below.
    template_file_id = var.template_file_id
    type             = "debian"
  }

  # No console block: the provider keeps state blockless and an explicit
  # block plans as a perpetual add (kalmia import gotcha).

  lifecycle {
    # Five live workers behind this resource; a plan that wants to replace
    # one is a config bug, not a change to apply.
    prevent_destroy = true
    # operating_system: create-only (above). mount_point: root@pam-attached
    # (above). pool_id: set at create (var.pool_id), never reconciled after;
    # the imported workers were placed in the pool root-side (README.md § Auth).
    ignore_changes       = [operating_system, mount_point, pool_id]
    replace_triggered_by = [terraform_data.rebuild[each.key]]
  }
}
