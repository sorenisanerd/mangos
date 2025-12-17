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
  backend = vault_nomad_secret_backend.nomad.backend
  role    = "management"
  type    = "management"
}

resource "vault_policy" "nomad-management" {
  name   = "nomad-management"
  policy = <<-EOP
    path "${vault_nomad_secret_backend.nomad.backend}/creds/${vault_nomad_secret_role.management.role}" {
      capabilities = ["read"]
    }
    EOP
}


locals {
  nomad_workload_default_role = "nomad-workload"
}

#
# Allow Nomad workloads to authenticate with Vault
# using an OIDC token issued by Nomad.
#
resource "vault_jwt_auth_backend" "nomad-workload" {
  description           = "Nomad Workload Identity authentication"
  path                  = "nomad-workload"
  type                  = "oidc"
  oidc_discovery_url    = "https://nomad.service.consul:4646"
  oidc_discovery_ca_pem = local.root-ca-cert
  default_role          = local.nomad_workload_default_role
}

#
# Default role for Nomad workloads. `nomad_namespace`, `nomad_job_id`,
# and `nomad_task` are recorded as metadata in the entity alias.
#
resource "vault_jwt_auth_backend_role" "nomad-workload" {
  backend   = vault_jwt_auth_backend.nomad-workload.path
  role_type = "jwt"
  role_name = local.nomad_workload_default_role

  bound_audiences         = ["vault.io"]
  user_claim              = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  token_type             = "service"
  token_policies         = ["nomad-workload"]
  token_period           = 30 * 60
  token_explicit_max_ttl = 0
}

# Placeholder!
resource "vault_policy" "nomad-workload" {
  name   = "nomad-workload"
  policy = <<-EOP
    path "consul/creds/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_namespace}}" {
      capabilities = ["read"]
    }

    path "secrets/tenants/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_namespace}}/*" {
      capabilities = ["create", "update", "list", "read", "delete"]
    }

    path "secret/nomad/data/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_namespace}}/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_job_id}}/*" {
      capabilities = ["read"]
    }

    path "secret/nomad/data/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_namespace}}/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_job_id}}" {
      capabilities = ["read"]
    }

    path "secret/nomad/data/{{identity.entity.aliases.${vault_jwt_auth_backend.nomad-workload.accessor}.metadata.nomad_namespace}}/*" {
      capabilities = ["list"]
    }

    path "secret/nomad/data/*" {
      capabilities = ["list"]
    }
    EOP
}

#
# Example role with special attributes. `bound_claims` defines
# the requirements that must be met.
#
resource "vault_jwt_auth_backend_role" "vault-plugin-manager" {
  backend   = vault_jwt_auth_backend.nomad-workload.path
  role_type = "jwt"
  role_name = "vault-plugin-manager"

  bound_audiences         = ["vault.${var.domain}"]
  user_claim              = "/nomad_job_id"
  user_claim_json_pointer = true
  claim_mappings = {
    nomad_namespace = "nomad_namespace"
    nomad_job_id    = "nomad_job_id"
    nomad_task      = "nomad_task"
  }
  bound_claims = {
    "nomad_namespace" = "admin"
  }
  token_type             = "service"
  token_policies         = ["vault-plugin-manager", "nomad-workload"]
  token_period           = 30 * 60
  token_explicit_max_ttl = 0
}

#
# Allow Nomad workloads to authenticate with Consul
# using an OIDC token issued by Nomad.
#
resource "consul_acl_auth_method" "nomad-workload" {
  depends_on = [vault_nomad_secret_backend.nomad]

  name = "nomad-workload"
  type = "jwt"
  config_json = jsonencode({
    OIDCDiscoveryURL    = "https://nomad.service.consul:4646"
    OIDCDiscoveryCACert = local.root-ca-cert
    ClaimMappings = {
      nomad_namespace     = "nomad_namespace",
      nomad_job_id        = "nomad_job_id",
      nomad_task          = "nomad_task",
      nomad_service       = "nomad_service"
      nomad_allocation_id = "nomad_allocation_id"
    }
  })
}

#
# Grant any service access to use
# `${nomad_namespace}--${nomad_service}` as its service
# name, providing a crude namespacing mechanism.
#
resource "consul_acl_binding_rule" "nomad-workload-service" {
  auth_method = consul_acl_auth_method.nomad-workload.name
  bind_type   = "service"
  bind_name   = "$${value.nomad_namespace}--$${value.nomad_job_id}"
  selector    = "\"nomad_service\" in value"
}

#
# If a Consul role named "${nomad_namespace}" exists,
# grant it to Nomad workloads.
#
resource "consul_acl_binding_rule" "nomad-workload-role" {
  auth_method = consul_acl_auth_method.nomad-workload.name
  bind_type   = "role"
  bind_name   = "$${value.nomad_namespace}"
  selector    = "\"nomad_service\" not in value"
}

#
# Grant all Nomad workloads `builtin/dns`.
#
resource "consul_acl_binding_rule" "nomad-workload-dns" {
  auth_method = consul_acl_auth_method.nomad-workload.name
  bind_type   = "templated-policy"
  bind_name   = "builtin/dns"
}

#
# Grant all Nomad workloads the `nomad-workload` role.
#
resource "consul_acl_binding_rule" "nomad-workload-nomad-workload" {
  auth_method = consul_acl_auth_method.nomad-workload.name
  bind_type   = "role"
  bind_name   = consul_acl_role.nomad-workload.name
}

resource "consul_acl_role" "nomad-workload" {
  name = "nomad-workload"
  policies = [
    consul_acl_policy.nomad-workload.id,
    consul_acl_policy.global-session.id,
    consul_acl_policy.all-agent-read.id,
  ]
}

resource "consul_acl_policy" "nomad-workload" {
  name        = "nomad-workload"
  description = "Common Nomad workload policy"
  rules       = <<-EOR
    key "autohostpattern" {
      policy = "read"
    }
    EOR
}

resource "consul_acl_policy" "global-session" {
  name        = "global-session"
  description = "Allow creating a session on any node"
  rules       = <<-EOR
    session_prefix "" {
      policy = "write"
    }
    EOR
}

