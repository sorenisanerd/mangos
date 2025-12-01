resource "vault_mount" "secretsv1" {
  path        = "secrets"
  type        = "kv"
  description = "Vault Secrets v1"
}

resource "vault_mount" "secretsv2" {
  path        = "secretsv2"
  type        = "kv"
  options     = { version = "2" }
  description = "KV Version 2 secrets"
}

resource "vault_policy" "renew-self" {
  name   = "renew-self"
  policy = <<-EOT
    path "auth/token/renew-self" {
      capabilities = ["update"]
    }
    EOT
}

resource "vault_policy" "lookup-self" {
  name   = "lookup-self"
  policy = <<-EOT
    path "auth/token/lookup-self" {
      capabilities = ["update"]
    }
    EOT
}

resource "vault_policy" "lookup-entity" {
  name   = "lookup-entity"
  policy = <<-EOP
    path "identity/lookup/entity" {
      capabilities = ["update"]
    }
    EOP
}

