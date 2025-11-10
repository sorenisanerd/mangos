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

vault {
  enabled               = true
  address               = "https://vault.service.consul:8200/"
  ca_file               = "/var/lib/nomad/ssl/ca.pem"
  jwt_auth_backend_path = "nomad-workload"
  default_identity {
    aud  = ["vault.io"]
    env  = false
    file = true
    ttl  = "1h"
  }
}

consul {
  service_auth_method   = "nomad-workload"
  task_auth_method      = "nomad-workload"
  allow_unauthenticated = false

  service_identity {
    aud = ["consul.io"]
    ttl = "1h"
  }

  task_identity {
    aud = ["consul.io"]
    ttl = "1h"
  }
}

server {
  oidc_issuer = "https://nomad.service.consul:4646"
}
