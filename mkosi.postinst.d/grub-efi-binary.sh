#!/bin/sh
# Quoting https://github.com/systemd/mkosi/blob/485da586a89f400ca115168041972417fec4f5b3/mkosi/resources/man/mkosi.1.md?plain=1#L870-L877
#
#   Note that we do not yet install grub to the ESP when `Bootloader=` is
#   set to `grub`. This has to be done manually in a postinst or finalize
#   script. The grub EFI binary should be installed to
#   `/efi/EFI/BOOT/BOOTX64.EFI` (or similar depending on the architecture)
#   and should be configured to load its configuration from
#   `EFI/<distribution>/grub.cfg` in the ESP. Signed versions of grub
#   shipped by distributions will load their configuration from this
#   location by default.
#
set -x
mkosi-chroot mkdir -p /efi/EFI/BOOT

if [ -e "${BUILDROOT}/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" ]
then
        mkosi-chroot cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed /efi/EFI/BOOT/BOOTX64.EFI
else
        mkosi-chroot cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi /efi/EFI/BOOT/BOOTX64.EFI
fi
