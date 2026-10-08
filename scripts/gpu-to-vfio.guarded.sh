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

# ── Resizable BAR sizing ─────────────────────────────────────
# BAR1 on the dGPU is a Resizable BAR, and its SIZE decides the NullMoth
# driver's VRAM budget:
#
#     budget = (fBarLen >= 4 GiB) ? fBarLen / 2 : 192 MB      (nvrm-fb.cpp)
#
# so a small BAR caps the driver at 192 MB no matter how much VRAM the card
# has. Set it as large as the card advertises: 16 GiB gives an 8 GiB budget.
#
# resource1_resize takes a BIT INDEX, not a byte count:
#   0=1MB 1=2MB 2=4MB ... 10=1GiB 11=2GiB 12=4GiB 13=8GiB 14=16GiB
# so the size in bytes is 2^(idx+20).
#
# HISTORY — this used to be 8 (256 MB), with a long comment claiming 256 MB
# was "the value macOS requires" and that a larger BAR made macOS refuse the
# assignment and the driver fail outright. Those measurements were real but
# they were a SYMPTOM, not a requirement: they were taken with the GPU on
# guest bus 0x00, where placeLargeBar1() has no parent bridge to reprogram
# and logs "bar1: parent root port not found", leaving macOS's own (small)
# assignment as the only option.
#
# The fix is to put the GPU BEHIND A PCIE ROOT PORT (guest bus 0x01) and stop
# QEMU advertising ACPI hotplug for PCI bridges:
#
#     -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
#
# Without that property macOS assigns a root-port device no resources at all
# (the root ports advertise zero-size `ranges`). With it, macOS resources the
# card, the driver places its own 16 GiB BAR, and the budget goes 192 MB ->
# 8 GiB. MEASURED: bar1@0x14:0x1000000000+0x400000000, budget 8589934592.
#
# Do not lower this back to 256 MB. A small BAR is not "what macOS requires";
# it is what a VM that cannot present the normal Mac topology is stuck with.
BAR_IDX_VFIO=14   # 16 GiB — maximum this card advertises; gives an 8 GiB budget
BAR_IDX_HOST=14   # 16 GiB — the same; kept separate as they need not match

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
    set_bar1 "$dev" "$BAR_IDX_VFIO" "16 GiB for passthrough"
    echo "vfio-pci" > "/sys/bus/pci/devices/$dev/driver_override" 2>/dev/null || true
    echo "$dev" > /sys/bus/pci/drivers_probe 2>/dev/null || true
}

# ── GPU-holder helpers (used by the force path) ──────────────
# System daemons are tolerated here — they are stopped via systemd later.
IGNORE_PROCS="nvidia-powerd|nvidia-persistenced"

# List live (non-zombie) PIDs holding NVIDIA devices
gpu_holders() {
    local pids=""
    for nvdev in /dev/nvidia*; do
        [ -e "$nvdev" ] || continue
        pids="$pids $(fuser "$nvdev" 2>/dev/null || true)"
    done
    for dev in "${ALL_DEVS[@]}"; do
        pids="$pids $(fuser "/sys/bus/pci/devices/$dev" 2>/dev/null || true)"
    done
    local out=""
    for pid in $pids; do
        pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        if echo "$pname" | grep -qE "$IGNORE_PROCS"; then continue; fi
        state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
        case "$state" in *Z*|*z*) continue;; esac
        out="$out $pid"
    done
    echo "$out"
}

# ── Discover / wake NVIDIA dGPU ──────────────────────────────
ASUS_DGPU_DISABLE=/sys/devices/platform/asus-nb-wmi/dgpu_disable
info "Discovering NVIDIA dGPU..."

GPU_BDF=$(lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
WAS_OFF=false
if [ -z "$GPU_BDF" ]; then
    info "dGPU is off — powering on for VFIO passthrough..."

    # Clear ASUS dgpu_disable if set
    if [ -f "$ASUS_DGPU_DISABLE" ] && grep -q 1 "$ASUS_DGPU_DISABLE" 2>/dev/null; then
        info "Clearing dgpu_disable..."
        tries=0
        while :; do
            if echo 0 > "$ASUS_DGPU_DISABLE" 2>/dev/null; then
                sleep 0.1
                if grep -q 0 "$ASUS_DGPU_DISABLE" 2>/dev/null; then
                    ok "dgpu_disable = 0"
                    break
                fi
            fi
            tries=$((tries + 1))
            [ "$tries" -ge 4 ] && { fail "Could not clear dgpu_disable"; exit 1; }
            sleep 0.5
        done
    fi

    # Power on any slot that was off
    for slot in /sys/bus/pci/slots/*/; do
        [ -e "$slot/power" ] || continue
        power=$(tr -dc '01' < "$slot/power" 2>/dev/null || true)
        if [ "$power" = "0" ]; then
            echo 1 > "$slot/power" 2>/dev/null || true
        fi
    done

    # Rescan PCI bus until GPU appears
    info "Rescanning PCI bus..."
    for _ in $(seq 1 16); do
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
        sleep 0.5
        GPU_BDF=$(lspci -D -d 10DE::0300 2>/dev/null | awk 'NR==1{print $1}')
        [ -n "$GPU_BDF" ] && break
    done
    if [ -z "$GPU_BDF" ]; then
        red "ERROR: dGPU did not appear after power-on."
        exit 1
    fi
    ok "dGPU powered on at $GPU_BDF"
    WAS_OFF=true
fi
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
if ! $WAS_OFF; then

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
HAS_SEAT=false
if command -v loginctl &>/dev/null; then
    if loginctl list-sessions --no-legend 2>/dev/null | grep -v "tty" | grep -q "seat0"; then
        HAS_SEAT=true
    fi
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

fi   # end of $WAS_OFF guard

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
    set_bar1 "$dev" "$BAR_IDX_VFIO" "16 GiB for passthrough"

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
