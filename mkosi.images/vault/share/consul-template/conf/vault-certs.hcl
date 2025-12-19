template {
    source      = "/usr/share/consul-template/templates/vault-certs.tmpl"
    destination = "/var/lib/vault/ssl/vault.crt"
    perms       = "0644"
    command     = <<-EOF
        set -xe ;
        if test -s /var/lib/vault/ssl/vault.key.new; then mv /var/lib/vault/ssl/vault.key.new /var/lib/vault/ssl/vault.key ; fi ;
        if test -s /var/lib/vault/ssl/ca.pem.new; then mv /var/lib/vault/ssl/ca.pem.new /var/lib/vault/ssl/ca.pem ; fi ;
        if systemctl is-active -q vault; then systemctl reload vault; fi
        EOF
}
