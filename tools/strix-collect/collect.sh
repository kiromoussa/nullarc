#!/bin/bash
# Stage 1 (read-only, no reboot): hardware profile for porting nullarc to Strix Point
# (Ryzen AI 9 HX 370 / Radeon 890M, GC 11.5.0) on an ASUS ROG Zephyrus G16 GA605WI.
# Run from the normal Linux boot, with amdgpu loaded:   sudo bash collect.sh [outdir]
# Output: <outdir> and <outdir>.tar.zst. Serials, UUIDs and MACs are scrubbed from text files.
set -u
[ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

HOME_DIR=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
OUT=${1:-$HOME_DIR/g16-dump}
mkdir -p "$OUT"/{acpi,gpu,sys,boot,input}
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

run() { local f=$1; shift; { "$@" 2>&1 || true; } > "$OUT/$f"; }   # run <outfile> <cmd...>

# ---- locate the amdgpu iGPU ------------------------------------------------
DEV=""
for c in /sys/class/drm/card[0-9]*; do
  d=$(readlink -f "$c/device")
  [ "$(cat "$d/vendor" 2>/dev/null)" = "0x1002" ] && [ "$(basename "$(readlink -f "$d/driver" 2>/dev/null)")" = "amdgpu" ] && { DEV=$d; CARD=$(basename "$c"); break; }
done
if [ -z "$DEV" ]; then echo "WARN: no amdgpu device bound; GPU section skipped (is amdgpu blacklisted?)"; fi
BDF=${DEV:+$(basename "$DEV")}

# ---- ACPI -----------------------------------------------------------------
for f in /sys/firmware/acpi/tables/* /sys/firmware/acpi/tables/dynamic/*; do
  [ -f "$f" ] && cp "$f" "$OUT/acpi/$(basename "$f").bin"
done
if command -v iasl >/dev/null; then
  (cd "$OUT/acpi" && for f in *.bin; do iasl -d "$f" >/dev/null 2>&1; done)
else
  echo "note: iasl not installed (sudo pacman -S acpica) - skipped .dsl decompile" > "$OUT/acpi/NOTE.txt"
fi

# ---- GPU ------------------------------------------------------------------
if [ -n "$DEV" ]; then
  run gpu/lspci.txt lspci -vvnn -s "$BDF"
  cp "$DEV/resource" "$OUT/gpu/resource.txt" 2>/dev/null
  for a in vendor device subsystem_vendor subsystem_device revision vbios_version \
           mem_info_vram_total mem_info_vis_vram_total mem_info_gtt_total \
           current_link_speed current_link_width power_dpm_force_performance_level; do
    [ -r "$DEV/$a" ] && echo "$a: $(cat "$DEV/$a")" >> "$OUT/gpu/sysfs_attrs.txt"
  done
  # sysfs IP discovery tree (kernel >= 6.5): die/ip hw_id, instance, version, base addrs
  if [ -d "$DEV/ip_discovery" ]; then
    find "$DEV/ip_discovery" -type f -readable 2>/dev/null | sort | while read -r f; do
      echo "${f#"$DEV"/}: $(cat "$f" 2>/dev/null | tr '\n' ' ')"
    done > "$OUT/gpu/ip_discovery_sysfs.txt"
  fi
  N=${CARD#card}
  DBG=/sys/kernel/debug/dri/$N
  for a in amdgpu_firmware_info amdgpu_gca_config amdgpu_pm_info amdgpu_gpu_recover \
           amdgpu_vram_mm amdgpu_sensors amdgpu_dm_visual_confirm amdgpu_dm_dtn_log; do
    [ -r "$DBG/$a" ] && cp "$DBG/$a" "$OUT/gpu/$a.txt" 2>/dev/null
  done
  [ -r "$DBG/amdgpu_vbios" ] && cp "$DBG/amdgpu_vbios" "$OUT/gpu/vbios.bin"
  # raw IP discovery table: sits in the last 64 KiB of (carved-out) VRAM on APUs; best effort
  if [ -r "$DBG/amdgpu_vram" ] && [ -r "$DEV/mem_info_vram_total" ]; then
    vt=$(cat "$DEV/mem_info_vram_total")
    dd if="$DBG/amdgpu_vram" of="$OUT/gpu/vram_top64k.bin" bs=4096 \
       skip=$(( (vt - 65536) / 4096 )) count=16 2>/dev/null
  fi
  # connectors + panel EDID (serial bytes 12-15 zeroed)
  for c in /sys/class/drm/${CARD}-*; do
    n=$(basename "$c")
    { echo "status: $(cat "$c/status" 2>/dev/null)"; echo "enabled: $(cat "$c/enabled" 2>/dev/null)"; cat "$c/modes" 2>/dev/null; } > "$OUT/gpu/$n.txt"
    if [ -s "$c/edid" ]; then
      cp "$c/edid" "$OUT/gpu/$n.edid"; printf '\0\0\0\0' | dd of="$OUT/gpu/$n.edid" bs=1 seek=12 conv=notrunc 2>/dev/null
    fi
  done
fi
run gpu/all_gpus.txt lspci -nnk -d ::0300
run gpu/all_gpus_3d.txt lspci -nnk -d ::0302
run gpu/drm_cards.txt bash -c 'for c in /sys/class/drm/card*; do echo "$c -> $(readlink -f $c/device)"; done'
# panel route: hybrid mux / dGPU switches exposed by asus-wmi
run gpu/asus_wmi.txt bash -c 'for a in gpu_mux_mode dgpu_disable egpu_enable panel_od mini_led_mode; do f=/sys/devices/platform/asus-nb-wmi/$a; [ -r $f ] && echo "$a: $(cat $f)"; done'
run gpu/backlight.txt bash -c 'for b in /sys/class/backlight/*; do echo "$b: type=$(cat $b/type) max=$(cat $b/max_brightness) cur=$(cat $b/actual_brightness 2>/dev/null)"; done'
run gpu/firmware_files.txt bash -c 'ls -la /usr/lib/firmware/amdgpu 2>/dev/null | grep -E "gc_11_5|psp_14|smu_14|dcn_3_5|sdma_6_1|vcn_4_0_5|mes_11_5|imu_11_5|sdma_6_1" ; pacman -Q linux-firmware linux-firmware-amdgpu 2>/dev/null'

# ---- system / platform ------------------------------------------------------
run sys/uname.txt uname -a
run sys/os_release.txt cat /etc/os-release
run sys/cmdline.txt cat /proc/cmdline
run sys/lscpu.txt lscpu
run sys/cpuinfo_cpu0.txt sed -n '1,/^$/p' /proc/cpuinfo
run sys/lspci_all.txt lspci -nnk
run sys/lspci_tree.txt lspci -tv
run sys/lsusb.txt lsusb
run sys/lsmod.txt lsmod
run sys/dmesg.txt dmesg
run sys/dmidecode.txt bash -c 'dmidecode -t bios -t system -t baseboard -t processor -t memory | grep -viE "serial|uuid|asset tag|wake-up"'
run sys/iommu.txt bash -c 'ls /sys/class/iommu; dmesg | grep -iE "iommu|amd-vi"'
run sys/ucode.txt bash -c 'grep -m1 microcode /proc/cpuinfo; dmesg | grep -i microcode'
run sys/i2c_devices.txt bash -c 'for d in /sys/bus/i2c/devices/*; do echo "$d: $(cat $d/name 2>/dev/null) $(cat $d/firmware_node/hid 2>/dev/null)"; done'
run sys/acpi_hids.txt bash -c 'for d in /sys/bus/acpi/devices/*; do echo "$(basename $d) hid=$(cat $d/hid 2>/dev/null) path=$(cat $d/path 2>/dev/null)"; done'
run sys/pci_net_bt.txt lspci -nnk -d ::0280
run sys/bluetooth_usb.txt bash -c 'lsusb | grep -iE "bluetooth|8087|0489|13d3"'
run sys/audio_cards.txt bash -c 'cat /proc/asound/cards; for c in /proc/asound/card*/codec#*; do echo "== $c"; head -20 "$c"; done'
run sys/sensors_thermal.txt bash -c 'for z in /sys/class/thermal/thermal_zone*; do echo "$z: $(cat $z/type) $(cat $z/temp)"; done'

# ---- input (trackpad, keyboard) ---------------------------------------------
run input/devices.txt cat /proc/bus/input/devices

# ---- boot environment (for placing OpenCore) --------------------------------
run boot/lsblk.txt lsblk -o NAME,FSTYPE,SIZE,PARTTYPENAME,MOUNTPOINTS
run boot/efibootmgr.txt efibootmgr -v
run boot/bootctl.txt bootctl status
run boot/secureboot.txt bash -c 'mokutil --sb-state; bootctl status | grep -i "secure boot"; od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null'
run boot/bootloader_files.txt bash -c 'ls -la /boot /boot/efi /efi /boot/loader 2>/dev/null; cat /boot/loader/entries/*.conf 2>/dev/null; cat /etc/default/grub 2>/dev/null'
run boot/fstab.txt cat /etc/fstab
run boot/free_space.txt bash -c 'for d in /dev/nvme?n1; do echo "== $d"; parted -s $d unit GiB print free 2>&1; done'

# ---- scrub identifiers from text files, then pack ----------------------------
find "$OUT" -type f \( -name '*.txt' -o -name '*.dsl' \) -print0 | xargs -0 sed -i -E \
  -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<uuid>/g' \
  -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/<mac>/g' \
  -e 's/([Ss]erial[^:=]*[:=] *).*/\1<scrubbed>/'
chown -R "${SUDO_USER:-root}": "$OUT" 2>/dev/null
tar -C "$(dirname "$OUT")" -cf - "$(basename "$OUT")" | { zstd -q -19 -o "$OUT.tar.zst" 2>/dev/null || xz -9 > "$OUT.tar.xz"; }
chown "${SUDO_USER:-root}": "$OUT".tar.* 2>/dev/null
echo
echo "done: $OUT  (+ archive next to it)"
echo "Files with unavoidable raw identifiers: acpi/*.bin (OEM table ids only) - review before publishing."
