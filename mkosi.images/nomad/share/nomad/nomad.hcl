data_dir = "/var/lib/nomad/data"

acl {
  enabled = true
}

client {
  enabled = true
}

tls {
  http = true
  rpc  = true

  ca_file   = "/var/lib/nomad/ssl/ca.pem"
  cert_file = "/var/lib/nomad/ssl/nomad.crt"
  key_file  = "/var/lib/nomad/ssl/nomad.key"
}
