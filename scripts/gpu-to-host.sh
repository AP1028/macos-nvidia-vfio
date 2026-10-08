#!/usr/bin/env bash
# gpu-to-host.sh — give the GPU back to its host driver and restore the full BAR1.
#
#   sudo ./gpu-to-host.sh
#
# Run this after shutting the VM down. Destroy the domain first; unbinding a GPU
# that a running VM is using will not go well.

GPU_BDF="${GPU_BDF:-0000:01:00.0}"
GPU_AUDIO_BDF="${GPU_AUDIO_BDF:-0000:01:00.1}"
HOST_DRIVER="${HOST_DRIVER:-nvidia}"
HOST_BAR_IDX="${HOST_BAR_IDX:-14}"       # 14 = 16 GiB

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

bar1_bytes() {
    local bdf="$1" vals
    vals=$(sed -n '2p' "/sys/bus/pci/devices/$bdf/resource" 2>/dev/null) || { echo 0; return; }
    # shellcheck disable=SC2086
    set -- $vals
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo 0; return; }
    local n=$(( $2 - $1 + 1 ))
    [ "$n" -gt 0 ] 2>/dev/null && echo "$n" || echo 0
}

DEVS=("$GPU_BDF")
[ -e "/sys/bus/pci/devices/$GPU_AUDIO_BDF" ] && DEVS+=("$GPU_AUDIO_BDF")

# Release from vfio-pci. driver_override first, as always.
for dev in "${DEVS[@]}"; do
    sysfs="/sys/bus/pci/devices/$dev"
    [ -e "$sysfs" ] || continue
    echo "" > "$sysfs/driver_override" 2>/dev/null || true
    cur=$(readlink "$sysfs/driver" 2>/dev/null | xargs -r basename || echo none)
    if [ "$cur" = "vfio-pci" ]; then
        echo "$dev: unbinding from vfio-pci"
        echo "$dev" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
        sleep 1
    fi
done

# Restore the full BAR1 while nothing holds the device.
if [ -e "/sys/bus/pci/devices/$GPU_BDF/resource1_resize" ]; then
    want=$(( 1 << (HOST_BAR_IDX + 20) ))
    before=$(bar1_bytes "$GPU_BDF")
    if [ "$before" != "$want" ]; then
        printf '%d\n' "$HOST_BAR_IDX" > "/sys/bus/pci/devices/$GPU_BDF/resource1_resize" 2>/dev/null || true
        after=$(bar1_bytes "$GPU_BDF")
        echo "$GPU_BDF: BAR1 $(( before / 1048576 )) MiB -> $(( after / 1048576 )) MiB"
    fi
fi

# Hand back to the host driver.
modprobe "$HOST_DRIVER" 2>/dev/null || true
for dev in "${DEVS[@]}"; do
    [ -e "/sys/bus/pci/devices/$dev" ] || continue
    if [ -e "/sys/bus/pci/drivers/$HOST_DRIVER/bind" ]; then
        echo "$dev" > "/sys/bus/pci/drivers/$HOST_DRIVER/bind" 2>/dev/null || true
    else
        echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    fi
done

echo
echo "verifying:"
for dev in "${DEVS[@]}"; do
    [ -e "/sys/bus/pci/devices/$dev" ] || continue
    drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs -r basename || echo none)
    printf '  %s -> %s\n' "$dev" "$drv"
done
nvidia-smi -L 2>/dev/null | sed 's/^/  /' || true
