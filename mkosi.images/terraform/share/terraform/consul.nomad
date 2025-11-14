job "consul" {
  namespace = "admin"

  group "client" {
    service {
      name = "consul"
      port = "http"
      connect {
        sidecar_service {}
      }
    }

    network {
      mode = "bridge"
      port "http" {
        static = 8500
      }
    }

    task "main" {
      # Get a Vault token to use in templates
      vault {
        role = "consul"
      }

      # Get Consul token
      consul {}

      template {
        data = <<-EOF
        encrypt   = "{{ with secret "secrets/mangos/consul/gossip" }}{{ .Data.encryption_key | trimSpace }}{{ end }}"
        node_name = "consul-api-{{ env "HOSTNAME" }}"
        acl {
          enabled = true
          tokens {
            agent = "{{ env "CONSUL_HTTP_TOKEN"}}"
          }
        }
        EOF
        destination = "${NOMAD_SECRETS_DIR}/consul.hcl"
      }
      driver = "docker"
      config {
        image = "hashicorp/consul"
        args  = ["agent",
                 "-retry-join", "10.0.2.15",
                 "-datacenter", "${NOMAD_REGION}-${NOMAD_DC}",
                 "-config-file", "${NOMAD_SECRETS_DIR}/consul.hcl"]
      }
    }
  }
}
