job "test" {
  namespace = "admin"
  group "vault-identity" {
    network {
      mode = "bridge"
    }

    volume "certs" {
      type      = "host"
      source    = "ca-certificates"
      read_only = true
    }

    service {
      name = "admin--test"
      connect {
        sidecar_service {
          proxy {
            upstreams {
              destination_name = "consul"
              local_bind_port  = 8500
            }
          }
        }
      }
    }

    task "server" {
      vault {}
      consul {}

      template {
        data = <<-EOF
        #!/bin/bash

        set -e
        
        consul acl token read -self -format json > consul.json

        jq -e '[(.Roles | length)==1, .Roles[0].Name=="nomad-workload"] | all' < consul.json

        VAULT_ADDR=https://10.0.2.15:8200
        VAULT_TLS_SERVER_NAME=vault.service.consul
        export VAULT_ADDR VAULT_TLS_SERVER_NAME

        vault token lookup -format=json > vault.json

        jq -e '[.data.meta.nomad_job_id=="test", .data.meta.nomad_namespace=="admin", .data.meta.nomad_task=="server", .data.meta.role=="nomad-workload"] | all' < vault.json

        echo SUCCESS
        sleep infinity
        EOF
        destination = "/local/test.sh"
        perms = "0755"
      }

      driver = "exec"
      config {
        command = "/bin/sh"
        args    = ["/local/test.sh"]
      }

      volume_mount {
        volume      = "certs"
        destination = "/etc/ssl/certs"
      }
    }
  }
}
