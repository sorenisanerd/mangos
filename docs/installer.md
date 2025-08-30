# Installer docs

The installer is included in the standard Mangos initrd, but only runs when explicitly requested.

To activate the installer, pass `mangos_install_target=ARG` on the kernel command line. `mangos-installer-generator` detects this and adds `mangos-install.service` to `initrd.target`.

 `ARG` can be either the name of a block device or the static string `ask`. Block devices can be specified as e.g. simply `/dev/sda`, but it's generally better to use the `/dev/disk/by-*` hierarchy to benefit from consistently named block devices. `mangos-installer-generator` will add `Requires=<target device>`  and `After=<target device>` to `mangos-install.service`.

If `ARG` is set to `ask`, a simple dialog will be shown listing all the detected block devices. Since the target device is not known ahead of time, no device specific `Requires=` or `After=` dependency can be added.

Once the target has been identified/selected, the installer streams the disk image from Github to the target device, decompressing it on the fly. The image is written directly to the block device, so **ALL** existing data on the device will be lost.

The image uses GPT. GPT keeps two copies of its header. One near the start of the disk, one at the end. The image size is unlikely to equal your disk size, so the installer ensures the secondary copy is moved to the end of the disk. It also creates a fresh UUID for the disk as well as the ESP.

Finally, an EFI boot entry is created and we reboot.

The installer also accepts configuration via systemd credentials. This lets you pass e.g. `-smbios type=11,value=io.systemd.credential:mangos_install_target=/dev/vdb` to QEMU, and it will be passed along to the installer. `mangos_install_source` can also be specified this way to override the default image URL.
