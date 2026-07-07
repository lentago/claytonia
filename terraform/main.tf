# The bullpen worker pool — the fleet's unit of capacity.
#
# Adopted from kalmia's guest layer on 2026-07-07 (#51; release:
# lentago/kalmia#37): products own their capacity, and the suite boundary
# (kalmia = local infra, solidago = cloud platform) leaves a future
# non-Proxmox worker with no home in either.
#
# This map is the pool's source of truth: scaling out is one new entry plus
# the root-side substrate steps in README.md § Scale-out. MACs are pinned so
# a worker's DHCP-reservation/Firewalla identity survives any rebuild.
locals {
  workers = {
    "claude-runner"   = { vm_id = 110, ip = "192.168.139.10", mac = "BC:24:11:7A:1A:E1" }
    "claude-runner-2" = { vm_id = 111, ip = "192.168.139.11", mac = "BC:24:11:A8:C7:AF" }
    "claude-runner-3" = { vm_id = 112, ip = "192.168.139.12", mac = "BC:24:11:05:FD:71" }
    "claude-runner-4" = { vm_id = 116, ip = "192.168.139.17", mac = "BC:24:11:FA:D4:3E" }
    "claude-runner-5" = { vm_id = 117, ip = "192.168.139.18", mac = "BC:24:11:BE:09:18" }
  }
}

# Proxmox is the first platform client behind this module seam (#47). A
# second platform lands as a sibling module consuming the same worker spec —
# touching nothing in this one.
module "proxmox" {
  source  = "./modules/proxmox"
  workers = local.workers
}

# Brownfield adoption (2026-07-07): all five workers pre-exist — released
# from kalmia state (lentago/kalmia#37), imported here. Import blocks are
# retained as a record; they no-op once state holds the resources.
import {
  for_each = local.workers
  to       = module.proxmox.proxmox_virtual_environment_container.worker[each.key]
  id       = "pve4/${each.value.vm_id}"
}

output "workers" {
  description = "Worker name → LAN IP."
  value       = { for name, w in local.workers : name => w.ip }
}
