# BypassCap

Userspace 80% charge cap for Sakata kernel (tested on POCO F7 / onyx,
xiaomi.eu + SakataX). No kernel source needed, no app needed.

## How it works

The Sakata kernel exposes a bypass switch in sysfs:

- `/sys/class/xm_power/charger/smart_charge/smart_night`
- Write `1` = bypass ON: charging suspends, the phone runs off the USB cable,
  battery current drops to 0 mA. Write `0` = bypass OFF: charging resumes.
- Verified by direct test: `echo 1` froze the battery at 0 mA with the bus
  live, `echo 0` resumed charging at several amps.

The module is a small root daemon that flips this switch for you:

1. `service.sh` runs at every boot as root and launches `bypasscap.sh`,
   which polls the battery every 30 seconds while the cable is plugged in.
2. Battery reaches 80% while charging -> daemon writes `1`. The phone runs
   off the cable and the battery rests at ~80%.
3. Battery sinks to 78% while suspended -> daemon writes `0`, charging resumes.
   The 2% gap stops the switch from flapping.
4. 79% deadband and the 100% trickle state are left alone.
5. Fresh plug-in below 80% with bypass stuck on -> daemon writes `0`,
   because plug in means intent to charge.
6. You release bypass yourself while the daemon is holding (action button,
   or the Sakata app tile) -> the daemon sees current flowing past its grace
   period, latches an override till you unplug, and stops fighting you.
   Next plug session the cap is active again automatically.
7. Unplug -> all session state is cleared.

The daemon also reports itself: every poll it rewrites the module
description in the KernelSU manager with a live emoji status, and appends
actions to `/data/adb/bypasscap/cap.log`.

What it does NOT do: it never touches ROM Battery protection (leave that on
Charge fully - the built-in 80% limit path is broken on this kernel and
blocks all charging at any SoC), it needs no app, no QS tile, and no settings
to flip.

## How to use

Do nothing day to day: plug in, it caps at 80. The module description in
the KernelSU manager always shows live status:

- 🔋 charging 76% - filling normally, cap engages at 80%
- ⛔ bypass ON, holding 88% - resting at the cap, phone on cable power
- 🔓 override till unplug (92%) - heading to 100%, auto-resets on unplug
- ⏸ idle - suspended by your own hand, daemon leaving it alone
- 🔌 unplugged - daemon idle

Travel-day full charge: tap the module **action button** once. It switches
bypass off and latches override till unplug. Tap it again to resume the cap
(it re-holds within ~30s if at 80%+). The button also prints battery state,
daemon PID, and recent log.

## Requirements

- Root with boot-script support (KernelSU tested; Magisk/APatch should work
  since service.sh is a plain boot script).
- A Sakata kernel exposing the bypass node above. On a kernel without it,
  the daemon writes into the void: it then sees current still flowing after
  its own write and latches override (fails safe, but the cap will not work).
- The Sakata bypass app is OPTIONAL: it writes the same node, so its tile
  remains usable as a manual backup (last writer wins; the daemon leaves
  manually-suspended states alone, so the two do not fight).
- HyperOS is NOT required. Nothing here is MIUI-specific: standard
  /sys/class/power_supply nodes and shell tools. Any AOSP-based ROM on onyx
  with a bypass-capable Sakata kernel should work, though only xiaomi.eu +
  SakataX has been tested.
- Wired charging only (the wireless path is untested).

## Install

- Via KernelSU manager: Modules > Install from storage > pick the release zip.
- Or via adb (root): copy this repo's files to `/data/adb/modules/bypasscap/`,
  `chmod 755 service.sh bypasscap.sh action.sh uninstall.sh`, reboot.
- Verify: `su -c 'tail /data/adb/bypasscap/cap.log'` should show the daemon
  starting, and the module description shows live status.

## Files

- `service.sh` - started by KernelSU on boot, launches the daemon detached.
- `bypasscap.sh` - the daemon (self-backgrounds).
- `action.sh` - action button: toggles full-charge override AND prints
  instant status (battery, state, cap mode, daemon PID, recent log).
- `uninstall.sh` - stops the daemon and removes state on module removal.
- `module.prop` - module metadata (description doubles as live status line).

## State and log

- State dir: `/data/adb/bypasscap/` (holding, override, last_status, cap.log)
- Log: `/data/adb/bypasscap/cap.log` - check what it did overnight.

## License

GPL-3.0. See LICENSE.
