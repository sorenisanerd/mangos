listener "unix" {
  address = "/run/vault/vault.sock"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/var/lib/vault/ssl/vault.crt"
  tls_key_file    = "/var/lib/vault/ssl/vault.key"
  tls_min_version = "tls13"
}

storage "raft" {
  path = "/var/lib/vault/raft"
}

api_addr     = "https://vault.service.consul:8200"
cluster_addr = "https://vault.service.consul:8201"

# Swap is encrypted, so we're ok
disable_mlock = true
