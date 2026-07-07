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
  description = "LXC template new workers are cut from — becomes a kalmia-baked image once lentago/kalmia#36 ships."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}
