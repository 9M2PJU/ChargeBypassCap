#!/system/bin/sh
# KernelSU action button: toggle full-charge override + status readout.
# Tap once   -> override till unplug: bypass OFF, charges to 100%.
# Tap again  -> override cleared: 80% cap resumes within ~30s.
STATEDIR=/data/adb/chargebypasscap
LOG=$STATEDIR/cap.log
HOLDING=$STATEDIR/holding
OVERRIDE=$STATEDIR/override
NODE=/sys/class/xm_power/charger/smart_charge/smart_night
CAPF=/sys/class/power_supply/battery/capacity
CURF=/sys/class/power_supply/battery/current_now
USBON=/sys/class/power_supply/usb/online

cap=$(cat $CAPF 2>/dev/null)
cur=$(cat $CURF 2>/dev/null)
usb=$(cat $USBON 2>/dev/null)
pid=$(pgrep -f "modules/chargebypasscap/bypasscap" 2>/dev/null | head -n 1)

if [ -f $OVERRIDE ]; then
  rm -f $OVERRIDE
  echo "✅ Override cleared. 80% cap is active again."
  echo "If at 80%+ and charging, bypass re-engages within ~30s."
else
  touch $OVERRIDE
  rm -f $HOLDING
  if [ "$usb" = "1" ] && [ -n "$cur" ] && [ "$cur" -gt -500000 ]; then
    echo 0 > $NODE
    sleep 8
    cur=$(cat $CURF 2>/dev/null)
    echo "🔋 Bypass turned OFF. Charging to 100%."
  else
    echo "🔓 Override set till unplug. Charging to 100%."
  fi
fi
echo "---"
echo "Battery: ${cap:-?}%"
if [ "$usb" != "1" ]; then
  echo "State: unplugged (daemon idle)"
elif [ -n "$cur" ] && [ "$cur" -lt -500000 ]; then
  echo "State: charging ($cur uA)"
else
  echo "State: suspended, bus-powered ($cur uA)"
fi
if [ -f $OVERRIDE ]; then
  echo "Cap: OFF (override till unplug)"
elif [ -f $HOLDING ]; then
  echo "Cap: HOLDING at 80%"
else
  echo "Cap: armed (engages at 80%)"
fi
if [ -n "$pid" ]; then
  echo "Daemon: running (PID $pid)"
else
  echo "Daemon: NOT running"
fi
echo "--- recent log ---"
tail -n 5 $LOG 2>/dev/null || echo "(no log yet)"
