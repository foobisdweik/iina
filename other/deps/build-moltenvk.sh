#!/bin/bash
# Install MoltenVK into the build prefix, for IINA's Vulkan renderer.
#
# other/build_deps.sh copies this file into buildscripts/ of
# iina/deps-buildscripts and runs it before libplacebo and mpv. MoltenVK is
# not compiled here: the official Khronos release has a signed, universal
# dylib for macOS 12.0 and later. This script installs, for each arch:
#   * lib/libMoltenVK.dylib, the arm64 or x86_64 part of the release dylib.
#     Its install name is already @rpath/libMoltenVK.dylib, so
#     fix-install-names.sh copies it with the other dylibs.
#   * include/vulkan and include/vk_video, the Vulkan headers of the release.
#   * lib/pkgconfig/vulkan.pc, so that meson finds Vulkan. It links to
#     MoltenVK directly, because IINA does not bundle the Vulkan loader.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="moltenvk"
: "${MOLTENVK_VERSION:?MOLTENVK_VERSION must be set by other/build_deps.sh}"
VERSION="${MOLTENVK_VERSION}"
TARBALL="MoltenVK-macos-${VERSION}.tar"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

# extract_source() in common.sh does not handle uncompressed .tar files.
extract() {
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    log_step "Extracting: ${TARBALL}"
    tar -xf "${SOURCES_DIR}/${TARBALL}" -C "$SRC_DIR"
}

install_for_arch() {
    local arch="$1"
    local prefix release
    prefix="$(get_prefix "$arch")"
    release="${SRC_DIR}/MoltenVK/MoltenVK"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    mkdir -p "${prefix}/lib/pkgconfig" "${prefix}/include"

    lipo "${release}/dynamic/dylib/macOS/libMoltenVK.dylib" -thin "$arch" \
        -output "${prefix}/lib/libMoltenVK.dylib"

    rm -rf "${prefix}/include/vulkan" "${prefix}/include/vk_video"
    cp -R "${release}/include/vulkan" "${release}/include/vk_video" "${prefix}/include/"

    # The pkg-config version must be the version of the Vulkan headers,
    # because mpv checks it (vulkan >= 1.4.309).
    local header_version
    header_version="$(awk '/#define VK_HEADER_VERSION /{print $3}' \
        "${prefix}/include/vulkan/vulkan_core.h")"
    [ -n "$header_version" ] || { echo "ERROR: no VK_HEADER_VERSION in vulkan_core.h" >&2; exit 1; }

    cat > "${prefix}/lib/pkgconfig/vulkan.pc" <<EOF
prefix=${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Vulkan (MoltenVK ${VERSION})
Description: Vulkan on Metal, linked directly without the Vulkan loader
Version: 1.4.${header_version}
Libs: -L\${libdir} -lMoltenVK
Cflags: -I\${includedir}
EOF
}

download_and_verify "$MOLTENVK_URL" "$MOLTENVK_SHA256" "$TARBALL"
extract

for arch in $ARCHS; do install_for_arch "$arch"; done
