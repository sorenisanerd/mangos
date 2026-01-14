#!/bin/bash

set -e
set -o pipefail

machine_id="$(cat /etc/machine-id)"

# Returns: mapper name for given device, or empty if not mapped
find_mapper_for() {
    dev_path="${1}"
    dev_name="$(basename "${dev_path}")"
    # shellcheck disable=2012 # this is system file and has predictable name
    holder="$(ls /sys/class/block/"${dev_name}"/holders/ | head -n 1)"
    cat "/sys/class/block/${holder}/dm/name"
}


test_recovery_key() {
    test_device="$1"
    mapper_name="$(find_mapper_for "${test_device}")"
    test_partition="$(lsblk -nlo PARTLABEL "${test_device}" | tr -d '\n')"
     # Get recovery key from Vault
    recovery_key="$(mangosctl sudo -- vault kv get -field=key "secrets/mangos/recovery-keys/${machine_id}/${test_partition}")"

    echo "=> Testing recovery key passphrase for device: ${test_device}, partition: ${test_partition}, mapper: ${mapper_name}"
    recovery_slot="$(cryptsetup luksDump "${test_device}" | \
        awk '/Tokens:/,/Keyslots:/ {if (/systemd-tpm2/) found=1; if (found && /^  [0-9]+:/) {print $1; exit}}' | \
        tr -d ':')"

    if cryptsetup open --test-passphrase "${test_device}" --verbose --key-slot "${recovery_slot}" <<< "${recovery_key}"; then
        echo "Recovery key is valid for device: ${test_device}"
    else
        echo "ERROR: Recovery key is NOT valid for device: ${test_device}"
        return 1
    fi

    real_dev="$(readlink -f "/dev/mapper/${mapper_name}")"
    echo "Device /dev/mapper/${mapper_name} points to ${real_dev}"
    
    is_swap=0
    swap_device="${test_device}"
    if swapon --show=NAME --noheadings | grep -xq "/dev/mapper/${mapper_name}"; then
        is_swap=1
        swap_device="/dev/mapper/${mapper_name}"
        swapoff "/dev/mapper/${mapper_name}"
    fi

    if swapon --show=NAME --noheadings | grep -xq "${real_dev}"; then
        is_swap=1
        swap_device="${real_dev}"
        swapoff "${real_dev}"
    fi

    if [ "${is_swap}" -eq 0 ]; then
        echo "Test device is not swap, trying next..."
        return 1
    fi
    echo "Swap device identified as: ${swap_device}"
    echo "=> End to end testing recovery key for ${test_partition} (device: ${test_device}, mapper: ${mapper_name})..."
    echo ""

    # Find TPM keyslot number
    tpm_slot="$(cryptsetup luksDump "${test_device}" | \
        awk '/Tokens:/,/Keyslots:/ {if (/systemd-tpm2/) found=1; if (found && /^  [0-9]+:/) {print $1; exit}}' | \
        tr -d ':')"

    echo "Removing TPM keyslot ${tpm_slot} (simulating TPM failure)..."
    # Provide the recovery key on stdin so systemd-cryptenroll does not prompt interactively.
    # Use --unlock-key-file=/dev/stdin to read the key from stdin when wiping the TPM slot.
    printf '%s' "${recovery_key}" | systemd-cryptenroll --wipe-slot=tpm2 --unlock-key-file=/dev/stdin "${test_device}"

    echo "Verifying device is still present... ${mapper_name}."

    if [ ! -b "/dev/mapper/${mapper_name}" ]; then
        echo "ERROR: Device not found - /dev/mapper/${mapper_name}"
        return 1
    fi

    cryptsetup close "${mapper_name}"

    echo "Unlocking with recovery key..."
    if echo -n "${recovery_key}" | cryptsetup open "${test_device}" "${mapper_name}" --key-file -
    then
        echo "Device unlocked successfully with recovery key."
    else
        echo "ERROR: Failed to unlock device with recovery key"
        exit 1
    fi
    
    swapon "${swap_device}"

    swapon --show=NAME --noheadings | grep -xq "${swap_device}" || {
            echo "ERROR: Swap not active after recovery"
            exit 1
    }
    echo "Swap active after recovery: OK"

    # Re-enroll TPM (cleanup for future tests)
    echo "Re-enrolling TPM keyslot..."
    # Re-enroll by supplying the recovery key on stdin (non-interactive)
    printf '%s' "${recovery_key}" | systemd-cryptenroll "${test_device}" \
        --tpm2-device=auto \
        --tpm2-pcrs=7 \
        --tpm2-public-key-pcrs=11 \
        --unlock-key-file=/dev/stdin

    echo "Recovery test: PASSED"

}

# Auto-detect first LUKS partition for testing
devices="$(lsblk -ln -o NAME,TYPE,FSTYPE | awk '$2=="part" && $3=="crypto_LUKS" {print "/dev/"$1}' | tr '\n' ' ')"

echo "> LUKS-encrypted devices found: ${devices}"
swaps_tested=""
for test_device in ${devices}; do
    echo "=> Testing device: ${test_device}"
    if test_recovery_key "${test_device}"
    then
        echo "=> Recovery test passed for device: ${test_device}"
        swaps_tested="${swaps_tested}, ${test_device}"
    fi
done

echo "> All recovery tests completed successfully."
echo "> Tested recovery passphrase for devices: ${devices}"
echo "> End to end tests done: ${swaps_tested}"
