# ChargeBypassCap

[![Release](https://img.shields.io/github/v/release/9M2PJU/ChargeBypassCap?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-green?style=flat-square)](https://kernelsu.org)
[![Platform](https://img.shields.io/badge/platform-Android%2015%2B-lightgrey?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap)

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/default-orange.png)](https://buymeacoffee.com/9m2pju)

Userspace 80% charge cap for Sakata kernel. No kernel source needed, no app needed, no settings to flip.

## Why

The built-in 80% Battery protection limit does not work on this combination:
POCO F7 running HyperOS EU (xiaomi.eu) with the SakataX kernel. Enabling it
does not cap charging at 80%. It freezes charging completely, at whatever
charge level the battery happens to be at.

What actually happens, verified by measurement:

- At 44% and again at 50% state of charge, turning on the 80% limit drops
  charge current to exactly 0 mA within seconds. The battery sits frozen
  while the cable stays plugged in.
- The kernel log shows why: the `soc_limit` voter holds `chg_en: 0` at those
  levels, thirty points below the limit it is supposed to enforce.
- Switching protection to Intelligent or Charge fully restores full-rate
  fast charging immediately (5+ A). Switching back to the 80% limit freezes
  it again within seconds. The bypass app was OFF through all of this, so
  the app is not the cause. The limiter itself is broken.

So on this ROM + kernel, the stock 80% limit is unusable: it behaves as a
"never charge" switch rather than a cap. This module replaces it entirely
in userspace. It leaves ROM Battery protection alone (keep it on Charge
fully so the broken limiter never engages) and enforces a real 80% hold
itself: charge to 80, run the phone off the cable, resume at 78. The bug
itself has been reported upstream to the Sakata developer with logs.

## How it works

The Sakata kernel exposes a bypass switch in sysfs:

- `/sys/class/xm_power/charger/smart_charge/smart_night`
- Write `1`: bypass ON. Charging suspends, the phone runs off the USB cable,
  battery current drops to 0 mA. Write `0`: bypass OFF, charging resumes.

A small root daemon (`bypasscap.sh`, started at boot by `service.sh`)
polls the battery every 30 seconds while the cable is plugged in:

| Battery | State | Action |
| --- | --- | --- |
| Reaches 80% while charging | Normal | Write `1`: hold at 80, phone runs off the cable |
| Sinks to 78% while suspended | Holding | Write `0`: charging resumes |
| 79%, or 100% trickle | Either | Left alone (deadband) |
| Fresh plug-in below 80%, stuck suspended | Suspended | Write `0`: plug in means intent to charge |
| Holding, but current flows past grace period | Holding | You released it manually: latch override till unplug |
| Unplugged | Any | Clear session state; next plug starts capped again |

The 2% gap between engage and release stops the switch from flapping. The
daemon never touches ROM Battery protection: leave that on Charge fully so
the broken built-in limiter never engages.

## Live status

The module description in the KernelSU manager always shows the live state,
rewritten by the daemon every poll:

| Display | Meaning |
| --- | --- |
| 🔋 charging 76% | Filling normally, cap engages at 80% |
| ⛔ bypass ON, holding 88% | Resting at the cap, phone on cable power |
| 🔓 override till unplug (92%) | Heading to 100%, auto-resets on unplug |
| ⏸ idle | Suspended by your own hand, daemon leaving it alone |
| 🔌 unplugged | Daemon idle |

## Installation

**KernelSU manager (recommended):**
Modules > Install from storage > pick the release ZIP from the
[releases page](https://github.com/9M2PJU/ChargeBypassCap/releases). Reboot.

**Manual (adb, root):**
copy this repository's files to `/data/adb/modules/chargebypasscap/`,
`chmod 755 service.sh bypasscap.sh action.sh uninstall.sh`, reboot.

Verify: `su -c 'tail /data/adb/chargebypasscap/cap.log'` should show the
daemon starting, and the module description shows live status.

## Usage

Do nothing day to day: plug in, it caps at 80.

**Travel-day full charge:** tap the module **action button** once. It
releases bypass and latches override till unplug. Tap it again to resume the
cap (it re-holds within ~30s if at 80%+). The button also prints battery
state, daemon PID, and recent log.

## Requirements

- Root with boot-script support (KernelSU tested; Magisk/APatch should work
  since `service.sh` is a plain boot script).
- A Sakata kernel exposing the bypass node above. Without it, the daemon
  writes into the void: it then sees current still flowing after its own
  write and latches override (fails safe, but the cap will not work).
- The Sakata bypass app is OPTIONAL: it writes the same node, so its tile
  remains usable as a manual backup (last writer wins; the daemon leaves
  manually-suspended states alone, so the two do not fight).
- HyperOS is NOT required. Nothing here is MIUI-specific. Any AOSP-based ROM
  on onyx with a bypass-capable Sakata kernel should work, though only
  xiaomi.eu + SakataX has been tested.
- Wired charging only (the wireless path is untested).

## Files

- `service.sh` - started by KernelSU on boot, launches the daemon detached.
- `bypasscap.sh` - the daemon (self-backgrounds).
- `action.sh` - action button: toggles full-charge override AND prints
  instant status (battery, state, cap mode, daemon PID, recent log).
- `uninstall.sh` - stops the daemon and removes state on module removal.
- `module.prop` - metadata; its description doubles as the live status line.
- `module.yaml` - manifest for the KernelSU Modules listing.

## Logging

- State dir: `/data/adb/chargebypasscap/` (holding, override, last_status, cap.log)
- Log: `/data/adb/chargebypasscap/cap.log` - check what it did overnight.

## Credits

Bypass node documented by the Sakata kernel developer. Bug report for the
broken built-in 80% limiter filed upstream against SakataX.

## License

GPL-3.0. See LICENSE.
