#!/bin/bash
# Make synthetic test clips for vtprobe in clips/.
#
# The clips are synthetic (moving test patterns with noise), not real footage.
# That is enough for timing and for checking supported sizes, because the cost
# of the effects depends on the frame size, not on the picture content. Judging
# quality needs real footage.
#
# Each clip is 12 s at 30 fps, encoded with H.264 at a low bitrate to imitate
# web video.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p clips

# Source: 4K test pattern with grain, encoded nearly losslessly.
if [[ ! -f clips/source-2160p.mp4 ]]; then
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=3840x2160:rate=30:duration=12" \
    -vf "noise=alls=8:allf=t+u,format=yuv420p" \
    -c:v libx264 -crf 12 -preset fast clips/source-2160p.mp4
fi

# width height bitrate
while read -r w h rate; do
  out="clips/${h}p.mp4"
  [[ -f "$out" ]] && continue
  ffmpeg -nostdin -hide_banner -loglevel error -y -i clips/source-2160p.mp4 \
    -vf "scale=${w}:${h}:flags=lanczos,setsar=1,format=yuv420p" \
    -c:v libx264 -b:v "$rate" -preset medium -movflags +faststart "$out"
  echo "made $out"
done <<'EOF'
426 240 300k
640 360 600k
854 480 1000k
1280 720 2000k
1920 1080 3500k
2560 1440 6000k
EOF
