#!/bin/bash

set -e

usage() {
    echo "Usage: $0 [--datacenter <datacenter>] [--region <region>] <mangos-server-address>"
    echo ""
    echo "Example: $0 --datacenter az1 --region us-west1 10.20.30.40"
    echo ""
    echo "$0 joins a non-Mangos node to a Mangos cluster:"
    echo "  - Installs the Verity signing certificate and CA root certificate"
    echo "  - Sets environment variables in /etc/environment.d/20-mangos.conf"
    echo "  - Installs Docker from upstream (curl https://get.docker.com etc. etc.)"
    echo "  - Adds sysusers.d config for Consul, Nomad, and Vault"
    echo "  - Downloads and installs Consul, Nomad, Vault, and Consul-Template sysexts"
    echo "  - Generates a private key and CSR for this node, gets is signed by Vault."
    echo "    This is essentially what grants the node access to the cluster."
    echo "  - Generates a recovery token for Consul on this node."
    echo "  - Generates Consul and Nomad TLS certificates."
    echo "  - Initializes the Consul client, injecting the gossip encryption key."
    echo "  - Acquires and sets up Consul ACL tokens for agent, default, replication, and"
    echo "    config_file_service_registration roles."
    echo "  - Acquires a Consul token for the Nomad agent."
    echo "  - Enables Nomad, Consul, and Consul-Template services."
    echo ""
    echo "$0 sets \$VAULT_ADDR, \$VAULT_CACERT, and \$VAULT_TLS_SERVER_NAME if not"
    echo "already set, but expects \$VAULT_TOKEN to be set. E.g.:"
    echo ""
    echo "    VAULT_TOKEN=token-with-e.g.-mangos-join-role $0 --datacenter az1 --region us-west1 10.20.30.40"
}

main() {
	if ! args="$(getopt -o '+h' --long 'help,datacenter:,region:' -n 'mangos-join' -- "$@")"
	then
		echo "Error parsing arguments" >&2
		usage
	fi

	eval set -- "${args}"
	while true
	do
		case "$1" in
			-h|--help)
				usage
                exit 0
				;;
            --datacenter)
                DATACENTER="$2"
                shift 2
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Internal error!" >&2
                exit 1
                ;;
        esac
    done

    systemd_version=$(systemctl --version | head -n1 | awk '{print $2}')
    if [ "${systemd_version}" -lt 257 ]
    then
        transfer_extension=conf
    else
        transfer_extension=transfer
    fi

    server="$1"
    export VAULT_ADDR=${VAULT_ADDR:-"https://${server}:8200"}
    export VAULT_CACERT=${VAULT_CACERT:-"/etc/ssl/certs/mangos.pem"}
    export VAULT_TLS_SERVER_NAME=${VAULT_TLS_SERVER_NAME:-"vault.service.consul"}

    if [ -z "${VAULT_TOKEN}" ]
    then
        echo "Error: \$VAULT_TOKEN must be set."
        usage
        exit 1
    fi

	do_step "Adding Verity signing certificate to /etc/verity.d" add_verity_certificate
	do_step "Adding CA certificate to /usr/local/share/ca-certificates" add_ca_certificate
    do_step "Adding environment variables to /etc/environment.d/20-mangos.conf" add_environment

    if ! which docker >/dev/null 2>&1
    then
        do_step "Installing Docker" chronic sh -c "curl -fsSL https://get.docker.com | bash"
    fi

	if [ ! -e "/usr/lib/sysusers.d/mangos.conf" ]
	then
		step "Creating Consul, Nomad, and Vault users"
		cat <<EOF > /usr/lib/sysusers.d/mangos.conf
# 0-99 are centrally allocated by Debian(/Ubuntu)
# 100-999 are "dynamically allocated system ids". We start at 501.
#Type   Name    ID      GECOS   Home directory  Shell
g               docker  501 -
u               nomad   502     Nomad   /var/lib/nomad  /bin/false
u               vault   503     Vault   /var/lib/vault  /bin/false
u               consul  504     Consul  /var/lib/consul /bin/false
EOF
		chronic systemd-sysusers
		greenln Success
	fi

    for component in "vault" "nomad" "consul" "consul-template"
    do
        do_step "Downloading ${component} sysext" download_hashistack_sysext ${component}
    done

    systemd-sysext merge
    systemctl restart systemd-resolved

    mkdir -p /etc/credstore{,.encrypted}
    keyfile="/etc/credstore.encrypted/mangos.key"
    if ! [ -s "${keyfile}" ]
    then
        do_step "Generating private key" chronic sh -c "openssl genrsa 2048 | systemd-creds encrypt - ${keyfile}"
    fi

    csr="/etc/credstore/mangos.csr"
    if ! [ -s "${csr}" ]
    then
        step "Generating Certificate Signing Request (CSR) ${csr}"
        chronic openssl req -key <(systemd-creds decrypt "${keyfile}") -new -subj "/CN=${HOSTNAME}.mangos/" -out "${csr}"
        greenln Success
    fi

    mkdir -p /var/lib/mangos
    step "Submitting CSR to Vault for signing"
    vault write -field=certificate pki-nodes/sign/node-cert \
        csr=@/etc/credstore/mangos.csr \
        common_name="${HOSTNAME}.mangos" \
        ttl=72h \
        format=pem > /var/lib/mangos/mangos.crt
    greenln Success

	step "Authenticating to Vault using TLS certificate"
	# Use the issued certificate to authenticate to Vault
	# This both verifies that the auth method works, the node can authenticate,
	# AND it creates the identity entity for this node.
	NODE_VAULT_TOKEN=$(vault login -method=cert -path=node-cert -client-cert=/var/lib/mangos/mangos.crt -client-key=<(systemd-creds decrypt /etc/credstore.encrypted/mangos.key) -token-only)
	greenln Success

	step "Getting mount accessor for node-cert"
	node_auth_accessor=$(vault read -field=accessor sys/mounts/auth/node-cert)
	echo "${node_auth_accessor}"

    entity_info=$(mktemp)
	step "Looking up Vault entity for this node"
	vault write -format=json identity/lookup/entity alias_name="${HOSTNAME}.mangos" alias_mount_accessor="${node_auth_accessor}" > "${entity_info}"
    entity_name=$(jq .data.name -r < "${entity_info}")
    entity_id=$(jq .data.id -r < "${entity_info}")
	greenln "${entity_name}"
    rm -f "${entity_info}"

    for group in consul-clients nomad-clients
    do
        step "Adding entity ${entity_name} to group ${group}"
		members="$(vault read -format=json identity/group/name/${group} | jq -r '.data.member_entity_ids | join(",")')"
		if [ -z "${members}" ]
		then
			members="${entity_id}"
		else
			members="${members},${entity_id}"
		fi
		vault write identity/group/name/${group} member_entity_ids="${members}"
        greenln Success
    done

	step "Authenticating to Vault again using TLS certificate"
	NODE_VAULT_TOKEN=$(vault login -method=cert -path=node-cert -client-cert=/var/lib/mangos/mangos.crt -client-key=<(systemd-creds decrypt /etc/credstore.encrypted/mangos.key) -token-only)
	greenln Success

	# If there's already an agent recovery token, we don't need to add a new one
	if ! [ -s "/etc/credstore.encrypted/consul.agent_recovery" ]
	then
		step "Generating Consul agent recovery token"
		agent_recovery_token=$(systemd-id128 -u new)
		systemd-creds -H encrypt - /etc/credstore.encrypted/consul.agent_recovery <<<"${agent_recovery_token}"
		greenln Success
	fi

    step "Issuing certificates for Consul and Nomad"
	mkdir -p /var/lib/consul/ssl
	chown -R consul:consul /var/lib/consul

	mkdir -p /var/lib/nomad/ssl
	chown -R nomad:nomad /var/lib/nomad

	CONSUL_DATACENTER=${REGION}-${DATACENTER} \
	NOMAD_REGION=${REGION} \
	NOMAD_DATACENTER=${DATACENTER} \
    VAULT_TOKEN=${NODE_VAULT_TOKEN} \
	consul-template -vault-renew-token=false -once \
		-config /usr/share/consul-template/conf/consul-certs.hcl \
		-config /usr/share/consul-template/conf/nomad-certs.hcl
	greenln Success

    argv=()

    if ! [ -s "/var/lib/consul/data/serf/local.keyring" ]
    then
        enckey=$(mktemp --suffix .json)
        step "Fetching Consul gossip encryption key from Vault"
        VAULT_TOKEN=${NODE_VAULT_TOKEN} vault read -field=encryption_key secrets/mangos/consul/gossip | jq -R '{encrypt:.}' > "${enckey}"
        chown consul:consul "${enckey}"
        greenln Success
        argv+=(-config-file="${enckey}")
    fi

	if ! [ -e "/var/lib/consul/data/serf" ]
	then
		step "Initializing Consul client"
		chronic systemd-run \
			-u consul-bootstrap \
			--uid=consul \
			--gid=consul \
			-p "Type=notify" \
			-p "StateDirectory=consul/data consul/ssl" \
			-p "Conflicts=consul.service" \
            -p "Before=consul.service" \
			/usr/bin/consul agent \
			-retry-join "${1}" \
			-config-dir=/usr/share/consul/ \
			-datacenter "${REGION}-${DATACENTER}" \
			"${argv[@]}"
		greenln Success
	fi

	do_step "Starting Consul agent" chronic systemctl start consul
    do_step "Joining Consul cluster" chronic consul join -token-file <(systemd-creds decrypt /etc/credstore.encrypted/consul.agent_recovery | jq -r .acl.tokens.agent_recovery) "${server}"

	step "Acquiring Consul management token"
	consul_mgmt_token=$(vault read -field=token consul/creds/management)
	greenln Success

	has_token() {
		jq -e ".$1" < /var/lib/consul/data/acl-tokens.json > /dev/null
	}

	if ! has_token agent
	then
		set_agent_token agent "$(CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create -node-identity "$(hostname):${REGION}-${DATACENTER}" -role-name=consul-agent -format=json |jq -r .SecretID)"
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

    if ! [ -s "/etc/credstore.encrypted/nomad.consul_token" ]
	then
		step "Creating Consul token for Nomad agent"
            CONSUL_HTTP_TOKEN=${consul_mgmt_token} consul acl token create \
			-service-identity nomad-client -policy-name nomad-client \
			-description "Nomad client on $(hostname)" \
			-format=json | jq .SecretID -r | systemd-creds -H encrypt - /etc/credstore.encrypted/nomad.consul_token
		greenln Success
	fi

    do_step "Enabling and starting Nomad, Consul, and Consul-Template services" chronic systemctl enable --now nomad consul consul-template
}

chronic() {
	if [ "${VERBOSE}" != "" ]
	then
		"$@"
		return $?
	fi
	local tmp

    tmp=$(mktemp)

	rv=0
	"$@" > "${tmp}" 2>&1 || rv=$?

	if [ ${rv} -ne 0 ]
	then
		cat "${tmp}"
	fi
	rm -f "${tmp}"
	return ${rv}
}

green() {
    echo -ne "\033[0;32m$*\033[0m"
}

greenln() {
    green "$@"
    echo
}

red() {
    echo -ne "\033[0;31m$*\033[0m"
}

bold() {
    echo -ne "\033[1m$*\033[0m"
}

step() {
    bold " > ${*}... "
}

success() {
    green "Success"
    echo
}

failure() {
    red "Failure"
    echo
}

do_step() {
	step "$1"
	shift
	if "$@"
	then
		success
	else
		failure
		exit 1
	fi
}

case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

set_agent_token() {
	do_step "Setting Consul $1 token" chronic consul acl set-agent-token -token-file <(systemd-creds decrypt /etc/credstore.encrypted/consul.agent_recovery) "$@"
}

function download_hashistack_component() {
    local component=$1

    latest_version=$(curl -s "https://api.github.com/repos/hashicorp/${component}/releases/latest" | jq .name -r)

    if which "${component}" >/dev/null 2>&1; then
        installed_version="$("${component}" version | head -n1 | awk '{print $2}')"
        if [ "${installed_version}" = "${latest_version}" ]; then
            echo "${component} is already at the latest version (${latest_version}). Skipping download."
            return
        else
            echo "${component} is at version ${installed_version}. Latest version is ${latest_version}. Downloading latest version."
        fi
    else
        echo "${component} is not installed. Downloading version ${latest_version}."
    fi
    tmpdir=$(mktemp -d)
    trap 'rm -rf ${tmpdir}' EXIT
    curl -SL "https://releases.hashicorp.com/${component}/${latest_version#v}/${component}_${latest_version#v}_linux_${ARCH}.zip" -o "${tmpdir}/${component}.zip"
    unzip -o "${tmpdir}/${component}.zip" -d "/usr/bin" "${component}"
    rm -rf "${tmpdir}"
}

function add_verity_certificate {
    mkdir -p /etc/verity.d

    cat <<-EOF > /etc/verity.d/mangos.crt
-----BEGIN CERTIFICATE-----
MIIC5TCCAc2gAwIBAgIUU4S+TVkL0DYHqZKONciHpPbfcbgwDQYJKoZIhvcNAQEL
BQAwGzEZMBcGA1UEAwwQU29yZW4ncyBob21lIGxhYjAeFw0yNTExMjAxOTI2NDJa
Fw0yNzExMjAxOTI2NDJaMBsxGTAXBgNVBAMMEFNvcmVuJ3MgaG9tZSBsYWIwggEi
MA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCh33sD2tIB9kk4ZJNOBHYaB39w
OusexE2YTcz5ziyAOEVSRKpkE3TLZyE5GRfgOIeCqhQJegSjp5TBkL7EzlVAwWaR
v5IreYblvKdyfAzQW+635UG0YjjehhWs169bE+ob9gf+Yg89Q3yvvM0OcJIVSoHb
nwqWKclDABhDY+tLWVdNpO+Mcv2hF69x/PRIa3Al++sZ3rrjNOROX5ANxx2Xdhla
R51LJxyvMOLCAe0qk6S98hoRPxtGpQed8PA8cfZlqaYho9qcrIWjXGp/gn8fB6RX
4JJ+hQqbgRZXmG5EzTeVhK6BqoK3aAX7+zGR4weJedu7TE3HP5fNc5+wmTRHAgMB
AAGjITAfMB0GA1UdDgQWBBSlUcInTLql8nP8vWkYGaCofw+WxDANBgkqhkiG9w0B
AQsFAAOCAQEAjGHKbbp4CqxSenVtmAJJGCwb0hZyIqAzM/76Z4BrkF92nYgF826c
9r3YZN2QKh1s/FQ7MJhslFDRhnvzUO0X4SZiyhxCGFutNGAyfoRhr7TGE3DJwJe8
wekbaiaDk/TY33WWuEvkzQKYIHxBo5v+zXWn/Q0kjkLvdiY9QnZJmUfSbr+6mzR4
4ZDRAnbxt6J60hsjmwGx23LhtrRNQ4gd6cQcQ+V9oR3XHmDjjImM4YTi0keo/NgX
neOQ3u5FAIIyA7HpfyQMpXstzlMCgmqK7e3sxF0piXq3J7aiHLDHfJJREsg5IQ9J
kEVGE8Bf5B8gHO9kH4yP7fyYT6jSgFEfRA==
-----END CERTIFICATE-----
EOF
}

function add_ca_certificate {
    cat <<EOF > /usr/local/share/ca-certificates/mangos.crt
-----BEGIN CERTIFICATE-----
MIIDIzCCAgugAwIBAgIUWqIh1c2u/zGBGgDTKxDwnnv3OGMwDQYJKoZIhvcNAQEL
BQAwGTEXMBUGA1UEAxMOTWFuZ29zIFJvb3QgQ0EwHhcNMjUxMTI5MDMwMjEyWhcN
MzUxMTI3MDMwMjQyWjAZMRcwFQYDVQQDEw5NYW5nb3MgUm9vdCBDQTCCASIwDQYJ
KoZIhvcNAQEBBQADggEPADCCAQoCggEBALIxy53iQGU3Rb85HTDgQA0uY/uhYALN
raLRxRsfKLEk2nt1CPorlPog4vdQN7rS+tDuSCM/zPfy91kaBGPBLin6jcf48mLd
ymid5h70CekfNCkpEsyaz/uygko0mYJJAGk1P5TysQ7kWNhX4cWFRSvhhdRaOFEz
8UdbadVNF09pCW87Pa3J6NBLO8N44n9/Q4tDc0n1d397s9vDv/L0ADGaAeqHvsix
dtIokib2xkRyT26/3PAscA3ip8J8zXpQUHha7zcGui4VaglaC/acn7//TMHETKkI
yy/lAuMR4KugZJrCSRxHscNvCLP5Y55ChSeYkaoJgaDaoAHFqrXC3DsCAwEAAaNj
MGEwDgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFMfA
LTWM4FkPXb5d2gvWgZioOV7KMB8GA1UdIwQYMBaAFMfALTWM4FkPXb5d2gvWgZio
OV7KMA0GCSqGSIb3DQEBCwUAA4IBAQB+9WqD9vsasfAJWPyFeQS0min2ly6SeoU6
F7ytadfQTrwpSTi8bnKJNbwK6h++Ttd5t8VG0pCS+iTwx406jdQI+7DAFz5r9D6e
HOPNY+C5QE+2YO8bmkj60sQTA20R8Nd8ItZna4gpPDt/usYZf0sAJBsd12B44eoA
A3BIPzcYmXK2NuKgtEHOLT/8V3A98NlJQsZFHenMCJF9dhGmi5LaEnqTUOk1YdKC
lbF4n83eC7YZ14gUs+Z75AskVdiOm7/FCqbLW6lEIZajINiPuNBCYlQ5iFrUIY7t
UrGt/p2xPeNx2Am+WYiu9Xq+jjZ08lqR2CyjciReVk253eTbEhZM
-----END CERTIFICATE-----
EOF

    update-ca-certificates
}

function add_environment {
    mkdir -p /etc/environment.d
    cat <<-EOF > /etc/environment.d/20-mangos.conf
CONSUL_DATACENTER=us-west1-2275melvin
NOMAD_DATACENTER=2275melvin
NOMAD_REGION=us-west1
VAULT_ADDR=https://vault.service.consul:8200
NOMAD_ADDR=https://nomad.service.consul:4646
EOF
}

function setup_environment {
    add_verity_certificate

    add_ca_certificate

    add_environment
}

function download_hashistack_sysext {
    mkdir -p /var/lib/extensions/

    local component=$1

    mkdir -p /var/lib/extensions/"${component}".raw.v
    mkdir -p "/usr/lib/sysupdate.${component}.d"
    cat <<EOF > "/usr/lib/sysupdate.${component}.d/${component}.${transfer_extension}"
[Source]
Type=url-file
Path=http://node-a6e4-b90b.lan:8081/
MatchPattern=${component}_@v.raw \
             ${component}_@v.raw.gz \
             ${component}_@v.raw.zstd \
             ${component}_@v.raw.xz \

[Target]
Type=regular-file
Path=/var/lib/extensions/${component}.raw.v/
InstancesMax=2
MatchPattern=${component}_@v.raw
Mode=0444
EOF
    /usr/lib/systemd/systemd-sysupdate -C "${component}" --verify=no update
}

main "$@"
