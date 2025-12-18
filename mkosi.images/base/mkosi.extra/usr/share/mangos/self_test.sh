#!/bin/bash
BASE_URL=${BASE_URL:-http://10.0.2.2:8081}
export BASE_URL

set -e
set -x

(while true; do echo from vm: ; df -h ; sleep 13; done) &

trap 'journalctl -n 1000 --no-pager' ERR
systemctl is-active systemd-veritysetup@root.service
systemctl is-active systemd-cryptsetup@swap.service
systemctl is-active systemd-cryptsetup@var.service
systemctl is-active systemd-cryptsetup@var\\x2dtmp.service
mangosctl bootstrap
mangosctl sudo enroll -g{vault-server,{nomad,consul}-{server,client}}s 127.0.0.1
mangosctl sudo -- nomad job run -detach /usr/share/mangos/test.nomad
sleep 5
docker ps || true
ls -l /run/docker.sock || true
ps aux | grep nomad || true
sleep 15
df -h || true
grep '' /var/lib/nomad/data/alloc/*/alloc/logs/* || true
echo Current log:
mangosctl sudo -- nomad alloc logs -namespace=admin -task server -job test
tries=10
while ! mangosctl sudo -- nomad alloc logs -namespace=admin -task server -job test | grep SUCCESS
do
        date
        echo Current logs:
        grep '' /var/lib/nomad/data/alloc/*/alloc/logs/* || true
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
