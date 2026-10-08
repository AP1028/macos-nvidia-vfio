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
