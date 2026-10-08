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
# ssh has silently mangled two earlier attempts.

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
