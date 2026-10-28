#!/system/bin/sh
# bypasscap - userspace 80% charge cap via the kernel bypass node.
# Direct sysfs control (per Sakata dev): 1 = bypass ON (suspend), 0 = OFF.
# NODE=/sys/class/xm_power/charger/smart_charge/smart_night
# No QS tile needed; the Sakata app/tile remains usable as manual backup
# (both write the same node, last writer wins).
# Behavior (always on while cable is plugged):
#   - Battery reaches 80% while charging -> writes 1 to the node.
#     Phone runs off the cable, battery rests at ~80%.
#   - Battery falls to 78% while suspended -> writes 0, charging resumes.
#   - You want 100% (travel day)? When it holds at 80%, use the action
#     button (or the Sakata app tile) to release bypass once yourself.
#     The daemon backs off until you unplug. Next plug session the 80%
#     cap is active again automatically.
#   - Plug in = intent to charge: on every fresh plug-in below 80% the
#     daemon makes sure bypass is OFF.
#
# Requirements: root + a Sakata kernel exposing the bypass node above.
# Runs as root from the KernelSU module service.sh at boot.
# State + log: /data/adb/chargebypasscap/cap.log

MODDIR=/data/adb/chargebypasscap
LOG=$MODDIR/cap.log
HOLDING=$MODDIR/holding
OVERRIDE=$MODDIR/override
NODE=/sys/class/xm_power/charger/smart_charge/smart_night
CAP=/sys/class/power_supply/battery/capacity
CUR=/sys/class/power_supply/battery/current_now
USBON=/sys/class/power_supply/usb/online
HIGH=80
LOW=78
POLL=30
CHG_THRESH=-500000
GRACE_POLLS=3

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
WEBROOT=$SCRIPTDIR/webroot
TEMPLATE=$WEBROOT/template.html
PAGE=$WEBROOT/index.html
LASTPAGE=$MODDIR/last_page
BASE_DESC="80% cap for Sakata kernel via bypass node. Action button = full charge / resume cap."
LAST_STATUS=$MODDIR/last_status

update_desc() {
  # Rewrite whenever module.prop does not already carry this exact status,
  # so external overwrites (module updates, manager edits) self-heal
  # on the next poll instead of going blind.
  want="[$1] $BASE_DESC"
  cur=$(grep '^description=' $MODPROP 2>/dev/null | sed 's/^description=//')
  if [ "$cur" != "$want" ]; then
    if grep -q '^description=' $MODPROP 2>/dev/null; then
      sed -i "s|^description=.*|description=$want|" $MODPROP
    fi
    echo "$1" > $LAST_STATUS
  fi
}

render_webui() {
  # Bake current status into the WebUI page (zero JS bridge needed).
  # $1 = state line, $2 = pct, $3 = detail line
  [ -f $TEMPLATE ] || return 0
  sig="$1|$2|$3"
  if [ -f $LASTPAGE ] && [ "$(cat $LASTPAGE 2>/dev/null)" = "$sig" ]; then
    return 0
  fi
  echo "$sig" > $LASTPAGE
  esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g'; }
  tmp=$WEBROOT/.index.html
  logtmp=$WEBROOT/.log.html
  tail -n 8 $LOG 2>/dev/null | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' > $logtmp
  sed -e "s|%%STATE%%|$(esc "$1")|g" -e "s|%%PCT%%|$(esc "$2")|g" \
      -e "s|%%DETAIL%%|$(esc "$3")|g" $TEMPLATE > $tmp
  sed -i "/%%LOG%%/r $logtmp" $tmp
  sed -i "/%%LOG%%/d" $tmp
  rm -f $logtmp
  mv $tmp $PAGE
}

prev_usb=$(cat $USBON 2>/dev/null)
cap0=$(cat $CAP 2>/dev/null)
cur0=$(cat $CUR 2>/dev/null)
rm -f $OVERRIDE
if [ "$prev_usb" = "1" ] && [ -n "$cap0" ] && [ "$cap0" -ge "$HIGH" ] && [ -n "$cur0" ] && ! is_charging "$cur0"; then
  touch $HOLDING
  log "bypasscap started (adopted existing hold at ${cap0}%)"
else
  rm -f $HOLDING
  log "chargebypasscap started (always-on 80% cap, override via action button)"
fi

grace=0

loop() {
  while true; do
    usb=$(cat $USBON 2>/dev/null)
    cap=$(cat $CAP 2>/dev/null)
    cur=$(cat $CUR 2>/dev/null)

    # Fresh plug-in: intent to charge. Clear session state; reconcile below 80%.
    if [ "$usb" = "1" ] && [ "$prev_usb" != "1" ]; then
      rm -f $HOLDING $OVERRIDE
      grace=0
      log "plug-in at $cap%"
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
          log "cap=$cap charging -> bypass ON"
          echo 1 > $NODE
          touch $HOLDING
          grace=$GRACE_POLLS
          sleep 30
        else
          # Holding but current flowing past grace: user released bypass.
          log "manual bypass-OFF detected -> override till unplug"
          touch $OVERRIDE
          rm -f $HOLDING
        fi
      elif [ "$cap" -le "$LOW" ] && ! is_charging "$cur"; then
        if [ -f $HOLDING ]; then
          log "cap=$cap suspended -> bypass OFF"
          echo 0 > $NODE
          rm -f $HOLDING
          sleep 30
        fi
        # else: suspended below 78 by your own hand -> left alone
      else
        : # deadband 79%, or full (100%, ~0 mA trickle): no action
      fi
    else
      # Unplugged: clear session state.
      rm -f $HOLDING $OVERRIDE
      grace=0
    fi

    # Live status: module list emoji + baked WebUI page.
    if [ "$usb" != "1" ]; then
      ST="🔌 unplugged"; DT="Daemon idle. Plug in to resume capping."
    elif [ -f $OVERRIDE ]; then
      ST="🔓 override till unplug (${cap:-?}%)"
      DT="Charging to 100%. Unplug to reset."
    elif [ -f $HOLDING ]; then
      ST="⛔ bypass ON, holding ${cap:-?}%"
      DT="Phone running off the cable, battery resting."
    elif [ -n "$cur" ] && is_charging "$cur"; then
      ST="🔋 charging ${cap:-?}%"
      if [ -n "$cap" ] && [ "$cap" -ge "$HIGH" ]; then
        DT="Over 80% - cap will engage shortly."
      else
        DT="Cap engages at 80%."
      fi
    else
      ST="⏸ idle ${cap:-?}%"; DT="Suspended by your own hand - left alone."
    fi
    update_desc "$ST"
    render_webui "$ST" "${cap:-?}%" "$DT"

    sleep $POLL
  done
}

loop &
