#!/system/bin/sh
# bypasscap - userspace charge cap via the kernel bypass node.
# Direct sysfs control (per Sakata dev): 1 = bypass ON (suspend), 0 = OFF.
# NODE=/sys/class/xm_power/charger/smart_charge/smart_night
# The daemon owns this node exclusively. The action button is the only
# supported manual control (it signals via the OVERRIDE file, which the
# daemon always honors). Anything else writing the node - app tiles,
# kernel re-inits, charger renegotiation - gets reverted within 1-2 polls.
# Behavior (always on while cable is plugged, cap adjustable in WebUI):
#   - Battery reaches CAP while charging -> writes 1 to the node.
#     Phone runs off the cable, battery rests at ~CAP.
#   - Battery falls to CAP-2 while suspended -> writes 0, charging resumes.
#   - Reboot with cable in above CAP: the hold is re-asserted (the kernel
#     node resets to 0 on boot, so adopt re-writes 1 instead of trusting it).
#   - You want 100% (travel day)? When it holds at CAP, use the action
#     button to release bypass once yourself. The daemon backs off until
#     you unplug. Next plug session the cap is active again automatically.
#     (External node writes are NOT a release path: they get re-asserted.)
#   - Plug in = intent to charge: on every fresh plug-in below CAP the
#     daemon makes sure bypass is OFF.
#   - Cap is set in the WebUI (Open button, slider 50-100%, default 80)
#     and stored in /data/adb/chargebypasscap/high. Daemon re-reads it
#     every poll, no reboot needed.
#
# Requirements: root + a Sakata kernel exposing the bypass node above.
# Runs as root from the KernelSU module service.sh at boot.
# State + log: /data/adb/chargebypasscap/cap.log

MODDIR=/data/adb/chargebypasscap
LOG=$MODDIR/cap.log
HOLDING=$MODDIR/holding
BEAT=$MODDIR/heartbeat
OVERRIDE=$MODDIR/override
HIGH_FILE=$MODDIR/high
NODE=/sys/class/xm_power/charger/smart_charge/smart_night
CAP=/sys/class/power_supply/battery/capacity
CUR=/sys/class/power_supply/battery/current_now
USBON=/sys/class/power_supply/usb/online
POLL=30
CHG_THRESH=-500000
GRACE_POLLS=4

# Adjustable cap: WebUI slider writes 50-100 into $HIGH_FILE.
# LOW (resume level) is always HIGH-2 to stop flapping.
read_high() {
  h=$(cat $HIGH_FILE 2>/dev/null)
  case "$h" in
    ''|*[!0-9]*) h=80 ;;
  esac
  [ "$h" -lt 50 ] && h=50
  [ "$h" -gt 100 ] && h=100
  echo "$h"
}

mkdir -p $MODDIR
rm -f $HOLDING $OVERRIDE

log() {
  echo "$(date '+%m-%d %H:%M') $1" >> $LOG
  tail -n 200 $LOG > $LOG.tmp
  mv $LOG.tmp $LOG
}

is_charging() { [ "$1" -lt "$CHG_THRESH" ]; }

SCRIPTDIR=$(dirname "$0")
MODPROP=$SCRIPTDIR/module.prop
LAST_STATUS=$MODDIR/last_status

update_desc() {
  # Rewrite whenever module.prop does not already carry this exact status,
  # so external overwrites (module updates, manager edits) self-heal
  # on the next poll instead of going blind.
  want="[$1] $2"
  cur=$(grep '^description=' $MODPROP 2>/dev/null | sed 's/^description=//')
  if [ "$cur" != "$want" ]; then
    if grep -q '^description=' $MODPROP 2>/dev/null; then
      sed -i "s|^description=.*|description=$want|" $MODPROP
    fi
    echo "$1" > $LAST_STATUS
  fi
}

prev_usb=$(cat $USBON 2>/dev/null)
cap0=$(cat $CAP 2>/dev/null)
cur0=$(cat $CUR 2>/dev/null)
rm -f $OVERRIDE
HIGH=$(read_high); LOW=$((HIGH - 2))
if [ "$prev_usb" = "1" ] && [ -n "$cap0" ] && [ "$cap0" -ge "$HIGH" ] && [ -n "$cur0" ] && ! is_charging "$cur0"; then
  touch $HOLDING
  # Re-assert the hold: a reboot resets the kernel node to 0, and this code
  # runs before the charger stack is up, so hammer the write until it reads
  # back stuck (2026-11-04: late charger init cleared the node minutes
  # after a one-shot rewrite during testing).
  for i in 1 2 3 4 5 6; do
    echo 1 > $NODE 2>/dev/null
    sleep 10
    [ "$(cat $NODE 2>/dev/null)" = "1" ] && break
  done
  log "bypasscap started (adopted existing hold at ${cap0}%, cap ${HIGH}%)"
  grace=10
else
  rm -f $HOLDING
  log "chargebypasscap started (always-on ${HIGH}% cap, override via action button)"
  grace=0
fi

reassert_count=0

loop() {
  while true; do
    HIGH=$(read_high); LOW=$((HIGH - 2))
    BASE_DESC="${HIGH}% cap via bypass node. Open=set cap, Action=full charge."
    usb=$(cat $USBON 2>/dev/null)
    cap=$(cat $CAP 2>/dev/null)
    cur=$(cat $CUR 2>/dev/null)
    resisted=0

    # Fresh plug-in: intent to charge. Clear session state; reconcile below cap.
    if [ "$usb" = "1" ] && [ "$prev_usb" != "1" ]; then
      rm -f $HOLDING $OVERRIDE
      grace=0
      log "plug-in at $cap% (cap ${HIGH}%)"
      if [ -n "$cap" ] && [ "$cap" -lt "$HIGH" ] && [ -n "$cur" ] && ! is_charging "$cur"; then
        log "plug-in below $HIGH suspended -> bypass OFF"
        echo 0 > $NODE
        sleep 30
      fi
    fi
    prev_usb=$usb

    if [ "$usb" = "1" ] && [ -n "$cap" ] && [ -n "$cur" ]; then
      if [ "$grace" -gt 0 ]; then
        # Settling after our own node write: hands off.
        grace=$((grace - 1))
      elif [ -f $OVERRIDE ]; then
        : # user override latched for this plug session, do nothing
      elif [ "$cap" -ge "$HIGH" ] && is_charging "$cur"; then
        if [ ! -f $HOLDING ]; then
          log "cap=$cap charging -> bypass ON (cap ${HIGH}%)"
          echo 1 > $NODE
          touch $HOLDING
          grace=$GRACE_POLLS
          sleep 30
        else
          # Holding but current flowing past grace with no override file.
          # Nobody asked for a release (the action button always sets
          # OVERRIDE first), so every external clear is treated as hostile
          # and re-asserted - reboot clears, charger renegotiation, ROM
          # top-ups, stray app writes, all of them. Only a node that
          # resists 10 consecutive re-asserts is declared broken, and then
          # we yield so a dead switch fails safe instead of chattering.
          reassert_count=$((reassert_count + 1))
          resisted=1
          if [ "$reassert_count" -ge 10 ]; then
            log "node ineffective after 10 re-asserts -> override till unplug"
            touch $OVERRIDE
            rm -f $HOLDING
            reassert_count=0
          else
            log "external node clear -> re-asserting hold ($reassert_count/10)"
            echo 1 > $NODE 2>/dev/null
            grace=$GRACE_POLLS
          fi
        fi
      elif [ "$cap" -le "$LOW" ] && ! is_charging "$cur"; then
        if [ -f $HOLDING ]; then
          log "cap=$cap suspended -> bypass OFF (resume at ${LOW}%)"
          echo 0 > $NODE
          rm -f $HOLDING
          sleep 30
        fi
        # else: suspended below resume level by your own hand -> left alone
      else
        : # deadband, or full (100%, ~0 mA trickle): no action
      fi
    else
      # Unplugged: clear session state.
      rm -f $HOLDING $OVERRIDE
      grace=0
    fi

    # Live status: module list emoji (WebUI reads live via ksu.exec).
    if [ "$usb" != "1" ]; then
      ST="🔌 unplugged"
    elif [ -f $OVERRIDE ]; then
      ST="🔓 override till unplug (${cap:-?}%)"
    elif [ -f $HOLDING ]; then
      if [ -n "$cur" ] && is_charging "$cur"; then
        ST="⛔ re-asserting hold ${cap:-?}%"
      else
        ST="⛔ bypass ON, holding ${cap:-?}%"
      fi
    elif [ -n "$cur" ] && is_charging "$cur"; then
      ST="🔋 charging ${cap:-?}%"
    else
      ST="⏸ idle ${cap:-?}%"
    fi
    update_desc "$ST" "$BASE_DESC"

    # Heartbeat for the service.sh watchdog. Unconditional: a live daemon
    # beats every poll, plugged or not. Non-resisted polls reset the
    # consecutive re-assert counter (only sustained resistance yields).
    date +%s 2>/dev/null > $BEAT
    [ "$resisted" = "0" ] && reassert_count=0

    sleep $POLL
  done
}

loop &
