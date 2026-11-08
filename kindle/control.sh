#!/bin/sh
# control.sh start|stop|status -- keep the Awing login loop alive in the
# background (survives KUAL exiting, resumes after the Kindle wakes).

DIR=${AWING_DIR:-/mnt/us/extensions/awing}
PIDFILE="$DIR/loop.pid"
LOG="$DIR/awing.log"

running() {
  [ -f "$PIDFILE" ] || return 1
  _p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null
}

case "${1:-status}" in
  start)
    if running; then
      echo "already running (pid $(cat "$PIDFILE"))"
      exit 0
    fi
    nohup sh "$DIR/autologin.sh" --loop >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    echo "started (pid $(cat "$PIDFILE")), log: $LOG"
    ;;
  stop)
    if running; then
      kill "$(cat "$PIDFILE")" 2>/dev/null
      rm -f "$PIDFILE"
      echo "stopped"
    else
      rm -f "$PIDFILE"
      echo "not running"
    fi
    ;;
  status)
    if running; then
      echo "running (pid $(cat "$PIDFILE"))"
      tail -n 5 "$LOG" 2>/dev/null
    else
      echo "not running"
    fi
    ;;
  *)
    echo "usage: $0 start|stop|status" >&2
    exit 2
    ;;
esac
