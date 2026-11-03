#!/bin/bash
# Score every screenshot in results/<name>.tsv against the reference
# screenshot of the 2160p file at the same time (shots/<name>/ref-<t>.png).
#
# Usage: ./score.sh <name>
#
# Both screenshots come from the same mpv color pipeline, so for HDR video
# the comparison measures only the upscaling, not the HDR-to-screenshot
# conversion. Both are cropped to the video area, using the margins that
# shot.lua recorded. The reference has the same aspect ratio, so it has the
# same margins.
#
# SSIM: 1.0 means identical structure. PSNR: higher is closer, in dB.
# Output: one row per screenshot, then the mean per tier and chain.
set -euo pipefail
cd "$(dirname "$0")"

name="$1"
tsv="results/$name.tsv"
out="results/$name-scores.tsv"
printf 'tier\tchain\ttime\tssim\tpsnr\n' > "$out"

grep -v '^#' "$tsv" | grep -v '^tier' | while IFS=$'\t' read -r tier chain _ _ _ _ _ png ml mt mr mb; do
  t="${png##*-}"; t="${t%.png}"
  ref="shots/$name/ref-$t.png"
  if [[ ! -f "$png" || ! -f "$ref" || -z "$ml" ]]; then
    printf '%s\t%s\t%s\t?\t?\n' "$tier" "$chain" "$t" >> "$out"; continue
  fi
  IFS=x read -r W H < <(ffprobe -v error -show_entries stream=width,height -of csv=p=0:s=x "$png")
  vw=$((W - ml - mr)); vh=$((H - mt - mb))
  crop="crop=${vw}:${vh}:${ml}:${mt},format=yuv444p"
  res="$(ffmpeg -nostdin -hide_banner -loglevel info -i "$png" -i "$ref" -filter_complex "
        [0:v]${crop},split=2[a1][a2]; [1:v]${crop},split=2[b1][b2];
        [a1][b1]ssim; [a2][b2]psnr" -frames:v 1 -f null - 2>&1 || true)"
  ssim="$(sed -n 's/.*SSIM .* All:\([0-9.]*\).*/\1/p' <<< "$res" | tail -1)"
  psnr="$(sed -n 's/.*PSNR .* average:\([0-9.inf]*\).*/\1/p' <<< "$res" | tail -1)"
  printf '%s\t%s\t%s\t%s\t%s\n' "$tier" "$chain" "$t" "${ssim:-?}" "${psnr:-?}" >> "$out"
done

# Mean over the screenshot times, per tier and chain.
awk -F'\t' 'NR>1 && $4!="?" {k=$1"\t"$2; s[k]+=$4; p[k]+=$5; n[k]++; if(!(k in o)){o[k]=++c; key[c]=k}}
  END {print "tier\tchain\tssim_mean\tpsnr_mean"; for(i=1;i<=c;i++){k=key[i]; printf "%s\t%.5f\t%.3f\n", k, s[k]/n[k], p[k]/n[k]}}' "$out"
