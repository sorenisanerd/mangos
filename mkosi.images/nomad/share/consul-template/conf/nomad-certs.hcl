template {
    source      = "/usr/share/consul-template/templates/nomad-certs.tmpl"
    destination = "/var/lib/nomad/ssl/nomad.crt"
    perms       = "0644"
    command     = <<-EOF
        if test -s /var/lib/nomad/ssl/nomad.key.new; then mv /var/lib/nomad/ssl/nomad.key.new /var/lib/nomad/ssl/nomad.key ; fi ;
        if test -s /var/lib/nomad/ssl/ca.pem.new; then mv /var/lib/nomad/ssl/ca.pem.new /var/lib/nomad/ssl/ca.pem ; fi ;
        if systemctl is-active -q nomad; then systemctl reload nomad; fi
        EOF
}
