#!/usr/bin/env bash
# Provision the macOS guest's storage and register the domain with libvirt.
#
#   sudo ./vms/macos/setup-macos.sh
#
# Idempotent: re-running only creates what is missing. The disk is a thin
# qcow2, so the 1 TiB is a ceiling, not an allocation.
set -euo pipefail

# ⚠️ EDIT THESE PATHS. OSX_KVM must point at your clone of OSX-KVM
# (it needs BaseSystem.img and OpenCore/OpenCore.qcow2 inside it).
OSX_KVM="${OSX_KVM:-/path/to/OSX-KVM}"

HERE=$(cd "$(dirname "$0")" && pwd)
DISK=/var/lib/libvirt/images/macos.img
DISK_SIZE=1T
DOMAIN_XML=$HERE/macos.xml

[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo" >&2; exit 1; }

echo "== 1. guest disk"
# Ownership: NixOS renders qemu.conf from verbatimConfig, and a bare
# `namespaces = []` makes libvirt treat the file as non-empty, so it skips its
# dynamic-ownership/managed-save settings and never chowns domain disks. QEMU
# therefore runs as root, and every other disk in this pool is root:root 0600.
# Match that -- do NOT chown to qemu or qemu-libvirtd.
if [ -e "$DISK" ]; then
  echo "   exists: $DISK ($(qemu-img info --output=json "$DISK" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["virtual-size"]//2**40,"TiB virtual,",d["actual-size"]//2**20,"MiB on disk")'))"
else
  echo "   creating $DISK ($DISK_SIZE thin)"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE"
fi
chown root:root "$DISK"
chmod 600 "$DISK"

echo "== 2. installer media"
for f in "$OSX_KVM"/BaseSystem.img "$OSX_KVM"/OpenCore/OpenCore.qcow2; do
  [ -f "$f" ] || { echo "   STOP: missing $f" >&2; exit 1; }
  echo "   ok: $f"
done

echo "== 3. define the domain"
virsh -c qemu:///system define "$DOMAIN_XML"
virsh -c qemu:///system list --all | grep -E 'macos|Name' || true

cat <<'EOF'

Done. Start it from virt-manager, or:

  virsh -c qemu:///system start macos --console

Inside the guest (OpenCore picks the recovery volume after a short pause):
Disk Utility -> erase the 1 TiB "sata" disk as APFS -> install macOS.

EOF
