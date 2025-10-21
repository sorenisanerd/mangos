#
# Vault Nomad secrets backend
#
resource "vault_nomad_secret_backend" "nomad" {
  backend                   = var.nomad-vault-path
  description               = "Nomad secrets engine"
  default_lease_ttl_seconds = var.nomad-vault-default-lease-ttl
  max_lease_ttl_seconds     = var.nomad-vault-max-lease-ttl
  max_ttl                   = var.nomad-vault-max-ttl
  address                   = var.nomad-address
  ttl                       = var.nomad-vault-ttl
  ca_cert                   = local.svc-ca
}

#
# Nomad servers are the ones that DO NOT run workloads, but make policy
# and scheduling decisions. Servers may also be clients, but we try to
# keep the policies separate.
#
# This is the Consul policy for Nomad servers.
#
# From https://developer.hashicorp.com/nomad/tutorials/integrate-consul/consul-service-mesh#create-a-nomad-server-policy
#
resource "consul_acl_policy" "nomad-server" {
  datacenters = []
  description = "Nomad Server Policy"
  name        = "nomad-server"
  rules       = <<-EOT
    agent_prefix "" {
      policy = "read"
    }

    node_prefix "" {
      policy = "read"
    }

    service_prefix "" {
      policy = "write"
    }

    acl = "write"
    EOT
}

#
# Nomad clients are the nodes that actually run workloads.
#
# This is the Consul policy for Nomad clients.
#
# https://developer.hashicorp.com/nomad/tutorials/integrate-consul/consul-service-mesh#create-a-nomad-client-policy
#
resource "consul_acl_policy" "nomad-client" {
  datacenters = []
  description = "Nomad Client Policy"
  name        = "nomad-client"
  rules       = <<-EOT
    agent_prefix "" {
      policy = "read"
    }

    node_prefix "" {
      policy = "read"
    }

    service_prefix "" {
      policy = "write"
    }

    key_prefix "" {
      policy = "read"
    }
    EOT
}

resource "vault_nomad_secret_role" "management" {
  backend   = vault_nomad_secret_backend.nomad.backend
  role      = "management"
  type      = "management"
}

resource "vault_policy" "nomad-management" {
  name   = "nomad-management"
  policy = <<-EOP
    path "${vault_nomad_secret_backend.nomad.backend}/creds/${vault_nomad_secret_role.management.role}" {
      capabilities = ["read"]
    }
    EOP
}
