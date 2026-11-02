variable "workers" {
  description = "Worker name → Proxmox identity: vm_id, static LAN IP (/24 assumed), pinned MAC, rebuild trigger."
  type = map(object({
    vm_id = number
    ip    = string
    mac   = string
    # Changing this string rebuilds that one worker (destroy, then create from
    # the template) through terraform_data.rebuild, but only while the
    # container's prevent_destroy is off; with it on, the plan errors.
    rebuild = optional(string, "claytonia#65: baseline")
  }))
}

variable "pool_id" {
  # Set at create so a replacement lands back in the pool. The token's
  # VM.Allocate comes only from its /pool/claytonia ACL, and a destroy takes the
  # VMID out of the pool, so a create that names no pool is refused (#65).
  description = "PVE resource pool new workers are created in."
  type        = string
  default     = "claytonia"
}

variable "node_name" {
  description = "PVE node hosting the pool."
  type        = string
  default     = "pve4"
}

variable "bridge" {
  description = "LAN bridge for eth0."
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "LAN gateway, also the DNS server (Firewalla)."
  type        = string
  default     = "192.168.139.1"
}

variable "cores" {
  type    = number
  default = 2
}

variable "memory_mb" {
  type    = number
  default = 4096
}

variable "swap_mb" {
  type    = number
  default = 512
}

variable "disk_gb" {
  type    = number
  default = 20
}

variable "datastore_id" {
  description = "Datastore for worker rootfs."
  type        = string
  default     = "local-lvm"
}

variable "template_file_id" {
  # The kalmia-baked runner image (lentago/kalmia#36): substrate + claytonia's
  # gitops loop, so a fresh worker needs only its NAS mount + secrets. Pinned to
  # a version — bump deliberately when a new image ships. Create-only and in the
  # resource's ignore_changes, so this affects NEW workers only; the imported
  # five are untouched. See provision/README.md § New worker.
  # v3 (lentago/kalmia#255): kalmia e351a4c with claytonia@0e91b2a, adding the
  # Gemini and Codex CLIs (#166); sha256 feb48f17ab7f8525e93253906fd5c019811911441171081ee40157e5bb064f44.
  # Its sudoers file still holds the blanket rule; cr-harden narrows it to the
  # token broker within a minute of first boot (#177).
  description = "LXC template (kalmia runner image) new workers are cut from."
  type        = string
  default     = "neptune:vztmpl/claytonia-runner-v3.tar.zst"
}
