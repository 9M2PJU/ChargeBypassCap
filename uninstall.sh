#!/system/bin/sh
# KernelSU uninstall script: stop the daemon, remove state.
pkill -f modules/bypasscap/bypasscap.sh
rm -rf /data/adb/bypasscap
