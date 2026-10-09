# macOS on KVM with an NVIDIA GPU passed through, running the NullMoth driver

A complete, self-contained guide: from enabling IOMMU in firmware to a macOS 15 guest
where a real NVIDIA GPU drives the display and provides Metal 3.

It is written from a machine where this works end to end. Everything here was measured —
where something is an inference rather than a measurement, it says so.

**Result:** driver-placed **16 GiB BAR**, **8 GiB VRAM budget**, GPU-composited desktop,
Metal 3 for applications.

---

## Contents

- [1. What you need](#1-what-you-need)
- [2. Firmware setup](#2-firmware-setup)
- [3. Host: IOMMU and vfio](#3-host-iommu-and-vfio)
- [4. Binding the GPU to vfio-pci, and hot-swapping it back *(optional)*](#4-binding-the-gpu-to-vfio-pci-and-hot-swapping-it-back-optional)
- [5. Choosing the BAR size](#5-choosing-the-bar-size)
- [6. OSX-KVM: the pieces macOS needs](#6-osx-kvm-the-pieces-macos-needs)
- [7. libvirt: which config, at which stage](#7-libvirt-which-config-at-which-stage)
- [8. Installing macOS](#8-installing-macos)
- [9. Installing the NullMoth driver](#9-installing-the-nullmoth-driver)
- [10. Verification](#10-verification)
- [11. Known bugs and recovery](#11-known-bugs-and-recovery)
- [12. Troubleshooting](#12-troubleshooting)
- [Appendix A. The full domain XML, both stages](#appendix-a-the-full-domain-xml-both-stages)
- [Appendix B. Supporting files in this repo](#appendix-b-supporting-files-in-this-repo)
- [Appendix C. Full source of every script](#appendix-c-full-source-of-every-script)
- [Credits and provenance](#credits-and-provenance)

---

## 1. What you need

### Hardware

| | |
|---|---|
| CPU | Intel with VT-d, or AMD with AMD-Vi (IOMMU). Almost everything since ~2015 has it; firmware support is the variable. |
| GPU | An NVIDIA GPU from the GSP generation (Turing/RTX 20-series or newer). Get its ids with `lspci -nn`; wherever this guide needs them it writes `<vendor>:<device>`, for example `10de:2c59`. Substitute your own. |
| Second GPU | **Strongly recommended.** If the passed-through GPU is your only display adapter, shutting down the VM leaves you with no console. |
| Display | Anything driven by the passed-through GPU's outputs. A monitor on the card's own output is the normal arrangement. |

**Laptop caveat.** On many gaming laptops the discrete GPU is wired to the internal panel
through a **MUX**. If the MUX is set to the iGPU, a passed-through NVIDIA cannot drive the
internal panel and you will see nothing — use an external output, or confirm the panel and
the dGPU share a path, *before* concluding a driver bug. This machine: external monitor on
the card's DP-1.

> **If your GPU has no output you can reach** (a laptop dGPU wired only to the internal
> panel through a MUX, or a card with no connected monitor), you have no way to *see* the
> guest even once the driver works. **It may be possible to install a virtual display
> driver in macOS and then stream the desktop to the host with
> [Moonlight](https://moonlight-stream.org/)**, since the guest would then have a display
> device that does not depend on a physical output. **This is untested here and is stated
> as a possibility, not a recipe** — the driver's relationship to a virtual display device
> is exactly the thing that would need to work, and it is unverified. Do not plan around
> it without testing.

**Verified on:** a laptop with an Intel CPU and a mobile NVIDIA RTX 5080 Max-Q (GB203M),
QEMU 11.1.1 and macOS 15.8.1. Passthrough works on desktop cards too; nothing here depends
on it being a laptop.

### Software

| | |
|---|---|
| Host | Any Linux with libvirt, and **QEMU new enough for the machine type in the configs** (`pc-q35-10.2`, so QEMU 10.2 or a version that maps that alias). Commands here are generic; two paths in the domain XMLs are distribution-specific and are flagged where they appear. |
| Guest | macOS 15 (Sequoia). Earlier releases should work; nothing here is version-pinned. |
| Driver | [nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver). **Read their README first** — it covers the bare-metal case, which this guide assumes. |

---

## 2. Firmware setup

Enter firmware setup and enable, in roughly this order:

| setting | value | why |
|---|---|---|
| **VT-d** / **VT for Directed I/O** (Intel) or **IOMMU** / **AMD-Vi** (AMD) | **Enabled** | Without it there are no IOMMU groups and no passthrough. The single most common omission. |
| **Above 4G Decoding** (if present) | **Enabled** | Lets the firmware hand out addresses above the 4 GiB line, which is where a large BAR has to live. **Many laptops have no such switch** and always decode above 4G; if it is absent, that is not a problem — check section 5 instead. |
| **Resizable BAR** / **Re-Size BAR Support** (if present) | **Enabled** | Required for the BAR sizing in section 5. Some machines ship it on with no way to turn it off, which is the same thing as far as this guide is concerned. |
| **SR-IOV** (if present) | Enabled | Harmless, occasionally needed. |
| **Virtualization** (VT-x / SVM) | Enabled | Obviously. |

Firmware menus differ wildly; on some boards "Above 4G" is under *PCI Subsystem Settings*
and VT-d under *Advanced → System Agent*. An option being absent usually means the firmware
does that thing unconditionally, or exposes no choice about it — plenty of laptops have no
Above 4G and no Resizable BAR switch, and work fine. Check what the card actually advertises
(section 5) before concluding that something is missing. On some boards a BIOS update does
reveal settings the vendor shipped hidden, so it is worth a look if VT-d is the one absent.

> **If the card has no Resizable BAR support, skip section 5 entirely.** Check first, since
> the answer is a property of the card rather than of the board:
>
> ```bash
> cat /sys/bus/pci/devices/$GPU/resource1_resize      # 0 or absent = no Resizable BAR
> ```
>
> Nothing is lost by skipping — the resize would fail with `0 = unsupported`, and
> `scripts/set-bar1.sh` would say the same. What it does cost you is the budget: without a
> resizable BAR1 the window is fixed at whatever the firmware assigned, commonly **256 MiB**
> on cards shipped without ReBAR (`nvidia-smi -q` reports it as `BAR1 Memory Usage`, and
> NVIDIA's own DOCA documentation shows that 256 MiB default). By the formula in section 5 a
> window that size leaves the driver its **192 MB fallback budget**, not the 8 GiB this guide
> is about — enough to boot, not enough for the desktop and Metal 3 results described here.
>
> **This route is not tested.** Every measurement in this guide comes from a card that
> advertises the capability, and the fallback path is read from the driver source rather than
> exercised. Treat the paragraph above as the expected shape of the problem, not as a recipe.

**Then verify from the host** (after booting Linux):

```bash
dmesg | grep -iE "DMAR|IOMMU" | head
# look for: "DMAR: IOMMU enabled" (Intel) / "AMD-Vi: Interrupt remapping enabled" (AMD)
```

If that says *disabled* or *not enabled*, no amount of software configuration will help —
go back to firmware.

---

## 3. Host: IOMMU and vfio

### Kernel parameters

The IOMMU is enabled through the **kernel command line** — the arguments your bootloader
passes to the kernel (see the [Arch Wiki: kernel parameters](https://wiki.archlinux.org/title/Kernel_parameters)
if that is unfamiliar). Enable the IOMMU and use identity mapping for the host, which
avoids needless DMA translation overhead for devices that stay on the host:

```
# Intel
intel_iommu=on iommu=pt

# AMD
amd_iommu=on iommu=pt
```

On NixOS:

```nix
boot.kernelParams = [ "intel_iommu=on" "iommu=pt" ];
```

On most other distributions, add them to the kernel command line in your bootloader.

> **Further reading:** the [Arch Wiki PCI passthrough via OVMF](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF) article is the
> standard reference for everything in this section and the next, and covers cases this
> guide does not (multi-GPU hosts, `iommu=pt` trade-offs, ACS overrides).

**Optional — bind the GPU to vfio-pci at boot.** Add:

```
vfio-pci.ids=<vendor>:<device>,<vendor>:<audio-device>
```

**This is one of the two routes to choose between, and it is the all-or-nothing one.** It
suits a host whose only job is running the guest, or one where a driver claims the card
before you can intervene. If you would rather keep the card usable on the host and hand it
over on demand, leave this out — section 3 sets out both routes properly, including what
each one costs you.

Use your own vendor:device ids. Get them with `lspci -nn`:

```bash
lspci -nn | grep -i -e nvidia -e vga
# 01:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [<vendor>:<device>]
# 01:00.1 Audio device [0403]: NVIDIA Corporation ... [<vendor>:<audio-device>]
```

**Do not add `pcie_acs_override=downstream,multifunction` unless you must.** It exists to
split IOMMU groups so devices can be isolated, but it weakens the isolation guarantee and
is a security trade-off. Check your groups first ([Verify IOMMU groups](#verify-iommu-groups));
most modern boards do not need it.

### Verify IOMMU groups

```bash
for g in $(find /sys/kernel/iommu_groups/* -maxdepth 0 -type d | sort -V); do
  echo "IOMMU Group ${g##*/}:"
  for d in $g/devices/*; do
    echo -e "\t$(lspci -nns ${d##*/})"
  done
done
```

**What you want:** the GPU and its audio function in a group of their own, or sharing only
with a PCIe bridge that you also pass through. If they share with unrelated devices, try a
different PCIe slot, or enable ACS in firmware, before reaching for `pcie_acs_override`.

### Load the vfio modules

```bash
sudo modprobe vfio vfio_iommu_type1 vfio_pci
```

To make it permanent, add `vfio-pci` to `/etc/modules-load.d/` (or NixOS
`boot.kernelModules = [ "vfio_pci" "vfio" "vfio_iommu_type1" ];`).

### Keep the host's NVIDIA driver off the passed-through card

**Choose one of the two routes below, and only one.** They are alternatives, not steps, and
the wrong pick is expensive to undo: blacklisting `nvidia` and binding at boot is simpler
and needs no scripts, but it makes the card permanently unavailable to the host until you
undo it and reboot. Hot-swapping keeps the card usable on the host and passes it to the
guest on demand, at the cost of having to release it first — and of the scripts in
[section 4](#4-binding-the-gpu-to-vfio-pci-and-hot-swapping-it-back-optional), which is why that
section is optional but this material is not.

If the host has an NVIDIA driver installed, make sure it does not grab the card you intend
to pass through.

* **Route A — bind at boot, and give the card up on the host.** Put the ids in the kernel
  command line (this is the `vfio-pci.ids=` parameter from section 2), and blacklist the
  driver so nothing else can claim the card:

  ```
  vfio-pci.ids=<vendor>:<device>,<vendor>:<audio-device>
  ```

  ```
  # /etc/modprobe.d/blacklist-nvidia.conf
  blacklist nvidia
  ```

  **From then on the card belongs to vfio-pci.** Nothing on the host can use it until you
  remove the blacklist and reboot. Simplest possible setup, and the right one if this
  machine exists to run the guest.

* **Route B — hot-swap it when you need it.** Leave both the driver and the card alone at
  boot, then hand the card over at run time with the scripts in section 4, and take it back
  the same way. The card stays usable on the host the rest of the time, which is how this
  guide's machine is set up.

  **Do not blacklist `nvidia` on this route**, and do not add `vfio-pci.ids=`: the swap-back
  path rebinds the card to the host driver, which needs `nvidia` loadable, and a card bound
  to vfio-pci from boot is not yours to hand back. Blacklisting turns a reversible handoff
  into a reboot.

  If you want the driver to lose the card without a blacklist, `softdep nvidia pre: vfio-pci`
  does it (distribution-specific) — but that is a boot-time binding too, so it belongs to
  route A despite not using `blacklist`.

---

## 4. Binding the GPU to vfio-pci, and hot-swapping it back *(optional)*

**This section is the other half of route B in
[section 3](#keep-the-hosts-nvidia-driver-off-the-passed-through-card); skip it if you bound
the card at boot under route A**, since there is then nothing to hand over and nothing to
take back.

This is the part that lets you use the GPU on the host and pass it to the guest without
rebooting. **This repo ships two sets of scripts that do it** — see
[Appendix B](#appendix-b-supporting-files-in-this-repo) — and the logic is explained here
so you can adapt or debug them. If you are happy to give the card up on the host instead,
route A in section 3 avoids all of this and needs no scripts.

### First: find your GPU's address

**Nothing below works until you substitute your own address for the placeholder.** PCI
addresses appear in three different formats in this guide and getting the conversion wrong
is the most common way to end up acting on the wrong device:

```bash
lspci -nn | grep -i -e nvidia -e vga
```

```
01:00.0 VGA compatible controller [0300]: NVIDIA Corporation ... [10de:2c59]
01:00.1 Audio device [0403]: NVIDIA Corporation ... [10de:22e9]
```

| where | format | looks like |
|---|---|---|
| `lspci` output | `bus:slot.function` | `01:00.0` |
| sysfs paths, and the `GPU_BDF` / `GPU_AUDIO_BDF` variables in the scripts | `domain:bus:slot.function` | `0000:ff:1f.0` |
| the domain XML's `<hostdev><source>` | four hex attributes | `domain='0x0000' bus='0xff' slot='0x1f' function='0x0'` |
| the domain XML's guest `<address type='pci'>` | **not the same thing at all** — this is where the device appears *inside* the guest | `bus='0x01' slot='0x00'` |

`lspci -D` prints the long form directly if you would rather not add the `0000:` yourself.
**Both functions of the card must be listed** — the GPU (`.0`) and its audio device
(`.1`) — or the guest sees half a card.

Throughout this guide the placeholder `0000:ff:1f.0` is used. `ff:1f.0` is not a real
device on any machine, so commands left unedited fail loudly instead of touching something
unexpected.

### The rule that breaks naive scripts

**`driver_override` must be cleared *before* you unbind.** While it names a driver, the
kernel re-binds the device immediately, the unbind silently fails, and the BAR resize that
follows then operates on a device that is still in use.

```bash
# ⚠️ SET THESE FIRST. ff:1f is a deliberately fake address: substitute yours from
# the recipe above, or every command below acts on a device that does not exist.
GPU=0000:ff:1f.0
AUDIO=0000:ff:1f.1
G=/sys/bus/pci/devices/$GPU
D=/sys/bus/pci/drivers/vfio-pci

# (1) stop anything using the GPU — see the warning below
# (2) clear driver_override FIRST
echo "" > $G/driver_override
# (3) unbind from the current driver
echo "$GPU" > /sys/bus/pci/drivers/$(basename $(readlink $G/driver))/unbind
# (4) set the BAR size (see section 5)
printf "14\n" > $G/resource1_resize
# (5) claim it
echo "vfio-pci" > $G/driver_override
echo "$GPU" > $D/bind
```

To give it back:

```bash
echo "" > $G/driver_override
echo "$GPU" > $D/unbind
echo "$GPU" > /sys/bus/pci/drivers/nvidia/bind
```

### Or just use the scripts

**Two pairs, and the difference is whether they check first.**

`scripts/gpu-to-vfio.sh` and `scripts/gpu-to-host.sh` are short. They set the address, clear
`driver_override`, unbind, size BAR1, bind, and verify — nothing else. They assume the GPU is
free. If something is using it, they will unbind anyway, and that is the case that can hang
the kernel.

`scripts/gpu-to-vfio.guarded.sh` and `scripts/gpu-to-host.guarded.sh` **check first and refuse
instead.** They stop the NVIDIA services, count everything holding the card — including a
compositor that has merely opened it, which is the usual holder and the one that is easy to
miss — and when the GPU is in use they ask: force it, defer until after your next logout, or
cancel. Verification afterwards is in both pairs. **Use these unless you have a reason not
to**, and read the warning below before using the short ones on a desktop machine.

See [Appendix B](#appendix-b-supporting-files-in-this-repo) for both sets, and **edit the
addresses at the top of whichever you use** — none of them guesses which GPU you mean.

### Warning: unbinding a busy GPU can hang the kernel

If the NVIDIA driver has the GPU open — X/Wayland running on it, a CUDA process, a
monitoring daemon — unbinding it can wedge the machine. Before unbinding, find out who holds
the card:

```bash
# if you have them (not every distribution ships these):
sudo fuser -v /dev/nvidia* 2>/dev/null
sudo lsof /dev/nvidia* 2>/dev/null | head
```

Neither tool is guaranteed to exist, and `fuser` can report nothing when an LSM answers
ENOENT on device paths, so the reliable check is to ask the kernel which processes have the
nodes open. Substitute your GPU's address, since the DRM node numbers are not the PCI ones:

```bash
GPU=0000:01:00.0        # your card, from section 4
nodes="/dev/nvidia*"
for n in $(ls /sys/class/drm/); do
  case "$n" in card[0-9]*|renderD*) ;; *) continue;; esac
  case "$n" in *-*) continue;; esac
  bdf=$(readlink -f "/sys/class/drm/$n/device" 2>/dev/null) || continue
  [ "${bdf##*/}" = "$GPU" ] && nodes="$nodes /dev/dri/$n"
done
echo "this GPU's nodes:$nodes"
for p in /proc/[0-9]*; do
  for f in "$p"/fd/*; do
    t=$(readlink "$f" 2>/dev/null) || continue
    case " $nodes " in *" $t "*) echo "$(basename "$p") $(cat "$p/comm" 2>/dev/null) -> $t";; esac
  done
done | sort -u
```

**Do not stop at `/dev/nvidia*`.** A compositor that has merely *opened* the card holds it
through `/dev/dri/cardN`, pins `nvidia_drm` just as firmly, and appears in none of the
`/dev/nvidia*` output. That is the usual holder on a desktop machine, and missing it is what
turns this warning into the paragraph below.

Stop anything you find, and if the GPU is your desktop's output, log out or switch to a TTY
first. On a single-GPU system this is the hard part; on a two-GPU system the passed-through
card is usually idle and this is trivial.

**When it does hang, it does not recover.** Observed twice here, both times from unbinding
while a process still held the card. The driver's teardown stops part-way and reports it:

```
NVRM: Attempting to remove device 0000:01:00.0 with non-zero usage count!
```

The kernel thread doing the unload (`rmmod`) then sits in uninterruptible sleep — `D` state
in `ps`, unkillable even with `kill -9` — and the module is left half-removed, with a
refcount of `-1`. In that state the GPU accepts no driver at all: the card cannot be bound to
`nvidia` or to `vfio-pci`, so passthrough is over until you reboot. **The stuck thread also
holds the shutdown up**, so a normal `systemctl reboot` or `shutdown` will not complete and
you have to cut the power — hold the power button. Nothing is lost by doing so; the machine
is already past the point where a clean shutdown is possible.

The only guard that works is the one in this section: make sure nothing holds the card
*before* you unbind. Counting holders is what the guarded scripts in section 4 do, and the
reason they refuse rather than proceed.

---

## 5. Choosing the BAR size

Only one QEMU setting matters more: the `ICH9-LPC` argument in
`config/macos-passthrough.xml` (see the comment there). The driver's VRAM budget is derived
from the BAR it places for itself in the guest:

```c
// kexts/NVRM/fb/nvrm-fb.cpp
budget = (fBarLen >= 4GiB) ? fBarLen / 2 : NVRM_VRAM_BAR1_BUDGET;   // 192 MB fallback
```

So **a guest BAR under 4 GiB caps you at 192 MB of VRAM budget** no matter how much the card
has, and a 16 GiB guest BAR gives an 8 GiB budget. Note which BAR that is: what you set from
the host, in this section, is a different one — and it is *smaller*, for a reason the next
subsection explains.

### `resource1_resize` takes a bit index, not a byte count

| bit index | size | | bit index | size |
|---|---|---|---|---|
| 8 | 256 MB | | 13 | 8 GiB |
| 11 | 2 GiB | | 14 | 16 GiB |
| **12** | **4 GiB** | | | |

```bash
echo 12 > /sys/bus/pci/devices/$GPU/resource1_resize   # 4 GiB
```

The card only accepts sizes it advertises. Read what yours offers:

```bash
cat /sys/bus/pci/devices/$GPU/resource1_resize   # 0 = unsupported
# -1 means "unsupported" too, in some kernels
lspci -vv -s "${GPU#0000:}" | grep -A2 "Resizable BAR"
```

**If that reports unsupported, there is nothing to size and you can skip this section** — but
read the note in section 2 first, because what you are left with is a much smaller VRAM
budget, and that path is untested here.

### What size to pick

**Set the host-side window to 4 GiB (bit 12). Do not use the largest size the card
advertises, even though it is tempting and the budget formula below rewards it.**

Two different BARs are in play, and this is the distinction the rest of the section turns on:

| | sized by | size | why |
|---|---|---|---|
| **host window**, before the VM starts | you, via `resource1_resize` | **4 GiB** | the guest firmware has to be able to *place* it |
| **guest BAR**, once macOS is up | the NullMoth driver | 16 GiB, or the card's maximum | the driver places its own, and macOS is free to put it high |

A larger host window breaks passthrough. At 8 GiB and above, the guest firmware places the
BAR on a **non-canonical address** — a 32-bit base written into the high dword of a 64-bit
BAR, observed here as `0x8508000000000000` — and QEMU/KVM reject it, so the domain either
fails to start or the guest comes up with no usable aperture. 4 GiB is the largest size that
still places correctly. The card advertises 16 GiB; that is what the driver uses once it is
running, not what you should write here.

**The budget still works out**, which is what makes the small host window easy to argue with:
the driver's 16 GiB guest BAR gives `fBarLen / 2` = **8 GiB**, the result this guide is about.
The 192 MB fallback applies to a *guest* BAR under 4 GiB, which is not what this setting
controls.

The cost of the smaller host window is a smaller aperture while the guest is placing its own
BAR, and that has not been a problem in practice here. It is also the one part of this setup
that is a firmware interaction rather than a driver one, so a machine that places 8 GiB
happily may exist; nothing here was measured above 4 GiB.

Verify after setting it:

```bash
python3 -c "l=open('/sys/bus/pci/devices/$GPU/resource').readlines(); \
a=int(l[1].split()[0],16); b=int(l[1].split()[1],16); print((b-a+1)/2**30,'GiB')"
```

**The BAR size must be set while the VM is off.** The guest driver reads the capability at
startup; changing it under a running guest does nothing useful.

**This is the host-side setting only**, as the table above says. OpenCore's `ResizeGpuBars`
must leave that BAR alone rather than size it a second time — section 9 gives its value.

`scripts/set-bar1.sh` does this. **It takes the size as an argument and will not run without
one** — pass bytes, a `GiB`/`MiB` suffix, or a bit index: `sudo scripts/set-bar1.sh 4GiB`. The
`gpu-to-vfio` scripts default to bit 12 for the same reason.

---

## 6. OSX-KVM: the pieces macOS needs

[OSX-KVM](https://github.com/kholia/OSX-KVM) provides two of the pieces a macOS guest needs:
a bootloader with the Apple-specific fixups (**OpenCore**), and Apple's recovery image.

```bash
git clone https://github.com/kholia/OSX-KVM.git
cd OSX-KVM

# Apple's recovery image (~700 MB) into BaseSystem.img
./fetch-macOS-v2.py            # choose a recent release
dmg2img BaseSystem.dmg BaseSystem.img

# OpenCore is already in the repo, or build/download the latest release
ls OpenCore/OpenCore.qcow2
```

**That is all this guide takes from OSX-KVM**: the OpenCore image and Apple's recovery media.
It does not use OSX-KVM's `OpenCore-Boot.sh`, which is a plain-QEMU invocation, and this
guide drives QEMU through libvirt instead. You do not need to read it. Be aware that the
setting which makes the GPU work is present there but **commented out**, so it is missing
from that script's invocation rather than configured by it; the working value is set in
`config/macos-passthrough.xml` and explained under `ICH9-LPC` in Appendix A.

### What OpenCore is doing for you

* **AppleSMC** — `-device isa-applesmc,osk=<key>`; macOS refuses to boot without it.

  **The key is not in this repository, and you have to supply your own.** The OSK is the
  64-byte key stored in the SMC of genuine Apple hardware. It is Apple's property, and
  redistributing it is what gets macOS-passthrough repositories taken down — which is why
  the domain XMLs here ship `osk=REPLACE_WITH_YOUR_OWN_OSK`.

  **How to get it.** It is not a secret, only legally encumbered, so any established
  macOS-on-QEMU project documents it: look at OSX-KVM's own repository and README, or
  search for "AppleSMC osk". It can also be read from genuine Apple hardware. **Do not
  commit it to a public repository** — keep it in your local copy of the domain XML, which
  is where this guide expects it.

  > **A placeholder `osk` boots macOS and gives you no display.** macOS starts, serves SSH,
  > loads its kexts and reports a correctly placed BAR1 — and never initialises a display.
  > The cursor on the black screen is your viewer's. `screencapture` fails with "could not
  > create image from display 0", `system_profiler` lists no display, and `virsh screenshot`
  > returns a black frame. Nothing in the guest log points at the SMC key, and the failure
  > survives an FLR, a GPU reset, a WindowServer restart and every `<video>` model — the
  > fault is upstream of the driver, so **no amount of driver debugging will find it.** The
  > `REPLACE_WITH_YOUR_OWN_OSK` placeholder is not a key that nearly works: a domain XML
  > redacted for sharing boots this far and no further. See section 12.
* **SMBIOS** — a plausible Mac model. `iMac19,1` is a common choice for a desktop GPU.
* **Board-id / serial** — in the OpenCore config.
* **Kexts** — Lilu, VirtualSMC, WhateverGreen and friends for a VM.
* **boot-args** — passed through to the kernel.

The OpenCore ESP lives *inside* `OpenCore.qcow2` (partition 1). To edit its config you must
mount that image:

```bash
sudo modprobe nbd max_part=16
sudo qemu-nbd --fork --connect=/dev/nbd1 OpenCore/OpenCore.qcow2
sudo mount /dev/nbd1p1 /mnt
$EDITOR /mnt/EFI/OC/config.plist
sync; sudo umount /mnt; sudo qemu-nbd --disconnect /dev/nbd1
```

> **Tooling trap:** `qemu-nbd --disconnect` while the filesystem is still mounted leaves a
> **stale mount**, and every later read/write fails with `Errno 5` while `qemu-img check`
> still reports the image as clean. This is how an OpenCore config gets corrupted. Always
> `umount` first, then `sync`, then disconnect — and prefer `--fork`.

---

## 7. libvirt: which config, at which stage

Two domain definitions, one per phase. Both are in `config/` in this repo.

### Stage 1 — `config/macos-install.xml` (installing macOS)

* **No PCI passthrough.** The GPU is not passed through yet.
* **`<video><model type='vmvga' heads='1' primary='yes'/></video>`** plus SPICE — you need
  a display to run the installer, and SPICE gives you keyboard and mouse.
* Everything else (memory, vCPU, OVMF, OpenCore disk, network) as in stage 2.

### Stage 2 — `config/macos-passthrough.xml` (the working configuration)

Differences from stage 1:

* **The GPU and its audio function are passed through**, and the GPU is placed **behind a
  PCIe root port** — guest bus `0x01`, not `0x00`.
* **`<video><model type='none'/></video>`** — the emulated GPU is removed so the NVIDIA is
  the only display device.
* **USB hostdevs for keyboard and mouse** — because with `video=none` the SPICE console has
  no display and cannot deliver input. Note the host **loses** those devices while the VM
  holds them.
* **`<qemu:commandline>`** carries the CPU string, `isa-applesmc`, `-smbios`, and the
  critical `ICH9-LPC` property.

> ### ⚠️ Both configs must be edited to work
>
> Three things, in both files:
>
> 1. **The `osk`.** They ship `osk=REPLACE_WITH_YOUR_OWN_OSK`, which is not a key and will not
>    boot a display — see the note in section 6 for what it is, why it is not in the repo,
>    and how to get one. **Edit this one first**, because its failure looks like a driver
>    problem rather than a missing key: macOS starts, serves SSH, loads the kexts, places
>    BAR1 correctly, and never initialises a display.
> 2. **The GPU address.** A **deliberately fake** `0xff:1f.0`, so that a copy-paste fails
>    loudly instead of quietly attaching the wrong device. The comment above it tells you
>    how to substitute yours.
> 3. **The disk and firmware paths.** They are from the machine this was written on — point
>    them at your own images, and at your distribution's OVMF files.
>
> **Both 1 and 3 must be edited before the domain is worth starting.** It is not a clean
> failure either way: with a fake address libvirt starts the domain and attaches nothing,
> and with the placeholder `osk` the guest comes up without a display.

Switch between them with:

```bash
virsh -c qemu:///system destroy macos            # stop it
virsh -c qemu:///system define config/macos-passthrough.xml
virsh -c qemu:///system start macos
```

**Switching to stage 2 is not just a `define`.** The domain expects the host to have been
prepared first — the GPU already bound to `vfio-pci`, and its BAR1 already sized — because
the guest reads the BAR at boot and cannot be given it later.

**On route A the card is already bound to `vfio-pci` from boot**, so only the BAR sizing is
left; skip the `gpu-to-vfio` lines below and run `scripts/set-bar1.sh` instead, while the
domain is off. **On route B**, hand the card over first:

`gpu-to-vfio.sh` takes the BAR size as a **bit index, not a byte count**; `scripts/set-bar1.sh`
is the one that accepts `16GiB`:

```bash
sudo scripts/gpu-to-vfio.sh 12       # bit index 12 = 4 GiB for passthrough (section 4-5)
virsh -c qemu:///system destroy macos
virsh -c qemu:///system define config/macos-passthrough.xml
virsh -c qemu:///system start macos
```

**Going back to stage 1** is the same in reverse — `destroy`, `define
config/macos-install.xml`, `start` — and **on route B** you must also run
`sudo scripts/gpu-to-host.sh` first, to return the GPU to the host driver, since stage 1
passes nothing through. On route A the card stays with `vfio-pci` and there is nothing to
hand back.

### Notes that save time

* **`<video>` and the root-port placement are not cosmetic.** Getting either wrong
  produces a guest that boots to a black screen or an Apple logo with no progress.
* **libvirt silently drops attributes it does not understand.** `hotplug='off'` on a
  root-port `<controller>` is one of them — it never reaches QEMU, which is why it is not in
  the shipped config. **Verify at QEMU, not in the XML:** the comment on the `ICH9-LPC`
  argument in Appendix A explains why it matters and how to confirm it arrived.
* **The `<qemu:commandline>` block is load-bearing.** If it disappears, macOS hangs at the
  Apple logo with zero CPU.

---

## 8. Installing macOS

Using **stage 1** (`config/macos-install.xml`):

**Create the guest disk before you start the domain — the command is step 1 below.** libvirt
will refuse to start a domain whose disk image is missing.

```bash
virsh -c qemu:///system define config/macos-install.xml
virsh -c qemu:///system start macos --console
```

**Step 1 is a host command; the rest happen in the SPICE window** (`virt-manager`, or
`virt-viewer -c qemu:///system macos`):

1. **Create the guest disk.** Nothing in the domain XML creates it. `scripts/setup-macos.sh`
   creates it (`/var/lib/libvirt/images/macos.img`, 1 TiB thin) and registers a domain — run
   it once before the first boot:

   ```bash
   sudo scripts/setup-macos.sh                      # creates the disk, defines stage 1
   ```
2. **OpenCore picker** → choose the macOS installer entry.
3. **Disk Utility** → *View → Show All Devices* → select the large SATA disk → **Erase** as
   **APFS**, GUID partition scheme.
4. Quit Disk Utility → **Install macOS** → pick the erased disk.
5. The installer reboots several times; OpenCore auto-selects the installer, then the
   installed volume. Let it run — the first stage alone takes 20-40 minutes.
6. Create your user account at the end.

**If the screen goes black and nothing happens:** this is usually the OpenCore picker
having no display, or the install media not being found. Give it a couple of minutes — the
installer is slow to draw its first frame.

**Getting files in and out** is easiest over SSH:

```bash
# in the guest, enable it
sudo systemsetup -setremotelogin on
ssh-copy-id you@<guest-ip>
```

Then keep the guest on a fixed address (a libvirt DHCP reservation, or a static IP).

### After the install

1. Set the guest's boot-args. In OpenCore's `config.plist`, under
   `NVRAM → Add → 7C436110-AB2A-4BBB-A880-FE41995C9F82 → boot-args`:

   ```
   keepsyms=1 nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth
   amfi_get_out_of_my_way=0x1 amfi=0x80 debug=0x8 serial=1
   ```

   `debug=0x8 serial=1` sends the kernel log to COM1. With `video=none`, that is **the only
   channel for driver messages.** See section 10.

2. Set `SecureBootModel` to `Disabled` and `csr-active-config` as the driver's README
   requires. Do this **before the stage-2 boot** — the driver install runs there and cannot
   run with SIP on:

   > **SIP must be off before the driver installer runs.** With SIP on, `install.sh` stops
   > at "back up kernel collection / Operation not permitted", which reads as a corrupt
   > package or a bad download — it is neither. The kernel collection carries the SIP
   > `restricted` flag, and root cannot read it with SIP on. Set `csr-active-config` in
   > OpenCore, reboot, confirm `csrutil status` says `disabled`, and only then install. See
   > section 9.

3. Shut down the guest, switch the domain to **stage 2** (section 7), and boot with the GPU
   passed through.

---

## 9. Installing the NullMoth driver

Follow the driver's own README for the package install; this section covers only what
differs in a VM.

**The tar package and 1401.app are NOT equivalent, and this is the single most important
thing in this section.** 1401.app wraps two scripts. `install.sh` — the 129-line script in
`nullmoth-nvidia-*.tar.gz` — installs the files and rebuilds the kernel collection. That is
half the job. `nullmoth-setup.sh` — **639 lines, only in 1401.app, which the tar does not
contain at all** — is the other half, and it:

* edits the OpenCore config — `boot-args`, `csr-active-config`, and the
  `com.apple.iokit.IONDRVSupport` entry in `Kernel.Block` (a function exists purely to find
  and manage that index)
* installs `com.nullmoth.crashcheck.plist` and `com.nullmoth.recover.plist` into
  `/Library/LaunchAgents` and `/Library/LaunchDaemons`
* resolves which ESP actually booted by reading OpenCore's own `boot-path` NVRAM variable
  instead of guessing
* runs display bring-up diagnostics against `debug.nvaccel_heads_published`,
  `debug.nvaccelfb`, `debug.nvrmfb_agdc` and `debug.nvaccel_iop`

**A tar-only install therefore produces exactly this symptom: all four kexts load, BAR1 is
placed at 16 GiB, the budget is the correct 8 GiB, frames are generated — and the desktop
never appears.** Nothing configured OpenCore and nothing published the display heads. If you
install without 1401.app, you must run `nullmoth-setup.sh` as well; it is inside the
release's `1401-Mac-*.zip`, at `1401.app/Contents/Resources/`, and it requires root and the
package path as an argument.

**Two ways through this section. Pick by what your display does — not by preference.**

| what you see | what to do |
|---|---|
| macOS reaches a **login window** on the passed-through card | Use **1401.app**. It is the vendor's own installer and it does the whole job: the driver, the OpenCore config, the `Kernel → Block` entry, the display-head publication. Download `1401-Mac-*.dmg` from the driver's releases, run it in the guest, reboot. |
| macOS **boots but shows nothing** — a cursor on black, a frozen Apple logo, or `screencapture` failing with *"could not create image from display 0"* | Do **not** reach for the tar first. Work through the four checks below in order; the usual cause is the OSK or a dirty GPU, not the driver. If those are clean and it still will not display, install from the tar and run `nullmoth-setup.sh` from the 1401 zip — that is the half `install.sh` does not do. |

**Before you install, check four things.** The installer writes kernel collections and
loads unsigned kexts, so it fails in ways that look like package corruption when the real
cause is one of these. Run all four first:

```bash
csrutil status                                          # MUST say: disabled
nvram -p | grep csr-active-config                       # MUST be present, not %00%00%00%00
lspci -nnk -s 01:00.0 | grep -i "driver in use"         # MUST be vfio-pci
python3 -c "l=open('/sys/bus/pci/devices/0000:01:00.0/resource').readlines(); a=int(l[1].split()[0],16); b=int(l[1].split()[1],16); print('BAR1 %d GiB' % ((b-a+1)/2**30))"
```

| check | must be | if it is not |
|---|---|---|
| `csrutil status` | `disabled` | `csr-active-config` is unset in OpenCore, or you have not rebooted since setting it. **With SIP on, root cannot read a `restricted` kernel collection**, so the installer's backup step fails — and reports it as a backup error, not as SIP. |
| `csr-active-config` | a real value; `<430A0000>` is the tested one | set it in `NVRAM → Add → 7C436110-…`, reboot, re-check before installing |
| host BAR1 | at least 4 GiB | size it while the domain is off (section 5) |
| `driver in use` | `vfio-pci` | bind it first (section 4) |

**Boot the driver-phase OpenCore config before you run the installer**, even though there
is no driver yet. The installer-phase and driver-phase configs differ in exactly the
settings the driver needs — `csr-active-config`, `ResizeAppleGpuBars`, and the IONDRVSupport
block — so an install attempted from the installer-phase config cannot succeed.

> **Install against a freshly reset GPU.** A guest reboot does not reset the physical card:
> with vfio the guest driver programs the real GPU. Booting macOS several times in one
> session leaves the passed-through card in a state that silently prevents
> `applyModeSetConfig` from running at all — the same frames-generated, dark-panel pair, with
> nothing pointing at the cause. This is prevention, not recovery: section 11 is what clears
> a session that has already gone wrong. Reset on the host before that boot — the scripts
> default to the right BAR size, so no bit index is needed:

```bash
sudo scripts/gpu-to-host.sh          # unbind vfio
echo 1 | sudo tee /sys/bus/pci/devices/0000:01:00.0/reset
sudo scripts/gpu-to-vfio.sh          # rebind and re-size (defaults to 4 GiB, section 5)
```

**Run `nullmoth-setup.sh` as the app does**, from a directory containing the audited
`install.sh` the app ships beside it (the tar's own copy is at `pkgroot/install.sh`), with
every input it demands:

```bash
sudo ./nullmoth-setup.sh \
  --pkg  /path/to/nullmoth-nvidia-<ver>.tar.gz \
  --sha  <its published sha256> \
  --tool /path/to/NullMothSafe.efi \
  --app  /path/to/1401.app/Contents/MacOS/1401
```

It refuses to run on a loose copy: `--tool` is required, and it insists the audited
installer sits beside it. Both come from `1401.app/Contents/Resources/` in the release zip.

**The settings the driver needs.**

* **Driver package**: 1.0.9 — the version shipped in the 1401-Mac releases, latest 1.0.14.
  Install it with 1401.app, or from the package directly.
* **`/Library/GPUBundles/nvmtl/nvrm610.conf` — leave it at the shipped values.** They are
  correct once BAR1 is large. **The installer rewrites this file on every install**, so
  check it afterwards.
* **boot-args**: exactly as in section 8.
* **OpenCore**: **`ResizeGpuBars=-1`**, `ResizeAppleGpuBars=-1`, `DevirtualiseMmio=False`.

  **`Kernel → Block com.apple.iokit.IONDRVSupport` is NOT needed here**, contrary to the
  driver's README. That block exists so the firmware framebuffer cannot take display index 0
  from NVRMFB, and with `<video>=none` the guest has no firmware framebuffer at all. The
  README's requirement applies to bare metal, where you cannot remove it. **In a working
  configuration there is no IONDRVSupport block, and NVRMFB owns index 0.**

  **`-1` is deliberate, and is where this differs from the driver's README, which says
  `13`.** The host sets BAR1 to 16 GiB before the domain starts (section 5), so OpenCore
  must leave that BAR alone rather than resizing it underneath. It also pays: the budget is
  `fBarLen / 2`, so 16 GiB gives **8 GiB against the README's 4**.

  **1401.app writes this value itself when it installs the driver** — "switches OpenCore
  from the installer's small GPU BAR to the full 8 GB one", i.e. `13`. **Set it back to
  `-1`** to keep the larger budget, or leave `13` and accept 4 GiB. Do not leave the host
  BAR at 16 GiB while OpenCore resizes to 8.

**What you should see.** Before the driver is installed, macOS drives the passed-through
card with its own fallback framebuffer: the external display shows the Apple logo, a
progress bar, then a login window, but the picture can be a static frame. After the driver
loads, the display is driven by the driver. **A cursor you can move with no desktop behind
it is section 11.1, not a failed install** — the kexts are loaded and the display binding is
stale. The remedy is `sudo killall -9 WindowServer` over SSH, which works with no console at
all.

**Updating an existing install.** Same script, same inputs — it detects the running driver
and updates in place, with its own backups (`config.plist.nullmoth-<timestamp>` on the ESP,
`/Library/NullMoth/backup-<timestamp>` for the driver):

```bash
sudo ./nullmoth-setup.sh \
  --pkg ~/Downloads/nullmoth-nvidia-<new>.tar.gz \
  --sha <published sha256> \
  --tool ~/NullMothSafe.efi \
  --app  ~/1401-bin \
  --efi  disk0s1
```

**`--efi` is usually necessary.** The script confirms which partition OpenCore started from
by reading OpenCore's `boot-path` NVRAM variable; **when that variable is empty it stops
with "OpenCore's startup partition could not be confirmed"** even after finding and naming
the right candidate. `disk0s1` is the small EFI partition from `diskutil list`.

**And make sure the guest can see the ESP.** An extra disk in the domain shifts the disk
numbering: a recovery medium left attached as `sdc` with its own `boot order` makes the
OpenCore partition invisible to `diskutil`, and the updater reports it as *"no OpenCore
config for this Mac on any connected disk"* — pointing at OpenCore rather than at the extra
disk. The domain should present exactly two:

```
sda   the macOS disk
sdb   the OpenCore ESP
```

If `virsh domblklist` shows more, the running domain is not the one in this repo:
`virsh undefine --nvram` and define it again.

> **Do not enable `NVMTL_HWPOOL=1`.** It installs private pool classes and correlates with
> a kernel panic.

---

## 10. Verification

Run these in the guest after the driver loads. **The first check is the decisive one:
`nvrm-autogo` reads `up` only once the driver's second bring-up pass has claimed the GPU** —
before that, macOS's own fallback framebuffer is still driving the card (section 9).

```bash
# the driver reached pass 2 and claimed the GPU
ioreg -l -w0 | grep '"nvrm-autogo"'                 # -> "up"

# all four kexts loaded
kmutil showloaded | grep -c nullmoth                # -> 4

# a display exists and is being driven
ioreg -rc IODisplay -w0 | grep -c -- "+-o "         # -> 1

# THE NUMBER THAT MATTERS — the VRAM budget
sysctl -n debug.nvrmfb_vram_budget_bytes            # -> 8589934592  (8 GiB)

# the BAR the driver placed for itself
ioreg -l -w0 | grep '"nvrm-bars"'
#   bar1@0x14:0x1000000000+0x400000000          <- 16 GiB
```

The driver's log should read:

```
bar1: Resizable BAR capability @0x134 says BAR1 = 16384 MB (sizes supported mask 0x4000)
bar1: host bridge 64-bit window 0x1000000000-0x17ffffffff (ACPI _CRS), CPU reaches 40 bits
bar1: placing BAR1 16384 MB @0x1000000000, BAR3 32 MB @0x1400000000 ... PLACED
```

**`PLACED` means the driver did the BAR placement itself.**

### Reading the driver's log

The driver logs with `kprintf`, which does **not** reach the unified log. With `<video>=none`
there is no emulated console, so the serial port is the only channel. Reading it requires
`debug=0x8 serial=1` in the guest boot-args. The example config writes the guest's COM1
to a file:

```xml
<serial type='file'>
  <source path='/tmp/macos-serial.log' append='off'/>
  <target type='isa-serial' port='0'><model name='isa-serial'/></target>
</serial>
```

```bash
strings /tmp/macos-serial.log | grep -aE "NVRM-xnu|NVAccel|NVRM-fb|bar1:"
```

### Reference performance

`tools/bench.sh`, 18 s autonomous drag:

```
flips 2438   WindowServer 16.43 s -> 6.74 ms/flip
grants +2   parks +0   refusals +0
compositor flips: 2436 -> 135.3 fps
```

**Watch `parks` and `refusals`, not the fps headline.** Continuous-drag fps varies
91-140 fps between runs on identical configuration; parks, refusals and ms/flip are stable.

**And note what continuous-drag fps misses.** The session above reported its best-ever
figures *while window switching was failing*. See the park leak in section 11.2.

---

## 11. Known bugs and recovery

Driver-side defects, current as of driver 1.0.9. None is fixable by configuration: the
kexts cannot be built from public sources, so they have to be fixed upstream.

### 11.1 A display-mode transition wedges the display — breaks the session

**The one that matters.** After a fullscreen app runs, or any display-mode transition, the
panel alternates between live content and a dead client's last frame — or freezes with
only the cursor moving.

| event | result |
|---|---|
| game in exclusive fullscreen | steady flash: splash ↔ game frame |
| switched to borderless, vsync Single | bursty flash: game frame ↔ desktop |
| left alone | flash partner degraded to a dark screen |
| **WindowServer restart** | **stable — flash gone** |
| borderless → fullscreen | **wedged again** |

**Workaround: run games windowed/borderless.** That avoids the trigger entirely — verified
across a long session.

**What it is not.** The wedge is **not** the flip path (`iop_flips 16766`, `iop_ok 16863`,
`iop_fail 0`, `iop_flip_stale 0`), **not** the composite (`screencapture` returns a correct,
stable desktop while the panel alternates), **not** async flip recycling, and **not** a
late-published framebuffer. The mechanism is that the composite source changes underneath
a running WindowServer, which keeps presenting to a surface bound before the change.

### 11.2 Park leak — window-switch drag lag

`kexts/NVRM/fb/nvrm-fb.cpp:1261`:

```c
SInt64 before = OSAddAtomic64(want, &gVramMappedBytes) + gVramParkedBytes;
if (before + want > budget) { ...refuse... }
```

`gParkedForever[24]` holds console/scanout-overlapping allocations and **never releases
them**; their bytes are charged against every later grant. Measured: **8-16 VRAM refusals
per window switch**, climbing, while `mapped` is 120 MB of an 8 GiB budget.

Symptom: continuous dragging is fine; the **first drag after switching windows** stalls.
A guest reboot clears it (the parked bytes are in-kernel state); running a game
accelerates it.

### 11.3 Shader translation is the bottleneck

`libnvmtl_translate.dylib` (Metal → SPIR-V) dominates: **2338 of ~2500 samples in
`nvmtl_translate`** vs 85 in `Render` during gameplay. Entering a game world stalls for
several seconds while pipelines compile, then recovers — slow, not broken.

### 11.4 Upscalers produce a wrong image

With `MetalFX` or `DLSS` enabled, games render a partially formed image: they render at
reduced internal resolution and expect the upscaler to reconstruct it, which the
translation layer does not implement. **Turn MetalFX, DLSS, Reflex and dynamic resolution
scaling off**; render at native resolution with TAA or no AA.

### 11.5 `screencapture` cannot see a game's output

Games present through the driver's zero-copy direct scanout, bypassing the WindowServer
composite, so `screencapture` returns only the desktop even with the game frontmost. Use
the game's own screenshot function.

### 11.6 Resolution changes are destructive

Only the native resolution and refresh are published — **no lower refresh rate** is
offered. Changing resolution wedges the display and can panic the kernel. Treat it as
destructive.

### Recovery

Cheapest first. Steps 1 and 2 are the wedge remedies; step 3 is for the park leak
(section 11.2).

| # | step | effect |
|---|---|---|
| 1 | **`sudo killall -9 WindowServer`**, then log in | **Verified.** Re-binds the scanout. ~30 s, logs out. Keeps the VM and the BAR. |
| 2 | **Host FLR**: unbind vfio-pci, `echo 1 > .../reset`, rebind, restart VM | **Verified.** Clears the display wedge. Costs a VM restart. |
| 3 | Guest reboot | Clears the parked bytes, but **does not** clear a scanout wedge. |

**Guest reboots do not clear a display wedge** — with vfio, the guest driver programs the
*physical* GPU, and a guest reboot never resets it. That is why step 1 or 2 is needed.

If the display wakes but the WindowServer's CPU time sits frozen, that is the wedge, not a
sleep state — go to step 1.

---

## 12. Troubleshooting

### A placeholder OSK boots but gives no display

**Check the OSK first: a wrong or placeholder `osk` gives you a macOS that boots, serves SSH,
loads the driver and reports `bar1: PLACED` — with no display.**

Inside the guest it looks almost healthy: WindowServer runs, `kmutil showloaded` shows all
four kexts, the driver places BAR1 correctly, and `applyModeSetConfig` succeeds. What it will
not do is initialise the display. The symptoms are worth recognising because they point
everywhere except the cause:

| what you see | what it actually means |
|---|---|
| `screencapture` fails with **"could not create image from display 0"** | macOS has no display at all |
| `system_profiler SPDisplaysDataType` lists no display | same |
| the external monitor shows a cursor you can move, on a black screen | the viewer's cursor, not the guest's |
| the QEMU console shows a frozen Apple logo and progress bar | the last frame the guest ever sent |
| `virsh screenshot` returns a black 1280x800 PNG | QEMU is fine; the guest is drawing nothing |

**This is not a driver problem, and no amount of driver debugging will find it.** It also
survives an FLR, a fresh GPU reset, a WindowServer restart, and every combination of
`<video>` model — because the fault is upstream of all of them.

Substitute a real OSK (section 6) and the same image, ESP and domain boot straight to a login
window. Until you do, a domain XML redacted for sharing boots exactly this far and no
further — which is why the placeholder is worth ruling out before anything else.

### If the display wedges

**What does not work:**

* Metal shader-cache clear.
* `killall Dock`.
* Wallpaper change.
* Display sleep/wake.
* `debug.nvaccelfb=3`.
* `debug.nvaccel_iop_async=0`.
* `nvrmctl` — it only exposes `go`, `good`, and `state`.

None of these clears a wedge. To clear one, use the recovery ladder in section 11 — cheapest
first.

### Tooling traps

* **Verify at the consumer, never at the writer.** A setting that is silently dropped and a
  setting that does not work look identical from where you wrote it, and every silent-drop
  incident in this setup had this shape.
* `qemu-nbd --disconnect` with a filesystem mounted leaves a **stale mount**; later I/O
  fails with `Errno 5` while `qemu-img check` reports the image clean. `umount` first.
* `pkill -f` patterns can match your own shell, because the pattern is in your own command
  line too. Check the matches with `pgrep -f` and kill by PID, or bracket a character
  (`[n]vrmctl`) so the pattern cannot match itself.
* HMP parses the `pmemsave` filename as an expression — quote it.
* macOS 15's `/usr/bin/python3` has no `Quartz`/`AppKit`, so `CGWindowListCopyWindowInfo`
  raises `ModuleNotFoundError` and looks like "no window".
* macOS ships no `timeout`, `setpci`, `lspci`, or `/usr/include`. Scripts that assume them
  fail on the guest, so the guest-side tooling in this repo is written around their absence.
* `sshd`-driven `ps aux` renders paths in **uppercase**; use `grep -i`.

---

## Appendix A. The full domain XML, both stages

Everything is inline here so this file is self-contained. The same content is also in
`config/` for direct use.

**Both files must be edited before use** — every emulator, loader, NVRAM and disk path is the
author's, and the passthrough file's GPU address is deliberately fake. Appendix B has the
full list.

### A.1 — `config/macos-passthrough.xml` (the working configuration)

Both GPU functions are passed through at guest bus `0x01` (behind a PCIe root port),
`<video>` is `none`, and the `ICH9-LPC` argument at the end is the fix. Its comment
explains why it is needed and how to verify it reached QEMU.

```xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>macos</name>
  <uuid>9b5b38a2-6667-4962-b89f-5ed53a52e499</uuid>
  <title>macOS (OpenCore)</title>
  <description>
    macOS guest for the NullMoth NVIDIA driver work, with an NVIDIA GPU and its
    audio function passed through. EDIT THE ADDRESSES: they are deliberately fake
    so this fails loudly rather than attaching the wrong device. The GPU sits
    behind a PCIe root port at guest bus 0x01, the host BAR1 is sized large before
    the domain starts, and the passed-through card drives the display: there is
    no emulated GPU at all (video is type='none'). The guest serial port writes
    to a file so the driver's kprintf trace can be captured from the host. For
    the pre-passthrough installer configuration see macos-install.xml; for the
    full write-up see the README in this repository.
  </description>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://apple.com/macos"/>
    </libosinfo:libosinfo>
  </metadata>

  <!-- 33554432 KiB = 32 GiB (larger than OSX-KVM's 4096 MiB default, deliberate). -->
  <memory unit='KiB'>33554432</memory>
  <currentMemory unit='KiB'>33554432</currentMemory>
  <!-- No <memoryBacking><locked/></memoryBacking>: it was here before and only
       raised the host commit; OSX-KVM does not lock the guest's RAM. -->
  <!-- 12 vCPUs, static placement, with no <topology> element: the socket/core/
       thread layout is deliberately left at libvirt's default. The CPU *model*
       is not set here either: it comes from the raw -cpu argument in
       <qemu:commandline> at the bottom of this file, which mirrors
       OpenCore-Boot.sh line 37 verbatim. libvirt cannot express that string
       (kvm=on and vmware-cpuid-freq=on have no XML equivalent), so libvirt must
       not emit a -cpu of its own. -->
  <vcpu placement='static'>12</vcpu>

  <os>
    <type arch='x86_64' machine='pc-q35-10.2'>hvm</type>
    <loader readonly='yes' type='pflash'>/run/libvirt/nix-ovmf/edk2-x86_64-code.fd</loader>
    <nvram template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'>/var/lib/libvirt/qemu/nvram/macos_VARS.fd</nvram>
    <!-- No <boot dev='hd'/> here: libvirt forbids os/boot together with the
         per-device <boot order> elements below, and the per-device order is
         what actually puts OpenCore first. -->
    <bootmenu enable='no'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>

  <!-- No libvirt <cpu> element, on purpose. The complete CPU model is passed
       verbatim to QEMU as a raw argument in <qemu:commandline> below, copied
       from OSX-KVM's OpenCore-Boot.sh line 37:

           -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,
                vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,
                +xsave,+xsaveopt,check

       libvirt has no XML for kvm=on or vmware-cpuid-freq=on, so it cannot
       express that string; if a cpu element were present libvirt would emit
       its own -cpu and the two would fight. The 12 vCPUs come from the <vcpu>
       element above. -->

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>

  <devices>
    <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>

    <controller type='pci' index='0' model='pcie-root'/>
    <!-- The GPU is passed through BEHIND THIS ROOT PORT: index 1 is the root
         port at 00:02.0, which is guest bus 0x01, and the two hostdevs at the
         bottom of this file sit on bus 0x01 slot 0x00 function 0x0/0x1.

         Putting the card behind a root port (rather than on the root complex
         at bus 0x00) only works in combination with the
         ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off argument in
         <qemu:commandline>: without that property macOS never resources a
         device behind a bridge. See that argument for the full explanation.

         The remaining root ports (indices 2-5) are declared and currently
         unused. -->
    <controller type='pci' index='1' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='1' port='0x10'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0' multifunction='on'/>
    </controller>
    <controller type='pci' index='2' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='2' port='0x11'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x1'/>
    </controller>
    <controller type='pci' index='3' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='3' port='0x12'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x2'/>
    </controller>
    <controller type='pci' index='4' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='4' port='0x13'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x3'/>
    </controller>
    <controller type='pci' index='5' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='5' port='0x14'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x4'/>
    </controller>

    <!-- macOS installs onto SATA/IDE most reliably; AHCI like OSX-KVM. -->
    <controller type='sata' index='0'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
    </controller>

    <!-- Boot order: OpenCore first (it chainloads the macOS volume itself),
         then the target disk. Without this OpenCore lands unordered and OVMF
         boots the disk with the lowest index, then drops to its built-in UEFI
         shell. -->
    <!-- 1 TiB thin volume: the virtual size only, qcow2 grows with guest writes. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback' discard='unmap'/>
      <source file='/var/lib/libvirt/images/macos.img'/>
      <target dev='sda' bus='sata'/>
      <boot order='2'/>
    </disk>

    <!-- OpenCore bootloader: does the AppleSMC/board-id work the guest needs. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='/path/to/OSX-KVM/OpenCore/OpenCore.qcow2'/>
      <target dev='sdb' bus='sata'/>
      <boot order='1'/>
    </disk>

    <!-- The macOS recovery media (BaseSystem.img) was attached here as sdc.
         It is DETACHED now that macOS is installed: it was the "macOS Base
         System" entry in the OpenCore picker. The image is untouched at
         /path/to/OSX-KVM/BaseSystem.img if it is ever needed again
         (re-add as a raw disk on bus='sata' and give it a boot order). -->

    <!-- NIC: vmxnet3 ON BUS 0x00.

         Model: vmxnet3, which has a native driver in macOS
         (AppleVmxnet3Ethernet.kext, inside IONetworkingFamily). virtio-net is
         NOT a substitute: macOS x86 has no native driver for non-transitional
         virtio, which is why model='virtio' gives no network here.

         Bus 0 is here for the "built-in" flag, not for enumeration. OSX-KVM's
         macOS-libvirt-Catalina.xml makes the same point in its comment: "Make
         sure you put your nic in bus 0x0 and slot 0x0y(y is numeric), this
         will make nic built-in and apple-store work". Bus 0 also gets the
         device flagged built-in, which iCloud/App Store sign-in wants.

         A device behind a PCIe root port is only usable because of the
                  ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off argument at the
         bottom of this file switches off. The GPU now sits behind a root port
         (bus 0x01) and is resourced correctly, so the NIC could move; it stays
         on bus 0x00 for the built-in flag.

         Slot 0x03 is used because the root bus is otherwise full: 0x02.0-0x02.4
         are pcie-root-ports, 0x1f.2 is the SATA controller, 0x07.0-0x07.7 are
         the USB controllers the SSDT requires, and 0x00 is q35's host bridge. -->
    <interface type='network'>
      <mac address='52:54:00:15:0c:0a'/>
      <source network='default'/>
      <model type='vmxnet3'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>

    <!-- USB, wired exactly as OSX-KVM's own shipped macOS-libvirt-Catalina.xml
         does. This is load-bearing and not cosmetic.

         OpenCore/EFI/OC/ACPI/SSDT-EHCI.aml declares an ACPI table "QEMUUSB"
         that binds the USB controllers to FIXED PCI addresses (verified by
         disassembling the shipped .aml with iasl):
             EH01  _ADR = 0x00070007   slot 7 function 7   (USB2.0 EHCI)
             UHC1  _ADR = 0x00070000   slot 7 function 0
             UHC2  _ADR = 0x00070001   slot 7 function 1
             UHC3  _ADR = 0x00070002   slot 7 function 2
         macOS only attaches HID through controllers at those addresses. When
         the addresses do not match, the kernel reports
             ACPI Exception: AE_NOT_FOUND, (SSDT: QEMUUSB) while loading table
         and the guest boots with NO keyboard and NO mouse, while the OpenCore
         picker still accepts input (that is firmware, not XNU). That was this
         VM's "boots but no input" bug.

         A previous revision used a single qemu-xhci controller at pci 0x2.0,
         matching OpenCore-Boot.sh's -device qemu-xhci line. That script is the
         OUTDATED path: it never places a controller at 00:07.x, so the SSDT's
         table finds nothing. The shipped libvirt XML is the reference, and it
         places ich9-ehci1/uhci1/uhci2/uhci3 on slot 0x07 as a multifunction
         group, which is exactly what the SSDT describes.

         Do not "simplify" this back to a single xHCI controller, and do not
         change these slot/function numbers: both break guest input. If the
         SSDT is ever regenerated (trinitronx's write-up recompiles it with
         iasl and picks different addresses), these addresses must be changed
         in lockstep with it. -->
    <!-- USB 3 (XHCI) controller. macOS 15 has no UHCI driver, so the
         ich9-uhci* companions below never get driven and any full/low-speed
         passed-through device is invisible (the emulated QEMU keyboard works
         only because it is high-speed on the EHCI). XHCI handles all speeds
         with no companion controller, so passed-through devices go here.
         Note: USBPorts.kext in the OpenCore ESP matches ACPI names
         EH01/UHC1-3, which this guest's ACPI does not declare, so that map
         matches nothing. -->
    <controller type='usb' index='1' model='qemu-xhci'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>
    </controller>

    <controller type='usb' index='0' model='ich9-ehci1'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x7'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci1'>
      <master startport='0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x0' multifunction='on'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci2'>
      <master startport='2'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x1'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci3'>
      <master startport='4'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x2'/>
    </controller>
    <input type='keyboard' bus='usb'/>
    <input type='tablet' bus='usb'/>

    <!-- Host USB keyboard passed through (JZ-2.4G wireless, 3151:4011).
         Needed because <video> is type='none', so the SPICE console has no
         display and cannot deliver keystrokes. This gives the guest a real
         keyboard for the OpenCore picker.
         NOTE: the HOST loses this keyboard while the VM holds it; the laptop's
         built-in PS/2 keyboard is unaffected (PS/2 cannot be passed through).
         Remove this hostdev (or `virsh detach-device`) to give it back. -->
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x3151'/>
        <product id='0x4011'/>
      </source>
      <address type='usb' bus='1' port='1'/>
    </hostdev>
    <!-- Logitech G502 SE HERO gaming mouse -->
    <hostdev mode='subsystem' type='usb' managed='yes'>
      <source>
        <vendor id='0x046d'/>
        <product id='0xc08b'/>
      </source>
      <address type='usb' bus='1' port='2'/>
    </hostdev>
    <graphics type='spice' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <!-- NO EMULATED GPU, on purpose. The passed-through NVIDIA drives the
         display, so it is the only display device in the guest and NVRMFB can
         own display index 0. This is required, not a preference: with an
         emulated GPU present the guest ends up with zero IOFramebuffer/
         IODisplay instances once the NullMoth driver loads and the screen
         freezes on the boot frame, and the emulated GPU also competed with
         NVRMFB for display index 0, which is what the driver's Kernel->Block
         of IONDRVSupport is meant to prevent.

         Consequences: the SPICE console has no display, so guest input comes
         from the two USB hostdevs above, and the serial log below is the other
         window into the guest. SSH is unaffected either way.

         The pre-passthrough configuration (macos-install.xml) uses
         <model type='vmvga' heads='1' primary='yes'/> here instead, so the
         installer is visible on the SPICE console. -->
    <video>
      <model type='none'/>
    </video>

    <sound model='ich9'/>
    <audio id='1' type='spice'/>

    <!-- Guest serial port, DELIBERATELY type='file'. The NullMoth driver logs
         with kprintf, which never reaches the unified log, so QEMU writes the
         guest's COM1 to a file that can be read from the host without guest
         sudo. Requires debug=0x8 serial=1 in the guest boot-args. This is the
         intended configuration for driver-log capture, not a temporary state. -->
    <serial type='file'>
      <source path='/tmp/macos-serial.log' append='off'/>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>

    <!-- The NVIDIA GPU, passed through for the NullMoth driver.

         BEHIND A PCIE ROOT PORT: guest bus 0x01, slot 0x00, function 0x0 for
         the GPU and function 0x1 for its audio function: the
         pcie-root-port declared at controller index 1 above.

         This arrangement depends on the
         ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off argument in
         <qemu:commandline> at the bottom of this file. macOS enumerates PCIe
         through ACPI (IOPCIHPType = 0x21), and while QEMU advertises ACPI
         hotplug for the bridges macOS defers enumeration of everything behind a
         root port to runtime, which never happens: the card then shows up as

         The host BAR1 is sized to 16 GiB before the domain starts
         (resource1_resize, bit index 14; see the README and gpu-to-vfio), and a
         16 GiB BAR1 passes through correctly in this configuration.

         Both functions are matched by host address, and managed='yes' lets
         libvirt bind vfio itself (the card is already on vfio-pci anyway).
         There is deliberately NO <rom bar='off'/>: macOS needs the native
         option ROM here. -->
    <!-- ============================================================
         EDIT THIS. 0xff:1f.0 below is a DELIBERATELY FAKE address: it is not
         a real device on any machine, so the domain will fail to start until
         you replace it with YOUR GPU's host address.

         Find it with:   lspci -nn | grep -i -e nvidia -e vga
         It looks like:  0000:01:00.0  ->  bus='0x01' slot='0x00' function='0x0'
         (format: bus:slot.function, hex; the 0000: prefix is the domain)

         Both functions must point at the SAME card: function 0 is the GPU,
         function 1 is its HDMI/DP audio. Get the audio address from the same
         lspci output (usually the next line, .1).
         ============================================================ -->
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <driver name='vfio'/>
      <source>
        <address domain='0x0000' bus='0xff' slot='0x1f' function='0x0'/>
      </source>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x0' multifunction='on'/>
    </hostdev>
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <driver name='vfio'/>
      <source>
        <!-- EDIT THIS TOO: your GPU's audio function (same bus/slot, function 1). -->
        <address domain='0x0000' bus='0xff' slot='0x1f' function='0x1'/>
      </source>
      <address type='pci' domain='0x0000' bus='0x01' slot='0x00' function='0x1'/>
    </hostdev>
    <memballoon model='none'/>
  </devices>

  <qemu:commandline>
    <!-- The CPU model, from OSX-KVM's OpenCore-Boot.sh line 37:
             -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,
                  +invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,
                  +aes,+xsave,+xsaveopt,check
         Nothing in this file sets a libvirt cpu element, so this is the only
         -cpu QEMU receives. The Penryn line (their pre-Sequoia one) wedges
         this guest with every vCPU spinning; -hle/-rtm disable TSX. -->
    <qemu:arg value='-cpu'/>
    <qemu:arg value='Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'/>
    <!-- AppleSMC: OpenCore needs it to expose the SMC keys macOS reads, and
         macOS refuses to boot without it.

         The osk below is a PLACEHOLDER. The real one is the 64-byte key held in
         the SMC of genuine Apple hardware. It is Apple's property, which is why
         this file does not carry it: redistributing it is what gets
         macOS-passthrough repositories taken down.

         Supply your own. See "OSX-KVM: the pieces macOS needs" in the README
         for how. Until you do, the domain will start but macOS will not boot. -->
    <qemu:arg value='-device'/>
    <qemu:arg value='isa-applesmc,osk=REPLACE_WITH_YOUR_OWN_OSK'/>
    <!-- Board identity macOS accepts with a discrete GPU (the model the
         NullMoth driver was tested on). -->
    <qemu:arg value='-smbios'/>
    <qemu:arg value='type=2'/>
    <!-- ============================================================
         THE KEY FIX. If you take one thing from this file, take this property.
         ============================================================

         Bridge-level ACPI hotplug OFF.

         WHY, in one paragraph: with this property ON (QEMU's default) the PCIe
         root ports advertise ZERO-SIZE `ranges` : all three window descriptors
         (32-bit MMIO, 64-bit prefetchable, I/O) report a size of 0. macOS reads
         those windows from firmware and believes them, so it assigns the device
         behind the port no address space at all. The card is visible in PCI
         config space : macOS reads its vendor/device id and bus/device/function
         : but gets no BAR, no interrupt (IRQ 0) and no IORegistry node, so the
         driver never attaches. Turning this property off makes the root ports
         advertise real windows, macOS resources the device normally, and the
         driver's placeLargeBar1() finally has the parent bridge it requires to
         place a large BAR itself.

         Linux is unaffected either way : it ignores `ranges` and programs the
         bridge's window registers directly. That asymmetry is what proved the
         fault was macOS-side rather than QEMU's: on identical QEMU config, Linux
         gave the same card behind the same root port IRQ 11 and every BAR,
         including one above 4G.

         Full details, the measurements, and everything that does NOT work are in
         the README (section: the critical QEMU setting).

         VERIFY IT REACHED QEMU. libvirt silently drops attributes it does not
         understand, and a dropped setting is indistinguishable from one that
         does not work. After starting the domain:

             P=$(pgrep -f "guest=macos" | head -1)
             tr '\0' '\n' < /proc/$P/cmdline | grep -c acpi-pci-hotplug-with-bridge-support

         That must print 1 or more. If it prints 0, this property did not reach
         QEMU and nothing downstream will work.

         OSX-KVM carries exactly this line (OpenCore-Boot.sh:47) commented out.
         This bridge-level switch is what governs the ACPI hotplug slots QEMU
         emits, and therefore what sets macOS's IOPCIHPType. -->
    <qemu:arg value='-global'/>
    <qemu:arg value='ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off'/>
  </qemu:commandline>
</domain>
```

### A.2 — `config/macos-install.xml` (stage 1: installing macOS)

Identical except: no PCI hostdevs, no USB hostdevs, an emulated GPU so the installer is
visible on the SPICE console, and the **recovery media attached as `sdc`** — without that
last one this file cannot install anything.

```xml
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>macos</name>
  <uuid>9b5b38a2-6667-4962-b89f-5ed53a52e499</uuid>
  <title>macOS (OpenCore)</title>
  <description>
    macOS guest for the NullMoth NVIDIA driver work, in its INSTALLER phase:
    this is the configuration to run macOS Setup with, before any GPU is passed
    through. It boots on QEMU's emulated VGA (vmvga), which the SPICE console
    displays, so the installer is visible and the console also supplies
    keyboard and mouse input. There are no PCI hostdevs and no USB hostdevs
    here. See macos-passthrough.xml for the working passthrough configuration,
    and the README in this repository for the full write-up.
  </description>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://apple.com/macos"/>
    </libosinfo:libosinfo>
  </metadata>

  <!-- 33554432 KiB = 32 GiB (larger than OSX-KVM's 4096 MiB default, deliberate). -->
  <memory unit='KiB'>33554432</memory>
  <currentMemory unit='KiB'>33554432</currentMemory>
  <!-- No <memoryBacking><locked/></memoryBacking>: it was here before and only
       raised the host commit; OSX-KVM does not lock the guest's RAM. -->
  <!-- 12 vCPUs, static placement, with no <topology> element: the socket/core/
       thread layout is deliberately left at libvirt's default. The CPU *model*
       is not set here either: it comes from the raw -cpu argument in
       <qemu:commandline> at the bottom of this file, which mirrors
       OpenCore-Boot.sh line 37 verbatim. libvirt cannot express that string
       (kvm=on and vmware-cpuid-freq=on have no XML equivalent), so libvirt must
       not emit a -cpu of its own. -->
  <vcpu placement='static'>12</vcpu>

  <os>
    <type arch='x86_64' machine='pc-q35-10.2'>hvm</type>
    <loader readonly='yes' type='pflash'>/run/libvirt/nix-ovmf/edk2-x86_64-code.fd</loader>
    <nvram template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'>/var/lib/libvirt/qemu/nvram/macos_VARS.fd</nvram>
    <!-- No <boot dev='hd'/> here: libvirt forbids os/boot together with the
         per-device <boot order> elements below, and the per-device order is
         what actually puts OpenCore first. -->
    <bootmenu enable='no'/>
  </os>

  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>

  <!-- No libvirt <cpu> element, on purpose. The complete CPU model is passed
       verbatim to QEMU as a raw argument in <qemu:commandline> below, copied
       from OSX-KVM's OpenCore-Boot.sh line 37:

           -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,
                vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,
                +xsave,+xsaveopt,check

       libvirt has no XML for kvm=on or vmware-cpuid-freq=on, so it cannot
       express that string; if a cpu element were present libvirt would emit
       its own -cpu and the two would fight. The 12 vCPUs come from the <vcpu>
       element above. -->

  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>

  <devices>
    <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>

    <controller type='pci' index='0' model='pcie-root'/>
    <!-- The GPU is passed through BEHIND THIS ROOT PORT in macos-passthrough.xml:
         index 1 is the root port at 00:02.0, which is guest bus 0x01, and the
         two hostdevs there sit on bus 0x01 slot 0x00 function 0x0/0x1. That
         only works in combination with the
         ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off argument in
         <qemu:commandline>, which is explained there.

         Nothing is attached to any of these root ports during installation, so
         they are inert here; they are kept so that this file differs from
         macos-passthrough.xml as little as possible. -->
    <controller type='pci' index='1' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='1' port='0x10'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x0' multifunction='on'/>
    </controller>
    <controller type='pci' index='2' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='2' port='0x11'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x1'/>
    </controller>
    <controller type='pci' index='3' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='3' port='0x12'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x2'/>
    </controller>
    <controller type='pci' index='4' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='4' port='0x13'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x3'/>
    </controller>
    <controller type='pci' index='5' model='pcie-root-port'>
      <model name='pcie-root-port'/>
      <target chassis='5' port='0x14'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x02' function='0x4'/>
    </controller>

    <!-- macOS installs onto SATA/IDE most reliably; AHCI like OSX-KVM. -->
    <controller type='sata' index='0'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x1f' function='0x2'/>
    </controller>

    <!-- Boot order: OpenCore first (it chainloads the macOS volume itself),
         then the target disk. Without this OpenCore lands unordered and OVMF
         boots the disk with the lowest index, then drops to its built-in UEFI
         shell. -->
    <!-- 1 TiB thin volume: the virtual size only, qcow2 grows with guest writes. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback' discard='unmap'/>
      <source file='/var/lib/libvirt/images/macos.img'/>
      <target dev='sda' bus='sata'/>
      <boot order='2'/>
    </disk>

    <!-- OpenCore bootloader: does the AppleSMC/board-id work the guest needs. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='writeback'/>
      <source file='/path/to/OSX-KVM/OpenCore/OpenCore.qcow2'/>
      <target dev='sdb' bus='sata'/>
      <boot order='1'/>
    </disk>

    <!-- macOS recovery media. This file is the INSTALL-PHASE configuration, so
         the recovery image is attached: it appears as the "macOS Base System"
         entry in the OpenCore picker, and it is what macOS Setup installs from.

         Raw, not qcow2 : the image is used as-is. Boot order 3 puts it after
         OpenCore (1) and the target disk (2), so OpenCore loads first and the
         picker decides. The installer writes to sda; this image is only read.

         The passthrough configuration does NOT attach it, since by then macOS is
         installed and boots from sda. Re-add it there if you ever need to
         reinstall. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='writeback'/>
      <source file='/path/to/OSX-KVM/BaseSystem.img'/>
      <target dev='sdc' bus='sata'/>
      <boot order='3'/>
    </disk>

    <!-- NIC: vmxnet3 ON BUS 0x00.

         Model: vmxnet3, which has a native driver in macOS
         (AppleVmxnet3Ethernet.kext, inside IONetworkingFamily). virtio-net is
         NOT a substitute: macOS x86 has no native driver for non-transitional
         virtio, which is why model='virtio' gives no network here.

         Bus 0 is here for the "built-in" flag, not for enumeration. OSX-KVM's
         macOS-libvirt-Catalina.xml makes the same point in its comment: "Make
         sure you put your nic in bus 0x0 and slot 0x0y(y is numeric), this
         will make nic built-in and apple-store work". Bus 0 also gets the
         device flagged built-in, which iCloud/App Store sign-in wants.

         A device behind a PCIe root port is only usable because of the
                  ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off argument at the
         bottom of this file switches off. In macos-passthrough.xml the GPU
         sits behind a root port (bus 0x01) and is resourced correctly, so the
         NIC could move; it stays on bus 0x00 for the built-in flag.

         Slot 0x03 is used because the root bus is otherwise full: 0x02.0-0x02.4
         are pcie-root-ports, 0x1f.2 is the SATA controller, 0x07.0-0x07.7 are
         the USB controllers the SSDT requires, and 0x00 is q35's host bridge. -->
    <interface type='network'>
      <mac address='52:54:00:15:0c:0a'/>
      <source network='default'/>
      <model type='vmxnet3'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x03' function='0x0'/>
    </interface>

    <!-- USB, wired exactly as OSX-KVM's own shipped macOS-libvirt-Catalina.xml
         does. This is load-bearing and not cosmetic.

         OpenCore/EFI/OC/ACPI/SSDT-EHCI.aml declares an ACPI table "QEMUUSB"
         that binds the USB controllers to FIXED PCI addresses (verified by
         disassembling the shipped .aml with iasl):
             EH01  _ADR = 0x00070007   slot 7 function 7   (USB2.0 EHCI)
             UHC1  _ADR = 0x00070000   slot 7 function 0
             UHC2  _ADR = 0x00070001   slot 7 function 1
             UHC3  _ADR = 0x00070002   slot 7 function 2
         macOS only attaches HID through controllers at those addresses. When
         the addresses do not match, the kernel reports
             ACPI Exception: AE_NOT_FOUND, (SSDT: QEMUUSB) while loading table
         and the guest boots with NO keyboard and NO mouse, while the OpenCore
         picker still accepts input (that is firmware, not XNU). That was this
         VM's "boots but no input" bug.

         A previous revision used a single qemu-xhci controller at pci 0x2.0,
         matching OpenCore-Boot.sh's -device qemu-xhci line. That script is the
         OUTDATED path: it never places a controller at 00:07.x, so the SSDT's
         table finds nothing. The shipped libvirt XML is the reference, and it
         places ich9-ehci1/uhci1/uhci2/uhci3 on slot 0x07 as a multifunction
         group, which is exactly what the SSDT describes.

         Do not "simplify" this back to a single xHCI controller, and do not
         change these slot/function numbers: both break guest input. If the
         SSDT is ever regenerated (trinitronx's write-up recompiles it with
         iasl and picks different addresses), these addresses must be changed
         in lockstep with it. -->
    <!-- USB 3 (XHCI) controller. macOS 15 has no UHCI driver, so the
         ich9-uhci* companions below never get driven and any full/low-speed
         passed-through device is invisible (the emulated QEMU keyboard works
         only because it is high-speed on the EHCI). XHCI handles all speeds
         with no companion controller; in macos-passthrough.xml the two
         passed-through USB devices attach to it. It is kept, empty, here so
         that the two configurations differ as little as possible.
         Note: USBPorts.kext in the OpenCore ESP matches ACPI names
         EH01/UHC1-3, which this guest's ACPI does not declare, so that map
         matches nothing. -->
    <controller type='usb' index='1' model='qemu-xhci'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x06' function='0x0'/>
    </controller>

    <controller type='usb' index='0' model='ich9-ehci1'>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x7'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci1'>
      <master startport='0'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x0' multifunction='on'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci2'>
      <master startport='2'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x1'/>
    </controller>
    <controller type='usb' index='0' model='ich9-uhci3'>
      <master startport='4'/>
      <address type='pci' domain='0x0000' bus='0x00' slot='0x07' function='0x2'/>
    </controller>
    <input type='keyboard' bus='usb'/>
    <input type='tablet' bus='usb'/>

    <graphics type='spice' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <!-- EMULATED VGA, for the installer. macOS Setup is driven from the SPICE
         console, so this file keeps an emulated GPU, and the console supplies
         keyboard and mouse input with it. This is the installer configuration
         only: macos-passthrough.xml sets <model type='none'/> here instead,
         because once the NullMoth driver loads the passed-through NVIDIA must
         be the guest's only display device, so that NVRMFB can own display
         index 0. -->
    <video>
      <model type='vmvga' heads='1' primary='yes'/>
    </video>

    <sound model='ich9'/>
    <audio id='1' type='spice'/>

    <!-- Guest serial port, DELIBERATELY type='file'. The NullMoth driver logs
         with kprintf, which never reaches the unified log, so QEMU writes the
         guest's COM1 to a file that can be read from the host without guest
         sudo. Requires debug=0x8 serial=1 in the guest boot-args. This is the
         intended configuration for driver-log capture, not a temporary state. -->
    <serial type='file'>
      <source path='/tmp/macos-serial.log' append='off'/>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>

    <!-- The GPU and its audio function are passed through here in
         macos-passthrough.xml: host 01:00.0 / 01:00.1, guest bus 0x01 slot
         0x00 function 0x0 / 0x1, behind the pcie-root-port above. They are
         deliberately absent during installation, because macOS Setup needs no
         discrete GPU and the SPICE console (see <video> above) provides the
         keyboard and mouse. macos-passthrough.xml also carries the two USB
         hostdevs that take over guest input once the emulated GPU is gone. -->
    <memballoon model='none'/>
  </devices>

  <qemu:commandline>
    <!-- The CPU model, from OSX-KVM's OpenCore-Boot.sh line 37:
             -cpu Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,
                  +invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,
                  +aes,+xsave,+xsaveopt,check
         Nothing in this file sets a libvirt cpu element, so this is the only
         -cpu QEMU receives. The Penryn line (their pre-Sequoia one) wedges
         this guest with every vCPU spinning; -hle/-rtm disable TSX. -->
    <qemu:arg value='-cpu'/>
    <qemu:arg value='Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check'/>
    <!-- AppleSMC: OpenCore needs it to expose the SMC keys macOS reads, and
         macOS refuses to boot without it.

         The osk below is a PLACEHOLDER. The real one is the 64-byte key held in
         the SMC of genuine Apple hardware. It is Apple's property, which is why
         this file does not carry it: redistributing it is what gets
         macOS-passthrough repositories taken down.

         Supply your own. See "OSX-KVM: the pieces macOS needs" in the README
         for how. Until you do, the domain will start but macOS will not boot. -->
    <qemu:arg value='-device'/>
    <qemu:arg value='isa-applesmc,osk=REPLACE_WITH_YOUR_OWN_OSK'/>
    <!-- Board identity macOS accepts with a discrete GPU (the model the
         NullMoth driver was tested on). -->
    <qemu:arg value='-smbios'/>
    <qemu:arg value='type=2'/>
    <!-- The bridge-level ACPI hotplug switch, kept here even though it does
         nothing in this configuration: with no PCI hostdevs there is no device
         behind a root port for macOS to fail to resource, so the property is
         harmless. It is kept so that the installer runs the same QEMU
         invocation as the working passthrough configuration, and so that the
         two files differ as little as possible. macos-passthrough.xml explains
         what this property does and why it is the key fix there. -->
    <qemu:arg value='-global'/>
    <qemu:arg value='ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off'/>
  </qemu:commandline>
</domain>
```

## Appendix B. Supporting files in this repo

> ### ⚠️ Every script and every config here MUST be edited before it will work
>
> Nothing in this repository knows your hardware. You must replace **all** of:
>
> | what | where | ships as |
> |---|---|---|
> | your GPU's host address | `macos-passthrough.xml` only (the install config passes nothing through); `GPU_BDF`/`GPU_AUDIO_BDF` in the scripts | a deliberately fake `ff:1f.0`, so it fails loudly rather than touching a real device |
> | **your keyboard and mouse** | the two USB hostdevs in `macos-passthrough.xml` | the author's devices (`3151:4011`, `046d:c08b`) |
> | **the emulator, loader and NVRAM paths** | both domain XMLs | NixOS paths (`/run/libvirt/nix-emulators/…`, `/run/libvirt/nix-ovmf/…`) |
> | your OSX-KVM clone and disk paths | both domain XMLs; `OSX_KVM` in `scripts/setup-macos.sh` | `/path/to/OSX-KVM`, `/var/lib/libvirt/images/macos.img` |
>
> **The USB row is the one that strands people.** With `<video>=none` the guest has no
> emulated console, so those two hostdevs are the *only* keyboard and mouse it gets — and
> if they are the author's device IDs, your guest boots to a desktop you cannot touch.
> Get yours with `lsusb`, and put your own `vendor`/`product` pairs in.
>
> The emulator and loader rows matter because libvirt will not start a domain whose
> emulator path does not exist. On most distributions `qemu-system-x86_64` is enough for
> the emulator, and the OVMF files are usually under `/usr/share/OVMF/` or
> `/usr/share/edk2/ovmf/`.

Two sets of scripts, pick either:

**The simple ones** (`scripts/gpu-to-vfio.sh`, `scripts/gpu-to-host.sh`,
`scripts/set-bar1.sh`) — short and readable, and easy to adapt. They do the minimum:
clear `driver_override`, unbind, resize BAR1, bind vfio-pci. They assume the GPU is free, so
on a desktop machine prefer the guarded pair.

**The guarded ones** (`scripts/gpu-to-vfio.guarded.sh`, `scripts/gpu-to-host.guarded.sh`) —
longer, and safe to run on a machine you care about, because they check before they act:
they stop the NVIDIA services, count everything holding the card (a compositor that has
merely opened it included), and when it is in use they offer to force, defer until after your
next logout, or cancel. They verify the binding afterwards too. `-s` makes them report and
exit 1 rather than ask, which is what you want from a script.

Two more, for the deferred path: `scripts/gpu-vfio-status.sh` reports the current state and
changes nothing, and `scripts/gpu-vfio-apply.sh` applies a switch that was deferred to your
next logout.

Both sets act only on the GPU address you set at the top of the file; neither guesses it.
Both run on the host and need root, and both take a BAR size as an argument: the two
`gpu-to-*` scripts as a bit index (`16GiB` is not a bit index and will be rejected),
`scripts/set-bar1.sh` as bytes, a `GiB`/`MiB` suffix, or a bit index.

| file | where it runs | what it does |
|---|---|---|
| `config/macos-install.xml` | host | stage 1: install macOS, no passthrough, SPICE display |
| `config/macos-passthrough.xml` | host | stage 2: the working passthrough configuration |
| `scripts/gpu-to-vfio.sh` | host | unbind the GPU from its driver, set the BAR, bind vfio-pci |
| `scripts/gpu-to-host.sh` | host | give the GPU back to the host driver |
| `scripts/gpu-to-vfio.guarded.sh` | host | the same, with checks; offers a deferred switch after logout |
| `scripts/gpu-to-host.guarded.sh` | host | give the GPU back, with checks |
| `scripts/gpu-vfio-status.sh` | host | report the current state; changes nothing |
| `scripts/gpu-vfio-apply.sh` | host | apply a deferred switch, after the logout |
| `scripts/set-bar1.sh` | host | set BAR1 size (`4GiB`, `4294967296` or bit index `12`; refuses to run without an argument) |
| `tools/bench.sh` | guest | autonomous drag benchmark; parks/refusals/fps |
| `tools/dragload.m` | guest | drag-load microbenchmark |
| `tools/surfbench.m` | guest | surface throughput |
| `tools/shaderbench.m` | guest | shader compilation |
| `tools/mmio-probe.py` | guest | read-only GPU inspection: identity, BARs, `IODeviceMemory` |
| `tools/install-progress` | host | live progress/ETA while macOS installs |

---

## Appendix C. Full source of every script

Inline so this file stands alone. The same files are in `scripts/` and `tools/`.

**All of them must be edited for your hardware** — see the warning in Appendix B.

### `scripts/gpu-to-vfio.guarded.sh` — GUARDED host script: release the GPU, set BAR1, bind vfio-pci

```bash
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
BAR_IDX_VFIO=12   # 4 GiB — largest host-side window that places correctly for a VM
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
```

### `scripts/gpu-to-host.guarded.sh` — GUARDED host script: give the GPU back

```bash
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
BAR_IDX_VFIO=12   # 4 GiB — largest host-side window that places correctly for a VM
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
```

### `scripts/gpu-vfio-status.sh` — GUARDED host script: report current state

```bash
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

cyan()   { echo -e "\e[36m$*\e[0m" >&2; }

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

    # Resizable BAR1: 16 GiB is what both the host and the guest want
    if [ -e "/sys/bus/pci/devices/$bdf/resource1_resize" ]; then
        bar_sz=$(bar1_human "$(bar1_bytes "$bdf")")
        case "$bar_sz" in
            "4 GiB")  printf "    BAR1:         \e[33m%s\e[0m  (small: caps the driver budget at 2 GiB)\n" "$bar_sz" ;;
            "16 GiB") printf "    BAR1:         \e[32m%s\e[0m  (correct for passthrough)\n" "$bar_sz" ;;
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
# NOTE: `lsmod | grep -q` reports a false negative under `set -o pipefail`:
# grep -q exits at the first match, lsmod dies of SIGPIPE, and the pipeline
# returns 141. Capture the list once and match against it instead.
LSMOD_LIST=$(lsmod 2>/dev/null || true)
for mod in nvidia_drm nvidia_modeset nvidia_uvm nvidia; do
    if grep -q "^$mod " <<<"$LSMOD_LIST"; then
        count=$(awk -v m="$mod" '$1==m {print $3}' <<<"$LSMOD_LIST")
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
    if grep -q "^$mod " <<<"$LSMOD_LIST"; then
        count=$(awk -v m="$mod" '$1==m {print $3}' <<<"$LSMOD_LIST")
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
```

### `scripts/gpu-vfio-apply.sh` — GUARDED host script: apply a deferred switch after logout

```bash
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
yellow() { echo -e "\e[33m$*\e[0m" >&2; }
info()   { echo -e "\e[34m[INFO]\e[0m  $*" >&2; }

if [ "$EUID" -ne 0 ]; then exec sudo "$0" "$@"; fi

PENDING="/etc/gpu-switch/pending"

if [ ! -f "$PENDING" ]; then
    red "No pending GPU switch found."
    echo "Run gpu-to-vfio or gpu-to-host first to schedule a switch."
    exit 1
fi

# ── Warn about active graphical sessions ─────────────────────
# Count sessions by property, not by scraping the table. `grep -v tty` on that
# table discards the session that matters: a Wayland or X session is class=user
# and *does* carry a TTY (tty2 here), so filtering on the word "tty" threw away
# exactly the session this warning exists to find.
count_seat_sessions() {
    local s class seat v out=""
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

if command -v loginctl &>/dev/null; then
    SEAT_SESSIONS=$(count_seat_sessions)
    ACTIVE=0
    [ -n "$SEAT_SESSIONS" ] && ACTIVE=$(wc -w <<<"$SEAT_SESSIONS")
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
```

### `scripts/gpu-to-vfio.sh` — Simple host script: release the GPU, set BAR1, bind vfio-pci

```bash
#!/usr/bin/env bash
# gpu-to-vfio.sh — release the GPU from its host driver, size BAR1 for the guest,
# and hand it to vfio-pci so a VM can be started against it.
#
#   sudo ./gpu-to-vfio.sh [BAR_BIT_INDEX]
#
# BAR_BIT_INDEX defaults to 12 (4 GiB). It is a BIT INDEX, not a byte count:
#   8=256MB  11=2GiB  12=4GiB  13=8GiB  14=16GiB      (size = 2^(idx+20))
#
# 4 GiB is the largest size that places correctly for a VM. At 8 GiB and above
# the guest firmware puts the BAR on a non-canonical address (a 32-bit base
# written into the high dword of a 64-bit BAR), which QEMU/KVM reject, so the
# domain either fails to start or the guest gets no usable aperture. This is the
# HOST-side window, set while the domain is off; once macOS is up the NullMoth
# driver places its own 16 GiB BAR and takes the 8 GiB budget from that.
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

BAR_IDX="${1:-12}"

# Refuse to run on an address that is not present. The shipped GPU_BDF is a
# deliberate placeholder, and without this check the bind loop below silently
# skips a nonexistent device while the verification loop prints nothing and
# still exits 0 — reporting success for a GPU that was never touched.
if [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
    echo "STOP: $GPU_BDF does not exist on this machine." >&2
    echo "      Edit GPU_BDF/GPU_AUDIO_BDF at the top of this script (find yours with: lspci -nn | grep -i nvidia)." >&2
    exit 1
fi

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
seen=0
for dev in "${DEVS[@]}"; do
    [ -e "/sys/bus/pci/devices/$dev" ] || continue
    seen=$(( seen + 1 ))
    drv=$(readlink "/sys/bus/pci/devices/$dev/driver" 2>/dev/null | xargs -r basename || echo none)
    printf '  %s -> %s\n' "$dev" "$drv"
    [ "$drv" = "vfio-pci" ] || rc=1
done
[ "$seen" -gt 0 ] || { echo "FAILED — no device was checked (wrong address?)" >&2; exit 1; }
[ "$rc" -eq 0 ] && echo "OK — the GPU is ready to pass through" || { echo "FAILED — check dmesg" >&2; exit 1; }
```

### `scripts/gpu-to-host.sh` — Simple host script: give the GPU back

```bash
#!/usr/bin/env bash
# gpu-to-host.sh — give the GPU back to its host driver and restore the full BAR1.
#
#   sudo ./gpu-to-host.sh
#
# Run this after shutting the VM down. Destroy the domain first; unbinding a GPU
# that a running VM is using will not go well.

# ⚠️ EDIT THIS. The address below is DELIBERATELY FAKE (ff:1f.0 is not a real
# device) so that a copy-paste fails loudly instead of touching the wrong GPU.
# Find yours with:  lspci -nn | grep -i -e nvidia -e vga
# It looks like 0000:01:00.0 -> use that. The audio function is .1 on the
# same bus/slot.
GPU_BDF="${GPU_BDF:-0000:ff:1f.0}"
GPU_AUDIO_BDF="${GPU_AUDIO_BDF:-0000:ff:1f.1}"
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
# Refuse to run on an address that is not present: the shipped GPU_BDF is a
# deliberate placeholder, and every loop below would otherwise skip it and this
# script would report nothing while doing nothing.
if [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
    echo "STOP: $GPU_BDF does not exist on this machine." >&2
    echo "      Edit GPU_BDF/GPU_AUDIO_BDF at the top of this script (find yours with: lspci -nn | grep -i nvidia)." >&2
    exit 1
fi
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
    sysfs="/sys/bus/pci/devices/$dev"
    [ -e "$sysfs" ] || continue
    # Let the kernel pick the right driver for THIS function. Binding every
    # device to $HOST_DRIVER is wrong for the GPU's audio function, which
    # belongs to snd_hda_intel: it cannot bind to nvidia, and it is otherwise
    # left with no driver at all (no host audio) until the next reboot.
    if [ "$dev" = "$GPU_BDF" ] && [ -e "/sys/bus/pci/drivers/$HOST_DRIVER/bind" ]; then
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
```

### `scripts/set-bar1.sh` — Set BAR1 size (no default, deliberately)

```bash
#!/usr/bin/env bash
# set-bar1.sh — set the passed-through GPU's Resizable BAR1 size.
#
#   sudo ./set-bar1.sh 4GiB           # or: 4294967296 | 12
#
# Accepts a size in bytes, a size with a GiB/MiB suffix, or a raw bit index.
# There is deliberately NO default: this is the size the guest firmware has to
# place, and too large a value breaks the passthrough outright.
#
# Set it to 4 GiB. At 8 GiB and above the firmware places the BAR on a
# non-canonical address (a 32-bit base in the high dword of a 64-bit BAR) which
# QEMU/KVM reject, so the domain fails to start or the guest gets no aperture.
#
# This is the HOST-side window, not the BAR the driver uses. Once macOS is up
# the NullMoth driver places its own (16 GiB here) and takes the 8 GiB budget
# from that, since budget = fBarLen / 2. Sizing this window to the card's
# maximum does not increase the budget; it only stops the guest booting.
#
# The device MUST be unbound while this runs (see gpu-to-vfio.sh, which does the
# unbind, the resize and the vfio bind in the right order).

# ⚠️ EDIT THIS. The address below is DELIBERATELY FAKE (ff:1f.0 is not a real
# device) so that a copy-paste fails loudly instead of touching the wrong GPU.
# Find yours with:  lspci -nn | grep -i -e nvidia -e vga
# It looks like 0000:01:00.0 -> use that. The audio function is .1 on the
# same bus/slot.
GPU_BDF="${GPU_BDF:-0000:ff:1f.0}"

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
```

### `tools/bench.sh` — Guest: autonomous drag benchmark

```bash
#!/bin/bash
# bench.sh [label] [seconds] -- one identical measurement procedure per test.
#
# Runs the autonomous compositor load generator and reports:
#   - compositor flips/s
#   - WindowServer CPU per flip (the cost of a composited frame)
#   - grant / park / refusal deltas (the allocation path)
#   - mapped VRAM against the budget
#
# Written as a file (not an inline ssh heredoc) because nested quoting through

L="${1:-unlabelled}"
SECS="${2:-20}"
NVRM=$(sysctl -n kern.boottime >/dev/null 2>&1; echo)

# The GUI session must be LIVE or the load runs against the login window and the
# numbers are meaningless (a WS restart drops to `console user: root` until the
# session comes back). Wait for it, with a hard cap.
# `console user != root` is NOT sufficient: it can be set while the desktop
# is still coming up, and then the load measures a half-initialised session
# (mapped VRAM ~114 MB instead of ~152-175 MB, and ~10 fps instead of ~133).
# Require a real session: the console user AND the Dock (only runs in a full
# session) AND the framebuffer showing session-sized VRAM use.
session_up() {
    [ "$(stat -f %Su /dev/console 2>/dev/null)" = "$(id -un)" ] || [ "$(stat -f %Su /dev/console 2>/dev/null)" != "root" ] || return 1
    pgrep -x Dock >/dev/null 2>&1 || return 1
    local m=$(($(sysctl -n debug.nvrmfb_vram_mapped_bytes 2>/dev/null || echo 0)/1048576))
    [ "$m" -ge 130 ] || return 1
    return 0
}
for _ in $(seq 1 60); do session_up && break; sleep 3; done
if ! session_up; then
    echo "===== $L: ABORTED - session not ready (console=$(stat -f %Su /dev/console) dock=$(pgrep -xc Dock 2>/dev/null || echo 0) mapped=$(($(sysctl -n debug.nvrmfb_vram_mapped_bytes 2>/dev/null || echo 0)/1048576))MB) ====="
    exit 1
fi
sleep 5

wp=$(pgrep -x WindowServer | head -1)
c0=$(ps -o time= -p "$wp" | tr -d ' ')
f0=$(sysctl -n debug.nvrmfb_flip_n)
g0=$(sysctl -n debug.nvrmfb_vram_grants)
p0=$(strings /tmp/macos-serial.log 2>/dev/null | grep -ac "parking it and rolling")
r0=$(strings /tmp/macos-serial.log 2>/dev/null | grep -ac "REFUSED")

out=$(sudo launchctl asuser "$(id -u)" $HOME/nvmtltest/dragload "$SECS" 900 2>&1 | grep -E "dragload:|flips during")

wp2=$(pgrep -x WindowServer | head -1)
c1=$(ps -o time= -p "$wp2" | tr -d ' ')
f1=$(sysctl -n debug.nvrmfb_flip_n)
g1=$(sysctl -n debug.nvrmfb_vram_grants)
p1=$(strings /tmp/macos-serial.log 2>/dev/null | grep -ac "parking it and rolling")
r1=$(strings /tmp/macos-serial.log 2>/dev/null | grep -ac "REFUSED")

python3 - "$L" "$c0" "$c1" "$f0" "$f1" "$g0" "$g1" "$p0" "$p1" "$r0" "$r1" <<'PY'
import sys
L, c0, c1, f0, f1, g0, g1, p0, p1, r0, r1 = sys.argv[1:12]
def secs(t):
    p = [float(x) for x in t.split(':')]
    return p[0]*3600 + p[1]*60 + p[2] if len(p) == 3 else (p[0]*60 + p[1] if len(p) == 2 else p[0])
d_cpu = secs(c1) - secs(c0)
d_f   = int(f1) - int(f0)
print(f"===== {L} =====")
print(f"  flips {d_f}   WindowServer CPU {d_cpu:.2f}s   -> {d_cpu*1000/max(d_f,1):.2f} ms/flip")
print(f"  grants +{int(g1)-int(g0)}   parks +{int(p1)-int(p0)}   refusals +{int(r1)-int(r0)}")
PY
echo "  mapped: $(( $(sysctl -n debug.nvrmfb_vram_mapped_bytes)/1048576 ))MB / $(( $(sysctl -n debug.nvrmfb_vram_budget_bytes)/1048576 ))MB"
echo "  $out" | sed 's/^/  /'
```

### `tools/mmio-probe.py` — Guest: read-only GPU inspection

```python
#!/usr/bin/env python3
"""
mmio-probe.py -- inspect the passed-through NVIDIA GPU from inside the macOS guest.

    sudo python3 /tmp/mmio-probe.py

Reads only. Prints:
  1. the IOPCIDevice's identity properties,
  2. the `reg` property (the BAR addresses/sizes macOS was given),
  3. the IODeviceMemory objects macOS created for those BARs,
  4. a best-effort attempt to map and read the first words of each BAR.

If step 4 is refused (likely: mapping IOPCIDevice BARs from userland needs an
entitlement or a kext), steps 1-3 are still the authoritative record of what the
guest firmware assigned.
"""
import ctypes
import sys

IOKIT = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
CF = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

kIOMainPortDefault = 0
kCFAllocatorDefault = ctypes.c_void_p(0)
UTF8 = 0x08000100

CF.CFStringCreateWithCString.restype = ctypes.c_void_p
CF.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
CF.CFDataGetLength.restype = ctypes.c_long
CF.CFDataGetLength.argtypes = [ctypes.c_void_p]
CF.CFDataGetBytePtr.restype = ctypes.c_void_p
CF.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
CF.CFRelease.argtypes = [ctypes.c_void_p]

IOKIT.IOServiceMatching.restype = ctypes.c_void_p
IOKIT.IOServiceMatching.argtypes = [ctypes.c_char_p]
IOKIT.IOServiceGetMatchingServices.restype = ctypes.c_int
IOKIT.IOServiceGetMatchingServices.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
IOKIT.IOIteratorNext.restype = ctypes.c_uint32
IOKIT.IOIteratorNext.argtypes = [ctypes.c_uint32]
IOKIT.IOObjectRelease.argtypes = [ctypes.c_uint32]
IOKIT.IORegistryEntryCreateCFProperty.restype = ctypes.c_void_p
IOKIT.IORegistryEntryCreateCFProperty.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint32]
IOKIT.IORegistryEntryGetName.restype = ctypes.c_int
IOKIT.IORegistryEntryGetName.argtypes = [ctypes.c_uint32, ctypes.c_char_p]
IOKIT.IORegistryEntryGetChildIterator.restype = ctypes.c_int
IOKIT.IORegistryEntryGetChildIterator.argtypes = [ctypes.c_uint32, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32)]
IOKIT.IOServiceOpen.restype = ctypes.c_int
IOKIT.IOServiceOpen.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
IOKIT.IOServiceClose.argtypes = [ctypes.c_uint32]


def cf(s):
    return CF.CFStringCreateWithCString(kCFAllocatorDefault, s.encode(), UTF8)


def prop(entry, key):
    v = IOKIT.IORegistryEntryCreateCFProperty(entry, cf(key), kCFAllocatorDefault, 0)
    if not v:
        return None
    n = CF.CFDataGetLength(v)
    p = CF.CFDataGetBytePtr(v)
    d = ctypes.string_at(p, n) if n > 0 else b""
    CF.CFRelease(v)
    return d


def name_of(entry):
    b = ctypes.create_string_buffer(256)
    IOKIT.IORegistryEntryGetName(entry, b)
    return b.value.decode(errors="replace")


def children(entry):
    out = []
    it = ctypes.c_uint32(0)
    IOKIT.IORegistryEntryGetChildIterator(entry, b"IOService", ctypes.byref(it))
    if not it.value:
        return out
    while True:
        c = IOKIT.IOIteratorNext(it.value)
        if not c:
            break
        out.append(c)
    IOKIT.IOObjectRelease(it.value)
    return out


def find_nvidia():
    it = ctypes.c_uint32(0)
    IOKIT.IOServiceGetMatchingServices(kIOMainPortDefault,
                                       IOKIT.IOServiceMatching(b"IOPCIDevice"),
                                       ctypes.byref(it))
    found = None
    while it.value:
        e = IOKIT.IOIteratorNext(it.value)
        if not e:
            break
        if prop(e, "vendor-id") == b"\xde\x10\x00\x00":
            found = e
            break
        IOKIT.IOObjectRelease(e)
    if it.value:
        IOKIT.IOObjectRelease(it.value)
    return found


def le(b):
    return int.from_bytes(b, "little") if b else None


def b64(b):
    return int.from_bytes(b, "little") if b else None


def decode_reg(reg):
    """Open Firmware PCI reg: 5 cells per entry = physhi, addr(2), size(2)."""
    out = []
    if not reg or len(reg) % 20:
        return out
    for i in range(0, len(reg), 20):
        e = reg[i:i + 20]
        physhi = int.from_bytes(e[0:4], "big")
        addr_hi = int.from_bytes(e[4:8], "big")
        addr_lo = int.from_bytes(e[8:12], "big")
        size_hi = int.from_bytes(e[12:16], "big")
        size_lo = int.from_bytes(e[16:20], "big")
        space = (physhi >> 24) & 0x03
        kind = {0: "config", 1: "io", 2: "mem32", 3: "mem64"}.get(space, "?")
        pref = " prefetch" if (physhi & 0x08) else ""
        if space == 3:
            addr = (addr_hi << 32) | addr_lo
            size = (size_hi << 32) | size_lo
        else:
            addr = addr_lo
            size = size_lo
        out.append((kind + pref, addr, size))
    return out


def fmt(n):
    if n is None:
        return "?"
    if n >= 2 ** 30:
        return "%.2f GiB" % (n / 2 ** 30)
    if n >= 2 ** 20:
        return "%.2f MiB" % (n / 2 ** 20)
    if n >= 2 ** 10:
        return "%.1f KiB" % (n / 2 ** 10)
    return "%d B" % n


def main():
    print("=== NVIDIA IOPCIDevice ===")
    dev = find_nvidia()
    if not dev:
        print("  NOT FOUND (no IOPCIDevice with vendor-id de100000)")
        return 1
    print("  name      :", name_of(dev))
    for k in ("vendor-id", "device-id", "class-code", "revision-id", "subsystem-id", "built-in"):
        v = prop(dev, k)
        print("  %-11s: %s" % (k, v.hex() if v else "(absent)"))

    print()
    print("=== reg property (BARs as the firmware told macOS) ===")
    reg = prop(dev, "reg")
    if reg:
        print("  raw (%d bytes): %s" % (len(reg), reg.hex()))
        for kind, addr, size in decode_reg(reg):
            print("    %-14s addr=0x%-18x size=%s (0x%x)" % (kind, addr, fmt(size), size))
    else:
        print("  (absent)")

    print()
    print("=== IODeviceMemory objects (BARs macOS actually created) ===")
    n = 0
    for c in children(dev):
        cname = name_of(c)
        if "IODeviceMemory" in cname:
            n += 1
            base = le(prop(c, "IODeviceMemoryBase"))
            size = b64(prop(c, "IODeviceMemorySize"))
            print("  %-26s base=0x%-18s size=%s" % (
                cname,
                ("%x" % base) if base is not None else "?",
                fmt(size)))
        IOKIT.IOObjectRelease(c)
    if n == 0:
        print("  (none)")

    print()
    print("=== userland map attempt ===")
    conn = ctypes.c_uint32(0)
    kr = IOKIT.IOServiceOpen(dev, ctypes.c_uint32(0xFFFFFFFF), 0, ctypes.byref(conn))
    print("  IOServiceOpen -> 0x%08x %s" % (kr & 0xFFFFFFFF,
                                           "(success)" if kr == 0 else "(refused)"))
    if kr == 0:
        IOKIT.IOServiceClose(conn)
    print()
    print("If the map was refused: that is expected.  Mapping IOPCIDevice BARs")
    print("from userland needs an entitlement or a kext, so section 2/3 above")
    print("(config-space BAR values) are the authoritative evidence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

### `tools/install-progress` — Host: live progress while macOS installs

```
#!/usr/bin/env bash
# install-progress — live progress/ETA for the macOS install happening in the
# "macos" libvirt domain.
#
#   ./install-progress                 # monitor until it stops growing
#   TOTAL_GIB=16 ./install-progress    # if you know the real download size
#
# Why this measures the disk and not the network: the macOS installer streams
# the ~13 GB shared-support volume straight into the guest's disk, so the
# target image's allocation is a faithful (and locally-observable) proxy for
# download progress. Network counters include the VM's other chatter; disk
# allocation does not.
#
# No sudo needed: virsh domblkinfo reads the allocation through libvirt.
set -uo pipefail

DOMAIN=${DOMAIN:-macos}
DISK=${DISK:-sda}
INTERVAL=${INTERVAL:-5}
# Rough size of the macOS shared-support download in GiB. The real figure varies
# per release; override with TOTAL_GIB=... once you can see the finish line, or
# just watch the "elapsed" figure, which needs no total at all.
TOTAL_GIB=${TOTAL_GIB:-14}

alloc_bytes() {
  virsh -c qemu:///system domblkinfo "$DOMAIN" "$DISK" 2>/dev/null \
    | awk '/Allocation/{print $2}'
}

hum() { # bytes -> human
  awk -v b="$1" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " ");
    i=1; while (b >= 1024 && i < 5) { b/=1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

hms() { # seconds -> 1h02m03s
  awk -v s="$1" 'BEGIN{
    if (s < 0 || s != s) { print "--"; exit }
    h=int(s/3600); m=int((s%3600)/60); sec=int(s%60);
    if (h) printf "%dh%02dm%02ds", h, m, sec; else printf "%dm%02ds", m, sec
  }'
}

TOTAL_BYTES=$(awk -v g="$TOTAL_GIB" 'BEGIN{printf "%d", g*1073741824}')

prev=$(alloc_bytes)
[ -n "${prev:-}" ] || { echo "cannot read allocation for $DOMAIN/$DISK" >&2; exit 1; }
start=$prev
start_ts=$(date +%s)
prev_ts=$start_ts
stalled=0

# terminal width for the bar
COLS=$(tput cols 2>/dev/null || echo 80)
[ "$COLS" -gt 100 ] && COLS=100

printf '\033[?25l'                     # hide cursor
trap 'printf "\033[?25h\n"; exit 0' INT TERM

while :; do
  now=$(alloc_bytes)
  now_ts=$(date +%s)
  dt=$((now_ts - prev_ts))
  [ "$dt" -le 0 ] && dt=1
  rate=$(( (now - prev) / dt ))        # B/s, instantaneous
  elapsed=$((now_ts - start_ts))
  avg=$(( (now - start) / (elapsed > 0 ? elapsed : 1) ))

  # progress bar + ETA against the assumed total
  pct=$(awk -v n="$now" -v t="$TOTAL_BYTES" 'BEGIN{ if (t<=0) {print 0; exit} p=100*n/t; if(p>100)p=100; printf "%.1f", p }')
  filled=$(awk -v p="$pct" -v w="$((COLS-46))" 'BEGIN{ if(w<10)w=10; n=int(p*w/100+0.5); if(n>w)n=w; for(i=0;i<n;i++)printf "="; for(i=n;i<w;i++)printf " "; }')

  if [ "$rate" -gt 0 ]; then
    eta=$(awk -v t="$TOTAL_BYTES" -v n="$now" -v r="$rate" 'BEGIN{ if(r<=0){print -1; exit} printf "%d", (t-n)/r }')
  else
    eta=-1
  fi

  # stall detection: nothing written since the last sample
  if [ "$now" -le "$prev" ]; then stalled=$((stalled+dt)); else stalled=0; fi

  printf '\r\033[K  [%s] %5s%%  %s  %s/s  eta %s  elapsed %s' \
    "$filled" "$pct" "$(hum "$now")" "$(hum "$rate")" "$(hms "$eta")" "$(hms "$elapsed")"

  # Stop conditions: long stall, or the download looks complete.
  if [ "$stalled" -ge 120 ]; then
    printf '\n\n  No growth for %ss. Either the download finished and the\n  install phase began (CPU-bound, watch the VM), or it stalled.\n' "$stalled"
    printf '  Disk allocation: %s\n' "$(hum "$now")"
    break
  fi
  if [ "$now" -ge "$TOTAL_BYTES" ]; then
    printf '\n\n  Reached the %s GiB estimate. If it is still writing,\n  re-run with a larger TOTAL_GIB to keep tracking.\n' "$TOTAL_GIB"
    break
  fi

  prev=$now
  prev_ts=$now_ts
  sleep "$INTERVAL"
done

printf '\033[?25h'
```

### `tools/dragload.m` — Guest: drag-load microbenchmark

```objc
// dragload.m — generate compositor load autonomously, and measure it.
//
// Opens a window with Metal-rendered content and moves it continuously for N
// seconds, then reports what the compositor achieved. This reproduces the load
// of dragging a window without needing a human, so every experiment can be
// measured the same way.
//
// Usage: dragload <seconds> [size] [fps-report]
//   Reports: compositor flips/s (read from the driver's sysctl before and after),
//   its own redraw rate, and elapsed wall time.
//
// Run it inside the GUI session:  launchctl asuser $(id -u) ./dragload 20

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
static long long sysctl_q(const char *name) {
    long long v = -1; size_t l = sizeof v;
    if (sysctlbyname(name, &v, &l, NULL, 0) != 0) return -1;
    return v;
}

@interface View : NSView
@property (nonatomic) id<MTLDevice> dev;
@property (nonatomic) id<MTLCommandQueue> q;
@property (nonatomic) NSUInteger frames;
@end

@implementation View
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    // Draw through Metal so the content is a real GPU surface, like a window's.
    if (!_q) { _dev = MTLCreateSystemDefaultDevice(); _q = [_dev newCommandQueue]; }
    id<CAMetalDrawable> d = [(CAMetalLayer *)self.layer nextDrawable];
    if (d) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1 + 0.8 * (double)(_frames % 60) / 60.0,
                                                             0.2, 0.6, 1.0);
        id<MTLCommandBuffer> cb = [_q commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e endEncoding];
        [cb presentDrawable:d];
        [cb commit];
        _frames++;
    }
}
- (void)layout { ((CAMetalLayer *)self.layer).drawableSize = self.bounds.size; }
- (CALayer *)makeBackingLayer { CAMetalLayer *l = [CAMetalLayer layer]; l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm; return l; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 20.0;
        int size    = argc > 2 ? atoi(argv[2]) : 900;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSRect r = NSMakeRect(200, 200, size, size);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:r
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        [w setTitle:@"dragload"];
        View *v = [[View alloc] initWithFrame:r];
        [w setContentView:v];
        [w makeKeyAndOrderFront:nil];
        [w setLevel:NSFloatingWindowLevel];        // stay visible over others
        [NSApp activateIgnoringOtherApps:YES];

        long long flip0 = sysctl_q("debug.nvrmfb_flip_n");
        long long park0 = -1;
        double t0 = now_s();
        NSUInteger moves = 0;
        NSRect screen = [[NSScreen mainScreen] frame];

        while (now_s() - t0 < secs) {
            @autoreleasepool {
                // Move the window like a drag: a smooth path across the screen.
                double t = now_s() - t0;
                double x = screen.size.width  * 0.5 + sin(t * 1.2) * screen.size.width  * 0.35;
                double y = screen.size.height * 0.5 + cos(t * 0.9) * screen.size.height * 0.30;
                [w setFrameOrigin:NSMakePoint(x, y)];
                [v setNeedsDisplay:YES];                 // force a redraw -> GPU surface churn
                [v displayIfNeeded];
                [w displayIfNeeded];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                moves++;
            }
        }
        double dt = now_s() - t0;
        long long flip1 = sysctl_q("debug.nvrmfb_flip_n");
        printf("dragload: %.1f s, %lu moves (%.1f/s), %lu redraws (%.1f/s)\n",
               dt, (unsigned long)moves, moves / dt, (unsigned long)v.frames, v.frames / dt);
        printf("  compositor flips during load: %lld  ->  %.1f fps\n",
               flip1 - flip0, (double)(flip1 - flip0) / dt);
        (void)park0;
        return 0;
    }
}
```

### `tools/surfbench.m` — Guest: surface throughput microbenchmark

```objc
// surfbench.m — measure the latency of the compositor's surface path.
//
// WindowServer's composited frames come from IOSurfaces that the accelerator
// adopts (nvaccel_iop_src_surf counts them). So: create an IOSurface, bind it to
// a Metal texture (which forces the driver to adopt it), time the pair, release.
//
// Usage: surfbench <count> <width> <height> [keep]
//   keep = 1 keeps every surface alive (fills VRAM, provokes the grant budget)
//
// The framebuffer's grant counters (debug.nvrmfb_vram_grants / _mapped_bytes)
// should move if this really exercises nvAllocVram -- check them around a run.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int count    = argc > 1 ? atoi(argv[1]) : 60;
        int W        = argc > 2 ? atoi(argv[2]) : 3440;
        int H        = argc > 3 ? atoi(argv[3]) : 1440;
        int keep     = argc > 4 ? atoi(argv[4]) : 0;

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 1; }
        printf("device: %s\n", [[dev name] UTF8String]);
        printf("%d x %dx%d surfaces, keep=%d\n", count, W, H, keep);

        NSMutableArray *alive = [NSMutableArray array];
        double *t = calloc(count, sizeof(double));
        int made = 0, failed = 0;

        for (int i = 0; i < count; i++) {
            double t0 = now_ms();

            NSDictionary *p = @{
                (id)kIOSurfaceWidth:           @(W),
                (id)kIOSurfaceHeight:          @(H),
                (id)kIOSurfaceBytesPerElement: @(4),
                (id)kIOSurfaceBytesPerRow:     @(W * 4),
                (id)kIOSurfacePixelFormat:     @(0x42475241),   // 'BGRA'
                (id)kIOSurfaceIsGlobal:        @YES,
            };
            IOSurfaceRef s = IOSurfaceCreate((CFDictionaryRef)p);
            if (!s) { failed++; t[i] = now_ms() - t0; continue; }

            MTLTextureDescriptor *d =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:W height:H mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModeManaged;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:d iosurface:s plane:0];
            if (!tex) { CFRelease(s); failed++; t[i] = now_ms() - t0; continue; }

            double dt = now_ms() - t0;
            t[i] = dt;
            made++;
            if (keep) { [alive addObject:@[ (__bridge id)s, tex ]]; }
            else      { CFRelease(s); }        // tex holds its own reference
        }

        qsort(t, count, sizeof(double), cmp);
        double sum = 0, max = 0;
        int over50 = 0, over200 = 0;
        for (int i = 0; i < count; i++) { sum += t[i]; if (t[i] > max) max = t[i];
                                          if (t[i] > 50) over50++; if (t[i] > 200) over200++; }
        printf("made %d, failed %d\n", made, failed);
        printf("  min    %8.2f ms\n", t[0]);
        printf("  median %8.2f ms\n", t[count / 2]);
        printf("  p90    %8.2f ms\n", t[(int)(count * 0.90)]);
        printf("  p99    %8.2f ms\n", t[(int)(count * 0.99) < count ? (int)(count * 0.99) : count - 1]);
        printf("  max    %8.2f ms\n", max);
        printf("  mean   %8.2f ms\n", sum / count);
        printf("  >50ms: %d   >200ms: %d\n", over50, over200);
        if (keep) printf("  holding %lu surfaces\n", (unsigned long)[alive count]);
        return 0;
    }
}
```

### `tools/shaderbench.m` — Guest: shader compilation microbenchmark

```objc
// shaderbench.m — measure the first-use shader cost through the translator.
//
// The pipeline is Metal -> AIR -> SPIR-V -> NVK/NAK -> GPU, and the plugin caches
// each stage (aircache / spvcache / linkcache). A cache MISS pays the full
// translation + compile. That is a one-time cost per distinct shader, which is
// the shape of "the first drag stalls for ~0.5 s, then it is smooth".
//
// Usage: shaderbench <count> [compute|render]
//   Each iteration compiles a DISTINCT shader (a varying constant), so every one
//   is a guaranteed cache miss. Timings are per compile.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <mach/mach_time.h>

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}
static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int count = argc > 1 ? atoi(argv[1]) : 20;
        int render = argc > 2 && !strcmp(argv[2], "render");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no device\n"); return 1; }
        printf("device: %s   mode: %s   n=%d\n", [[dev name] UTF8String],
               render ? "render" : "compute", count);

        double *t = calloc(count, sizeof(double));
        int ok = 0, fail = 0;

        for (int i = 0; i < count; i++) {
            double t0 = now_ms();
            NSError *__autoreleasing err = nil;
            NSString *src;

            if (!render) {
                // Distinct compute kernel per iteration -> cache miss every time.
                src = [NSString stringWithFormat:
                    @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "kernel void k(device float*o, uint i[[thread_position_in_grid]]){"
                     "  float x = (float)i * %d.0f;"
                     "  for (int j=0;j<8;j++) x = fma(x, 1.0001f, %d.0f);"
                     "  o[i] = x; }\n", i + 1, i + 3];
            } else {
                // Distinct fragment shader -> the shape the compositor uses.
                src = [NSString stringWithFormat:
                    @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "struct V { float4 p [[position]]; float2 uv; };\n"
                     "fragment float4 f(V in [[stage_in]], texture2d<float> t [[texture(0)]],"
                     " sampler s [[sampler(0)]]) {"
                     "  float4 c = t.sample(s, in.uv);"
                     "  return c * %d.0f + %d.0f; }\n", (i % 7) + 1, (i % 5) + 1];
            }

            id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
            if (!lib) { fail++; t[i] = now_ms() - t0; continue; }
            id<MTLFunction> fn = [lib newFunctionWithName:render ? @"f" : @"k"];
            if (!fn) { fail++; t[i] = now_ms() - t0; continue; }

            id obj = render
                ? (id)[dev newRenderPipelineStateWithDescriptor:
                        ({ MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                           d.vertexFunction = fn; d.fragmentFunction = fn;
                           d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; d; })
                                             error:&err]
                : (id)[dev newComputePipelineStateWithFunction:fn error:&err];
            if (!obj) { fail++; t[i] = now_ms() - t0; continue; }

            t[i] = now_ms() - t0;
            ok++;
        }

        qsort(t, count, sizeof(double), cmp);
        double sum = 0, max = 0; int over100 = 0;
        for (int i = 0; i < count; i++) { sum += t[i]; if (t[i] > max) max = t[i]; if (t[i] > 100) over100++; }
        printf("compiled %d, failed %d\n", ok, fail);
        printf("  min    %8.1f ms\n", t[0]);
        printf("  median %8.1f ms\n", t[count / 2]);
        printf("  p90    %8.1f ms\n", t[(int)(count * 0.9)]);
        printf("  max    %8.1f ms\n", max);
        printf("  mean   %8.1f ms\n", sum / count);
        printf("  >100ms: %d\n", over100);
        return 0;
    }
}
```

### `scripts/setup-macos.sh` — Host: idempotent domain/disk setup

```bash
#!/usr/bin/env bash
# Provision the macOS guest's storage and register the domain with libvirt.
#
#   sudo ./setup-macos.sh [path/to/domain.xml]
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
# Which domain definition to register. Defaults to the install-phase config
# from this repo; pass the passthrough one once macOS is installed.
DOMAIN_XML="${1:-$HERE/../config/macos-install.xml}"

[ "$(id -u)" -eq 0 ] || { echo "STOP: run with sudo" >&2; exit 1; }

echo "== 1. guest disk"
# Ownership: if your host generates qemu.conf from a configuration
# manager, libvirt may refuse a domain whose files it does not own.
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
```

---

## Credits and provenance

* [NullMoth nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver) — the
  driver itself, and the author answered questions during this work.
* [OSX-KVM](https://github.com/kholia/OSX-KVM) — OpenCore packaging, the recovery-image
  tooling, and the boot script whose commented-out line turned out to be the fix.
* The [Arch Wiki PCI passthrough](https://wiki.archlinux.org/title/PCI_passthrough_via_OVMF)
  article — the standard reference for section 3 and section 4.

Every figure in this guide is measured, except where it is explicitly labelled an
inference. Section 11.2 is the substantive example: the driver exposes no counter for
parked bytes, so the claim that they consume the budget is derived from the refusal
condition rather than read from a counter, and it says so.
