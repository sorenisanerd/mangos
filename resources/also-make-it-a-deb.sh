#!/bin/bash

set -x
set -e
set -o pipefail

debdir=$(mktemp -d)

trap 'rm -rf "${debdir}"' EXIT

cp -r ${BUILDROOT}/* ${debdir}/

rm -rf ${debdir}/{var,usr/lib/{extension-release,sysupdate.*}.d}

case "${ARCHITECTURE}" in
        x86-64)
                arch=amd64
                ;;
        *)
                arch=${ARCHITECTURE}
                ;;
esac

mkdir -p "${debdir}/DEBIAN"
cat <<-EOF > "${debdir}/DEBIAN/control"
Package: ${SUBIMAGE}
Version: ${IMAGE_VERSION}
Architecture: ${arch}
Maintainer: Soren Hansen <soren.hansen@mastercard.com>
Description: ${SUBIMAGE}
EOF
mkdir -p ${OUTPUTDIR}/pool
dpkg-deb --root-owner-group --build "${debdir}" "${OUTPUTDIR}/${SUBIMAGE}_${IMAGE_VERSION}_${arch}.deb"
