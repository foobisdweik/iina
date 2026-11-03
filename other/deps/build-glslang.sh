#!/bin/bash
# Build glslang as static libraries, for libplacebo's Vulkan support.
#
# other/build_deps.sh copies this file into buildscripts/ of
# iina/deps-buildscripts and runs it before libplacebo. libplacebo uses
# glslang to compile mpv's GLSL shaders to SPIR-V (the shader format of
# Vulkan). The libraries are static, so they are linked into libplacebo and
# the app gets no extra dylib.
#
# glslang is installed into its own directory, <prefix>/opt/glslang, which
# build-libplacebo.sh passes as -Dvulkan-sdk. So only glslang's headers are
# added to libplacebo's include path, and no other build sees them.
#
# Options:
#   * ENABLE_OPT=OFF: the SPIR-V optimizer needs SPIRV-Tools, and libplacebo
#     does not need it.
#   * ENABLE_HLSL=OFF: mpv's shaders are GLSL only.
#   * BUILD_EXTERNAL=OFF, tests and binaries off: only the libraries.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="glslang"
: "${GLSLANG_VERSION:?GLSLANG_VERSION must be set by other/build_deps.sh}"
VERSION="${GLSLANG_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    # The later -DCMAKE_INSTALL_PREFIX replaces the one from cmake_configure.
    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DCMAKE_INSTALL_PREFIX="$(get_prefix "$arch")/opt/glslang" \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_EXTERNAL=OFF \
        -DENABLE_OPT=OFF \
        -DENABLE_HLSL=OFF \
        -DENABLE_GLSLANG_BINARIES=OFF \
        -DGLSLANG_TESTS=OFF \
        -DGLSLANG_ENABLE_INSTALL=ON

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$GLSLANG_URL" "$GLSLANG_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
