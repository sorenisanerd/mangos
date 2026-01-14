#!/bin/bash

builddir="$(mktemp -d)"
mkdir -p "${builddir}/imgs"

# Reconstruct the ESP the tarball
tar xf "${OUTPUTDIR}/mangos_${IMAGE_VERSION}.tar" -C "${builddir}" ./boot ./efi --strip-components=2

# We only need the UKI.
rm "${builddir}"/vmlinuz*

# Compress the raw images
for path in ${OUTPUTDIR}/mangos_${IMAGE_VERSION}.{grub,root-${ARCHITECTURE}*.*}.raw
do
    resources/strip_trailing_null_blocks.sh "${path}"
    filename="$(basename "${path}")"
    zstd "${OUTPUTDIR}/${filename}" -o "${builddir}/imgs/${filename}.zst"
done

size="$(du -s "${builddir}" | grep -oE '^[0-9]*')"

systemd-repart --empty=create --sector-size=512 --size=$(( size + (10*1024) ))K --definitions=resources/repart.installer.d --root="${builddir}" --dry-run=no "${OUTPUTDIR}/mangos-installer_${IMAGE_VERSION}.raw"
