#!/bin/sh
# Fetch a video from a URL, normalize it once, then loop it to RTMP forever.
# POSIX sh (busybox). Steady-state RSS ~40 MB.
set -u

VIDEO_URL="${VIDEO_URL:-}"
RTMP_URL="${RTMP_URL:-rtmp://live.restream.io/live}"
CACHE_DIR="${CACHE_DIR:-/var/cache/loopstream}"
STALL_TIMEOUT="${STALL_TIMEOUT:-45}"
MAX_HOURS="${MAX_HOURS:-6}"
REFRESH="${REFRESH:-0}"          # 1 = re-check the URL on every session cycle
VB="${VB:-1800k}"                # bitrate used only if a transcode is needed
AB="${AB:-96k}"
POLL="${POLL:-15}"
PROGRESS=/tmp/progress

log() { echo "$(date -u +%FT%TZ) $*"; }
die() { log "FATAL: $*"; exit 1; }

[ -n "$VIDEO_URL" ]      || die "VIDEO_URL not set"
[ -n "${STREAM_KEY:-}" ] || die "STREAM_KEY not set (fly secrets set STREAM_KEY=...)"

mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR"
KEY=$(printf '%s' "$VIDEO_URL" | md5sum | cut -c1-16)
SRC="$CACHE_DIR/src-$KEY"
LOOP="$CACHE_DIR/loop-$KEY.mp4"

# ---------------------------------------------------------------- download ---
fetch() {
  log "downloading $VIDEO_URL"
  # -C - resumes a partial file; --retry-all-errors covers catbox's occasional
  # 5xx. Ingress is free on Fly, so retrying is cheap.
  curl -fL --retry 8 --retry-delay 5 --retry-all-errors \
       --connect-timeout 20 --max-time 1800 \
       -C - -o "$SRC.part" "$VIDEO_URL" || return 1
  mv "$SRC.part" "$SRC"
  log "downloaded $(du -h "$SRC" | cut -f1)"
}

# --------------------------------------------------------------- normalize ---
# The server should only ever remux (-c copy). If the fetched file already
# matches TikTok's shape we just rewrite the container; if not we transcode
# ONCE at boot and then stream cheaply forever.
normalize() {
  probe=$(ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,width,height,pix_fmt,avg_frame_rate \
      -of default=nw=1:nk=1 "$SRC" 2>/dev/null) || return 1
  vcodec=$(echo "$probe" | sed -n 1p)
  width=$(echo  "$probe" | sed -n 2p)
  height=$(echo "$probe" | sed -n 3p)
  pixfmt=$(echo "$probe" | sed -n 4p)
  rate=$(echo   "$probe" | sed -n 5p)
  fps=$(( $(echo "$rate" | cut -d/ -f1) / $(echo "$rate" | cut -d/ -f2) ))
  acodec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
      -of default=nw=1:nk=1 "$SRC" 2>/dev/null)

  log "source: $vcodec ${width}x${height} ${fps}fps $pixfmt audio=${acodec:-none}"

  if [ "$vcodec" = "h264" ] && [ "$pixfmt" = "yuv420p" ] && [ "$acodec" = "aac" ] \
     && [ "$width" -le 720 ] && [ "$height" -le 1280 ] && [ "$fps" -le 30 ]; then
    log "already stream-ready, remuxing only"
    ffmpeg -v error -y -i "$SRC" -c copy -movflags +faststart "$LOOP" || return 1
  else
    log "transcoding once to 720x1280@30 (this is the only expensive step)"
    ffmpeg -v error -y -i "$SRC" \
      -vf "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30" \
      -c:v libx264 -preset veryfast -profile:v main -level 3.1 -pix_fmt yuv420p \
      -b:v "$VB" -maxrate "$VB" -bufsize "$VB" \
      -x264-params "nal-hrd=cbr:force-cfr=1:keyint=60:min-keyint=60:scenecut=0" \
      -c:a aac -b:a "$AB" -ar 44100 -ac 2 \
      -movflags +faststart "$LOOP" || return 1
  fi

  # Keep only this URL's artifacts so the rootfs can't fill up over redeploys.
  find "$CACHE_DIR" -type f ! -name "*$KEY*" -delete 2>/dev/null
  log "ready: $LOOP ($(du -h "$LOOP" | cut -f1))"
}

prepare() {
  if [ -s "$LOOP" ] && [ "$REFRESH" != "1" ]; then
    log "using cached loop"
    return 0
  fi
  [ -s "$SRC" ] || fetch || return 1
  normalize
}

# ------------------------------------------------------------------ stream ---
FFPID=""
shutdown() { log "signal received, stopping"; [ -n "$FFPID" ] && kill "$FFPID" 2>/dev/null; exit 0; }
trap shutdown TERM INT

BACKOFF=5
until prepare; do
  log "prepare failed, retrying in 30s"
  rm -f "$SRC.part"
  sleep 30
done

while :; do
  : > "$PROGRESS"
  log "connecting to $RTMP_URL"

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

  # REFRESH=1: pick up a new upload at the same URL between sessions.
  if [ "$REFRESH" = "1" ]; then rm -f "$SRC" "$LOOP"; prepare || log "refresh failed, keeping old loop"; fi
done
