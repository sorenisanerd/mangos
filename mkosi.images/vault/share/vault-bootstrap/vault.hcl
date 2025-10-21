listener "unix" {
  address = "/run/vault/vault.sock"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

storage "raft" {
  path = "/var/lib/vault/raft"
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

# Swap is encrypted, so we're ok
disable_mlock = true
