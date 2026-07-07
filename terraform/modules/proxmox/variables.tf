variable "workers" {
  description = "Worker name → Proxmox identity: vm_id, static LAN IP (/24 assumed), pinned MAC."
  type = map(object({
    vm_id = number
    ip    = string
    mac   = string
  }))
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
  description = "LXC template (kalmia runner image) new workers are cut from."
  type        = string
  default     = "neptune:vztmpl/claytonia-runner-v1.tar.zst"
}
