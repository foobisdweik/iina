#!/bin/bash
# Replacement for buildscripts/build-mpv.sh in iina/deps-buildscripts.
#
# other/build_deps.sh copies this file over the original. The original script
# downloads a release tarball. This script clones mpv at the commit in
# MPV_COMMIT instead, because no mpv release has the gpu-next render API yet.
# The meson options are the same as in the original script.
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="mpv"
: "${MPV_REPO:?MPV_REPO must be set by other/build_deps.sh}"
: "${MPV_COMMIT:?MPV_COMMIT must be set by other/build_deps.sh}"
VERSION="${MPV_COMMIT:0:12}"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

# Clone mpv at MPV_COMMIT and check that the checkout is exactly that commit.
# The source directory is always recreated so that patches apply to clean code.
clone_source() {
    rm -rf "$SRC_DIR"
    log_step "Cloning: ${DEP_NAME} ${MPV_COMMIT}"
    git init -q "$SRC_DIR"
    git -C "$SRC_DIR" remote add origin "$MPV_REPO"
    git -C "$SRC_DIR" fetch -q --depth 1 origin "$MPV_COMMIT"
    git -C "$SRC_DIR" checkout -q FETCH_HEAD
    local head
    head="$(git -C "$SRC_DIR" rev-parse HEAD)"
    if [ "$head" != "$MPV_COMMIT" ]; then
        echo "ERROR: mpv checkout is ${head}, expected ${MPV_COMMIT}" >&2
        exit 1
    fi
}

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    meson_setup "$build_dir" "$SRC_DIR" "$arch" \
        -Dlibmpv=true \
        -Dcplayer=false \
        -Dmacos-cocoa-cb=disabled \
        -Dmacos-touchbar=disabled \
        -Dmacos-media-player=disabled \
        -Dmanpage-build=disabled \
        -Dtests=false \
        -Dlua=luajit \
        -Djavascript=enabled \
        -Dlcms2=enabled \
        -Dvulkan=disabled \
        -Dgl=enabled \
        -Dzimg=enabled \
        -Dlibbluray=enabled \
        -Dlibarchive=enabled \
        -Duchardet=enabled \
        -Djpeg=enabled \
        -Drubberband=enabled \
        -Dswift-flags="-target ${arch}-apple-macosx${MACOSX_DEPLOYMENT_TARGET}"

    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install

    # Stop here if the patch did not add the gpu-next render API. Without this
    # check IINA would build, but silently fall back to the legacy renderer.
    if ! grep -q 'MPV_RENDER_API_TYPE_OPENGL_NEXT' "$(get_prefix "$arch")/include/mpv/render.h"; then
        echo "ERROR: the installed mpv/render.h has no MPV_RENDER_API_TYPE_OPENGL_NEXT" >&2
        exit 1
    fi
}

clone_source
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
