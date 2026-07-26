#!/bin/sh
# Supervisor + streamer. POSIX sh (busybox), no bash, no external deps.
# Memory footprint: ffmpeg in -c copy mode is ~35-50 MB RSS. This script ~1 MB.
set -u

VIDEO="${VIDEO:-/app/loop.mp4}"
RTMP_URL="${RTMP_URL:-rtmp://live.restream.io/live}"
STALL_TIMEOUT="${STALL_TIMEOUT:-45}"   # seconds with no encoder progress -> kill
MAX_HOURS="${MAX_HOURS:-6}"            # cycle the session every N hours (0 = never)
POLL="${POLL:-15}"
PROGRESS=/tmp/progress

log() { echo "$(date -u +%FT%TZ) $*"; }

[ -n "${STREAM_KEY:-}" ] || { log "FATAL: STREAM_KEY not set (fly secrets set STREAM_KEY=...)"; exit 1; }
[ -r "$VIDEO" ]          || { log "FATAL: $VIDEO not readable"; exit 1; }

FFPID=""
shutdown() {
  log "signal received, stopping"
  [ -n "$FFPID" ] && kill "$FFPID" 2>/dev/null
  exit 0
}
trap shutdown TERM INT

BACKOFF=5

while :; do
  : > "$PROGRESS"
  log "connecting to ${RTMP_URL}"

  # -c copy      : pure remux. No encoding => almost no CPU, fits shared-cpu-1x.
  # -re          : pace output at real time (mandatory for a file source).
  # -stream_loop : loop the input forever inside one connection.
  # -fflags +genpts + -avoid_negative_ts : rebuild timestamps across the loop
  #                seam, otherwise the PTS resets and the ingest drops the feed.
  # -progress    : heartbeat file the watchdog below reads.
  ffmpeg -hide_banner -nostdin -nostats -loglevel error \
    -fflags +genpts \
    -re -stream_loop -1 -i "$VIDEO" \
    -c copy -copyts -avoid_negative_ts make_zero \
    -max_muxing_queue_size 128 \
    -progress "$PROGRESS" \
    -f flv -flvflags no_duration_filesize \
    "${RTMP_URL}/${STREAM_KEY}" &
  FFPID=$!

  START=$(date +%s)
  while kill -0 "$FFPID" 2>/dev/null; do
    sleep "$POLL"
    NOW=$(date +%s)

    LAST=$(stat -c %Y "$PROGRESS" 2>/dev/null || echo 0)
    if [ $((NOW - LAST)) -gt "$STALL_TIMEOUT" ]; then
      log "stalled: no progress for ${STALL_TIMEOUT}s, killing"
      kill -9 "$FFPID" 2>/dev/null
      break
    fi

    if [ "$MAX_HOURS" -gt 0 ] && [ $((NOW - START)) -ge $((MAX_HOURS * 3600)) ]; then
      log "session reached ${MAX_HOURS}h, cycling"
      kill "$FFPID" 2>/dev/null; sleep 3; kill -9 "$FFPID" 2>/dev/null
      break
    fi
  done

  wait "$FFPID" 2>/dev/null
  RAN=$(( $(date +%s) - START ))

  # Healthy sessions reset the backoff; rapid failures back off up to 60s so a
  # rejected key doesn't hammer the ingest.
  if [ "$RAN" -gt 120 ]; then
    BACKOFF=5
  else
    BACKOFF=$((BACKOFF * 2)); [ "$BACKOFF" -gt 60 ] && BACKOFF=60
  fi

  log "stream ended after ${RAN}s, retrying in ${BACKOFF}s"
  sleep "$BACKOFF"
done
