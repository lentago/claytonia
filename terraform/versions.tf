terraform {
  required_version = ">= 1.7.0" # `import` blocks with for_each land in 1.7

  required_providers {
    proxmox = {
      # Pinned to a minor: the provider is pre-1.0 (SDKv2 → Plugin Framework
      # migration in progress) and minors can break. Bump deliberately, in
      # step with kalmia's pin.
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }
  }
}
