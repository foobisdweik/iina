#!/bin/bash
# Build vtprobe for this Mac.
set -euo pipefail
cd "$(dirname "$0")"
clang -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
  -mmacosx-version-min=26.0 \
  -framework Foundation -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework VideoToolbox \
  -o vtprobe vtprobe.m
echo "Built $(pwd)/vtprobe"
