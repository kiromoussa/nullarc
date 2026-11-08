# strix-collect

Hardware profile and amdgpu register traces for porting nullarc from Phoenix (780M, gfx1103) to
Strix Point (890M, gfx1150) on an ASUS ROG Zephyrus G16 GA605WI (Ryzen AI 9 HX 370).

| Step | Command | Needs reboot | Touches disks |
|---|---|---|---|
| 1. profile | `sudo bash collect.sh` | no | no (read-only) |
| 2. gfx trace | boot with `modprobe.blacklist=amdgpu`, `sudo bash trace.sh gfx` | yes | no |
| 3. display trace | boot again with the same cmdline, `sudo bash trace.sh dc` | yes | no |

The cmdline change is a one-off edit in the bootloader menu (press `e`), not a permanent setting.
Text output is scrubbed of serials, UUIDs and MACs. Review `acpi/*.bin` before publishing anything.
