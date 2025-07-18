#!/bin/sh

set -e

if [ "${PROFILES}" != "${PROFILES#*verity-none*}" ]
then
  efi_entry_regex="^mangos-[0-9]+\.[0-9]+\.[0-9].*$"
  regex_description="'mangos-<kernel version>-<64 hex digits>'"
else
  efi_entry_regex="^mangos-[0-9]+\.[0-9]+\.[0-9].*-[0-9a-f]{64}$"
  regex_description="'mangos-<kernel version>'"
fi

token="${IMAGE_ID}_${IMAGE_VERSION}"

# EFI boot entry comes first. Grab its name.
efi_entry="$(grep ^menuentry ${BUILDROOT}/efi/grub/grub.cfg | head -n 1 | cut -d '"' -f2)"

# Ensure it matches the expected format
if ! echo "${efi_entry}" | grep -Eq "${efi_entry_regex}"
then
  echo "Expected entry named ${regex_description}, found: $efi_entry"
  exit 1
fi

# Copy currently distributed GRUB config 
cp -r "${BUILDROOT}/usr/share/mangos/boot/"* "${BUILDROOT}/boot/grub"

# Move the UKI EFI binary
mv ${BUILDROOT}/boot/EFI/Linux/${efi_entry}.efi ${BUILDROOT}/boot/EFI/Linux/${IMAGE_ID}_${IMAGE_VERSION}.efi 

# Now the non-UKI / "BIOS" variety
mkdir -p ${BUILDROOT}/boot/mangos

kvers="$(echo ${efi_entry} | sed -e "s/-[0-9a-f]\{64\}$//g" -e "s/${IMAGE_ID}-\(.*\)$/\1/g")"
roothash="$(echo "${efi_entry}" | grep -oE '[0-9a-f]{64}$' || true)"

echo "Info detected from EFI menuentry '${efi_entry}':"
echo ""
echo "  Kernel version: $kvers"
echo "        roothash: $roothash"
echo

echo "'*initrd*' matches in /boot:"
find "${BUILDROOT}/boot" -name '*initrd*'
echo ''

mv "${BUILDROOT}/boot/mangos/${kvers}/vmlinuz" "${BUILDROOT}/boot/mangos/vmlinuz-${IMAGE_VERSION}"

for initrd in "${BUILDROOT}/boot/mangos/initrd.cpio.gz" "${BUILDROOT}/boot/mangos/initrd"
do
  if [ -e "${initrd}" ]
  then
    mv "${initrd}" "${BUILDROOT}/boot/mangos/initrd.img-${IMAGE_VERSION}"
    break
  fi
done

if [ ! -e "${BUILDROOT}/boot/mangos/initrd.img-${IMAGE_VERSION}" ]
then
  echo "initrd not found in any of the expected locations."
  exit 1
fi

mkdir -p ${BUILDROOT}/boot/mangos/grub.d
cfgfile=${BUILDROOT}/boot/mangos/grub.d/${token}.cfg

echo "Creating ${cfgfile}"
rm ${BUILDROOT}/efi/grub/grub.cfg

if [ -n "${roothash}" ]
then
  root_arg="roothash=${roothash} "
else
  root_arg="root=/dev/disk/by-partlabel/${token}"
fi

cat <<EOF > ${cfgfile}
menuentry "${token}" {
  if [ "\${grub_platform}" == "efi" ]; then
    echo "Loading UKI..."
    chainloader /EFI/Linux/${token}.efi
  else 
    echo "Loading kernel..."
    linux /${IMAGE_ID}/vmlinuz-${IMAGE_VERSION} nosplash debug verbose ${root_arg} \${systemd_machine_id} \${extra_kernel_args} console=hvc0 console=ttyS0
    echo "Loading initrd..."
    initrd /${IMAGE_ID}/initrd.img-${IMAGE_VERSION}
    echo "Launching ${IMAGE_ID} ${IMAGE_VERSION}..."
  fi
}
EOF

cp ${BUILDROOT}/boot/${IMAGE_ID}/vmlinuz-${IMAGE_VERSION}    ${OUTPUTDIR}/${token}.vmlinuz
cp ${BUILDROOT}/boot/${IMAGE_ID}/initrd.img-${IMAGE_VERSION} ${OUTPUTDIR}/${token}.initrd.cpio.gz
cp "${cfgfile}" "${OUTPUTDIR}/${token}.grub.cfg"
