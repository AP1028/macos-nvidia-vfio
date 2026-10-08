#!/usr/bin/env bash
# gpu-to-vfio.sh — release the GPU from its host driver, size BAR1 for the guest,
# and hand it to vfio-pci so a VM can be started against it.
#
#   sudo ./gpu-to-vfio.sh [BAR_BIT_INDEX]
#
# BAR_BIT_INDEX defaults to 14 (16 GiB). It is a BIT INDEX, not a byte count:
#   8=256MB  11=2GiB  12=4GiB  13=8GiB  14=16GiB      (size = 2^(idx+20))
# Use the largest size your card advertises. A BAR under 4 GiB caps the NullMoth
# driver's VRAM budget at 192 MB, because budget = fBarLen/2 (with a 192 MB
# fallback below 4 GiB).
#
# Set for your hardware:
# ⚠️ EDIT THIS. The address below is DELIBERATELY FAKE (ff:1f.0 is not a real
# device) so that a copy-paste fails loudly instead of touching the wrong GPU.
# Find yours with:  lspci -nn | grep -i -e nvidia -e vga
# It looks like 0000:01:00.0 -> use that. The audio function is .1 on the
# same bus/slot.
GPU_BDF="${GPU_BDF:-0000:ff:1f.0}"
GPU_AUDIO_BDF="${GPU_AUDIO_BDF:-0000:ff:1f.1}"
HOST_DRIVER="${HOST_DRIVER:-nvidia}"

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

BAR_IDX="${1:-14}"
DEVS=("$GPU_BDF")
[ -e "/sys/bus/pci/devices/$GPU_AUDIO_BDF" ] && DEVS+=("$GPU_AUDIO_BDF")

bar1_bytes() {
    local bdf="$1" vals
    vals=$(sed -n '2p' "/sys/bus/pci/devices/$bdf/resource" 2>/dev/null) || { echo 0; return; }
    # shellcheck disable=SC2086
    set -- $vals
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo 0; return; }
    local n=$(( $2 - $1 + 1 ))
    [ "$n" -gt 0 ] 2>/dev/null && echo "$n" || echo 0
}

command -v fuser >/dev/null && {
    busy=$(fuser "/dev/nvidia0" 2>/dev/null || true)
    [ -n "$busy" ] && {
        echo "WARNING: these processes hold the GPU: $busy" >&2
        echo "Unbinding a busy GPU can hang the kernel. Stop them first." >&2
        exit 1
    }
}

modprobe vfio vfio_iommu_type1 vfio_pci 2>/dev/null || true

for dev in "${DEVS[@]}"; do
    sysfs="/sys/bus/pci/devices/$dev"
    [ -e "$sysfs" ] || { echo "skip $dev (not present)"; continue; }

    # driver_override MUST be cleared before unbind: while it names a driver the
    # kernel immediately re-binds, the unbind silently fails, and the BAR resize
    # that follows then operates on a device still in use.
    echo "" > "$sysfs/driver_override" 2>/dev/null || true

    cur=$(readlink "$sysfs/driver" 2>/dev/null | xargs -r basename || echo none)
    if [ "$cur" != "none" ] && [ "$cur" != "vfio-pci" ]; then
        echo "$dev: unbinding from $cur"
        echo "$dev" > "/sys/bus/pci/drivers/$cur/unbind" 2>/dev/null || true
        sleep 1
    fi
done

# Size BAR1 on the GPU only (the audio function has no resizable BAR).
if [ -e "/sys/bus/pci/devices/$GPU_BDF/resource1_resize" ]; then
    want=$(( 1 << (BAR_IDX + 20) ))
    before=$(bar1_bytes "$GPU_BDF")
    if [ "$before" = "$want" ]; then
        echo "$GPU_BDF: BAR1 already $(( before / 1048576 )) MiB"
    else
        printf '%d\n' "$BAR_IDX" > "/sys/bus/pci/devices/$GPU_BDF/resource1_resize"
        after=$(bar1_bytes "$GPU_BDF")
        echo "$GPU_BDF: BAR1 $(( before / 1048576 )) MiB -> $(( after / 1048576 )) MiB"
        [ "$after" = "$want" ] || echo "  WARNING: card did not accept that size; it may not advertise it" >&2
    fi
else
    echo "$GPU_BDF: no resizable BAR1 (non-Resizable-BAR card)" >&2
fi

for dev in "${DEVS[@]}"; do
    sysfs="/sys/bus/pci/devices/$dev"
    [ -e "$sysfs" ] || continue
    echo "vfio-pci" > "$sysfs/driver_override" 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
done

echo
echo "verifying:"
rc=0
for dev in "${DEVS[@]}"; do
    [ -e "/sys/bus/pci/devices/$dev" ] || continue
    drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs -r basename || echo none)
    printf '  %s -> %s\n' "$dev" "$drv"
    [ "$drv" = "vfio-pci" ] || rc=1
done
[ "$rc" -eq 0 ] && echo "OK — the GPU is ready to pass through" || { echo "FAILED — check dmesg" >&2; exit 1; }
