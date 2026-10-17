#!/bin/bash
# mkvideo.sh OUT.mp4 [SECONDS]: the "YouTube-like" case's clip: 1080p30 H.264 (FFmpeg's testsrc2) whose
# sound is the measurement tone (30 Hz, about -15 dBFS, FLAC so it stays a pure sine). video.html plays it.
set -e
OUT=${1:?OUT.mp4}; S=${2:-330}
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" \
  -f lavfi -i "sine=frequency=30:sample_rate=48000:duration=$S" \
  -filter_complex "[1:a]volume=2.0,aformat=channel_layouts=stereo[a]" -map 0:v -map "[a]" -t "$S" \
  -c:v libx264 -preset veryfast -b:v 3M -pix_fmt yuv420p -c:a flac -movflags +faststart "$OUT"
