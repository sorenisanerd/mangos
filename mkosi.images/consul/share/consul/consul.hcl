tls {
  defaults {
    cert_file = "/var/lib/consul/ssl/consul.crt"
    key_file  = "/var/lib/consul/ssl/consul.key"
  }
}

data_dir = "/var/lib/consul/data"

# The real encryption key is provided during
# bootstrapping/enrollment and persisted to the data dir,
# and does not need to be provided again.
# However, not providing a key at all disables encryption,
# so we just pass a bunch of NULLs to keep it enabled.
encrypt = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true
}

bind_addr      = "0.0.0.0"
advertise_addr = "{{ GetPrivateInterfaces | exclude \"name\" \"docker\" | attr \"address\" }}"

ports {
  https     = 8501
  grpc      = 8502
  grpc_tls  = 8503
}
