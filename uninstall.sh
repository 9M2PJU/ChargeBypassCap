#!/system/bin/sh
# KernelSU uninstall script: stop the daemon, remove state.
pkill -f modules/chargebypasscap/bypasscap.sh
rm -rf /data/adb/chargebypasscap
