resource "vault_mount" "ssh" {
  type = "ssh"
  path = "ssh"
}

resource "vault_ssh_secret_backend_ca" "ssh-ca" {
  backend              = vault_mount.ssh.path
  generate_signing_key = true
}

resource "vault_ssh_secret_backend_role" "any-user" {
  backend                 = vault_mount.ssh.path
  name                    = "any-user"
  allowed_users           = "*"
  allow_user_certificates = true
  allowed_extensions      = "permit-pty,permit-port-forwarding,permit-user-rc,permit-X11-forwarding,permit-agent-forwarding"
  default_extensions = {
    permit-pty = ""
  }
  key_type = "ca"
  ttl      = "1800"
}

#
# SSH key signing role that only allows signing keys
# that match the requesting host's hostname.
#
resource "vault_ssh_secret_backend_role" "host-self" {
  backend                  = vault_mount.ssh.path
  name                     = "host-self"
  allow_host_certificates  = true
  allowed_domains          = "{{identity.entity.aliases.${vault_auth_backend.node-cert.accessor}.name}}"
  allow_bare_domains       = true
  allowed_domains_template = true
  allow_subdomains         = false
  key_type                 = "ca"
  ttl                      = 315360000 // "87600h" == 10 years
}

#
# Allow nodes to get SSH host keys signed for any domain.
#
resource "vault_policy" "ssh-host-self-signer" {
  name   = "ssh-host-self-signer"
  policy = <<-EOP
    path "ssh/config/ca" {
      capabilities = ["read"]
    }
    path "ssh/sign/host-self" {
      capabilities = ["create", "update"]
    }
    EOP
}

#
# Allows signing ANY ssh host
#
resource "vault_policy" "ssh-host-signer" {
  name   = "ssh-host-signer"
  policy = <<-EOP
    path "ssh/config/ca" {
      capabilities = ["read"]
    }
    path "ssh/sign/host" {
      capabilities = ["create", "update"]
    }
    EOP
}

#
# Allows signing user keys granting access to log in as ANY user
#
resource "vault_policy" "ssh-as-anyone" {
  name   = "ssh-as-anyone"
  policy = <<-EOP
    path "ssh/config/ca" {
      capabilities = ["read"]
    }
    path "ssh/sign/any-user" {
      capabilities = ["create", "update"]
    }
    EOP
}
