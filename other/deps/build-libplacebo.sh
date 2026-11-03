#!/bin/bash
# Replacement for buildscripts/build-libplacebo.sh in iina/deps-buildscripts.
#
# other/build_deps.sh copies this file over the original. The differences
# from the original script are:
#   * Vulkan is enabled, so that mpv can render with gpu-next on Vulkan and
#     run compute shaders. libplacebo uses its bundled Vulkan headers, and
#     links to MoltenVK (vulkan.pc from build-moltenvk.sh) for
#     vkGetInstanceProcAddr.
#   * glslang is enabled. It compiles shaders to SPIR-V, the shader format of
#     Vulkan. build-glslang.sh installs it into <prefix>/opt/glslang, and the
#     patch in patches/libplacebo/ makes libplacebo search that directory.
#   * The source is reset before the patches are applied, so that a second
#     run does not fail on patches that are already applied.
# The other meson options are the same as in the original script.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libplacebo"
VERSION="${LIBPLACEBO_VERSION}"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

# Use a recursive clone so the glad2 (OpenGL) and Vulkan-Headers submodules
# are included. A tarball from GitLab /-/archive/ does not bundle submodules.
clone_source() {
    if [ -d "$SRC_DIR" ]; then
        log_step "Already cloned: ${DEP_NAME} v${VERSION}"
        git -C "$SRC_DIR" checkout -q -- .
        git -C "$SRC_DIR" clean -q -f -d
        return 0
    fi
    log_step "Cloning: ${DEP_NAME} v${VERSION}"
    git clone --recurse-submodules --depth 1 \
        --branch "v${VERSION}" \
        "${LIBPLACEBO_REPO}" \
        "$SRC_DIR"
}

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    meson_setup "$build_dir" "$SRC_DIR" "$arch" \
        -Dvulkan=enabled \
        -Dvk-proc-addr=enabled \
        -Dopengl=enabled \
        -Dd3d11=disabled \
        -Ddemos=false \
        -Dtests=false \
        -Dshaderc=disabled \
        -Dglslang=enabled \
        -Dvulkan-sdk="$(get_prefix "$arch")/opt/glslang" \
        -Dlcms=enabled

    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install

    # Stop here if Vulkan or glslang is missing. Without this check, mpv
    # would only fail later, with a less clear error.
    local pc
    pc="$(get_prefix "$arch")/lib/pkgconfig/libplacebo.pc"
    for var in pl_has_vulkan pl_has_glslang; do
        if [ "$(PKG_CONFIG_PATH="$(dirname "$pc")" pkg-config --variable="$var" libplacebo)" != "1" ]; then
            echo "ERROR: libplacebo was built without ${var#pl_has_}" >&2
            exit 1
        fi
    done
}

clone_source
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
