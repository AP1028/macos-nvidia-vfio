# Findings for the driver author

Defects and requests for
[nullmoth/nvidia-macos-driver](https://github.com/nullmoth/nvidia-macos-driver), found
while getting a passed-through NVIDIA GPU working in a QEMU/KVM macOS 15 guest.

## Read this first: which findings still apply

**Many of these were measured while the GPU was stuck on guest bus `0x00` with a 256 MB
BAR and a 192 MB VRAM budget.** That was not a macOS requirement — it was the consequence
of one QEMU property being left at its default, so macOS would not resource a device
behind a PCIe root port. With the GPU behind a root port and

```
-global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off
```

the driver places a 16 GiB BAR, the budget becomes 8 GiB, and several of the old findings
stop reproducing. **Treat the two groups differently:**

| # | finding | era | status now |
|---|---|---|---|
| 1 | boot-hold cap expires before the auto-go | 256 MB | **likely gone** — the placement succeeds now, so the timing collision may not arise. Re-check before acting. |
| 2 | `nvmtl-allow.txt` rung order | any | **still valid** — an independent config bug |
| 3 | WindowServer saturates a core to composite | 192 MB | **re-check** — plausibly budget pressure, not a driver defect |
| 4 | no lower refresh rate published | any | **still valid** |
| 5 | resolution change wedges the display, and panicked once | any | **still valid** — reproduced at 16 GiB |
| 6 | shipped `nvrm610.conf` throttled the compositor 3-4x | 192 MB | **withdrawn as a finding** — the shipped values are correct with a real BAR; the throttle was the 192 MB budget |
| 7 | a 256 MB BAR leaves ~13 MB of headroom | 256 MB | **obsolete** — not the configuration any more |
| 8 | `NVMTL_HWPOOL=1` panics | any | **still valid** — do not enable |
| 9 | `gParkedForever` leaks the budget permanently | any | **still valid, and worse with a big budget** — quantified in 13 |
| 10 | BAR table depends on `IODeviceMemory` descriptors | 256 MB | **latent** — no longer blocking, but the hardening suggestion stands |
| 11 | "a ≥4 GiB BAR is unusable in a VM" | 256 MB | **RETRACTED** — corrected in place below |
| 12 | scanout binding survives a display-mode transition | **current (16 GiB)** | **THE MOST SERIOUS — breaks the session** |
| 13 | park leak consumes the budget (quantified) | **current (8 GiB)** | **still valid** |
| 14 | Metal → SPIR-V translation dominates runtime | **current** | **still valid** |
| 15 | `NVRM.kext` not buildable from public sources | **current** | **still valid** — blocks fixes for 12-14 |

Findings 1-11 come from driver 1.0.1. Findings 12-15 come from 1.0.9 in the configuration
where the driver works.

Values are measured unless labelled as inference. The one worth flagging is the ~7.9 GiB
parked-bytes figure in finding 13, derived from the refusal condition because no counter
exposes it.

---

<details open>
<summary><b>1 — the 40 s boot-hold cap expires before the 100 s auto-go</b> <i>[256 MB era — may no longer reproduce]</i></summary>

The display never arms with WindowServer up, making the Metal desktop unreachable, i.e.
the README's *"your NVIDIA card drives the display"* case fails. A timing collision
between the cap and the auto-go delay. Workaround as used here: a boot-arg that settles
the timing (`nvrmsettle=15000`), no longer needed now the BAR placement succeeds.
</details>

<details>
<summary><b>2 — <code>nvmtl-allow.txt</code> ships with its WindowServer rule unreachable</b> <i>[era-independent]</i></summary>

The allow-list is evaluated in rung order, so the shipped "everyone" rung shadows the
`-Name denies` rung. Reorder, or document the precedence — the file reads as though the
deny applies.
</details>

<details>
<summary><b>3 — WindowServer saturates a core to composite</b> <i>[192 MB era — re-check]</i></summary>

Compositing alone consumes a full core. Better once the BAR was real; worth re-measuring.
</details>

<details>
<summary><b>4 — no lower refresh rate is published at the native resolution</b> <i>[era-independent]</i></summary>

Only 165 Hz at 3440x1440. No way to pick a lower rate, which would help when the
translator is the bottleneck.
</details>

<details>
<summary><b>5 — changing resolution wedges the display, and is the context of a KERNEL PANIC</b> <i>[era-independent]</i></summary>

A resolution change is destructive and the same code path panicked. See the manual's
"Display modes" section.
</details>

<details>
<summary><b>6 — the shipped <code>nvrm610.conf</code> throttled the compositor by 3-4x</b> <i>[192 MB era — WITHDRAWN]</i></summary>

`NVMTL_VRAM_WS_NONIMAGE_MB=0` / `HEADROOM_MB=256` / `RES2_WS=0` starved it: dragging ran
at 16-21 fps instead of 58-80. **A symptom of the 192 MB budget** — with a real BAR the
shipped values are correct and no workaround is needed.
</details>

<details>
<summary><b>7 — a 256 MB BAR leaves the compositor ~13 MB of headroom</b> <i>[256 MB era — OBSOLETE]</i></summary>

Consequence of the small budget; no longer applicable with a 16 GiB BAR.
</details>

<details>
<summary><b>8 — <code>NVMTL_HWPOOL=1</code> installs private pool classes and correlates with a panic</b> <i>[era-independent]</i></summary>

Do not enable.
</details>

<details>
<summary><b>9 — <code>gParkedForever</code> leaks the VRAM budget permanently</b> <i>[era-independent, and worse with a large BAR]</i></summary>

Until nothing can allocate. Quantified as Finding 13 below.
</details>

<details>
<summary><b>10 — the BAR table depends on IODeviceMemory descriptors, so a >4G BAR silently disables it</b> <i>[256 MB era — latent only]</i></summary>

`bars[FB]` becomes BAR3 and `go(2) failed`. **Suggested hardening:** read the BAR *size*
from the Resizable BAR capability (which works at every size) and fall back to probing
`configRead32(0x10 + 4*bar)` when no descriptor matches. **The "256 MB is the only value
that works" advice attached to this finding is superseded.**
</details>

<details>
<summary><b>11 — <code>&gt;= 4 GiB BAR is unusable in a VM</code> — SUPERSEDED</b> <i>[RETRACTED]</i></summary>

**A large BAR works in a VM.** The blocker was never the BAR size: macOS would not
resource the device behind a root port, so the GPU sat on bus 0 and `placeLargeBar1()`
failed with `bar1: parent root port not found`. Fix that (one QEMU property) and a 16 GiB
BAR is placed successfully with an 8 GiB budget. The original measurements remain accurate
*for a GPU on bus 0*: 8 GiB → QEMU died with a non-canonical address
(`0x8408400000000000`); 4 GiB → macOS assigned above 4G with no descriptor published. That
8 GiB crash no longer occurs either, because macOS now programs a sane address instead of
garbage — it never generates one when the device is resourced normally.
</details>

<details open>
<summary><b>12 — the scanout binding survives a display-mode transition (breaks the session)</b> <i>[CURRENT — most serious]</i></summary>

The only defect that makes the machine unusable, and the only one needing a workaround to
use at all. See "Known bugs" §1 for the symptom progression, the four hypotheses falsified
by measurement, and the author's own comment naming the remedy.

**Request:** a way to re-bind the scanout without restarting the WindowServer — an
`nvrmctl` subcommand, or a sysctl that forces a re-bind — would turn a session-breaking
bug into a recoverable one.
</details>

<details open>
<summary><b>13 — the park leak eventually consumes the entire budget (quantified)</b> <i>[CURRENT]</i></summary>

Mechanism and measurements in "Known bugs" §2. **Two requests:**

1. **Expose `gVramParkedBytes` as a sysctl.** There is no way to read it today; the
   ~7.9 GiB figure is *inferred* from the refusal condition. Diagnosing this needs the
   counter.
2. **Release parked allocations** when the console/scanout surface they overlap is gone,
   or stop charging them against every later grant.
</details>

<details>
<summary><b>14 — Metal → SPIR-V translation dominates runtime</b> <i>[CURRENT]</i></summary>

2338 of ~2500 samples in `nvmtl_translate` vs 85 in `Render`. **Request:** a persistent
on-disk pipeline cache. The world-load stall is the visible symptom; the steady-state cost
is what keeps frame rates low.
</details>

<details open>
<summary><b>15 — <code>NVRM.kext</code> cannot be built from public sources</b> <i>[CURRENT]</i></summary>

Reported because it blocks third-party fixes for Findings 12-14. Three independent gaps,
each verified:

1. **No build script compiles the kexts.** `build/` emits only NVAccel, NVRMAGDC, the
   plugin, the translator and NVK. `kexts/NVRM/rmcc.py:6` references `build-nvrm.sh`,
   which is not in the tree.
2. **Public `open-gpu-kernel-modules` 610.57.04 has no Darwin support.** `grep -ri darwin`
   → zero hits; `nvport/debug.h` reaches `#error "Unsupported target OS"`; and
   `make TARGET_OS=Darwin` exits 0 while writing an **ELF** object (magic `7f 45 4c 46`).
3. **Unpublished artifacts required** — `build-nvrm.sh`, `libnvkernel.a`,
   `$NV/_out/Darwin_x86_64/compile_cmds.sh`. `accel_build.sh` exits 1 against a clean
   clone; `grep -r compile_cmds` in the public tree returns nothing.

**Additionally:** `destroyScanoutResource` and `setupScanout` are declared in
`kexts/NVRM/accel/iofam/IOAccelLegacyDisplayMachine.h` but are **headers only** — the
implementation is not public. So Finding 12 cannot be patched from outside even in
principle.

**Request:** publish `build-nvrm.sh`, or the Darwin port of the kernel modules, or
`libnvkernel.a`.
</details>

---
