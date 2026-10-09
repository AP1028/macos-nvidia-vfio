#!/usr/bin/env bash
set -euo pipefail

# gpu-to-vfio.guarded.sh — release the GPU from its host driver, size BAR1 for
# the guest, and hand it to vfio-pci, with pre-flight checks.
#
#   sudo ./gpu-to-vfio.guarded.sh [-s]
#
# -s makes it non-interactive: it reports and exits rather than asking.
#
# ⚠️ EDIT THE ADDRESSES BELOW (GPU_BDF / GPU_AUDIO_BDF) before running. This
# script never guesses which GPU you mean, and never powers a laptop dGPU on
# for you — waking one is vendor-specific, so do that first.

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

# ── Resizable BAR sizing ─────────────────────────────────────
# BAR1 on the dGPU is a Resizable BAR. A large one breaks VM passthrough:
# at 8 GiB and above the guest firmware places it on a non-canonical
# address (0x8508000000000000 — a 32-bit base written into the high dword
# of a 64-bit BAR), which QEMU/KVM reject, so the domain either fails to
# start or the guest ends up with no usable aperture. 4 GiB is the largest
# size that still places correctly. Shrink for the VM, restore max for host.
#
# resource1_resize takes a BIT INDEX, not a byte count:
#   0=1MB 1=2MB 2=4MB ... 10=1GiB 11=2GiB 12=4GiB 13=8GiB 14=16GiB
# so the size in bytes is 2^(idx+20).
BAR_IDX_VFIO=12   # 4 GiB — largest size that passes through correctly
BAR_IDX_HOST=14   # 16 GiB — the maximum this card advertises

# BAR1 size in bytes for a BDF (0 if unassigned or no resizable BAR1)
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

# Ensure BAR1 is at the VM size, releasing the device if it is bound.
ensure_bar1_for_vfio() {
    local dev="$1"
    local f="/sys/bus/pci/devices/$dev/resource1_resize"
    [ -e "$f" ] || return 0
    [ "$(bar1_bytes "$dev")" = "$(( 1 << (BAR_IDX_VFIO + 20) ))" ] && return 0
    local drv
    drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo none)
    echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
    if [ "$drv" != "none" ]; then
        echo "$dev" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null || true
        sleep 0.5
    fi
    set_bar1 "$dev" "$BAR_IDX_VFIO" "4 GiB for passthrough"
    echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
}


# ── GPU-holder helpers (used by the force path) ──────────────
# NVIDIA daemons are tolerated here — they are stopped via systemd later.
IGNORE_PROCS="nvidia-powerd|nvidia-persistenced"

# The GPU's DRM nodes. A compositor that has merely *opened* the card — without
# driving any display on it — pins nvidia_drm through /dev/dri/cardN, and no
# service check or /dev/nvidia* scan sees that. Leaving it out is how a handoff
# decides the GPU is free, unbinds it, and then wedges the kernel in rmmod.
#
# Node names come from `ls` and ownership from `readlink`, with no existence
# test: on some systems an LSM answers ENOENT for the passed-through card, so
# `[ -e /dev/dri/card0 ]` and `[ -e /sys/class/drm/card0 ]` both report false
# while `ls` lists them.
gpu_drm_nodes() {
    local node link bdf out=""
    for node in $(ls /sys/class/drm/ 2>/dev/null); do
        case "$node" in
            card[0-9]*|renderD*) ;;
            *) continue;;
        esac
        case "$node" in *-*) continue;; esac          # connector entries
        link=$(readlink -f "/sys/class/drm/$node/device" 2>/dev/null) || continue
        bdf="${link##*/}"
        case "$bdf" in
            "$GPU_BUSDEV"*) out="$out /dev/dri/$node";;
        esac
    done
    echo "${out# }"
}

# List live (non-zombie) PIDs holding NVIDIA devices
gpu_holders() {
    local pids=""
    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        pids="$pids $(fuser "$nvdev" 2>/dev/null || true)"
    done
    # The card itself: through its DRM nodes (a compositor, a game) and through
    # the PCI device. Without the DRM nodes the usual desktop-session holder is
    # invisible here, which is how a handoff unbinds a GPU that is still in use.
    for node in $(gpu_drm_nodes); do
        pids="$pids $(fuser "$node" 2>/dev/null || true)"
    done
    for dev in "${ALL_DEVS[@]}"; do
        pids="$pids $(fuser "/sys/bus/pci/devices/$dev" 2>/dev/null || true)"
    done
    # fuser can report nothing at all when an LSM answers ENOENT on device
    # paths, so the same holders are also collected by walking /proc. The
    # alternation is written out in the case syntax on purpose: `case $x in
    # $pat)` with pat="a|b" is one literal pattern and never matches.
    for p in /proc/[0-9]*; do
        local pid=${p#/proc/}
        [ -d "$p/fd" ] || continue
        for f in "$p"/fd/*; do
            local t
            t=$(readlink "$f" 2>/dev/null) || continue
            case "$t" in
                /dev/nvidia*)
                    pids="$pids $pid"; break;;
                /dev/dri/*)
                    case " $(gpu_drm_nodes) " in
                        *" $t "*) pids="$pids $pid"; break;;
                    esac;;
            esac
        done
    done
    local out=""
    for pid in $pids; do
        pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
        state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
        case "$state" in *Z*|*z*) continue;; esac
        case " $out " in *" $pid "*) continue;; esac
        out="$out $pid"
    done
    echo "$out"
}

# ── GPU address: yours, not a guess ──────────────────────────
# ⚠️ EDIT THESE. The addresses below are DELIBERATELY FAKE (ff:1f.0 is not a
# real device) so a copy-paste fails loudly instead of acting on the wrong GPU.
# Find yours with:  lspci -nn | grep -i -e nvidia -e vga
# It looks like 0000:01:00.0 -> use that. The audio function is .1 on the same
# bus/slot. This script never guesses, and never powers a laptop dGPU on for
# you: waking one is vendor-specific (on ASUS it is dgpu_disable, elsewhere a
# MUX or vendor tool), so do that yourself before running this.
GPU_BDF="${GPU_BDF:-0000:ff:1f.0}"
GPU_AUDIO_BDF="${GPU_AUDIO_BDF:-0000:ff:1f.1}"
info "Checking the configured GPU..."

for dev in "$GPU_BDF" "$GPU_AUDIO_BDF"; do
    [ -e "/sys/bus/pci/devices/$dev" ] && continue
    red "ERROR: $dev does not exist on this machine."
    red "Edit GPU_BDF/GPU_AUDIO_BDF at the top of this script."
    exit 1
done
GPU_BUSDEV="${GPU_BDF%.*}"

# Gather all NVIDIA functions on this device and their drivers
ALL_DEVS=()
ALL_DRIVERS=()
while IFS= read -r line; do
    bdf=$(echo "$line" | awk '{print $1}')
    drv=$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    ALL_DEVS+=("$bdf")
    ALL_DRIVERS+=("$drv")
done < <(lspci -D -s "$GPU_BUSDEV".* -d 10DE: 2>/dev/null)

if [ ${#ALL_DEVS[@]} -eq 0 ]; then
    red "ERROR: No NVIDIA functions found on device $GPU_BUSDEV"
    exit 1
fi

# ── Show summary ─────────────────────────────────────────────
if ! $SILENT; then
echo ""
info "Found ${#ALL_DEVS[@]} NVIDIA device function(s):"
for i in "${!ALL_DEVS[@]}"; do
    desc=$(lspci -s "${ALL_DEVS[$i]}" 2>/dev/null | cut -d' ' -f2-)
    iommu=$(basename "$(readlink "/sys/bus/pci/devices/${ALL_DEVS[$i]}/iommu_group" 2>/dev/null)" 2>/dev/null || echo "?")
    printf "  %-13s  driver: %-10s  iommu_group: %-3s  %s\n" \
        "${ALL_DEVS[$i]}" "${ALL_DRIVERS[$i]}" "$iommu" "$desc"
done
fi

# ── Check: already all on vfio-pci? ──────────────────────────
all_vfio=true
for drv in "${ALL_DRIVERS[@]}"; do
    [ "$drv" != "vfio-pci" ] && all_vfio=false
done
if $all_vfio; then
    # Already bound — but BAR1 may still be at the host size (e.g. after a
    # gpu-to-host that was interrupted), which breaks passthrough. Enforce it.
    for dev in "${ALL_DEVS[@]}"; do
        ensure_bar1_for_vfio "$dev"
    done
    if $SILENT; then exit 0; fi
    green ""
    green "All NVIDIA functions are already bound to vfio-pci."
    exit 0
fi

# ── GPU was off: skip all checks, go straight to binding ────

# ── Check: GPU function on something unexpected? ─────────────
mixed=false
for i in "${!ALL_DEVS[@]}"; do
    dev="${ALL_DEVS[$i]}"
    drv="${ALL_DRIVERS[$i]}"
    # Only the GPU function (class 03) matters for this check
    class=$(cat "/sys/bus/pci/devices/$dev/class" 2>/dev/null | cut -c3-4 || true)
    if [ "$class" = "03" ] && [ "$drv" != "nvidia" ] && [ "$drv" != "vfio-pci" ] && [ "$drv" != "none" ]; then
        warn "GPU function $dev is bound to unexpected driver: $drv"
        mixed=true
    fi
done
if $mixed; then
    yellow "GPU in unexpected state. Continuing anyway..."
fi

# ── Check for displays actively driven by NVIDIA ──────────────
info "Checking for displays actively driven by NVIDIA GPU..."
HAS_DISPLAY=false
if [ -d "/sys/bus/pci/devices/$GPU_BDF/drm" ]; then
    for card in /sys/bus/pci/devices/$GPU_BDF/drm/card*; do
        [ -d "$card" ] || continue
        for conn_dir in "$card"/card*-*; do
            [ -d "$conn_dir" ] || continue
            status=$(cat "$conn_dir/status" 2>/dev/null || echo "unknown")
            [ "$status" != "connected" ] && continue
            # Verify the connector actually drives a display (enabled + modes)
            enabled=$(cat "$conn_dir/enabled" 2>/dev/null || echo "disabled")
            modes=$(cat "$conn_dir/modes" 2>/dev/null | head -1 || true)
            if [ "$enabled" = "enabled" ] && [ -n "$modes" ]; then
                conn_name=$(basename "$conn_dir")
                yellow "Display $conn_name is ACTIVE on the NVIDIA GPU (mode: $modes)"
                HAS_DISPLAY=true
            else
                conn_name=$(basename "$conn_dir")
                info "Connector $conn_name reports connected but is not enabled — skipping"
            fi
        done
    done
fi
$HAS_DISPLAY && $SILENT && { yellow "Display(s) actively driven by NVIDIA GPU"; exit 1; }
$HAS_DISPLAY && ! $SILENT && yellow "Moving the GPU to VFIO will kill active displays immediately."

# ── Check for processes using nvidia devices ─────────────────
info "Checking for processes using NVIDIA devices..."
has_procs=false
for nvdev in /dev/nvidia*; do
    [ -e "$nvdev" ] || continue
    pids=$(fuser "$nvdev" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        shown=false
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
            if ! $shown; then echo ""; yellow "Processes using $nvdev:"; shown=true; fi
            has_procs=true
            echo "  PID $pid  ($pname)"
        done
    fi
done
for dev in "${ALL_DEVS[@]}"; do
    pids=$(fuser "/sys/bus/pci/devices/$dev" 2>/dev/null || true)
    if [ -n "$pids" ]; then
        shown=false
        for pid in $pids; do
            pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
            if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
            if ! $shown; then echo ""; yellow "Processes holding $dev:"; shown=true; fi
            has_procs=true
            echo "  PID $pid  ($pname)"
        done
    fi
done

# ── Check for active graphical sessions ──────────────────────
count_seat_sessions() {
    local s class seat out=""
    for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        class=$(loginctl show-session "$s" -p Class --value 2>/dev/null || true)
        seat=$(loginctl show-session "$s" -p Seat --value 2>/dev/null || true)
        case "$class" in manager|greeter) continue;; esac
        case "$seat" in ""|-|*"("* ) continue;; esac
        case " $out " in *" $s "*) continue;; esac
        out="$out $s"
    done
    echo "$out"
}

HAS_SEAT=false
if command -v loginctl &>/dev/null; then
    [ -n "$(count_seat_sessions)" ] && HAS_SEAT=true
fi

if ! $has_procs && ! $HAS_DISPLAY && ! $HAS_SEAT; then
    $SILENT || ok "No active users, displays, or processes on the NVIDIA GPU."
fi

# ── Blocking: ask user how to proceed ────────────────────────
if $has_procs || $HAS_DISPLAY || $HAS_SEAT; then
    if $SILENT; then
        $has_procs && yellow "Processes holding NVIDIA devices"
        $HAS_DISPLAY && yellow "Display(s) actively driven by NVIDIA GPU"
        $HAS_SEAT && yellow "Active graphical sessions"
        exit 1
    fi
    echo ""
    yellow "──────────────────────────────────────────────────────"
    yellow "  The NVIDIA GPU is currently in use by the host."
    yellow "  Binding it to vfio-pci now will disrupt your desktop."
    yellow "──────────────────────────────────────────────────────"
    echo ""
    echo "  [f] Force  — kill processes & unbind immediately (risky)"
    echo "  [l] Logout — schedule binding; log out, then run gpu-vfio-apply"
    echo "  [c] Cancel — abort"
    echo ""
    read -rp "Choose [f/l/c]: " answer
    case "$answer" in
        [fF])
            warn "Forcing GPU unbind — this may crash your desktop."

            # ── Kill everything holding the GPU (SIGKILL) ──────
            info "Killing processes using the GPU..."
            for nvdev in /dev/nvidia*; do
                [ -e "$nvdev" ] || continue
                fuser -k "$nvdev" 2>/dev/null || true
            done
            for dev in "${ALL_DEVS[@]}"; do
                fuser -k "/sys/bus/pci/devices/$dev" 2>/dev/null || true
            done

            # ── Wait for the GPU to be fully released ───────────
            info "Waiting for processes to release the GPU..."
            waited=0
            escalated=false
            while :; do
                remaining=$(gpu_holders)
                if [ -z "$remaining" ]; then
                    ok "GPU released."
                    break
                fi
                # Grace period, then re-kill any survivors with SIGKILL
                if ! $escalated && [ "$waited" -ge 6 ]; then
                    escalated=true
                    warn "Escalating — SIGKILL to survivors: $remaining"
                    kill -9 $remaining 2>/dev/null || true
                fi
                if [ "$waited" -ge 30 ]; then   # 30 × 0.5s = 15s
                    red "ERROR: processes still hold the GPU after 15s:"
                    for pid in $remaining; do
                        red "  PID $pid  ($(ps -p "$pid" -o comm= 2>/dev/null || echo unknown))"
                    done
                    red ""
                    red "Unbinding now would hang the kernel (nvidia os_delay)."
                    red "Aborting — log out of your desktop and use the [l] Logout path instead."
                    exit 1
                fi
                sleep 0.5
                waited=$((waited + 1))
            done
            ;;
        [lL])
            mkdir -p /etc/gpu-switch
            echo "vfio" > /etc/gpu-switch/pending
            green ""
            green "GPU binding to vfio-pci scheduled for next logout."
            echo ""
            yellow "Steps to complete:"
            yellow "  1. Log out of your desktop session"
            yellow "  2. Press Ctrl+Alt+F2 to switch to a VT"
            yellow "  3. Log in as root"
            yellow "  4. Run:  gpu-vfio-apply"
            echo ""
            exit 0
            ;;
        *)
            red "Aborted."
            exit 1
            ;;
    esac
fi

# ── Stop NVIDIA services ─────────────────────────────────────
info "Stopping NVIDIA services..."
systemctl stop nvidia-persistenced.service 2>/dev/null && ok "nvidia-persistenced stopped" || true
systemctl stop nvidia-powerd.service 2>/dev/null && ok "nvidia-powerd stopped" || true

# ── Remove NVIDIA modules ────────────────────────────────────
info "Unloading NVIDIA kernel modules..."
for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia nvidia_wmi_ec_backlight; do
    if lsmod | grep -q "^$mod "; then
        if rmmod "$mod" 2>/dev/null; then
            ok "Removed module: $mod"
        else
            warn "Could not remove module: $mod (may be in use — force with rmmod -f if needed)"
        fi
    fi
done
sleep 0.5


# ── Bind to vfio-pci ─────────────────────────────────────────
info "Binding NVIDIA functions to vfio-pci..."

# Ensure vfio-pci knows about these devices
for dev in "${ALL_DEVS[@]}"; do
    pci_id=$(lspci -ns "$dev" 2>/dev/null | awk '{print $3}')
    if [ -n "$pci_id" ]; then
        echo "$pci_id" | sed 's/:/ /' > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    fi
done

for dev in "${ALL_DEVS[@]}"; do
    info "Processing $dev..."

    # Release the device FIRST. driver_override must be cleared before the
    # unbind: while it names a driver the kernel re-binds the device
    # immediately, the unbind silently fails, and the BAR resize below then
    # returns EBUSY.
    echo "" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true

    # Unbind from current driver
    cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")
    if [ -n "$cur_drv" ]; then
        # Final safety check: unbinding a busy nvidia driver hangs the kernel
        if [ "$cur_drv" = "nvidia" ]; then
            remaining=$(gpu_holders)
            if [ -n "$remaining" ]; then
                fail "Processes still hold the GPU — aborting to avoid a kernel hang:"
                for pid in $remaining; do
                    fail "  PID $pid  ($(ps -p "$pid" -o comm= 2>/dev/null || echo unknown))"
                done
                fail ""
                fail "Log out of your desktop, then run:  gpu-vfio-apply"
                exit 1
            fi
        fi
        echo "$dev" > "/sys/bus/pci/drivers/$cur_drv/unbind" 2>/dev/null || true
        sleep 0.5
    fi

    # BAR1 must be programmed while the device is unbound
    set_bar1 "$dev" "$BAR_IDX_VFIO" "4 GiB for passthrough"

    # Pin to vfio-pci and probe
    if ! echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null; then
        fail "Could not set driver_override for $dev"
        continue
    fi
    echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
done

sleep 1

# ── Verify ───────────────────────────────────────────────────
echo ""
info "Verifying binding..."
all_ok=true
for dev in "${ALL_DEVS[@]}"; do
    cur_drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "none")
    if [ "$cur_drv" = "vfio-pci" ]; then
        ok "$dev  →  vfio-pci"
    else
        fail "$dev  →  $cur_drv  (expected vfio-pci)"
        all_ok=false
    fi
done

echo ""
if $all_ok; then
    green "All NVIDIA functions successfully bound to vfio-pci."
    green "The GPU is ready for VM passthrough."
    echo ""
    yellow "To return the GPU to the host later, run:  gpu-to-host"
else
    red "Some devices failed to bind. Check dmesg for details."
    exit 1
fi
