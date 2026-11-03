#!/bin/bash
# Run the vk-probe matrix: every chain on every tier clip of one source.
#
# Usage: ./run.sh <name> [chains...]
#   <name>   folder clips/<name>/ with one file per tier whose name starts
#            with the tier: 240p..., 360p..., 480p..., 720p..., 1080p...,
#            1440p..., and 2160p... as the reference. A symlink to a
#            download folder works.
#   chains   chain names from chains.sh (default: all)
#   TIERS    environment variable, for example TIERS="240p 480p" (default: all)
#   SHOTS    environment variable: screenshot times in seconds
#            (default: "6.01")
#   SPEED_START  environment variable: where the 20 s speed run starts (default: 2)
#   HINT     --target-colorspace-hint value. "yes" makes mpv output real HDR
#            (PQ) on macOS; the default "auto" converts HDR to SDR (default: auto)
#
# For each clip and chain, the script does these runs in full screen:
#   1. a speed run: 20 s of playback, then the render statistics,
#   2. one screenshot run per time in SHOTS, rendered at window size.
# It also takes reference screenshots of the 2160p file with the baseline
# chain, so that scoring compares two screenshots that went through the same
# color pipeline. This matters for HDR, where the screenshot is a converted
# version of what the display shows.
# The results go to results/<name>.tsv; screenshots go to shots/<name>/.
#
# mpv opens a full-screen window for each run. Don't use the Mac while
# this runs, because other GPU work changes the timings.
set -euo pipefail
cd "$(dirname "$0")"
source ./chains.sh

name="$1"; shift
chains="${*:-$ALL_CHAINS}"
src="clips/$name"
shots="${SHOTS:-6.01}"
mkdir -p "results" "shots/$name"
out="results/$name.tsv"

# Record the power state, because Low Power Mode and battery power change GPU speed.
power="$(pmset -g batt | head -1 | sed 's/.*from //; s/'"'"'//g') lowpower=$(pmset -g | awk '/lowpowermode/ {print $2}')"
echo "# $(date '+%F %T') $power" >> "$out"
grep -q '^tier' "$out" || printf 'tier\tchain\tavg_ms\tpeak_ms\tdropped\tdelayed\thwdec\tshot\tml\tmt\tmr\tmb\n' >> "$out"

COMMON=(--no-config --vo=gpu-next --gpu-api=vulkan --hwdec=videotoolbox
        --target-colorspace-hint="${HINT:-auto}"
        --fs --no-audio --no-osc --osd-level=0 --hidpi-window-scale=no
        --msg-level=all=error,vkstats=info,shot=info)

# The first file in the folder whose name starts with the tier.
clip_for() { find -L "$src" -maxdepth 1 -type f -name "$1*" | sort | head -1; }

# shoot <clip> <png> <time> <mpv options...>: prints the margins line.
shoot() {
  local clip="$1" png="$2" t="$3"; shift 3
  mpv "${COMMON[@]}" "$@" --script=shot.lua --script-opts=shot-out="$png" \
      --pause --hr-seek=yes --start="$t" "$clip" 2>&1 | grep 'RESULT shot' || true
}

# Reference screenshots, taken once.
ref="$(clip_for 2160p)"
if [[ -n "$ref" ]]; then
  read -r -a base <<< "$(chain_opts baseline)"
  for t in $shots; do
    png="shots/$name/ref-$t.png"
    [[ -f "$png" ]] || shoot "$ref" "$png" "$t" "${base[@]}" > /dev/null
  done
fi

for tier in ${TIERS:-240p 360p 480p 720p 1080p 1440p}; do
  clip="$(clip_for "$tier")"
  [[ -n "$clip" ]] || continue
  for chain in $chains; do
    read -r -a opts <<< "$(chain_opts "$chain")"

    speed="$(mpv "${COMMON[@]}" "${opts[@]}" --script=vkstats.lua \
              --start="${SPEED_START:-2}" --length=20 "$clip" 2>&1 | grep RESULT || true)"
    avg="$(sed -n 's/.*fresh_total_avg_ms=\([0-9.]*\).*/\1/p' <<< "$speed")"
    peak="$(sed -n 's/.*fresh_total_peak_ms=\([0-9.]*\).*/\1/p' <<< "$speed")"
    drop="$(sed -n 's/.*frame_drop=\([^ ]*\).*/\1/p' <<< "$speed")"
    delayed="$(sed -n 's/.*vo_delayed=\([^ ]*\).*/\1/p' <<< "$speed")"
    hwdec="$(sed -n 's/.*hwdec=\([^ ]*\).*/\1/p' <<< "$speed")"

    for t in $shots; do
      png="shots/$name/$tier-$chain-$t.png"
      shot="$(shoot "$clip" "$png" "$t" "${opts[@]}")"
      m() { sed -n "s/.* $1=\([0-9-]*\).*/\1/p" <<< "$shot"; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$tier" "$chain" "${avg:-?}" "${peak:-?}" "${drop:-?}" "${delayed:-?}" \
        "${hwdec:-?}" "$png" "$(m ml)" "$(m mt)" "$(m mr)" "$(m mb)" | tee -a "$out"
    done
  done
done
