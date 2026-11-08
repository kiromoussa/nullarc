#!/bin/bash
# Stage 2: record every MMIO read/write amdgpu does while it brings up the Radeon 890M (Strix Point).
# Based on tools/linux-trace/trace.sh, with a display (DC) pass added for the DCN 3.5 scanout path.
#
# Boot Linux ONCE with  modprobe.blacklist=amdgpu  on the kernel cmdline (edit the entry in the
# bootloader menu, press e / or add to the entry temporarily - do not make it permanent), so amdgpu is
# not loaded yet. Then, as root:
#       sudo bash trace.sh gfx     # compute/firmware bring-up, dc=0 (small trace)
#       sudo bash trace.sh dc      # display bring-up, dc=1 (large trace; run after a reboot)
# Each pass needs a fresh boot because amdgpu can only be loaded cleanly once per boot.
# Output: ~/g16-trace-<mode>/regtrace.txt.xz + dmesg.txt
set -e
MODE=${1:-gfx}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
case "$MODE" in gfx) DC=0; BUF=65536;; dc) DC=1; BUF=131072;; *) echo "usage: $0 gfx|dc"; exit 1;; esac
grep -qw amdgpu /proc/modules && { echo "amdgpu is already loaded - reboot with modprobe.blacklist=amdgpu first"; exit 1; }

HOME_DIR=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
OUT=$HOME_DIR/g16-trace-$MODE
mkdir -p "$OUT"
mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null || true
T=/sys/kernel/tracing
[ -d $T/events/amdgpu/amdgpu_device_wreg ] || { echo "kernel has no amdgpu_device_wreg tracepoint"; exit 1; }

echo 0 > $T/tracing_on
echo $BUF > $T/buffer_size_kb          # per CPU
: > $T/trace
echo 1 > $T/events/amdgpu/amdgpu_device_wreg/enable
echo 1 > $T/events/amdgpu/amdgpu_device_rreg/enable
echo 1 > $T/tracing_on
if [ $DC = 0 ]; then
  modprobe amdgpu ip_block_mask=0xffffffff dc=0 2>&1 | tail -3 || true
else
  modprobe amdgpu 2>&1 | tail -3 || true
fi
sleep 30
echo 0 > $T/tracing_on
cp $T/trace "$OUT/regtrace.txt"
dmesg > "$OUT/dmesg_full.txt"
dmesg | grep -iE "amdgpu|psp|rlc|mes|kiq|dcn|dmub|smu|imu" > "$OUT/dmesg.txt"
grep -c . "$OUT/regtrace.txt" | sed 's/^/trace lines: /'
if [ $DC = 1 ]; then   # dump live display state while amdgpu is up
  D=$(ls -d /sys/kernel/debug/dri/*/amdgpu_dm_dtn_log 2>/dev/null | head -1)
  [ -n "$D" ] && cp "$D" "$OUT/dtn_log.txt"
  for c in /sys/class/drm/card*-eDP-*; do [ -d "$c" ] && { cat "$c/modes" "$c/status"; } >> "$OUT/edp.txt" 2>/dev/null; done
fi
xz -9 "$OUT/regtrace.txt"
find "$OUT" -name '*.txt' -print0 | xargs -0 sed -i -E 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<mac>/g'
chown -R "${SUDO_USER:-root}": "$OUT"
echo "done: $OUT"
