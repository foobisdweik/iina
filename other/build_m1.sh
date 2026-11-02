#!/bin/bash
# Build IINA for Apple Silicon with optimizations for one CPU (default: M1).
#
# 1. other/build_deps.sh builds all dependencies for arm64 with
#    -mcpu=<CPU> -O3, including libmpv with the gpu-next render API.
# 2. xcodebuild builds IINA (Release configuration, arm64 only) with:
#      * -mcpu=<CPU> and -O3 for the C and Objective-C code,
#      * -target-cpu <CPU> for the Swift code, which Release already builds
#        with -O and whole-module optimization.
#
# The app runs only on Macs with that CPU or a newer Apple Silicon CPU, not on
# Intel Macs. Most video work in IINA happens in hand-written assembly (FFmpeg,
# dav1d), on the GPU (libplacebo) or in the VideoToolbox hardware decoder, so
# expect small gains: mostly in software decoding, filters and scaling.
#
# Usage:
#   other/build_m1.sh [--cpu <CPU>] [--skip-deps] [build_deps.sh options]
#
# Requirements: macOS with Xcode, and the build tools from Homebrew:
#   brew install meson ninja cmake pkg-config autoconf automake libtool nasm
set -euo pipefail

ROOT_PATH="$(cd "$(dirname "$0")/.." && pwd)"
CPU="apple-m1"
BUILD_DEPS=true
DEPS_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'
log() { echo -e "${BLUE}==> $*${NC}"; }
die() { echo -e "${RED}error: $*${NC}" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --cpu) [[ $# -ge 2 ]] || die "--cpu needs a value"; CPU="$2"; shift 2 ;;
    --cpu=*) CPU="${1#*=}"; shift ;;
    --skip-deps) BUILD_DEPS=false; shift ;;
    --arch | --arch=*) die "build_m1.sh always builds for arm64" ;;
    *) DEPS_ARGS+=("$1"); shift ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "IINA can only be built on macOS"
[[ "$CPU" =~ ^apple-m[0-9]+$ ]] || die "invalid CPU: $CPU (use an Apple Silicon CPU name, for example apple-m1)"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found. Install Xcode."

if [[ "$BUILD_DEPS" == true ]]; then
  "${ROOT_PATH}/other/build_deps.sh" --arch arm64 --cpu "$CPU" ${DEPS_ARGS[@]+"${DEPS_ARGS[@]}"}
else
  log "Skipping the dependency build, using the dylibs in deps/lib"
  # The dylibs must be arm64 dylibs. A universal build also contains arm64.
  lipo -info "${ROOT_PATH}/deps/lib/libmpv.2.dylib" | grep -q arm64 ||
    die "deps/lib/libmpv.2.dylib has no arm64 code. Run without --skip-deps."
fi

DERIVED_DATA="${ROOT_PATH}/build/${CPU}"
log "Building IINA for ${CPU} (Release, arm64)"
xcodebuild -project "${ROOT_PATH}/iina.xcodeproj" -scheme iina -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  GCC_OPTIMIZATION_LEVEL=3 \
  OTHER_CFLAGS="\$(inherited) -mcpu=${CPU}" \
  OTHER_SWIFT_FLAGS="\$(inherited) -target-cpu ${CPU}"

APP="${DERIVED_DATA}/Build/Products/Release/IINA.app"
[[ -d "$APP" ]] || die "the build finished, but ${APP} does not exist"
echo -e "${GREEN}Done: ${APP}${NC}"
echo "This app runs only on Macs with ${CPU} or a newer Apple Silicon CPU."
