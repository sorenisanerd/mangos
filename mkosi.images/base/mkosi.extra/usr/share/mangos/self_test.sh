#!/bin/bash
BASE_URL=${BASE_URL:-http://10.0.2.2:8081}
export BASE_URL

set -e
set -x

trap 'journalctl -n 1000 --no-pager' ERR
systemctl is-active systemd-veritysetup@root.service
systemctl is-active systemd-cryptsetup@swap.service
systemctl is-active systemd-cryptsetup@var.service
systemctl is-active systemd-cryptsetup@var\\x2dtmp.service

mkdir -p /var/lib/terraform
cat <<'EOF' > /var/lib/terraform/admin_users.auto.tfvars
admin_users = {foo = "$2y$10$AG67OR.v0dzi5UOcpRW8hOLSHSDeW3MVJh.g/2hnf/wJak9dAbyde"}
EOF

mangosctl bootstrap
mangosctl sudo enroll -g{vault-server,{nomad,consul}-{server,client}}s 127.0.0.1
mangosctl sudo -- nomad job run /usr/share/mangos/test.nomad

env VAULT_ADDR=https://127.0.0.1:8200/ \
    VAULT_TLS_SERVER_NAME=vault.service.consul \
    VAULT_CACERT=/var/lib/vault/ssl/ca.pem \
    vault login -no-store -method userpass username=foo password=bar

tries=10
while ! mangosctl sudo -- nomad alloc logs -namespace=admin -task server -job test | grep SUCCESS
do
        if [ $tries -le 0 ]
        then
                echo "Test job did not complete successfully"
                exit 1
        fi
        tries=$((tries - 1))
        echo "Sleeping 10 seconds."
        sleep 10
        echo "Trying again. $tries tries left"
done
