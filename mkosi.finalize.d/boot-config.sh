#!/bin/sh

set -e

mv ${BUILDROOT}/boot/EFI/Linux/*.efi ${BUILDROOT}/boot/EFI/Linux/${IMAGE_ID}_${IMAGE_VERSION}.efi
