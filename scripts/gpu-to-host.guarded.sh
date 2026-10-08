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
fail()   { echo -e "\e[31m[FAIL]\e[0m  $*" >&2; }
warn()   { echo -e "\e[33m[WARN]\e[0m  $*" >&2; }

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

SILENT=false
case "${1:-}" in -s) SILENT=true; shift;; esac

# ── Cardwire: pause the GPU manager for the handoff ──────────
# Same as gpu-to-vfio: while cardwired runs, its LSM hides the GPU paths
# this script probes. Resumed by the EXIT trap when the GPU is back on
# nvidia (gpu-on handles the "GPU was powered off" path via exec below).
if systemctl is-active --quiet cardwired.service 2>/dev/null; then
    systemctl stop cardwired.service 2>/dev/null \
        && ok "cardwired paused for GPU handoff" \
        || warn "could not stop cardwired — binding may misbehave"
fi
cardwire_resume() {
    local drv="none"
    if [ -n "${GPU_BDF:-}" ]; then
        drv=$(readlink "/sys/bus/pci/devices/$GPU_BDF/driver" 2>/dev/null | xargs basename 2>/dev/null || echo none)
    fi
    [ "$drv" = "nvidia" ] || return 0
    systemctl is-enabled --quiet cardwired.service 2>/dev/null || return 0
    systemctl is-active --quiet cardwired.service 2>/dev/null && return 0
    systemctl start cardwired.service 2>/dev/null && ok "cardwired resumed"
    return 0
}
trap cardwire_resume EXIT

# ── Discover / wake NVIDIA dGPU ──────────────────────────────
info "Discovering NVIDIA dGPU..."

GPU_BDF=$(lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
if [ -z "$GPU_BDF" ]; then
    info "dGPU is off — running gpu-on to power it on..."
    exec gpu-on
fi
GPU_BUSDEV="${GPU_BDF%.*}"

ALL_DEVS=()
ALL_DRIVERS=()
IOMMU_GROUPS=()
while IFS= read -r line; do
    bdf=$(echo "$line" | awk '{print $1}')
    drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    iommu=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")
    ALL_DEVS+=("$bdf")
    ALL_DRIVERS+=("$drv")
    IOMMU_GROUPS+=("$iommu")
done < <(lspci -D -s "$GPU_BUSDEV".* -d 10DE: 2>/dev/null)

if [ ${#ALL_DEVS[@]} -eq 0 ]; then
    red "ERROR: No NVIDIA functions found on device $GPU_BUSDEV"
    exit 1
fi

# ── Show summary ─────────────────────────────────────────────
echo ""
info "Found ${#ALL_DEVS[@]} NVIDIA device function(s):"
for i in "${!ALL_DEVS[@]}"; do
    desc=$(lspci -s "${ALL_DEVS[$i]}" 2>/dev/null | cut -d' ' -f2-)
    printf "  %-13s  driver: %-10s  iommu_group: %-3s  %s\n" \
        "${ALL_DEVS[$i]}" "${ALL_DRIVERS[$i]}" "${IOMMU_GROUPS[$i]}" "$desc"
done

# ── Check: already all on host drivers? ───────────────────────
all_host=true
for i in "${!ALL_DEVS[@]}"; do
    drv="${ALL_DRIVERS[$i]}"
    dev="${ALL_DEVS[$i]}"
    if [ "$drv" = "vfio-pci" ] || [ "$drv" = "none" ]; then
        # Check if this is the GPU itself — it MUST be on nvidia
        class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null | cut -c3-4 || true)
        if [ "$class" = "03" ]; then
            yellow "GPU function $dev is not on nvidia (driver: $drv)"
            all_host=false
        elif [ "$drv" = "vfio-pci" ]; then
            all_host=false
        fi
    fi
done
if $all_host; then
    if $SILENT; then exit 0; fi
    green ""
    green "All NVIDIA functions are on host drivers (GPU on nvidia)."
    info "Verifying NVIDIA services..."
    systemctl is-active --quiet nvidia-persistenced.service 2>/dev/null \
        || { systemctl start nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced started (was stopped)"; }
    systemctl is-active --quiet nvidia-powerd.service 2>/dev/null \
        || { systemctl start nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd started (was stopped)"; }
    ok "NVIDIA services are running."
    if [ -e /dev/nvidia0 ]; then
        ok "/dev/nvidia0 present"
    fi
    exit 0
fi

# ── Check: VM using the vfio device? ─────────────────────────
info "Checking if a running VM is using this GPU..."
vm_active=false
for iommu in $(printf '%s\n' "${IOMMU_GROUPS[@]}" | sort -u); do
    if [ -e "/dev/vfio/$iommu" ]; then
        if fuser "/dev/vfio/$iommu" >/dev/null 2>&1; then
            vm_active=true
            red "ERROR: IOMMU group $iommu is in use by a running VM!"
            red "  /dev/vfio/$iommu is held by:"
            fuser -v "/dev/vfio/$iommu" 2>&1 | sed 's/^/  /' >&2
        fi
    fi
done
if $vm_active; then
    red ""
    red "Aborting: shut down the VM first, then re-run this script."
    exit 1
fi
ok "No VM is using the GPU."

# ── Ensure nvidia modules are loaded ─────────────────────────
info "Ensuring NVIDIA kernel modules are loaded..."
for mod in nvidia nvidia_modeset nvidia_uvm nvidia_drm; do
    if ! lsmod | grep -q "^$mod "; then
        modprobe "$mod" 2>/dev/null && ok "Loaded module: $mod" || warn "Could not load $mod (will try after binding)"
    else
        ok "Module $mod already loaded"
    fi
done

# ── Resizable BAR sizing (mirror of gpu-to-vfio) ─────────────
# Keep BAR1 as large as the card advertises for passthrough: the NullMoth
# driver's VRAM budget is fBarLen/2, so a big BAR is the point (16 GiB ->
# 8 GiB budget). resource1_resize takes a BIT INDEX:
# 8=256MiB, 12=4GiB, 13=8GiB, 14=16GiB.
#
# HISTORY: this used to be 8 (256 MB), on the belief that macOS would not
# assign a larger Resizable BAR. That was a symptom of the GPU being on bus
# 0x00 where the driver had no parent root port; with the GPU behind a PCIe
# root port and -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off,
# a 16 GiB BAR is assigned and placed by the driver itself.
BAR_IDX_VFIO=14   # 16 GiB — must match gpu-to-vfio; see the note there
BAR_IDX_HOST=14   # 16 GiB — the maximum this card advertises

bar1_bytes() {
    local bdf="$1" vals
    vals=$(sed -n '2p' "/sys/bus/pci/devices/$bdf/resource" 2>/dev/null) || { echo 0; return; }
    # shellcheck disable=SC2086
    set -- $vals
    [ -n "${1:-}" ] && [ -n "${2:-}" ] || { echo 0; return; }
    local n=$(( $2 - $1 + 1 ))
    [ "$n" -gt 0 ] 2>/dev/null && echo "$n" || echo 0
}

# Program BAR1 to bit-index $2. The device MUST be unbound or this is EBUSY.
set_bar1() {
    local dev="$1" idx="$2" want="$3"
    local f="/sys/bus/pci/devices/$dev/resource1_resize"
    [ -e "$f" ] || return 0            # no resizable BAR1 (e.g. audio fn)
    local want_b=$(( 1 << (idx + 20) ))
    local before after
    before=$(bar1_bytes "$dev")
    if [ "$before" = "$want_b" ]; then
        ok "$dev BAR1 already $want ($(( before / 1048576 )) MiB)"
        return 0
    fi
    if ! printf '%d\n' "$idx" > "$f" 2>/dev/null; then
        warn "$dev could not set BAR1 to $want (device must be unbound)"
        return 0
    fi
    after=$(bar1_bytes "$dev")
    ok "$dev BAR1 $(( before / 1048576 )) MiB -> $(( after / 1048576 )) MiB ($want)"
}

# ── Clear driver_override, unbind from vfio-pci, re-probe ────
info "Returning GPU to the nvidia host driver..."

# Remove the PCI IDs that gpu-to-vfio added to vfio-pci's new_id
for dev in "${ALL_DEVS[@]}"; do
    pci_id=$(lspci -ns "$dev" 2>/dev/null | awk '{print $3}')
    if [ -n "$pci_id" ]; then
        echo "$pci_id" | sed 's/:/ /' > /sys/bus/pci/drivers/vfio-pci/remove_id 2>/dev/null || true
    fi
done

for dev in "${ALL_DEVS[@]}"; do
    info "Processing $dev..."

    # Clear driver_override
    echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true

    # Unbind from whatever driver holds it (normally vfio-pci)
    cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
    if [ -n "$cur_drv" ]; then
        echo "$dev" > "/sys/bus/pci/drivers/$cur_drv/unbind" 2>/dev/null || true
        sleep 0.5
    fi

    # Restore BAR1 to the maximum while the device is unbound
    set_bar1 "$dev" "$BAR_IDX_HOST" "max for host"

    # Trigger re-probe
    echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
done

sleep 2

# ── If any device is still unbound, try loading nvidia and re-probe ──
for dev in "${ALL_DEVS[@]}"; do
    cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "$cur_drv" = "none" ]; then
        warn "$dev has no driver. Loading nvidia modules and retrying..."
        modprobe nvidia 2>/dev/null || true
        modprobe nvidia_drm 2>/dev/null || true
        sleep 0.5
        echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    fi
done

sleep 1

# ── Verify ───────────────────────────────────────────────────
echo ""
info "Verifying binding..."
all_ok=true
for dev in "${ALL_DEVS[@]}"; do
    cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null | cut -c3-4 || true)
    if [ "$class" = "03" ]; then
        # GPU function: must be nvidia
        if [ "$cur_drv" = "nvidia" ]; then
            ok "$dev  →  nvidia"
        else
            fail "$dev  →  $cur_drv  (expected nvidia)"
            all_ok=false
        fi
    else
        # Audio/USB/etc: any host driver is fine
        if [ "$cur_drv" != "vfio-pci" ] && [ "$cur_drv" != "none" ]; then
            ok "$dev  →  $cur_drv"
        else
            fail "$dev  →  $cur_drv  (expected host driver)"
            all_ok=false
        fi
    fi
done

# ── Start NVIDIA services ────────────────────────────────────
info "Starting NVIDIA services..."
systemctl start nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced started" || true
systemctl start nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd started" || true

# ── Runtime PM ───────────────────────────────────────────────
for dev in "${ALL_DEVS[@]}"; do
    pm_control="/sys/bus/pci/devices/$dev/power/control"
    if [ -w "$pm_control" ]; then
        echo "auto" > "$pm_control" 2>/dev/null || true
    fi
done

# ── Quick health check ───────────────────────────────────────
echo ""
if [ -e /dev/nvidia0 ]; then
    ok "/dev/nvidia0 exists"
else
    warn "/dev/nvidia0 not found — GPU may need a few seconds to initialize"
fi

if command -v nvidia-smi &>/dev/null; then
    if nvidia-smi -L &>/dev/null 2>&1; then
        ok "nvidia-smi reports GPU visible"
    else
        warn "nvidia-smi could not detect GPU (ignore if X11/Wayland is not running)"
    fi
fi

echo ""
if $all_ok; then
    green "GPU successfully returned to the host nvidia driver."
    yellow "You may need to restart your display manager if you want X11/Wayland to use it:"
    yellow "  sudo systemctl restart display-manager.service"
else
    red "Some devices failed to bind to nvidia. Check dmesg for errors."
    red "You may need to reboot."
    exit 1
fi
