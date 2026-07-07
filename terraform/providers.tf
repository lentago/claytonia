provider "proxmox" {
  endpoint = "https://192.168.139.8:8006/"

  # Auth: PROXMOX_VE_API_TOKEN env var (claytonia-tf@pve!terraform token,
  # ACL-scoped to /pool/claytonia) — never in code, tfvars, or CI logs.
  # Creation commands: README.md § Auth.

  # The cluster serves a self-signed cert issued by the PVE Cluster Manager
  # CA. Rather than skip verification, both run contexts trust that CA out of
  # band (the provider has no CA-file argument): SSL_CERT_FILE points Go at
  # the committed pve-root-ca.pem while SSL_CERT_DIR keeps the system roots.
  # Same pattern as kalmia — see README.md § Auth.
  insecure = false
}
