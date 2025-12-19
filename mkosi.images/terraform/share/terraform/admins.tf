resource "nomad_namespace" "admin" {
  name        = "admin"
  description = "Admin namespace"
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
