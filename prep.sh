#!/usr/bin/env bash
# Run this ONCE, on your own machine — not on Fly.
# Everything expensive happens here so the server only has to remux.
set -euo pipefail

IN="${1:?usage: ./prep.sh input.mp4 [media/loop.mp4]}"
OUT="${2:-media/loop.mp4}"
VB="${VB:-1800k}"     # video bitrate — the single biggest lever on your Fly bill
AB="${AB:-96k}"       # audio bitrate
mkdir -p "$(dirname "$OUT")"

VF="scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30"

# Two passes with a slow preset: this runs once, so spend the CPU here and buy
# noticeably better quality at the same bitrate. nal-hrd=cbr gives a true
# constant bitrate, which RTMP ingests are much happier with than VBR.
X264="nal-hrd=cbr:force-cfr=1:keyint=60:min-keyint=60:scenecut=0:bframes=2:ref=3"

ffmpeg -y -i "$IN" -an -vf "$VF" \
  -c:v libx264 -preset veryslow -profile:v main -level 3.1 \
  -b:v "$VB" -maxrate "$VB" -bufsize "$VB" -x264-params "$X264" \
  -pass 1 -passlogfile /tmp/loopstream-2pass -f null /dev/null

ffmpeg -y -i "$IN" -vf "$VF" \
  -c:v libx264 -preset veryslow -profile:v main -level 3.1 \
  -b:v "$VB" -maxrate "$VB" -bufsize "$VB" -x264-params "$X264" \
  -pass 2 -passlogfile /tmp/loopstream-2pass \
  -pix_fmt yuv420p \
  -c:a aac -b:a "$AB" -ar 44100 -ac 2 \
  -movflags +faststart \
  "$OUT"

rm -f /tmp/loopstream-2pass*
ls -lh "$OUT"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,pix_fmt,bit_rate \
  -of default=noprint_wrappers=1 "$OUT"

cat <<'NOTE'

Checks: 720x1280, 30/1, yuv420p. bufsize == bitrate keeps the ingest buffer
shallow so a reconnect recovers fast. Keyframe every 2s (keyint=60 @ 30fps).
NOTE
