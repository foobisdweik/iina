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
#   * Vulkan is enabled in libplacebo and mpv, and a patch adds the Vulkan
#     render API (MPV_RENDER_API_TYPE_VULKAN, header mpv/render_vk.h), so
#     that gpu-next can run compute shaders. Two extra build scripts install
#     MoltenVK (Vulkan on Metal, bundled as libMoltenVK.dylib) and glslang
#     (a shader compiler, linked statically into libplacebo).
#   * The mpv patches of the build scripts are not applied, because all of
#     them are already part of mpv master.
#   * zlib and expat always come from the macOS SDK (build-sdk-pkgconfig.sh),
#     and CMAKE_PREFIX_PATH is cleared, so that no dylib links to a library
#     from MacPorts or Homebrew.
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
CPU=""

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
    --cpu <CPU>          Optimize for one Apple Silicon CPU, for example apple-m1. Needs
                         --arch arm64. The dylibs then run only on that CPU and newer ones.
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
    --cpu) [[ $# -ge 2 ]] || die "--cpu needs a value"; CPU="$2"; shift 2 ;;
    --cpu=*) CPU="${1#*=}"; shift ;;
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
if [[ -n "$CPU" ]]; then
  [[ "$CPU" =~ ^apple-m[0-9]+$ ]] || die "invalid CPU: $CPU (use an Apple Silicon CPU name, for example apple-m1)"
  [[ "$ARCH" == "arm64" ]] || die "--cpu needs --arch arm64, because the result cannot run on Intel Macs"
fi

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
MOLTENVK_VERSION="${MOLTENVK_VERSION}"
MOLTENVK_SHA256="${MOLTENVK_SHA256}"
MOLTENVK_URL="${MOLTENVK_URL}"
GLSLANG_VERSION="${GLSLANG_VERSION}"
GLSLANG_SHA256="${GLSLANG_SHA256}"
GLSLANG_URL="${GLSLANG_URL}"
EOF
for script in build-mpv.sh build-libplacebo.sh build-moltenvk.sh build-glslang.sh \
              build-sdk-pkgconfig.sh; do
  cp "${DEPS_OVERLAY}/${script}" "${WORK_DIR}/buildscripts/${script}"
done
for dep in mpv libplacebo; do
  rm -rf "${WORK_DIR}/patches/${dep}"
  mkdir -p "${WORK_DIR}/patches/${dep}"
  cp "${DEPS_OVERLAY}/patches/${dep}"/*.patch "${WORK_DIR}/patches/${dep}/"
done
# Add the extra build scripts to build.sh: the SDK .pc files before every
# other library, and MoltenVK and glslang before libplacebo, which needs both.
python3 - "${WORK_DIR}/build.sh" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
def insert_before(line, extra):
    global text
    if text.count(line) != 1:
        sys.exit(f"error: expected one '{line}' line in {path}")
    text = text.replace(line, extra + line)
insert_before("run buildscripts/build-freetype.sh",
    "run buildscripts/build-sdk-pkgconfig.sh   # zlib and expat from the macOS SDK (added by IINA)\n")
insert_before("run buildscripts/build-libplacebo.sh",
    "run buildscripts/build-moltenvk.sh        # Vulkan on Metal (added by IINA)\n"
    "run buildscripts/build-glslang.sh         # GLSL to SPIR-V compiler for libplacebo (added by IINA)\n")
open(path, "w").write(text)
PYEOF
# build-mpv.sh reads MPV_REPO and MPV_COMMIT from versions.env through common.sh.
export MPV_REPO MPV_COMMIT

# 2b. Optional CPU tuning. Every library gets -mcpu=<CPU> (the instructions
#     and the instruction scheduling of that CPU) and -O3. Each build system
#     reads its flags from a different place:
#       * meson (mpv, libplacebo, dav1d, libass, ...) reads the machine file,
#         because meson_setup() clears CFLAGS.
#       * cmake, autotools and FFmpeg (through --extra-cflags) read the CFLAGS
#         that setup_arch_env() exports.
#     -ffast-math and -Ofast are not used, because mpv and libplacebo depend on
#     exact IEEE float behavior (for example, NaN means "default" for the
#     tone-mapping-param option).
if [[ -n "$CPU" ]]; then
  log "Optimizing all dependencies for ${CPU} (-mcpu=${CPU} -O3)"
  python3 - "${WORK_DIR}/extra/meson-darwin.ini.in" "$CPU" <<'EOF'
import re, sys
path, cpu = sys.argv[1], sys.argv[2]
text = open(path).read()
# Add the flags to the compile arguments only (c_args, cpp_args, objc_args,
# objcpp_args), not to the *_link_args lines.
pattern = re.compile(r"^((?:c|cpp|objc|objcpp)_args\s*=\s*\[.*)\]\s*$", re.M)
text, count = pattern.subn(lambda m: m.group(1) + f", '-mcpu={cpu}', '-O3']", text)
if count != 4:
    sys.exit(f"error: expected 4 compile argument lines in {path}, found {count}")
open(path, "w").write(text)
EOF
  cat >>"${WORK_DIR}/buildscripts/common.sh" <<EOF

# Added by IINA other/build_deps.sh --cpu: add CPU tuning to the flags of
# cmake, autotools and FFmpeg builds. Later flags win, so -O3 replaces -O2.
eval "_iina_base_\$(declare -f setup_arch_env)"
setup_arch_env() {
    _iina_base_setup_arch_env "\$@"
    local opt="-mcpu=${CPU} -O3"
    export CFLAGS="\${CFLAGS} \${opt}"
    export CXXFLAGS="\${CXXFLAGS} \${opt}"
    export OBJCFLAGS="\${OBJCFLAGS} \${opt}"
}
EOF
fi

# 3. Build every dependency, then package the dylibs the way the official
#    release workflow does. CMake searches the directories in
#    CMAKE_PREFIX_PATH (for example /opt/local from MacPorts) before the SDK,
#    so clear it for the build.
unset CMAKE_PREFIX_PATH
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
# copy-headers.sh copies only some mpv headers. IINA's Vulkan renderer also
# needs mpv/render_vk.h and the Vulkan C headers that it includes. The C++
# headers (*.hpp, *.cppm) are about 20 MB and IINA does not use them.
cp "${WORK_DIR}/install/${HEADER_ARCH}/include/mpv/render_vk.h" "${WORK_DIR}/output/include/mpv/"
mkdir -p "${WORK_DIR}/output/include/vulkan"
cp "${WORK_DIR}/install/${HEADER_ARCH}/include/vulkan"/*.h "${WORK_DIR}/output/include/vulkan/"
cp -R "${WORK_DIR}/install/${HEADER_ARCH}/include/vk_video" "${WORK_DIR}/output/include/"

# 4. Install the result into deps/.
log "Installing the dylibs into deps/lib"
LIB_PATH="${ROOT_PATH}/deps/lib"
mkdir -p "$LIB_PATH"
find "$LIB_PATH" -maxdepth 1 -name '*.dylib' -delete
cp -p "$OUTPUT_LIBS"/*.dylib "$LIB_PATH/"

log "Installing the headers into deps/include"
# Recreate the Vulkan folders, so that headers from an earlier build that are
# no longer copied do not stay behind.
rm -rf "${ROOT_PATH}/deps/include/vulkan" "${ROOT_PATH}/deps/include/vk_video"
for dir in "${WORK_DIR}/output/include"/*/; do
  name="$(basename "$dir")"
  mkdir -p "${ROOT_PATH}/deps/include/${name}"
  cp -R "$dir". "${ROOT_PATH}/deps/include/${name}/"
done
grep -q 'MPV_RENDER_API_TYPE_OPENGL_NEXT' "${ROOT_PATH}/deps/include/mpv/render.h" ||
  die "deps/include/mpv/render.h has no gpu-next render API"
grep -q 'MPV_RENDER_API_TYPE_VULKAN' "${ROOT_PATH}/deps/include/mpv/render_vk.h" ||
  die "deps/include/mpv/render_vk.h has no Vulkan render API"
[[ -f "${LIB_PATH}/libMoltenVK.dylib" ]] || die "deps/lib/libMoltenVK.dylib is missing"
# Every dylib may link only to other bundled dylibs (@rpath) and to system
# libraries. A path such as /opt/local/lib/libz.1.dylib exists only on the
# build Mac, so IINA would fail to start on other Macs.
foreign="$(for lib in "$LIB_PATH"/*.dylib; do
  [[ -L "$lib" ]] && continue
  otool -L "$lib" | tail -n +2 | awk '{print $1}' |
    { grep -Ev '^(@rpath/|/usr/lib/|/System/Library/)' || true; } | sed "s|^|$(basename "$lib"): |"
done)"
[[ -z "$foreign" ]] || die "dylibs link to libraries outside the app and the system:
${foreign}"

# 5. Make the dylib references in the Xcode project match deps/lib.
log "Updating iina.xcodeproj"
python3 "${ROOT_PATH}/other/sync_xcode_dylibs.py"

# 6. Download yt-dlp and the official plugins.
if [[ "$DOWNLOAD_EXTRAS" == true ]]; then
  log "Downloading yt-dlp and plugins"
  "${ROOT_PATH}/other/download_libs.sh" --skip-dylibs ${DOWNLOAD_ARGS[@]+"${DOWNLOAD_ARGS[@]}"}
fi

echo -e "${GREEN}Done. The dependencies are in deps/. Open iina.xcodeproj and build the project.${NC}"
