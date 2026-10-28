#!/system/bin/sh
# KernelSU service script: started as root on every boot (late_start).
# Fully detaches the daemon so the boot sequence (or adb shell) never hangs.
MODDIR=${0%/*}
nohup sh "$MODDIR/bypasscap.sh" >/dev/null 2>&1 < /dev/null &
