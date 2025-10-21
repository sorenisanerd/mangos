template {
    source      = "/usr/share/consul-template/templates/consul-certs.tmpl"
    destination = "/var/lib/consul/ssl/consul.crt"
    perms       = "0644"
    command     = <<-EOF
        if test -s /var/lib/consul/ssl/consul.key.new; then mv /var/lib/consul/ssl/consul.key.new /var/lib/consul/ssl/consul.key ; fi ;
        if test -s /var/lib/consul/ssl/ca.pem.new; then mv /var/lib/consul/ssl/ca.pem.new /var/lib/consul/ssl/ca.pem ; fi ;
        if systemctl is-active -q consul; then systemctl reload consul; fi
        EOF
}
