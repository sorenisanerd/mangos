variable "config" {
  description = "Name of the Nomad dynamic host volume to use for Caddy config."
  type        = string
}

variable "data" {
  description = "Name of the Nomad dynamic host volume to use for Caddy data."
  type        = string
}

variable "namespace" {
  type = string
}

job "caddy" {
  namespace = var.namespace

  group "caddy" {
    network {
      mode = "bridge"
      port "http" {
        static = 80
      }
      port "https" {
        static = 443
      }
      dns {
        servers = ["${attr.unique.network.ip-address}"]
      }
    }

    volume "data" {
      type            = "host"
      source          = var.data
      access_mode     = "single-node-multi-writer"
      attachment_mode = "file-system"
    }

    volume "config" {
      type            = "host"
      source          = var.config
      access_mode     = "single-node-multi-writer"
      attachment_mode = "file-system"
    }

    task "caddy" {
      consul {}
      driver = "docker"
      config {
        image = "caddy"
        args  = ["caddy", "run", "--config", "/local/caddy/Caddyfile", "--adapter", "caddyfile"]
        ports = ["http", "https"]
      }

      template {
        data        = <<EOF
{
	acme_ca https://vault.service.consul:8200/v1/pki-svc/acme/directory
	acme_ca_root /local/ca.pem
}
{{ range $svc := services -}}
{{ if (not ($svc.Name | regexMatch "-sidecar-proxy$")) -}}
{{ if $svc.Tags | contains "service-http" -}}
{{ $svc.Name }}.service.consul {
	reverse_proxy { {{- if in $svc.Tags "ssl=true" }}
		transport http {
			tls
		}{{ end }}
		dynamic srv {{ $svc.Name }}.service.consul {
			resolvers{{ range service "dns.consul" }} {{ .Address }}:8600{{ end }}
		}
	}
}
{{ end }}{{ end }}{{ end -}}
EOF
        destination = "local/caddy/Caddyfile"
      }

      template {
        data        = <<-EOF
        {{ with secret "pki-root/cert/ca" }}{{ .Data.certificate }}{{ end }}
        EOF
        destination = "local/ca.pem"
      }

      resources {
        cpu    = 128
        memory = 256
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }
    }
  }
}
