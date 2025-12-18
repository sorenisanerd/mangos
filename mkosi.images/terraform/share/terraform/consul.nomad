job "consul" {
  namespace = "admin"

  group "client" {
    service {
      tags = ["api"]
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
      port "dns" {
        static       = 8600
        host_network = "default"
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
        addresses {
          dns = "0.0.0.0"
        }
        node_name = "consul-api-{{ env "NOMAD_SHORT_ALLOC_ID" }}"
        acl {
          enabled = true
          tokens {
            default = "{{ env "CONSUL_HTTP_TOKEN" }}"
            agent   = "{{ env "CONSUL_HTTP_TOKEN" }}"
          }
        }
        ui_config {
          enabled = true
        }
        EOF
        destination = "${NOMAD_SECRETS_DIR}/consul.hcl"
        change_mode = "restart"
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
