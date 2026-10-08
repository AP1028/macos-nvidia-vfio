#!/usr/bin/env bash
# set-bar1.sh — set the passed-through GPU's Resizable BAR1 size.
#
#   sudo ./set-bar1.sh 16GiB          # or: 17179869184 | 14
#
# Accepts a size in bytes, a size with a GiB/MiB suffix, or a raw bit index.
# There is deliberately NO default: this value decides the NullMoth driver's
# VRAM budget, and a small one silently caps it at 192 MB.
#
#     budget = (fBarLen >= 4 GiB) ? fBarLen / 2 : 192 MB
#
#   16 GiB BAR -> 8 GiB budget      256 MB BAR -> 192 MB budget
#
# The device MUST be unbound while this runs (see gpu-to-vfio.sh, which does the
# unbind, the resize and the vfio bind in the right order).

GPU_BDF="${GPU_BDF:-0000:01:00.0}"

set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
[ $# -ge 1 ] || { echo "usage: $0 <size>    e.g. $0 16GiB  |  $0 17179869184  |  $0 14" >&2; exit 2; }

arg="$1"
case "$arg" in
    *GiB|*Gib|*gib) size=$(( ${arg%[Gg]i[Bb]} * 1024 * 1024 * 1024 )) ;;
    *MiB|*Mib|*mib) size=$(( ${arg%[Mm]i[Bb]} * 1024 * 1024 )) ;;
    *[0-9])         size="$arg" ;;
    *) echo "unrecognised size: $arg" >&2; exit 2 ;;
esac

# A bare small integer is treated as a bit index, which is what sysfs wants.
if [ "$size" -le 31 ] 2>/dev/null; then
    idx="$size"
    size=$(( 1 << (idx + 20) ))
    echo "interpreting '$arg' as bit index $idx = $(( size / 1048576 )) MiB"
else
    idx=""
fi

f="/sys/bus/pci/devices/$GPU_BDF/resource1_resize"
[ -e "$f" ] || { echo "$GPU_BDF has no resizable BAR1" >&2; exit 1; }

drv=$(readlink "/sys/bus/pci/devices/$GPU_BDF/driver" 2>/dev/null | xargs -r basename || echo none)
[ "$drv" = "none" ] || {
    echo "$GPU_BDF is bound to '$drv'; the resize will fail with EBUSY." >&2
    echo "Unbind it first (gpu-to-vfio.sh does this in the right order)." >&2
    exit 1
}

before=$(sed -n '2p' "/sys/bus/pci/devices/$GPU_BDF/resource" | awk '{print $2-$1+1}')
printf '%s\n' "${idx:-$size}" > "$f"
after=$(sed -n '2p' "/sys/bus/pci/devices/$GPU_BDF/resource" | awk '{print $2-$1+1}')

echo "BAR1: $(( before / 1048576 )) MiB -> $(( after / 1048576 )) MiB"
if [ "$after" != "$size" ]; then
    echo "WARNING: wanted $(( size / 1048576 )) MiB but got $(( after / 1048576 )) MiB." >&2
    echo "The card only accepts sizes it advertises; check 'lspci -vv' for its" >&2
    echo "Resizable BAR capability, or cat $f." >&2
    exit 1
fi

if [ "$after" -ge $(( 4 * 1024 * 1024 * 1024 )) ]; then
    echo "expected driver VRAM budget: $(( after / 2 / 1048576 )) MiB"
else
    echo "WARNING: BAR1 is under 4 GiB, so the driver's budget falls back to 192 MB." >&2
    echo "Use the largest size the card advertises." >&2
fi
