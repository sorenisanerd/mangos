#!/bin/bash

fmt="%-17s %-8s %-8s %-14s %s\n"

printf "${fmt}" "Component" "Latest" "Binary" "mkosi.version"
for component in consul consul-template nomad terraform vault
do
	latest_release="$(curl https://github.com/hashicorp/${component}/releases/latest -w '%header{location}' -o /dev/null -s | sed -e s%.*/v%%g)"

	binary_version="$(mkosi.images/${component}/bin/${component} --version |& head -n1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')"
	binary_version="${binary_version#v}"

	from_mkosi_version="$(sed -e s%-.*%%g mkosi.images/${component}/mkosi.version)"

	info=""

	if [ "${latest_release}" != "${from_mkosi_version}" ] || [ "${binary_version}" != "${from_mkosi_version}" ]
	then
		info="MISMATCH"
	fi
	printf "${fmt}" "${component}" "${latest_release}" "${binary_version}" "${from_mkosi_version}" "${info}"

done
