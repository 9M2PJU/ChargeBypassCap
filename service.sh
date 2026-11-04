#!/system/bin/sh
# KernelSU service script: started as root on every boot (late_start).
# Launches the daemon detached, plus a watchdog that restarts it if its
# heartbeat goes stale. Everything detaches so boot (or adb shell) hangs.
MODDIR=${0%/*}
STATEDIR=/data/adb/chargebypasscap
BEAT=$STATEDIR/heartbeat
LOG=$STATEDIR/cap.log
launch() {
  nohup sh "$MODDIR/bypasscap.sh" >/dev/null 2>&1 < /dev/null &
}
launch
(
fails=0
while true; do
  sleep 180
  now=$(date +%s 2>/dev/null)
  beat=$(cat $BEAT 2>/dev/null)
  case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
  if [ -z "$now" ]; then
    continue
  elif [ $((now - beat)) -gt 180 ]; then
    fails=$((fails + 1))
    if [ "$fails" -ge 5 ]; then
      echo "$(date '+%m-%d %H:%M') watchdog: daemon still stale after 5 restarts, giving up till next boot" >> $LOG
      exit 0
    fi
    echo "$(date '+%m-%d %H:%M') watchdog: daemon stale, restarting ($fails/5)" >> $LOG
    for p in $(pgrep -f bypasscap\.sh 2>/dev/null); do
      if [ "$p" != "$$" ]; then kill "$p" 2>/dev/null; fi
    done
    sleep 5
    for p in $(pgrep -f bypasscap\.sh 2>/dev/null); do
      if [ "$p" != "$$" ]; then kill -9 "$p" 2>/dev/null; fi
    done
    launch
  else
    fails=0
  fi
done
) >/dev/null 2>&1 < /dev/null &
