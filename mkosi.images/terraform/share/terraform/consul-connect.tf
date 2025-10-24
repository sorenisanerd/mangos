#
# These resources are based on how Consul would have created them.
#
resource "vault_mount" "connect-root" {
  path                      = "consul-connect-root-ca"
  type                      = "pki"
  description               = "Root CA backend for Consul Connect"
  max_lease_ttl_seconds     = 60 * 60 * 24 * 3650 # 10 year ttl
  default_lease_ttl_seconds = 60 * 60 * 24 * 3650 # 10 year ttl
}

resource "vault_mount" "connect-intermediate" {
  path                      = "consul-connect-intermediate-${var.datacenter}-ca"
  type                      = "pki"
  description               = "Intermediate CA backend for Consul Connect"
  max_lease_ttl_seconds     = 60 * 60 * 24 * 365 # 1 year ttl
  default_lease_ttl_seconds = 60 * 60 * 24 * 365 # 1 year ttl
}

resource "vault_pki_secret_backend_root_cert" "connect-root" {
  backend  = vault_mount.connect-root.path
  type     = "internal"
  key_type = "ec"
  key_bits = 256

  # Consul would have used something like "pri-w3iz5nr.vault.ca.bf437316.consul"
  # (that's a real example, btw), but there are no particular requirements
  # for its format or anything. Making it human readable like
  # this makes it easier to realize that it was set by a human.
  common_name = "consul-connect-root-ca-2025"

  # Consul also sets a couple more SANs (from same example):
  # DNS:pri-w3iz5nr.vault.ca.bf437316.consul (same as the CN)
  # URI:spiffe://bf437316-8d17-f661-6cd8-b8d6f37fbcfe.consul
  #
  # As far as I can tell neither Consul nor the SPIFFE spec
  # requires them, so I'm omitting them for simplicity.
  #
  # uri_sans = ["spiffe://bf437316-8d17-f661-6cd8-b8d6f37fbcfe.consul"]
}

#resource "vault_pki_secret_backend_intermediate_cert_request" "connect-intermediate" {
#  backend     = vault_mount.connect-intermediate.path
#  type        = "internal"
#  common_name = "Intermediate CA"
#}

#
# This is what Consul's documentation refers to as "Consul-managed PKI paths"
#
# https://developer.hashicorp.com/consul/docs/connect/ca/vault#consul-managed-pki-paths
#
# Step 3 in the documentation creates a policy that allows Consul to renew
# its own token, but we provide that capability using the `renew-self` and
# `lookup-self` policies, so those are left out.
#
resource "vault_policy" "consul-managed-connect-pki" {
  name   = "consul-managed-connect-pki"
  policy = <<-eop
    #
    # "1. Allow Consul to create and manage both PKI engines:"
    #
    path "/sys/mounts/${vault_mount.connect-root.path}" {
      capabilities = [ "create", "read", "update", "delete", "list" ]
    }

    path "/sys/mounts/${vault_mount.connect-intermediate.path}" {
      capabilities = [ "create", "read", "update", "delete", "list" ]
    }

    path "/sys/mounts/${vault_mount.connect-intermediate.path}/tune" {
      capabilities = [ "update" ]
    }

    #
    # "2. Allow Consul full use of both PKI engines:"
    #
    path "/${vault_mount.connect-root.path}/*" {
      capabilities = [ "create", "read", "update", "delete", "list" ]
    }

    path "/${vault_mount.connect-intermediate.path}/*" {
      capabilities = [ "create", "read", "update", "delete", "list" ]
    }
    eop
}

#
# Per https://developer.hashicorp.com/consul/docs/connect/ca/vault#additional-vault-acl-policies-for-sensitive-operations
#
resource "vault_policy" "policy-vault-special-root-rotation" {
  name   = "consul-connect-special-privileges"
  policy = <<-eop
    path "/${vault_mount.connect-root.path}/root/sign-self-issued" {
      capabilities = [ "sudo", "update" ]
    }
    eop
}

#
# This is what Consul's documentation refers to as "Vault-managed PKI paths"
#
# https://developer.hashicorp.com/consul/docs/connect/ca/vault#vault-managed-pki-paths
#
# Step 3 in the documentation creates a policy that allows Consul to renew
# its own token, but we provide that capability using the `renew-self` and
# `lookup-self` policies.
#
resource "vault_policy" "vault-managed-connect-pki" {
  name   = "vault-managed-connect-pki"
  policy = <<-EOP
    # "1. Allow Consul to read both PKI mounts and to manage the
    #  intermediate PKI mount configuration"
    path "/sys/mounts/${vault_mount.connect-root.path}" {
      capabilities = [ "read" ]
    }

    path "/sys/mounts/${vault_mount.connect-intermediate.path}" {
      capabilities = [ "read" ]
    }

    path "/sys/mounts/${vault_mount.connect-intermediate.path}/tune" {
      capabilities = [ "update" ]
    }

    # "2. Allow Consul read-only access to the root PKI engine, to
    #  automatically rotate intermediate CAs as needed, and full use
    #  of the intermediate PKI engine"
    path "/${vault_mount.connect-root.path}/" {
      capabilities = [ "read" ]
    }

    path "/${vault_mount.connect-root.path}/root/sign-intermediate" {
      capabilities = [ "update" ]
    }

    path "/${vault_mount.connect-intermediate.path}/*" {
      capabilities = [ "create", "read", "update", "delete", "list" ]
    }
    EOP
}

resource "vault_approle_auth_backend_role" "consul-connect" {
  backend       = vault_auth_backend.approle.path
  role_name     = "consul-connect"
  token_max_ttl = 24 * 60 * 60
  token_policies = [
    # This top one is only needed during root rotation.
    # Don't enable it unless you need to rotate root CA.
    #    vault_policy.policy-vault-special-root-rotation.name,
    vault_policy.consul-managed-connect-pki.name,
    vault_policy.renew-self.name,
    vault_policy.lookup-self.name
  ]
  token_ttl = 60 * 60
}

resource "vault_approle_auth_backend_role_secret_id" "consul-connect" {
  backend   = vault_auth_backend.approle.path
  role_name = vault_approle_auth_backend_role.consul-connect.role_name
}

resource "consul_certificate_authority" "ca" {
  connect_provider = "vault"

  config_json = jsonencode({
    RootPKIPath         = vault_mount.connect-root.path
    IntermediatePKIPath = vault_mount.connect-intermediate.path
    Address             = "https://vault.service.consul:8200/"
    CAFile              = "/var/lib/consul/ssl/ca.pem"
    AuthMethod = {
      Type = "approle"
      Params = {
        role_id   = vault_approle_auth_backend_role.consul-connect.role_id
        secret_id = vault_approle_auth_backend_role_secret_id.consul-connect.secret_id
      }
    }
    IntermediateCertTTL = "8760h0m0s"
  })
}

#
# Not needed at all for bootstrapping, but it doesn't hurt anything to
# set it early.
#
resource "consul_config_entry" "proxy_defaults" {
  kind = "proxy-defaults"
  # Note that only "global" is currently supported for proxy-defaults and that
  # Consul will override this attribute if you set it to anything else.
  name = "global"

  config_json = jsonencode({
    Meta = {
      metrics_port_envoy = "9102"
    }
    Config = {
      envoy_prometheus_bind_addr = "0.0.0.0:9102"
    }
    AccessLogs = {
      Enabled = true
    }
    Expose           = {}
    MeshGateway      = {}
    TransparentProxy = {}
  })
}
