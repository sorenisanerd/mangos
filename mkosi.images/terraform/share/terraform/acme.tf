resource "vault_pki_secret_backend_config_cluster" "pki_config_cluster" {
  backend  = vault_mount.pki-svc.path
  path     = "https://vault.service.consul:8200/v1/pki-svc"
  aia_path = "https://vault.service.consul:8200/v1/pki-svc"
}

resource "vault_pki_secret_backend_role" "acme" {
  backend        = vault_mount.pki-svc.path
  name           = "acme"
  ttl            = 72 * 3600
  max_ttl        = 72 * 3600
  allow_any_name = true
  no_store       = false
  key_type       = "any"
}

resource "vault_pki_secret_backend_config_urls" "pki-svc" {
  backend                 = vault_mount.pki-svc.path
  issuing_certificates    = ["{{cluster_aia_path}}/issuer/{{issuer_id}}/der"]
  crl_distribution_points = ["{{cluster_aia_path}}/issuer/{{issuer_id}}/crl/der"]
  ocsp_servers            = ["{{cluster_path}}/ocsp"]
  enable_templating       = true
}

resource "vault_pki_secret_backend_config_acme" "acme" {
  backend                  = vault_mount.pki-svc.path
  enabled                  = true
  default_directory_policy = "role:${vault_pki_secret_backend_role.acme.name}"
  allowed_roles            = [vault_pki_secret_backend_role.acme.name]
  allow_role_ext_key_usage = false
  dns_resolver             = ""
  eab_policy               = "not-required"
}
