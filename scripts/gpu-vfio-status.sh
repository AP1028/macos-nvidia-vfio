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
cyan()   { echo -e "\e[36m$*\e[0m" >&2; }
info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }

echo ""
cyan "═════════════════════════════════════════════"
cyan "  GPU VFIO / Host Binding Status"
cyan "═════════════════════════════════════════════"
echo ""

# ── Resizable BAR helper ─────────────────────────────────────
# BAR1 is resized for passthrough (4 GiB) and restored for the host
# (16 GiB) by gpu-to-vfio / gpu-to-host. Show the current size.
# resource1_resize uses a bit index, so size = 2^(idx+20) bytes.
bar1_bytes() {
    local bdf="$1" vals
    vals=$(sed -n '2p' "/sys/bus/pci/devices/$bdf/resource" 2>/dev/null) || { echo 0; return; }
    # shellcheck disable=SC2086
    set -- $vals
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo 0; return; }
    local n=$(( $2 - $1 + 1 ))
    [ "$n" -gt 0 ] 2>/dev/null && echo "$n" || echo 0
}
bar1_human() {
    local b="$1"
    if   [ "$b" -ge 1073741824 ]; then echo "$(( b / 1073741824 )) GiB"
    elif [ "$b" -ge 1048576 ];    then echo "$(( b / 1048576 )) MiB"
    elif [ "$b" -gt 0 ];          then echo "$(( b / 1024 )) KiB"
    else echo "unassigned"; fi
}

# ── NVIDIA PCI devices ───────────────────────────────────────
echo "── NVIDIA dGPU PCI Devices ──"
echo ""

FOUND=false
while IFS= read -r line; do
    FOUND=true
    bdf=$(echo "$line" | awk '{print $1}')
    desc=$(echo "$line" | cut -d' ' -f2-)
    vendor_id=$(lspci -ns "$bdf" 2>/dev/null | awk '{print $3}' || echo "unknown")

    drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    iommu=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")

    # Color by driver
    case "$drv" in
        nvidia)   drv_color="\e[32m" ;;  # green — host
        vfio-pci) drv_color="\e[35m" ;;  # purple — VM-ready
        *)        drv_color="\e[31m" ;;  # red — unknown
    esac

    printf "  \e[1m%-37s\e[0m  vendor:device = %s\n" "$bdf" "$vendor_id"
    printf "    %s\n" "$desc"
    printf "    driver:       ${drv_color}%s\e[0m\n" "$drv"
    printf "    iommu_group:  %s\n" "$iommu"

    # Resizable BAR1: 4 GiB = passthrough size, 16 GiB = host max
    if [ -e "/sys/bus/pci/devices/$bdf/resource1_resize" ]; then
        bar_sz=$(bar1_human "$(bar1_bytes "$bdf")")
        case "$bar_sz" in
            "4 GiB")  printf "    BAR1:         \e[35m%s\e[0m  (passthrough size)\n" "$bar_sz" ;;
            "16 GiB") printf "    BAR1:         \e[32m%s\e[0m  (host maximum)\n" "$bar_sz" ;;
            *)        printf "    BAR1:         %s\n" "$bar_sz" ;;
        esac
    fi

    # Check runtime PM status
    pm_status=$(cat "/sys/bus/pci/devices/$bdf/power/runtime_status" 2>/dev/null || echo "unknown")
    printf "    pm_status:    %s\n" "$pm_status"

    # Show IOMMU group peers
    iommu_dir="/sys/kernel/iommu_groups/$iommu/devices" 2>/dev/null
    if [ -d "$iommu_dir" ]; then
        peers=$(ls "$iommu_dir" 2>/dev/null | grep -v "${bdf##0000:}" || true)
        if [ -n "$peers" ]; then
            printf "    iommu_peers:  %s\n" "$peers"
        fi
    fi
    echo ""
done < <(lspci -D -d 10DE: 2>/dev/null)

if ! $FOUND; then
    yellow "  No NVIDIA PCI devices found."
    yellow "  (GPU may be hard-disabled via ASUS dgpu_disable, or absent.)"
    echo ""
fi

# ── NVIDIA kernel modules ────────────────────────────────────
echo "── NVIDIA Kernel Modules ──"
echo ""
has_mod=false
for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    if lsmod 2>/dev/null | grep -q "^$mod "; then
        count=$(lsmod 2>/dev/null | grep "^$mod " | awk '{print $3}')
        printf "  \e[32m%-20s  loaded  (used by: %s)\e[0m\n" "$mod" "${count:-0}"
        has_mod=true
    fi
done
if ! $has_mod; then
    echo "  (none loaded)"
fi
echo ""

# ── VFIO kernel modules ──────────────────────────────────────
echo "── VFIO Kernel Modules ──"
echo ""
has_mod=false
for mod in vfio_pci vfio_pci_core vfio_iommu_type1 vfio; do
    if lsmod 2>/dev/null | grep -q "^$mod "; then
        count=$(lsmod 2>/dev/null | grep "^$mod " | awk '{print $3}')
        printf "  \e[35m%-20s  loaded  (used by: %s)\e[0m\n" "$mod" "${count:-0}"
        has_mod=true
    fi
done
if ! $has_mod; then
    echo "  (none loaded)"
fi
echo ""

# ── VM activity check (requires root) ────────────────────────
echo "── VM Activity ──"
echo ""
if [ "$EUID" -eq 0 ]; then
    vm_found=false
    for vfio_dev in /dev/vfio/*; do
        [ -e "$vfio_dev" ] || continue
        iommu=$(basename "$vfio_dev")
        if fuser "$vfio_dev" >/dev/null 2>&1; then
            vm_found=true
            printf "  \e[33m/dev/vfio/%s  IN USE by VM:\e[0m\n" "$iommu"
            fuser -v "$vfio_dev" 2>&1 | sed 's/^/    /'
        fi
    done
    if ! $vm_found; then
        echo "  No VM seems to be using any VFIO device."
    fi
else
    yellow "  Run as root for VM activity check."
fi
echo ""

# ── Processes using nvidia devices ───────────────────────────
echo "── Processes Using NVIDIA Devices ──"
echo ""
has_proc=false
for nvdev in /dev/nvidia*; do
    [ -e "$nvdev" ] || continue
    if [ "$EUID" -eq 0 ]; then
        pids=$(fuser "$nvdev" 2>/dev/null || true)
        if [ -n "$pids" ]; then
            has_proc=true
            for pid in $pids; do
                pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
                user=$(ps -p "$pid" -o user= 2>/dev/null || echo "?")
                printf "  %-8s  PID %-6s  %s\n" "$user" "$pid" "$pname"
            done
        fi
    else
        has_proc=true
        yellow "  Run as root to check."
        break
    fi
done
if ! $has_proc; then
    echo "  (none)"
fi
echo ""

# ── DRM connectors (displays) ────────────────────────────────
echo "── Displays Connected to NVIDIA ──"
echo ""
gpu_bdf=$(lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
if [ -n "$gpu_bdf" ] && [ -d "/sys/bus/pci/devices/$gpu_bdf/drm" ]; then
    has_conn=false
    for card in /sys/bus/pci/devices/$gpu_bdf/drm/card*; do
        [ -d "$card" ] || continue
        for conn in "$card"/card*-*/status; do
            [ -f "$conn" ] || continue
            conn_name=$(basename "$(dirname "$conn")")
            status=$(cat "$conn" 2>/dev/null)
            if [ "$status" = "connected" ]; then
                has_conn=true
                mode=$(cat "$(dirname "$conn")/modes" 2>/dev/null | head -1 || echo "?")
                printf "  \e[33m%-10s  %-10s  %s\e[0m\n" "$conn_name" "$status" "$mode"
            else
                printf "  %-10s  %s\n" "$conn_name" "$status"
            fi
        done
    done
    if ! $has_conn; then
        echo "  No displays connected."
    fi
else
    echo "  NVIDIA DRM not available (GPU not on nvidia driver)."
fi
echo ""

# ── Services ─────────────────────────────────────────────────
echo "── NVIDIA Services ──"
echo ""
for svc in nvidia-persistenced.service nvidia-powerd.service; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        printf "  \e[32m%-35s active\e[0m\n" "$svc"
    elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        printf "  \e[33m%-35s enabled but inactive\e[0m\n" "$svc"
    else
        printf "  %-35s not active\n" "$svc"
    fi
done
# ── Kernel cmdline VFIO params ───────────────────────────────
echo "── Kernel Cmdline VFIO Settings ──"
echo ""
grep -oP 'vfio[^ ]*' /proc/cmdline 2>/dev/null | sed 's/^/  /' || echo "  (none)"
echo ""

# ── Verdict ──────────────────────────────────────────────────
echo "── Summary ──"
echo ""
if [ -n "$gpu_bdf" ]; then
    drv=$(readlink "/sys/bus/pci/devices/$gpu_bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    case "$drv" in
        nvidia)
            green "  GPU is bound to nvidia — ready for host use."
            green "  To pass to a VM:    gpu-to-vfio"
            ;;
        vfio-pci)
            green "  GPU is bound to vfio-pci — ready for VM passthrough."
            green "  To return to host:  gpu-to-host"
            ;;
        *)
            yellow "  GPU is on '$drv' — unexpected state."
            ;;
    esac
else
    yellow "  Could not detect GPU state."
fi
echo ""
