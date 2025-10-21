variable "userpass-path" {
  default = "userpass"
}

resource "vault_auth_backend" "userpass" {
  path = var.userpass-path
  type = "userpass"
}

#
# Grants user access to update own password
#
resource "vault_policy" "change-own-password" {
  name   = "change-own-password"
  policy = <<-EOT
    path "auth/${vault_auth_backend.userpass.path}/users/{{identity.entity.aliases.${vault_auth_backend.userpass.accessor}.name}}" {
      capabilities = ["update"]
      allowed_parameters = {
        "password" = []
      }
    }
    EOT
}
