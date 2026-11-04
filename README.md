<p align="center">
  <img src="logo.jpg" alt="ChargeBypassCap logo" width="360">
</p>

# ChargeBypassCap

[![Release](https://img.shields.io/github/v/release/9M2PJU/ChargeBypassCap?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap/releases)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square)](LICENSE)
[![KernelSU](https://img.shields.io/badge/KernelSU-module-green?style=flat-square)](https://kernelsu.org)
[![Platform](https://img.shields.io/badge/platform-Android%2015%2B-lightgrey?style=flat-square)](https://github.com/9M2PJU/ChargeBypassCap)

[![Buy Me A Coffee](https://cdn.buymeacoffee.com/buttons/default-orange.png)](https://buymeacoffee.com/9m2pju)

Userspace adjustable charge cap for Sakata kernel. No kernel source needed, no app needed - set the cap in the module WebUI (Open button).

> **Two variants exist - pick yours:** this repo is for **POCO F7 (onyx)** on Sakata(X) kernels (drives `smart_night`). For **POCO X3 Pro (vayu)** on RE404 (drives `input_suspend`), use [ChargeBypassCap-PMI](https://github.com/9M2PJU/ChargeBypassCap-PMI). Same daemon logic, different node.

## Why

The built-in 80% Battery protection limit does not work on this combination:
POCO F7 with the SakataX kernel. Enabling it does not cap charging at 80%.
It freezes charging completely, at whatever charge level the battery happens
to be at. (Measured on xiaomi.eu + older SakataX; the phone has since moved
to the CN base with SakataX 6.6.144, where the limiter has not been
re-tested - with the module as sole decider there is no reason to.)

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
polls the battery every 60 seconds while the cable is plugged in
(CAP = your WebUI setting, 50-100%, default 80):

| Battery | State | Action |
| --- | --- | --- |
| Reaches CAP while charging | Normal | Write `1`: hold at CAP, phone runs off the cable |
| Sinks to CAP-2 while suspended | Holding | Write `0`: charging resumes |
| Deadband between, or 100% trickle | Either | Left alone (deadband) |
| Fresh plug-in below CAP, stuck suspended | Suspended | Write `0`: plug in means intent to charge |
| Holding, but current flows past grace period | Holding | You released it manually: latch override till unplug (but see Reboots: external clears within 10 min of start are re-asserted) |
| Reboot with cable in above CAP | Booting | Hammer node to `1` till it sticks, 5-min grace; re-assert if cleared within 10 min of start (v1.10) |
| Unplugged | Any | Clear session state; next plug starts capped again |

The 2% gap between engage and release stops the switch from flapping. The
daemon never touches ROM Battery protection: leave that on Charge fully so
the broken built-in limiter never engages.

### Reboots (fixed in v1.10)

2026-11-04, POCO F7: kernel-flash reboots overnight exposed an adopt bug.
A reboot resets the kernel node to 0, but the daemon trusted the stale hold
and never re-wrote it. One poll later the resumed charge current looked
like a manual release, latched override, and the battery went 81% to 100%
by 02:35. A first fix (single rewrite on adopt) failed in live testing:
the daemon starts before the charger stack is up, so the write was lost
and late charger init cleared the node minutes later. v1.10 hammers the
write until it reads back stuck (5-minute grace) and re-asserts any node
clear within 10 minutes of start instead of yielding. Verified across
three reboot cycles with cable in: one re-assert, then steady 0 mA hold,
zero false overrides.

### ROM Battery protection modes

| ROM mode | With this module |
| --- | --- |
| Charge fully | Use this. The module is the sole decider; verified working. |
| 80% limit | Never use. Measured broken: freezes all charging at any level (0 mA at 44% and 50%) through the same voter the module drives. |
| Intelligent / smart | Not recommended. Its top-up resume current disarms the module through the same branch as the reboot bug (override till unplug), and its hold-then-top-up behavior is unverified on this stack. |

None of these matter while the phone is powered off. Offline charging
goes to 100% no matter what, so unplug before a scheduled shutdown if
you want to wake at the cap.

How they interact, in detail: the module and the ROM limiter share one
kernel voter (`soc_limit` in the MCA buck-charger driver). The module
holds by voting suspend; the ROM 80% limit votes suspend too, but its
implementation on this stack freezes charging at whatever level the
battery happens to be at, so the two cannot cooperate - the module can
never release a ROM-held freeze. Intelligent charging is subtler: while
it holds, both sides agree and nothing happens, but the moment it
resumes current for its morning top-up, the module (holding, no OVERRIDE
file) reads it as a manual release and latches override till unplug -
the cap stands down and the phone finishes to 100%. v1.10 only
re-asserts such clears within 10 minutes of boot; a 6am top-up still
disarms it. Recommended setup, verified live: ROM on Charge fully,
module cap at 80%, cable out before any scheduled shutdown.

### MIUI ROM toggles

The sister module's phone (POCO X3 Pro, MIUI 14) has its own two toggles
and findings - documented in the
[ChargeBypassCap-PMI](https://github.com/9M2PJU/ChargeBypassCap-PMI) README.

## Safety

The module only votes suspend/resume through the kernel's own bypass
switch - the same node Sakata's bypass app drives, same values. It has
no path to voltage or current: float voltage, fast-charge current,
JEITA temperature derating, and OVP/OCP/thermal shutdown stay enforced
by the PMIC hardware and lower driver layers no matter what the module
writes, so overvoltage/overcurrent via this module is not possible.
Every stuck state is safe: node stuck at 1 = phone runs off the cable
(a designed mode); stuck at 0 = ordinary charging; daemon crash = the
node just stays put. Sysfs is written only on state transitions (60s
polls, 2% engage/release gap, bounded boot hammer), a few transitions a
day - no relay-chatter on the FETs. Measured on the author's phone:
battery health Good, zero charger fault/OVP/OCP/JEITA events in the
kernel log across months of use. Every bug found so far produced
overcharge to 100% (a longevity nit), never an unsafe electrical state.
One caveat: after a kernel update, glance at the log once - a kernel
that repurposes the node would silently neuter the cap, not damage
anything.

## Live status

The module description in the KernelSU manager always shows the live state,
rewritten by the daemon every poll:

| Display | Meaning |
| --- | --- |
| 🔋 charging 76% | Filling normally, cap engages at your setting |
| ⛔ bypass ON, holding 88% | Resting at the cap, phone on cable power |
| 🔓 override till unplug (92%) | Heading to 100%, auto-resets on unplug |
| ⏸ idle | Suspended by your own hand, daemon leaving it alone |
| 🔌 unplugged | Daemon idle |

## Installation

**KernelSU-Next manager (recommended):**
Modules > Install from storage > pick the release ZIP from the
[releases page](https://github.com/9M2PJU/ChargeBypassCap/releases). Reboot.

**Manual (adb, root):**
copy this repository's files to `/data/adb/modules/chargebypasscap/`,
`chmod 755 service.sh bypasscap.sh action.sh uninstall.sh`, reboot.

Verify: `su -c 'tail /data/adb/chargebypasscap/cap.log'` should show the
daemon starting, and the module description shows live status.

## Usage

**Set your cap:** tap the module **Open** button. A settings page shows live
status plus a slider (50-100%, default 80): pick when bypass triggers on,
tap Save. Charging resumes 2% below the cap. No reboot needed.

Do nothing day to day: plug in, it caps at your setting.

**Travel-day full charge:** tap the module **action button** once. It
releases bypass and latches override till unplug. Tap it again to resume the
cap (it re-holds within ~60s if at cap+ and charging). The button also prints
battery state, daemon PID, and recent log.

## Requirements

- Root with boot-script support (KernelSU-Next tested; Magisk/APatch should work
  since `service.sh` is a plain boot script).
- A Sakata kernel exposing the bypass node above. Without it, the daemon
  writes into the void: it then sees current still flowing after its own
  write and latches override (fails safe, but the cap will not work).
- The Sakata bypass app is OPTIONAL: it writes the same node, so its tile
  remains usable as a manual backup (last writer wins; the daemon leaves
  manually-suspended states alone, so the two do not fight).
- HyperOS is NOT required. Nothing here is MIUI-specific. Any AOSP-based ROM
  on onyx with a bypass-capable Sakata kernel should work; tested on the CN
  base OS3.0.306.0 with SakataX 6.6.144 (earlier builds on xiaomi.eu).
- Wired charging only (the wireless path is untested).

## Audit report (2026-10-29, v1.7.1 on POCO F7)

Method: live checks on the author's phone (POCO F7, xiaomi.eu + SakataX,
module installed from the v1.7.1 release ZIP) plus a full read of all four
scripts. Every check below was run, not inferred.

Live checks, all passed:

- Single daemon: one `sh .../bypasscap.sh` process (PPID 1, RSS ~1.3 MB).
  No twins, no strays in `service.d`.
- Installed files match the repo: `bypasscap.sh`, `service.sh`,
  `action.sh`, `uninstall.sh` are md5-identical to v1.7.1. `module.prop`
  differs only in the live `description=` status line (by design).
- Permissions: all four scripts `755`.
- Node control: `/sys/class/xm_power/charger/smart_charge/smart_night`
  written `0 -> 1 -> 0` directly, each read back correctly (cable
  unplugged, daemon state untouched by the test).
- Action button: tapped ON then OFF. Override latched and cleared
  correctly, status output accurate, no leftover state files.
- Idle footprint: daemon wakes every 60 s, reads three sysfs files, sleeps.
  No log writes and no node writes while unplugged.
- Log (`cap.log`): only plug-in, cap-engage and start lines. No errors,
  no crash loops.
- `uninstall.sh`: kills the daemon by its exact module path and removes
  only `/data/adb/chargebypasscap`. Verified by reading, not executed.

Bugs found and fixed during this audit:

- Twin daemons: the v1.0 tile-tapping daemon
  (`/data/adb/service.d/bypasscap.sh`) was still launching at every boot
  next to the module daemon, both driving charging control. Killed both,
  deleted the legacy script and its dead state dir. One daemon since.
- Dead action button: `action.sh` shipped `644`, the manager could not
  execute it (`Permission denied`). Fixed on device, then fixed in git:
  all scripts are `755` from v1.7.1 on.

Minor nits (cosmetic, no behavior change, left as-is):

- Boot log lines use two names: `bypasscap started ...` in the
  adopt-existing-hold branch vs `chargebypasscap started ...` in the
  normal branch.

Verdict: healthy. One resident process, bounded writes (one sysfs node
plus its own state dir), fails safe (a kernel that ignores the node lands
in override, never in a bootloop), clean uninstall.

### Resource usage (measured 2026-10-29, unplugged, screen off)

- Memory: one process, VmRSS 1248 KB (~1.2 MB). State dir 12 KB total
  (`cap.log` capped at 200 lines, currently 524 B).
- CPU: 0.14 s (self plus forked helpers) over an 80.6 s window covering
  ~1.3 polls, i.e. about 0.1 s per 60 s poll, 0.17% of one core.
  Lifetime average since daemon start: 0.16%. Per poll it forks ~6
  helpers (`cat` x3, `rm`, `grep`+`sed` for the status line) and sleeps;
  ~50 voluntary context switches per poll, each microseconds.
- Sleep state: parked in `rt_sigsuspend` (inside `sleep 60`) between
  polls. Holds no wakelocks, registers no alarms, writes nothing while
  unplugged.
- Bottom line: below anything the battery stats can attribute. Any
  single user app wakes the phone orders of magnitude more.

## Audit report (2026-11-04, v1.11 code on POCO F7)

Full re-audit after the v1.10 reboot fix, all paths exercised live.
Verdict: healthy, no code changes needed.

- **Files:** all four scripts md5-identical to the release. One fix
  applied on device: `action.sh`, `service.sh`, `uninstall.sh` were
  `644` installed (repo ships `755`) - the manager action button needs
  the exec bit, so they were chmodded to `755`. Future installs from
  the repo/zip are unaffected.
- **Daemon:** single instance (PID 6377), RSS 1244 KB (matches October),
  CPU below `/proc` tick resolution across 15+ min windows - same
  ~0.1 s/poll class as measured before. No duplicate daemons.
- **Paths verified live:** plug-in detect; adopt + hammer across a
  reboot with cable in; one `re-asserting hold` against late charger
  init; engage from a real 1.28 A charge state (`cap=100 charging ->
  bypass ON`, 0 mA after); action-button release (override latched,
  1.5 A flows, daemon hands-off for 75 s, outputs accurate); action
  clear + automatic re-hold within one poll; node driven 1 -> 0 -> 1.
- **13:49 manual-OFF:** user cable juggling (unplug/replug), which
  clears the node via charger renegotiation. Benign and correctly
  classified; within 10 min of boot v1.10 would have re-asserted it.
- **Measurement note:** frozen `/proc` CPU counters plus the
  -500000 engage threshold can mimic a stuck daemon (a charger
  delivering under threshold reads as idle deadband, correctly
  silent). The plug-event log line is the ground-truth liveness check,
  and it fired on cue.
- **Not exercised this round:** resume-from-hold at CAP-2 (battery
  never left 100%), full-rate pump hold at 5 A+.
- **Manager on this phone:** KernelSU-Next (X3 Pro uses KowSU).

## Files

- `service.sh` - started by KernelSU-Next on boot, launches the daemon detached.
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
