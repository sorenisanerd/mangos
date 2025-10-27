#!/bin/bash

set -e

if [ -z "${MANGOS_VERSION}" ]
then
	MANGOS_VERSION="$(. /etc/os-release; echo ${IMAGE_VERSION})"
fi

if [ -z "${BASE_URL}" ]
then
	BASE_URL="$(. /etc/os-release ; echo ${MKOSI_SERVE_URL})"
fi

# Determine if this system is booted in EFI mode
is_efi() {
	test -d /sys/firmware/efi
}


# Convert a CIDR prefix length to a netmask. E.g.:
# 32 -> 255.255.255.255
# 31 -> 255.255.255.254
# ...
# 0  -> 0.0.0.0
prefix_to_netmask() {
	bits=$(($1))
	rv=''

	bits_to_mask=(0 128 192 224 240 248 252 254 255)

	octets=0
	while [ $octets -lt 4 ]
	do
		octets=$(($octets + 1))

		if [ $bits -ge 8 ]
		then
			rv="${rv}255."
		elif [ $bits -le 0 ]
		then
			rv="${rv}0."
		else
			rv="${rv}${bits_to_mask[$bits]}."
		fi
		bits=$(($bits - 8))
	done
	echo "${rv%.}"
}

# Generate an "ip=" argument suitable for passing to the kernel command line
ip_arg_for_default_interface() {
	read _ _ gw _ dev _ ip _ < <(ip -o route get 8.8.8.8)
	prefix="$(ip -o addr show dev $dev | grep ' inet ' | head -n 1 | grep -Eo '/[0-9]+' | cut -f2 -d/)"
	netmask=$(prefix_to_netmask $prefix)
	printf '%s::%s:%s:%s:%s:none' "${ip}" "${gw}" "${netmask}" "$(hostname)" "${dev}"
}

# Extract the first nameserver from /etc/resolv.conf
nameserver() {
	grep nameserver /etc/resolv.conf | awk -- '{ print $2 }'
}

# Install mangos on a BIOS (i.e. non-EFI) system
#
# Downloads Mangos kernel and initrd, shoves an entry in to grub, and reboots.
#
# A lot of unsound assumptions are made here (e.g. the grub directory). Please adjust to
# accommodate other layouts and configurations.
bios_install() {
	wget "${BASE_URL}/mangos-installer_${MANGOS_VERSION}.vmlinuz" -O /boot/mangos.vmlinuz
	wget "${BASE_URL}/mangos-installer_${MANGOS_VERSION}.initrd" -O /boot/mangos.initrd
	cat >> /etc/grub.d/40_custom <<EOF
menuentry "mangos-install" {
    echo "Loading kernel"
    linux /mangos.vmlinuz ip=$(ip_arg_for_default_interface) nameserver=$(nameserver) mangos_install_target=ask mangos_install_source=${BASE_URL}/mangos_${MANGOS_VERSION}.raw.gz
    echo "Loading initrd"
    initrd /mangos.initrd
    echo "Booting"
}
EOF
	grub2-mkconfig | tee /boot/grub2/grub.cfg
	grub2-reboot mangos-install
	echo "Sleeping 5 seconds before rebooting into mangos-install. CTRL-C to abort."
	sleep 5
	sync; sync; systemctl reboot
}

do_install() {
	if is_efi
	then
		efi_install
	else
		bios_install
	fi
}

do_enroll() {
	declare -A groups

	args="$(getopt -o 'g:' --long 'group:' -n 'mangosctl enroll' -- "$@")"
	if [ $? != 0 ]
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		case "$1" in
			-g|--group)
				groups[$2]=1
				shift 2
				;;
			--)
				shift
				break
				;;
			*)
				echo "Error parsing arguments" >&2
				usage
				;;
		esac
	done

	if [ $# -ne 1 ]
	then
		echo "Usage: $0 enroll [[--group GROUP] [--group GROUP]...] CONSUL_RETRY_JOIN" >&2
		exit 1
	fi

	confext_dir="$(mktemp -d)"

	mkdir -p ${confext_dir}/etc/extension-release.d
	echo 'ID=_any' > ${confext_dir}/etc/extension-release.d/extension-release.${hostname}

	echo ${hostname} > ${confext_dir}/etc/hostname
	echo CONSUL_DATACENTER=${REGION}-${DATACENTER} > ${confext_dir}/etc/mangos.environment
	echo NOMAD_DATACENTER=${DATACENTER} >> ${confext_dir}/etc/mangos.environment
	echo NOMAD_REGION=${REGION} >> ${confext_dir}/etc/mangos.environment

	localcerts=$(mktemp -d)
	mkdir -p ${confext_dir}/etc/ssl/certs
	vault read -format=raw pki-root/ca/pem >  ${localcerts}/pki-root.crt
	update-ca-certificates --etccertsdir ${confext_dir}/etc/ssl/certs --localcertsdir ${localcerts}
	rm ${confext_dir}/etc/ssl/certs/pki-root.pem
	cp ${localcerts}/pki-root.crt ${confext_dir}/etc/ssl/certs/pki-root.pem
	rm -rf ${localcerts}


	mkdir -p ${confext_dir}/etc/credstore
	mkdir -p ${confext_dir}/etc/credstore.encrypted

	echo -n "Generating private key... "
	openssl genrsa -quiet 2048 | systemd-creds encrypt - ${confext_dir}/etc/credstore.encrypted/mangos.key
	echo "Done"

	echo -n "Generating Certificate Signing Request (CSR) $csr... "
	openssl req -key <(systemd-creds decrypt ${confext_dir}/etc/credstore.encrypted/mangos.key) -new -subj "/CN=${hostname}.mangos/" -out "${confext_dir}/etc/credstore/mangos.csr"
	echo "Done"

	mkdir -p /var/lib/mangos
	vault write -field=certificate pki-nodes/sign/node-cert \
		csr=@${confext_dir}/etc/credstore/mangos.csr \
		common_name=${hostname}.mangos \
		ttl=72h \
		format=pem > /var/lib/mangos/mangos.crt

	NODE_VAULT_TOKEN=$(vault login -method=cert -path=node-cert -client-cert=/var/lib/mangos/mangos.crt -client-key=<(systemd-creds decrypt ${confext_dir}/etc/credstore.encrypted/mangos.key) -token-only)

	node_auth_accessor=$(vault read -field=accessor sys/auth/node-cert)
	entity_name=$(vault write -field=name identity/lookup/entity alias_name=$(hostname).mangos alias_mount_accessor=${node_auth_accessor})

	for group in ${!groups[@]}
	do
		do_entity addgroup ${entity_name} ${group}
	done

    # Enroll the node into Consul
	echo "Enrolling node into Consul:"

	echo -n "Issuing certificates for Consul and Nomad... "
	mkdir -p /var/lib/consul/ssl
	chown -R consul:consul /var/lib/consul

	mkdir -p /var/lib/nomad/ssl
	chown -R nomad:nomad /var/lib/nomad

	CONSUL_DATACENTER=${REGION}-${DATACENTER} \
	NOMAD_REGION=${REGION} \
	NOMAD_DATACENTER=${DATACENTER} \
	consul-template -vault-renew-token=false -once \
		-config /usr/share/consul-template/conf/consul-certs.hcl \
		-config /usr/share/consul-template/conf/nomad-certs.hcl

	enckey=$(mktemp --suffix .json)
	chown consul:consul $enckey
	vault read -field=encryption_key secrets/mangos/consul/gossip | jq -R '{encrypt:.}' > ${enckey}
	echo Done

	echo -n "Generating Consul agent recovery token... "
	agent_recovery_token=$(systemd-id128 -u new)
	systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/consul.agent_recovery <<<${agent_recovery_token}
	echo Done

	if ! [ -e "/var/lib/consul/data/raft" ]
	then
		echo -n "Bootstrapping Consul client... "
		chronic systemd-run \
			-u consul-bootstrap \
			--uid=consul \
			--gid=consul \
			-p "Type=notify" \
			-p "StateDirectory=consul/data consul/ssl" \
			-p "Conflicts=consul.service" \
			/usr/bin/consul agent \
			-retry-join ${1} \
			-config-dir=/usr/share/consul/ \
			-datacenter "${REGION}-${DATACENTER}" \
			-config-file=${enckey}
	fi

	systemctl start consul

	consul_mgmt_token=$(vault read -field=token consul/creds/management)

	has_token() {
		jq -e ".$1" < /var/lib/consul/data/acl-tokens.json > /dev/null
	}

	if ! has_token agent
	then
		set_agent_token agent "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -node-identity $(hostname):${REGION}-${DATACENTER} -role-name=consul-agent -format=json |jq -r .SecretID)"
	fi

	if ! has_token default
	then
		set_agent_token default  "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-default -format=json | jq -r .SecretID)"
	fi

	if ! has_token replication
	then
		set_agent_token replication "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-replication -format=json | jq -r .SecretID)"
	fi

	if ! has_token config_file_service_registration
	then
		set_agent_token config_file_service_registration "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-registration -format=json | jq -r .SecretID)"
	fi

	argv=()

	if [ "${groups[nomad-servers]}" = "1" ]
	then
		argv+=(-service-identity nomad-server -policy-name nomad-server)
	fi

	if [ "${groups[nomad-clients]}" = "1" ]
	then
		argv+=(-service-identity nomad-client -policy-name nomad-client)
	fi

	echo -n "Creating Consul token for Nomad server... "
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
                        -service-identity nomad-server \
                        -service-identity nomad-client \
                        -policy-name nomad-server      \
                        -policy-name nomad-client      \
                        -description "Nomad Server/Client token on $(hostname)" \
                        -format=json | jq .SecretID -r | systemd-creds -H encrypt - ${confext_dir}/etc/credstore.encrypted/nomad.consul_token
	echo "Done"
	rm -rf "/var/lib/confexts/${hostname}"

	mv ${confext_dir} /var/lib/confexts/${hostname}
	systemd-confext refresh
}

do_group() {
	case "$1" in
		list)
			vault list identity/group/name
			;;
		*)
			echo "Unknown subcommand $1" >&2
			exit 1
			;;
	esac
}

do_entity() {
	case "$1" in
		list)
			vault list identity/entity/name
			;;
		addgroup)
			entity_name="$2"
			group_name="$3"
			if [ -z "$entity_name" -o -z "$group_name" ]
			then
				echo "Usage: $0 entity addgroup ENTITY GROUP" >&2
				exit 1
			fi
			entity_id=$(vault read -field=id identity/entity/name/${entity_name})
			members="$(vault read -format=json identity/group/name/${group_name} | jq -r '.data.member_entity_ids | join(",")')"
			if [ -z "${members}" ]
			then
				members="${entity_id}"
			else
				members="${members},${entity_id}"
			fi
			vault write identity/group/name/${group_name} member_entity_ids="${members}"
			;;
		*)
			echo "Unknown subcommand $1" >&2
			exit 1
			;;
	esac
}

do_update() {
	for d in /usr/lib/sysupdate*.d/*.transfer
	do
		mkdir -p "/run/${d#/usr/lib/}.d"
		cat <<EOF >> "/run/${d#/usr/lib/}.d/override.conf"
[Source]
Path=${BASE_URL}
[Transfer]
Verify=no
EOF
	done

	args="$(getopt -o 'c:' --long 'component:' -n 'mangosctl update' -- "$@")"
	if [ $? != 0 ]
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		case "$1" in
			-c|--component)
				defs="${tmpdir}/sysupdate.${2}.d"
				shift 2
				;;
			--)
				shift
				break
				;;
			*)
				echo "Error parsing arguments" >&2
				usage
				;;
		esac
	done

	updatectl "$@"

	if is_efi
	then
		return
	fi

	cat <<'EOF' > /boot/grub/grub.cfg
if [ -s $prefix/grubenv ]; then
  load_env
fi
if [ "${next_entry}" ] ; then
   set default="${next_entry}"
   set next_entry=
   save_env next_entry
   set boot_once=true
else
   set default="0"
fi
EOF

	# Add the snippets in reverse order.
	cat $(printf '%s\n' /boot/grub/mangos_*.grub.cfg | tac) >> /boot/grub/grub.cfg

	ip_arg="$(grep -oE 'ip=[^ ]+' /proc/cmdline)"
	nameserver_arg="$(grep -oE 'nameserver=[^ ]+' /proc/cmdline)"
	grub-editenv /boot/grub/grubenv set kernel_args="${ip_arg} ${nameserver_arg}"
}

chronic() {
	local tmp=$(mktemp)
	rv=0
	"$@" > ${tmp} 2>&1 || rv=$?

	if [ $rv -ne 0 ]
	then
		cat "${tmp}"
	fi
	rm -f ${tmp}
	return $rv
}

run_terraform() {
	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	nsenter -t $(pidof vault) -n \
	terraform -chdir=/var/lib/terraform "$@"
}

run_terraform_apply() {
	chronic run_terraform apply -auto-approve "$@"
}

do_bootstrap() {
	REGION=global
	DATACENTER=test

	while [ $# -gt 0 ]
	do
		case "$1" in
			--region=*)
				REGION="${1#--region=}"
				;;
			--region)
				REGION="$2"
				shift 2
				;;
			--datacenter=*)
				DATACENTER="${1#--datacenter=}"
				;;
			--datacenter)
				DATACENTER="$2"
				shift 2
				;;
			--clean)
				CLEANUP=1
				shift
				;;
			*)
				echo "Unknown argument $1"
				usage
		esac
	done

	# Clean up from previous runs
	if [ -n "$CLEANUP" ]
	then
		systemd-sysext unmerge
		systemd-confext unmerge
		systemctl daemon-reload
		systemctl stop vault vault-bootstrap consul consul-bootstrap nomad nomad-bootstrap || true
		shopt -s nullglob
		rm -rf /var/lib/{terraform,vault,consul,nomad,confexts} /var/lib/private/{terraform,vault,consul,nomad}.* /run/{vault,nomad,consul}
		systemctl reset-failed
	fi

	echo "Downloading the full hashistack:"
	do_update update component:{consul,consul-template,nomad,terraform,vault}
	echo Done.

	echo -n "Merging Hashistack sysext... "
	chronic systemd-sysext refresh
	echo Done

	echo -n "Reloading systemd... "
	systemctl daemon-reload
	echo Done

	echo -n "Reloading systemd-resolved... "
	chronic systemctl reload systemd-resolved
	echo Done

	echo -n "Bootstrapping vault... "
	chronic systemd-run \
		-u vault-bootstrap \
		--uid=vault \
		--gid=vault \
		-p "Type=notify" \
		-p "StateDirectory=vault/raft vault/ssl" \
		-p "StateDirectoryMode=0700" \
		-p "RuntimeDirectory=vault" \
		-p "RuntimeDirectoryMode=0700" \
		-p "RuntimeDirectoryPreserve=yes" \
		-p "Conflicts=vault.service" \
		-p "PrivateNetwork=yes" \
		-p 'ExecStartPost=curl -X PUT -H "X-Vault-Request: true" -d "{\"secret_shares\":1,\"secret_threshold\":1}" http://127.0.0.1:8200/v1/sys/init -o ${RUNTIME_DIRECTORY}/init.json' \
		/usr/bin/vault server -config=/usr/share/vault-bootstrap
	echo "Done".

	echo -n "Saving encrypted unseal key and root token... "
	jq -r '.keys[0]' /run/vault/init.json | systemd-creds -H encrypt - /var/lib/private/vault.unseal_key
	jq -r '.root_token' /run/vault/init.json | systemd-creds -H encrypt - /var/lib/private/vault.root_token
	rm /run/vault/init.json
	echo "Done"

	# Unseal vault
	echo -n "Unsealing vault... "
	systemd-creds decrypt /var/lib/private/vault.unseal_key | jq '{key:.}' -R | chronic curl --unix-socket /run/vault/vault.sock http://127.0.0.1:8200/v1/sys/unseal --data @- -X POST
	echo Done

	echo -n "Copying terraform files into place... "
	mkdir -p /var/lib/terraform
	cp /usr/share/terraform/* /var/lib/terraform
	echo Done

	echo -n "Initializing terraform... "
	chronic terraform -chdir=/var/lib/terraform init
	echo Done

	export VAULT_ADDR=http://127.0.0.1:8200

	echo -n "Bootstrapping PKI infrastructure... "
	run_terraform_apply -target=terraform_data.bootstrap-pki
	echo "Done"

	echo -n "Issuing certificates for Vault, Consul, and Nomad... "

	mkdir -p /var/lib/vault/ssl
	chown -R vault:vault /var/lib/vault

	mkdir -p /var/lib/consul/ssl
	chown -R consul:consul /var/lib/consul

	mkdir -p /var/lib/nomad/ssl
	chown -R nomad:nomad /var/lib/nomad

	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	VAULT_ADDR=unix:///run/vault/vault.sock \
	CONSUL_DATACENTER=${REGION}-${DATACENTER} \
	CONSUL_SERVER=yes \
	VAULT_SERVER=yes \
	NOMAD_REGION=${REGION} \
	NOMAD_DATACENTER=${DATACENTER} \
	NOMAD_SERVER=yes \
	consul-template -vault-renew-token=false -once \
		-config /usr/share/consul-template/conf/vault-certs.hcl \
		-config /usr/share/consul-template/conf/consul-certs.hcl \
		-config /usr/share/consul-template/conf/nomad-certs.hcl
	echo Done

	echo -n "Restarting Vault in non-bootstrap mode... "
	chronic systemctl start vault
	echo Done

	echo -n "Generating encryption key for Consul... "
	enckey=$(mktemp --suffix .json)
	chown consul:consul $enckey
	consul keygen | jq -R '{encrypt:.}' > ${enckey}
	echo Done

	echo -n "Launching Consul in bootstrap mode... "
	chronic systemd-run \
		-u consul-bootstrap \
		--uid=consul \
		--gid=consul \
		-p "Type=notify" \
		-p "StateDirectory=consul/data consul/ssl" \
		-p "Conflicts=consul.service" \
		/usr/bin/consul agent \
		-retry-join 127.0.0.1 \
		-config-dir=/usr/share/consul/ \
		-datacenter "${REGION}-${DATACENTER}" \
		-config-file=${enckey} -bootstrap
	echo "Done"

	echo "${REGION}-${DATACENTER}" > /var/lib/private/consul.datacenter

	echo -n "Waiting until this node is the Consul leader... "
	journalctl -u consul-bootstrap -f -I -n all | grep -q "cluster leadership acquired"
	echo "Done"

	echo -n "Bootstrapping Consul... "
	export VAULT_ADDR=https://127.0.0.1:8200
	export VAULT_TLS_SERVER_NAME=vault.service.consul
	export VAULT_CACERT=/var/lib/vault/ssl/ca.pem
	run_terraform_apply -target=terraform_data.consul-bootstrap
	echo Done

	echo -n "Writing Consul gossip encryption key to Vault... "
	jq -r .encrypt < ${enckey} | \
	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	chronic vault write secrets/mangos/consul/gossip encryption_key=-
	echo Done

	echo -n "Generating Consul agent recovery token... "
	agent_recovery_token=$(systemd-id128 -u new)
	systemd-creds -H encrypt - /var/lib/private/consul.agent_recovery <<<${agent_recovery_token}
	echo Done

	echo -n "Launching Consul in non-bootstrap mode... "
	chronic systemctl start consul
	echo Done

	echo -n "Waiting until regaining Consul leadership... "
	journalctl -u consul -f -I -n all | grep -q "cluster leadership acquired"
	echo "Done"

	echo -n "Acquiring Consul management token... "
	consul_mgmt_token="$(VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) vault read -field=token consul/creds/management)"
	echo Done

	echo -n "Creating a base set of Consul ACL roles and policies... "
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} run_terraform_apply -target=terraform_data.consul-bootstrap-roles
	echo Done

	set_agent_token agent                            "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -node-identity $(hostname):${REGION}-${DATACENTER} -role-name=consul-agent -format=json |jq -r .SecretID)"
	set_agent_token default                          "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-default -format=json | jq -r .SecretID)"
	set_agent_token replication                      "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-replication -format=json | jq -r .SecretID)"
	set_agent_token config_file_service_registration "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -role-name=consul-registration -format=json | jq -r .SecretID)"

	mkdir -p /var/lib/confexts/bootstrap/etc/extension-release.d
	echo 'ID=_any' > /var/lib/confexts/bootstrap/etc/extension-release.d/extension-release.bootstrap
	mkdir -p /var/lib/confexts/bootstrap/etc/credstore.encrypted

	CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
						-service-identity vault:${REGION}-${DATACENTER} \
						-format=json | jq -r .SecretID | systemd-creds -H encrypt - /var/lib/confexts/bootstrap/etc/credstore.encrypted/vault.consul_token

	systemd-confext refresh
	systemctl restart vault

	echo -n "Creating Consul token for Nomad server... "
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
                        -service-identity nomad-server \
                        -service-identity nomad-client \
                        -policy-name nomad-server      \
                        -policy-name nomad-client      \
                        -description "Nomad Server/Client token on $(hostname)" \
                        -format=json | jq .SecretID -r | systemd-creds -H encrypt - /var/lib/private/nomad.consul_token
	echo "Done"

	mkdir -p /run/nomad
	systemd-creds decrypt /var/lib/private/nomad.consul_token | jq -R '{consul:{token:.}}' > /run/nomad/consul-agent.json

	chown nomad:nomad /run/nomad/consul-agent.json

	dc_and_region="$(mktemp --suffix .json)"
	chown nomad:nomad "${dc_and_region}"
	echo "{ \"datacenter\": \"${DATACENTER}\", \"region\": \"${REGION}\" }" > "${dc_and_region}"

	echo $REGION > /var/lib/private/nomad.region
	echo $DATACENTER > /var/lib/private/nomad.datacenter

	echo -n "Launching Nomad in bootstrap mode... "
	chronic systemd-run \
		-u nomad-bootstrap \
		--uid=nomad \
		--gid=nomad \
		-p "Type=notify" \
		-p "StateDirectory=nomad/data nomad/ssl" \
		-p "Conflicts=nomad.service" \
		/usr/bin/nomad agent -server -bootstrap-expect=1 \
			-config=/usr/share/nomad \
			-config=/run/nomad/consul-agent.json \
			-config="${dc_and_region}"
	echo "Done"

	echo -n "Waiting until this node is the Nomad leader... "
	journalctl -u nomad-bootstrap -f -I -n all | grep -q "cluster leadership acquired"
	echo "Done"

	echo -n "Waiting until Nomad is resolvable via Consul..."
	while ! resolvectl query nomad.service.consul >/dev/null 2>&1
	do
		echo -n "."
		sleep 1
	done
	echo " Done"

	export NOMAD_ADDR=https://127.0.0.1:4646/
	export NOMAD_TLS_SERVER_NAME=nomad.service.consul

	echo -n "Bootstrapping Nomad via Vault... "
	chronic run_terraform_apply -target=vault_nomad_secret_backend.nomad
	echo Done

	echo -n "Starting Nomad in non-bootstrap mode... "
	chronic systemctl start nomad
	echo Done

	echo -n "Final Terraform run... "
	CONSUL_HTTP_TOKEN=${consul_mgmt_token} chronic run_terraform_apply
	echo Done
}

set_agent_token() {
	echo -n "Setting Consul $1 token... "
	chronic consul acl set-agent-token -token-file <(systemd-creds decrypt /var/lib/private/consul.agent_recovery) "$@"
	echo Done
}

run_vault() {
	VAULT_ADDR=https://127.0.0.1:8200/ \
	VAULT_TLS_SERVER_NAME=vault.service.consul \
	VAULT_CACERT=/var/lib/vault/ssl/ca.pem \
	VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
	vault "$@"
}

usage() {
	echo 'Usage: $0 {install|update|enroll}'
	echo
	echo ' install          - install mangos on this machine'
	echo ' update           - update an existing mangos installation'
	echo ' enroll           - generate a private key and CSR for this machine'
	echo ' addext EXTENSION - pull and merge an extension (e.g. \"debug\")'
	echo ' bootstrap-mangos - bootstrap a mangos installation'
	echo ''
	echo 'Options for bootstrap-mangos:'
	echo '  --region=REGION          Set the region for the mangos installation (default: global)'
	echo '  --datacenter=DATACENTER  Set the datacenter for the mangos installation (default: dc1)'
	echo '  --clean                  Clean up any existing mangos installation before bootstrapping'
	exit 1
}

do_addext() {
	args="$(getopt -o 'v:' --long 'version:' -n 'mangosctl addext' -- "$@")"
	if [ $? != 0 ]
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		echo "arg: $1"
		case "$1" in
			-v|--version)
				IMAGE_VERSION="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
		esac
	done

	extname="$1"

	if [ -z "${extname}" ]
	then
		echo "No extension name specified" >&2
		usage
	fi

	if [ -z "${IMAGE_VERSION}" ]
	then
		image_file_name="${extname}.raw"
	else
		image_file_name="${extname}_${IMAGE_VERSION}.raw"
	fi

	wget --progress=dot:giga -O /var/lib/extensions/"${image_file_name}" "${BASE_URL}/${image_file_name}"
	systemd-sysext refresh
}

if [ "$1" = "sudo" ]
then
	if [ -e "/var/lib/private/vault.root_token" ]
	then
		export VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token)
	else
		echo "Could not find root token" >&2
	fi

	if [ -e "/var/lib/vault/ssl/vault.crt" ]
	then
		export VAULT_CACERT=/var/lib/vault/ssl/ca.pem
	else
		echo "Could not find Vault CA certificate" >&2
	fi

	export VAULT_ADDR="${VAULT_ADDR:-https://vault.service.consul:8200/}"

	if [ -n "$VAULT_TOKEN" ]
	then
		export CONSUL_HTTP_TOKEN=$(VAULT_TOKEN=$VAULT_TOKEN vault read -field=token consul/creds/management)
	fi
	shift
	if [ "$1" = "--" ]
	then
		shift
		exec "$@"
	fi
fi

if [ $# -lt 1 ]
then
	usage
else
	case "$1" in
		install)
			shift
			do_install
			;;
		update)
			shift
			do_update "$@"
			;;
		group)
			shift
			do_group "$@"
			;;
		entity)
			shift
			do_entity "$@"
			;;
		addext)
			shift
			do_addext "$@"
			;;
		enroll)
			shift
			do_enroll "$@"
			;;
		bootstrap-mangos|bootstrap)
			shift
			do_bootstrap "$@"
			;;
		vault)
			shift
			run_vault "$@"
			;;
		terraform)
			shift
			VAULT_ADDR=https://127.0.0.1:8200/ \
			VAULT_TLS_SERVER_NAME=vault.service.consul \
			VAULT_CACERT=/var/lib/vault/ssl/ca.pem \
			VAULT_TOKEN=$(systemd-creds decrypt /var/lib/private/vault.root_token) \
			CONSUL_HTTP_TOKEN=$(run_vault read -field=token consul/creds/management) \
			run_terraform "$@"
			;;
		*)
			echo "Unknown subcommand $1"
			usage
			;;
	esac
fi
