variable "approle-path" {
  default     = "approle"
  type        = string
  description = "Path for approle auth backend in Vault"
}

resource "vault_auth_backend" "approle" {
  path = var.approle-path
  type = "approle"
}
