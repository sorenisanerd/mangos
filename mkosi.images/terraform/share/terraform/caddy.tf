resource "nomad_job" "caddy" {
  jobspec = file("${path.module}/caddy.nomad")

  hcl2 {
    vars = {
      "data"      = nomad_dynamic_host_volume.caddy-volumes["caddy-data"].name,
      "config"    = nomad_dynamic_host_volume.caddy-volumes["caddy-config"].name,
      "namespace" = nomad_namespace.admin.name
    }
  }
}

resource "nomad_dynamic_host_volume" "caddy-volumes" {
  for_each = toset(["caddy-data", "caddy-config"])

  name      = each.value
  namespace = nomad_namespace.admin.name
  plugin_id = "mkdir"

  capacity_min = "1.0 GiB"
  capacity_max = "1.0 GiB"

  capability {
    access_mode     = "single-node-multi-writer"
    attachment_mode = "file-system"
  }
}
