#!/bin/bash
# Make the tier clips for vk-probe from one high-resolution source.
#
# Usage: ./make-tiers.sh <source-video> <name> [start-seconds]
#
# Output in clips/<name>/:
#   original.mp4  a 30 s cut of the source at full size, nearly lossless.
#                 This is the reference for scoring.
#   240p.mp4 ... 1440p.mp4
#                 the same cut, downscaled and encoded with H.264 at a low
#                 bitrate, to imitate web video.
# Tiers that are not smaller than the source are skipped.
set -euo pipefail
cd "$(dirname "$0")"

srcfile="$1"; name="$2"; start="${3:-0}"
dir="clips/$name"
mkdir -p "$dir"

if [[ ! -f "$dir/original.mp4" ]]; then
  # -an: the tests play without audio. setsar=1 keeps square pixels, because
  # a non-square pixel shape changes the display size and breaks the crop.
  ffmpeg -nostdin -hide_banner -loglevel error -y -ss "$start" -t 30 -i "$srcfile" \
    -an -vf "setsar=1,format=yuv420p" -c:v libx264 -crf 10 -preset slow \
    "$dir/original.mp4"
fi

IFS=x read -r W H < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
  -of csv=p=0:s=x "$dir/original.mp4")

# height bitrate
while read -r h rate; do
  (( h < H )) || continue
  out="$dir/${h}p.mp4"
  [[ -f "$out" ]] && continue
  # Width keeps the aspect ratio and is rounded to an even number.
  ffmpeg -nostdin -hide_banner -loglevel error -y -i "$dir/original.mp4" \
    -vf "scale=-2:${h}:flags=lanczos,setsar=1,format=yuv420p" \
    -c:v libx264 -b:v "$rate" -preset medium "$out"
  echo "made $out"
done <<'EOF'
240 300k
360 600k
480 1000k
720 2000k
1080 3500k
1440 6000k
EOF
