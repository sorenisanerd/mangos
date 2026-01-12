resource "nomad_namespace" "admin" {
  name        = "admin"
  description = "Admin namespace"
}

variable "admin_users" {
  description = "Map of admin usernames to their bcrypt hashes."
  type        = map(string)
  default     = {}
}

resource "vault_generic_secret" "admins" {
  for_each  = var.admin_users

  path      = "auth/${vault_auth_backend.userpass.path}/users/${each.key}"
  data_json = jsonencode({
    password_hash = each.value
    token_policies = [
      vault_policy.nomad-management.name,
      vault_policy.ssh-as-anyone.name
    ]
  })
  lifecycle {
    ignore_changes = [data_json]
  }
}

resource "vault_token_auth_backend_role" "mangos-join" {
    role_name = "mangos-join"
    allowed_policies  = [
      vault_policy.node-cert-signer.name,
      vault_policy.sys-auth-node-cert-reader.name,
      vault_policy.lookup-entity.name,
      vault_policy.consul-management.name,
      vault_policy.vault-identity-group-consul-clients-rw.name,
      vault_policy.vault-identity-group-nomad-clients-rw.name,
    ]
}
