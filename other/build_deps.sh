#!/bin/bash
# Build all of IINA's dependencies from source, with a libmpv that supports
# mpv's gpu-next renderer, and install them into deps/.
#
# This script uses IINA's official build scripts (iina/deps-buildscripts) at
# the commit pinned in other/deps/versions.env, with these changes:
#   * mpv is built from mpv master at a pinned commit, not from the v0.41.0
#     release. The patches in other/deps/patches/mpv/ add the gpu-next
#     OpenGL render API (MPV_RENDER_API_TYPE_OPENGL_NEXT) and fix the macOS
#     build without Vulkan.
#   * libplacebo is updated, because mpv master needs a newer version.
#   * The mpv patches of the build scripts are not applied, because all of
#     them are already part of mpv master.
#
# After the build, the script copies the dylibs to deps/lib and the headers to
# deps/include, updates iina.xcodeproj to match the dylibs, and downloads
# yt-dlp and the official plugins with other/download_libs.sh.
#
# Requirements: macOS with Xcode, and the build tools from Homebrew:
#   brew install meson ninja cmake pkg-config autoconf automake libtool nasm
set -euo pipefail

ROOT_PATH="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_OVERLAY="${ROOT_PATH}/other/deps"
source "${DEPS_OVERLAY}/versions.env"

ARCH="universal"
WORK_DIR="${ROOT_PATH}/deps/buildscripts"
DOWNLOAD_EXTRAS=true
DOWNLOAD_ARGS=()

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_usage() {
  cat <<EOF

Usage: $0 [options]
    -h, --help           Display this help message
    --arch <ARCH>        Architecture to build: universal | arm64 | x86_64 (default: universal)
    --work-dir <DIR>     Directory for the build scripts, sources and build files
                         (default: deps/buildscripts). Keep it to reuse downloaded sources.
    --skip-downloads     Do not download yt-dlp and the official plugins
    --skip-plugins       Download yt-dlp, but not the official plugins

EOF
}

log() { echo -e "${BLUE}==> $*${NC}"; }
die() { echo -e "${RED}error: $*${NC}" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) print_usage; exit 0 ;;
    --arch) [[ $# -ge 2 ]] || die "--arch needs a value"; ARCH="$2"; shift 2 ;;
    --arch=*) ARCH="${1#*=}"; shift ;;
    --work-dir) [[ $# -ge 2 ]] || die "--work-dir needs a value"; WORK_DIR="$2"; shift 2 ;;
    --work-dir=*) WORK_DIR="${1#*=}"; shift ;;
    --skip-downloads) DOWNLOAD_EXTRAS=false; shift ;;
    --skip-plugins) DOWNLOAD_ARGS+=(--skip-plugins); shift ;;
    *) print_usage; die "unknown option: $1" ;;
  esac
done

case "$ARCH" in
  universal) BUILD_ARCH="all" ;;
  arm64 | x86_64) BUILD_ARCH="$ARCH" ;;
  *) die "invalid architecture: $ARCH (use universal, arm64 or x86_64)" ;;
esac

[[ "$(uname -s)" == "Darwin" ]] || die "the dependencies can only be built on macOS"
missing=()
for tool in git python3 meson ninja cmake pkg-config aclocal autoreconf nasm perl xcrun; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  die "missing build tools: ${missing[*]}
       Install them with: brew install meson ninja cmake pkg-config autoconf automake libtool nasm"
fi

# 1. Get the official build scripts at the pinned commit. A reset of the
#    tracked files removes changes from an earlier run. The untracked folders
#    sources/, build/ and install/ stay, so downloads are reused.
log "Preparing iina/deps-buildscripts ${DEPS_BUILDSCRIPTS_COMMIT:0:7} in ${WORK_DIR}"
mkdir -p "$WORK_DIR"
if [[ ! -d "${WORK_DIR}/.git" ]]; then
  git -C "$WORK_DIR" init -q
  git -C "$WORK_DIR" remote add origin "$DEPS_BUILDSCRIPTS_REPO"
fi
git -C "$WORK_DIR" fetch -q --depth 1 origin "$DEPS_BUILDSCRIPTS_COMMIT"
git -C "$WORK_DIR" checkout -q --force FETCH_HEAD
git -C "$WORK_DIR" clean -q -f -d -- patches buildscripts
[[ "$(git -C "$WORK_DIR" rev-parse HEAD)" == "$DEPS_BUILDSCRIPTS_COMMIT" ]] ||
  die "deps-buildscripts checkout is not ${DEPS_BUILDSCRIPTS_COMMIT}"

# 2. Apply the changes for gpu-next. The build scripts source versions.env,
#    so values appended at the end replace the original values.
log "Applying the gpu-next changes (mpv ${MPV_COMMIT:0:7}, libplacebo ${LIBPLACEBO_VERSION})"
cat >>"${WORK_DIR}/versions.env" <<EOF

# Added by IINA other/build_deps.sh
LIBPLACEBO_VERSION="${LIBPLACEBO_VERSION}"
MPV_REPO="${MPV_REPO}"
MPV_COMMIT="${MPV_COMMIT}"
EOF
cp "${DEPS_OVERLAY}/build-mpv.sh" "${WORK_DIR}/buildscripts/build-mpv.sh"
rm -rf "${WORK_DIR}/patches/mpv"
mkdir -p "${WORK_DIR}/patches/mpv"
cp "${DEPS_OVERLAY}"/patches/mpv/*.patch "${WORK_DIR}/patches/mpv/"
# build-mpv.sh reads MPV_REPO and MPV_COMMIT from versions.env through common.sh.
export MPV_REPO MPV_COMMIT

# 3. Build every dependency, then package the dylibs the way the official
#    release workflow does.
log "Building the dependencies for ${ARCH}. This takes a long time."
(cd "$WORK_DIR" && bash build.sh "$BUILD_ARCH")

log "Fixing install names"
(cd "$WORK_DIR" && bash fix-install-names.sh "$BUILD_ARCH")
if [[ "$ARCH" == "universal" ]]; then
  log "Creating universal binaries"
  (cd "$WORK_DIR" && bash lipo.sh)
  OUTPUT_LIBS="${WORK_DIR}/output/fat"
  HEADER_ARCH="arm64"
else
  OUTPUT_LIBS="${WORK_DIR}/output/${ARCH}"
  HEADER_ARCH="$ARCH"
  # Sign the single-architecture dylibs too. lipo.sh does this for universal builds.
  for lib in "$OUTPUT_LIBS"/*.dylib; do
    [[ -L "$lib" ]] || codesign --force --sign - "$lib"
  done
fi
(cd "$WORK_DIR" && bash copy-headers.sh "install/${HEADER_ARCH}/include" "output/include")

# 4. Install the result into deps/.
log "Installing the dylibs into deps/lib"
LIB_PATH="${ROOT_PATH}/deps/lib"
mkdir -p "$LIB_PATH"
find "$LIB_PATH" -maxdepth 1 -name '*.dylib' -delete
cp -p "$OUTPUT_LIBS"/*.dylib "$LIB_PATH/"

log "Installing the headers into deps/include"
for dir in "${WORK_DIR}/output/include"/*/; do
  name="$(basename "$dir")"
  mkdir -p "${ROOT_PATH}/deps/include/${name}"
  cp -R "$dir". "${ROOT_PATH}/deps/include/${name}/"
done
grep -q 'MPV_RENDER_API_TYPE_OPENGL_NEXT' "${ROOT_PATH}/deps/include/mpv/render.h" ||
  die "deps/include/mpv/render.h has no gpu-next render API"

# 5. Make the dylib references in the Xcode project match deps/lib.
log "Updating iina.xcodeproj"
python3 "${ROOT_PATH}/other/sync_xcode_dylibs.py"

# 6. Download yt-dlp and the official plugins.
if [[ "$DOWNLOAD_EXTRAS" == true ]]; then
  log "Downloading yt-dlp and plugins"
  "${ROOT_PATH}/other/download_libs.sh" --skip-dylibs ${DOWNLOAD_ARGS[@]+"${DOWNLOAD_ARGS[@]}"}
fi

echo -e "${GREEN}Done. The dependencies are in deps/. Open iina.xcodeproj and build the project.${NC}"
