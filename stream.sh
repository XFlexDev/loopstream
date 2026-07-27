#!/bin/sh
set -u

VIDEO_URL="${VIDEO_URL:-}"
RTMP_URL="${RTMP_URL:-rtmp://live.restream.io/live}"
CACHE_DIR="${CACHE_DIR:-/var/cache/loopstream}"
STALL_TIMEOUT="${STALL_TIMEOUT:-45}"
MAX_HOURS="${MAX_HOURS:-6}"
REFRESH="${REFRESH:-0}"
POLL="${POLL:-15}"
PROGRESS=/tmp/progress

log() { echo "$(date -u +%FT%TZ) $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "$VIDEO_URL" ]      || die "VIDEO_URL not set"
[ -n "${STREAM_KEY:-}" ] || die "STREAM_KEY not set"

mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"
KEY=$(printf '%s' "$VIDEO_URL" | md5sum | cut -c1-16)
LOOP="$CACHE_DIR/loop-$KEY.mp4"

fetch() {
  log "downloading raw video from $VIDEO_URL"
  curl -fL --retry 8 --retry-delay 5 --retry-all-errors \
       --connect-timeout 20 --max-time 1800 \
       -C - -o "$LOOP.part" "$VIDEO_URL" || return 1
  mv "$LOOP.part" "$LOOP"
  find "$CACHE_DIR" -type f ! -name "*$KEY*" -delete 2>/dev/null
  log "ready: $LOOP ($(du -h "$LOOP" | cut -f1))"
}

prepare() {
  if [ -s "$LOOP" ] && [ "$REFRESH" != "1" ]; then
    log "using cached file"
    return 0
  fi
  fetch
}

FFPID=""
shutdown() { log "signal received, stopping"; [ -n "$FFPID" ] && kill "$FFPID" 2>/dev/null; exit 0; }
trap shutdown TERM INT

BACKOFF=5
until prepare; do
  log "download failed, retrying in 30s"
  rm -f "$LOOP.part"
  sleep 30
done

while :; do
  : > "$PROGRESS"
  log "connecting to $RTMP_URL (zero transcode, pure copy)"

  ffmpeg -hide_banner -nostdin -nostats -loglevel error \
    -fflags +genpts \
    -re -stream_loop -1 -i "$LOOP" \
    -c copy -copyts -avoid_negative_ts make_zero \
    -max_muxing_queue_size 128 \
    -progress "$PROGRESS" \
    -f flv -flvflags no_duration_filesize \
    "$RTMP_URL/$STREAM_KEY" &
  FFPID=$!

  START=$(date +%s)
  while kill -0 "$FFPID" 2>/dev/null; do
    sleep "$POLL"
    NOW=$(date +%s)
    LAST=$(stat -c %Y "$PROGRESS" 2>/dev/null || echo 0)
    if [ $((NOW - LAST)) -gt "$STALL_TIMEOUT" ]; then
      log "stalled: no progress for ${STALL_TIMEOUT}s, killing"
      kill -9 "$FFPID" 2>/dev/null; break
    fi
    if [ "$MAX_HOURS" -gt 0 ] && [ $((NOW - START)) -ge $((MAX_HOURS * 3600)) ]; then
      log "session reached ${MAX_HOURS}h, cycling"
      kill "$FFPID" 2>/dev/null; sleep 3; kill -9 "$FFPID" 2>/dev/null; break
    fi
  done

  wait "$FFPID" 2>/dev/null
  RAN=$(( $(date +%s) - START ))
  if [ "$RAN" -gt 120 ]; then BACKOFF=5
  else BACKOFF=$((BACKOFF * 2)); [ "$BACKOFF" -gt 60 ] && BACKOFF=60; fi
  log "stream ended after ${RAN}s, retrying in ${BACKOFF}s"
  sleep "$BACKOFF"

  if [ "$REFRESH" = "1" ]; then rm -f "$LOOP"; prepare || log "refresh failed, keeping old file"; fi
done
