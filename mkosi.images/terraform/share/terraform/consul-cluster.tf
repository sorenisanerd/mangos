#
# Bootstraps Consul's ACL subsystem
#
resource "vault_consul_secret_backend" "consul" {
  path       = "consul"
  address    = "http://127.0.0.1:8500"
  bootstrap  = true
}

#
# Vault server role, allows Vault to register itself with Consul
#
resource "vault_consul_secret_backend_role" "vault-server" {
  backend            = vault_consul_secret_backend.consul.path
  name               = "vault-server"
  service_identities = ["vault"]
}

#
# Management role, issues management tokens for Consul
#
resource "vault_consul_secret_backend_role" "management" {
  name    = "management"
  backend = vault_consul_secret_backend.consul.path

  consul_policies = [
    "global-management",
  ]
}

resource "consul_acl_role" "agent" {
  name        = "consul-agent"
  description = "Consul Agent \"agent\" token role"
  policies    = []
}

resource "consul_acl_role" "registration" {
  name        = "consul-registration"
  description = "Consul Agent \"config_file_service_registration\" token role"
  policies    = []
}

resource "consul_acl_role" "replication" {
  name        = "consul-replication"
  description = "Consul Agent \"replication\" token role"
  policies    = []
}

resource "consul_acl_role" "default" {
  name        = "consul-default"
  description = "Consul Agent \"default\" token role"
  policies    = [
    consul_acl_policy.all-node-read.id,
    consul_acl_policy.all-service-read.id,
  ]
}

resource "consul_acl_policy" "all-agent-read" {
  datacenters = []
  description = "agent:all:read"
  name        = "all-agent-read"
  rules       = <<-EOT
    agent_prefix "" {
      policy = "read"
    }
    EOT
}

resource "consul_acl_policy" "all-node-read" {
  datacenters = []
  description = "node:all:read"
  name        = "all-node-read"
  rules       = <<-EOT
    node_prefix "" {
      policy = "read"
    }
    EOT
}

resource "consul_acl_policy" "all-service-read" {
  datacenters = []
  description = "service:all:read"
  name        = "all-service-read"
  rules       = <<-EOT
    service_prefix "" {
      policy = "read"
    }
    EOT
}

resource "consul_acl_policy" "all-key-read" {
  name = "all-key-read"
  rules = <<-EOR
    key_prefix "" {
      policy = "read"
    }
    EOR
}

resource "consul_acl_policy" "acl-write" {
  name  = "acl-write"
  rules = <<-EOR
    acl = "write"
    EOR
}

resource "vault_policy" "consul-gossip" {
  name   = "consul-gossip"
  policy = <<-EOP
    path "secrets/mangos/consul/gossip" {
      capabilities = ["read"]
    }
    EOP
}

resource "vault_policy" "consul-management" {
  name   = "consul-management"
  policy = <<-EOP
    path "${vault_consul_secret_backend_role.management.backend}/creds/${vault_consul_secret_backend_role.management.name}" {
      capabilities = ["read"]
    }
    EOP
}


resource "terraform_data" "consul-bootstrap" {
  depends_on = [
    vault_consul_secret_backend.consul,
    vault_consul_secret_backend_role.management,
    vault_mount.secretsv1
  ]
}

resource "terraform_data" "consul-bootstrap-roles" {
  depends_on = [
    consul_acl_role.agent,
    consul_acl_role.registration,
    consul_acl_role.replication,
    consul_acl_role.default,
    consul_acl_policy.nomad-client,
    consul_acl_policy.nomad-server
  ]
}
