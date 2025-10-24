template {
    source      = "/usr/share/consul-template/templates/node-cert.tmpl"
    destination = "/var/lib/mangos/mangos.crt"
    perms       = "0644"
}
