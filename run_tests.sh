#!/bin/bash

set -e
set -x

cols=120
rows=40

build=0
testid=$$

asciiname_rec=""

if which asciinema > /dev/null 2>&1
then
        asciiname_rec="asciinema rec --append --cols ${cols} --rows ${rows} mangos-${testid}.acast -c"
fi


while [ $# -gt 0 ]
do
    case "$1" in
        --no-build)
            build=0
            shift
            ;;
        --build)
            build=1
            shift
            ;;
        --test-id=)
            testid="${1#--test-id=}"
            shift
            ;;
        -B|--bump)
            bumparg=-B
            shift
            ;;
        --no-asciinema)
            asciiname_rec=""
            shift
            ;;
    esac
done

if [ "${build}" = 1 ]
then
    echo Building mangos
    mkosi -f ${bumparg}

    echo Building installer
    mkosi --profile=installer -f
fi

slice="mangos-test-${testid}.slice"
systemd_run="systemd-run --user --slice ${slice}"

trap "echo exit code: $?; systemctl --user stop mangos-test-${testid}.slice; journalctl --user -u ${slice}" EXIT

echo 'Launch web server (mkosi serve)'
$systemd_run -u "mangos-test-${testid}-serve" -d -- mkosi serve

tmpdir="$(mktemp -d)"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "${tmpdir}/efivars.fd"

tpmdir="${tmpdir}/tpm"
mkdir -p "${tpmdir}"

echo Prepping the TPM
$systemd_run -u "mangos-test-${testid}-tpm-prep" -d --wait -- \
    mkosi sandbox -- \
    swtpm_setup --tpm-state "${tpmdir}" \
        --tpm2 --pcr-banks sha256 \
        --display --config /dev/null

# Create a uuid for the VM's serial. It's used to generate the machine id.
# The machine ID is in turn used to generate partition UUID's for swap,
# /var, and /var/tmp, so it needs to remain consistent throughout the test.
uuid="$(uuidgen)"

target_disk="${tmpdir}/target_disk.raw"

# Current repart setup is something like:
# ESP: 1G
# GRUB partition: 1M (yes, M)
# 2 x root verity sets:
#   root-verity-sig: 16K (yes, K)
#   root-verity: 300M
#   root: 2G
# Swap: 4G
# /var/tmp: 4G minimum
# /var: 4G minimum
# Total: ~17.6GB
echo Creating target disk
mkosi sandbox -- qemu-img create "${target_disk}" 20G

run() {
    qemu_args=""
    sdrun_args=""
    bootindex=1

    while [ $# -gt 0 ]
    do
        case "$1" in
            --blockdev=*)
                # Example: --blockdev installer:/path/to/installer.raw

                arg="${1#--blockdev=}"
                src="${arg#*:}"
                id="${arg%%:*}"
                qemu_args="${qemu_args}-blockdev driver=raw,node-name=${id},discard=unmap,file.driver=file,file.filename=${src},file.aio=io_uring,cache.direct=yes,cache.no-flush=yes -device virtio-blk-pci,drive=${id},serial=${id},bootindex=${bootindex} "
                bootindex=$(($bootindex + 1))
                shift
                ;;
            --wait|-P)
                sdrun_args="${sdrun_args}$1 "
                shift
                ;;
            -smbios)
                qemu_args="${qemu_args}$1 $2 "
                shift 2
                ;;
        esac
    done

    $systemd_run -u "mangos-test-${testid}-swtpm" -d -- \
        mkosi sandbox -- \
        swtpm socket --tpmstate dir="${tpmdir}" --ctrl type=unixio,path="${tmpdir}/swtpm-sock" --tpm2

    # Give swtpm a chance to start?
    sleep 3

    script="${tmpdir}/script.sh"
    echo '#!/bin/sh' > "${script}"
    chmod +x "${script}"

    cat <<EOF >> "${script}"
    mkosi sandbox -- \
        qemu-system-x86_64 \
        -no-reboot \
        -machine type=q35,smm=on,hpet=off \
        -smp 2 \
        -m 4096M \
        -object rng-random,filename=/dev/urandom,id=rng0 \
        -device virtio-rng-pci,rng=rng0,id=rng-device0 \
        -device virtio-balloon,free-page-reporting=on \
        -no-user-config \
        -nic user,model=virtio-net-pci \
        -cpu host \
        -accel kvm \
        -nographic \
        -nodefaults \
        -chardev stdio,mux=on,id=console,signal=off \
        -device virtio-serial-pci,id=mkosi-virtio-serial-pci \
        -device virtconsole,chardev=console \
        -mon console \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
        -drive if=pflash,format=raw,file='${tmpdir}/efivars.fd' \
        -global ICH9-LPC.disable_s3=1 \
        -global driver=cfi.pflash01,property=secure,value=on \
        -device virtio-scsi-pci,id=mkosi \
        ${qemu_args} \
        -chardev socket,id=chrtpm,path='${tmpdir}/swtpm-sock'  \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -uuid '${uuid}' \
        -smbios type=11,value=io.systemd.credential.binary:firstboot.locale=Qy5VVEYtOA== \
        -smbios type=11,value=io.systemd.credential.binary:firstboot.timezone=QW1lcmljYS9Mb3NfQW5nZWxlcw== \
        -smbios type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$(ssh-keygen -y -f mkosi.key | base64 -w 0) \
        -smbios type=11,value=io.systemd.credential.binary:vmm.notify_socket=$(echo -n vsock:2:23433 | base64 -w 0)  \
        -smbios type=11,value=io.systemd.stub.kernel-cmdline-extra='systemd.wants=network.target module_blacklist=vmw_vmci systemd.tty.term.hvc0=xterm-256color systemd.tty.columns.hvc0=${cols} systemd.tty.rows.hvc0=${rows} ip=enc0:any ip=enp0s1:any ip=enp0s2:any ip=host0:any ip=none loglevel=4 SYSTEMD_SULOGIN_FORCE=1 systemd.tty.term.console=xterm-256color systemd.tty.columns.console=${cols} systemd.tty.rows.console=${rows} console=hvc0 TERM=xterm-256color' \
        -smbios type=11,value=io.systemd.boot.kernel-cmdline-extra='systemd.wants=network.target module_blacklist=vmw_vmci systemd.tty.term.hvc0=xterm-256color systemd.tty.columns.hvc0=${cols} systemd.tty.rows.hvc0=${rows} ip=enc0:any ip=enp0s1:any ip=enp0s2:any ip=host0:any ip=none loglevel=4 SYSTEMD_SULOGIN_FORCE=1 systemd.tty.term.console=xterm-256color systemd.tty.columns.console=${cols} systemd.tty.rows.console=${rows} console=hvc0 TERM=xterm-256color' \
        -device vhost-vsock-pci,guest-cid=42
EOF

    $systemd_run -u "mangos-test-${testid}-qemu" -d -E TERM=xterm-256color ${sdrun_args} -- \
        ${asciiname_rec} "${script}"
    sleep 2
}

IMAGE_VERSION="$(mkosi summary --json | jq .Images[0].ImageVersion -r)"
installer="$(pwd)/out/mangos-installer_${IMAGE_VERSION}.raw"

echo 'Run VM (Secure Boot enrollment)'
run --blockdev=installer:"${installer}" \
    --blockdev=persistent:"${target_disk}" --wait

echo 'Run VM (install mangos)'
run -smbios type=11,value=io.systemd.credential:mangos_install_target=/dev/vdb \
    -smbios type=11,value=io.systemd.credential:mangos_install_source=http://10.0.2.2:8081/mangos_${IMAGE_VERSION}.raw \
    --blockdev=installer:"${installer}" \
    --blockdev=persistent:"${target_disk}" --wait

# Run/test
echo 'Run installed OS'
run --blockdev=persistent:"${target_disk}"

cat <<'EOF' > "${tmpdir}/is_ready.sh"
#!/bin/sh
if grep -q '^READY=1$'
then
    kill -2 ${SOCAT_PPID}
fi
exit 0
EOF
chmod +x "${tmpdir}/is_ready.sh"

# Exit status 130 means killed by signal 2 (SIGINT)
echo 'Waiting for installed OS to be ready...'
$systemd_run -u "mangos-test-${testid}-socat" -d -p SuccessExitStatus=130 --wait -- mkosi --debug sandbox -- socat VSOCK-LISTEN:23433,fork,socktype=5 EXEC:"${tmpdir}/is_ready.sh"
echo $?

echo ssh into VM
if ! ssh -i ./mkosi.key \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -o LogLevel=ERROR \
    -o ProxyCommand="mkosi sandbox -- socat - VSOCK-CONNECT:42:%p" \
    root@mkosi echo Test succesful
then
    echo Fail
    exit 1
fi
