#!/usr/bin/env bash
set -euo pipefail

# gpu-to-host.guarded.sh — give the GPU back to its host driver and restore the
# full BAR1, with checks.
#
#   sudo ./gpu-to-host.guarded.sh [-s]
#
# Run this after shutting the VM down.
#
# ⚠️ EDIT THE ADDRESSES BELOW (GPU_BDF / GPU_AUDIO_BDF) before running. This
# script never guesses which GPU you mean.

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


# ── GPU address: yours, not a guess ──────────────────────────
# ⚠️ EDIT THESE. The addresses below are DELIBERATELY FAKE (ff:1f.0 is not a
# real device) so a copy-paste fails loudly instead of acting on the wrong GPU.
# Find yours with:  lspci -nn | grep -i -e nvidia -e vga
# It looks like 0000:01:00.0 -> use that. The audio function is .1 on the same
# bus/slot. This script never guesses, and never powers a laptop dGPU on for
# you: waking one is vendor-specific, so do that yourself before running this.
GPU_BDF="${GPU_BDF:-0000:ff:1f.0}"
GPU_AUDIO_BDF="${GPU_AUDIO_BDF:-0000:ff:1f.1}"
info "Checking the configured GPU..."

if [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
    red "ERROR: $GPU_BDF does not exist on this machine."
    echo "  Edit GPU_BDF/GPU_AUDIO_BDF at the top of this script." >&2
    echo "  If the GPU is powered down on a laptop, enable it with your" >&2
    echo "  vendor's GPU-mode setting first, then re-run." >&2
    exit 1
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
# gpu-to-vfio shrinks BAR1 to 4 GiB because a larger one breaks guest
# passthrough. Restore the maximum here so the host gets the full aperture
# back. resource1_resize takes a BIT INDEX: 12=4GiB, 14=16GiB.
BAR_IDX_VFIO=12   # 4 GiB
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
