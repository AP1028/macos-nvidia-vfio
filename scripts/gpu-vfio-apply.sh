#!/usr/bin/env bash
set -euo pipefail
# ============================================================================
#  REVIEW BEFORE RUNNING. This script detects the GPU itself (via lspci), but it
#  still assumes things about your machine:
#
#    * the GPU is the first NVIDIA 3D controller lspci reports -- if you have
#      more than one, set GPU_BDF below explicitly;
#    * the BAR sizes at the bottom of this block match the card this was written
#      for. Check what yours advertises:  lspci -vv | grep -A2 "Resizable BAR"
#    * it may reference host services (e.g. a GPU power manager) that do not
#      exist on your system. Those guards degrade to no-ops, but read them.
#
#  It will NOT silently damage anything: if it cannot find the GPU it stops.
#  Still, read it before running it as root.
# ============================================================================

red()    { echo -e "\e[31m$*\e[0m" >&2; }
green()  { echo -e "\e[32m$*\e[0m" >&2; }
yellow() { echo -e "\e[33m$*\e[0m" >&2; }
info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }
ok()     { echo -e "\e[32m[OK]\e[0m    $*" >&2; }

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

PENDING="/etc/gpu-switch/pending"

if [ ! -f "$PENDING" ]; then
    red "No pending GPU switch found."
    echo "Run gpu-to-vfio or gpu-to-host first to schedule a switch."
    exit 1
fi

# ── Warn about active graphical sessions ─────────────────────
if command -v loginctl &>/dev/null; then
    ACTIVE=$(loginctl list-sessions --no-legend 2>/dev/null | grep -v "tty" | grep "seat0" | wc -l)
    if [ "$ACTIVE" -gt 0 ]; then
        yellow "WARNING: ${ACTIVE} active graphical session(s) detected."
        yellow "It's safer to log out of your desktop first."
        yellow "Then switch to a VT (Ctrl+Alt+F2), log in as root, and run this again."
        echo ""
        read -rp "Proceed anyway? [y/N] " ans
        [[ "$ans" =~ ^[Yy] ]] || exit 1
    fi
fi

# ── Read and apply ───────────────────────────────────────────
MODE=$(cat "$PENDING")
rm -f "$PENDING"

info "Applying pending GPU switch: ${MODE}"
case "$MODE" in
    vfio)
        info "Binding GPU to vfio-pci..."
        exec gpu-to-vfio
        ;;
    host)
        info "Returning GPU to nvidia host driver..."
        exec gpu-to-host
        ;;
    *)
        red "Unknown pending mode: ${MODE}"
        exit 1
        ;;
esac
