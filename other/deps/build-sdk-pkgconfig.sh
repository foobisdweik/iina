#!/bin/bash
# Point pkg-config at the zlib and expat of the macOS SDK.
#
# other/build_deps.sh copies this file into buildscripts/ of
# iina/deps-buildscripts and runs it before all other build scripts.
#
# Why: the SDK has no zlib.pc or expat.pc. When pkg-config does not find a
# library, meson falls back to CMake, and CMake on macOS also searches
# /opt/local (MacPorts) and /opt/homebrew. A dylib then links to, for
# example, /opt/local/lib/libz.1.dylib, and IINA fails to start on a Mac
# without that file. With these .pc files, pkg-config finds the SDK library
# first, so the dylibs link to /usr/lib/libz.1.dylib and
# /usr/lib/libexpat.1.dylib, which every Mac has.
set -euo pipefail
source "$(dirname "$0")/common.sh"

# sdk_header_version <header> <awk program>: read a version from an SDK header.
sdk_header_version() {
    awk "$2" "${MACOS_SDK}/usr/include/$1"
}

ZLIB_SDK_VERSION="$(sdk_header_version zlib.h '/#define ZLIB_VERSION /{gsub(/"/, "", $3); print $3; exit}')"
EXPAT_SDK_VERSION="$(sdk_header_version expat.h '
    /define XML_MAJOR_VERSION/{ma=$NF} /define XML_MINOR_VERSION/{mi=$NF}
    /define XML_MICRO_VERSION/{mc=$NF} END{print ma "." mi "." mc}')"
[ -n "$ZLIB_SDK_VERSION" ] || { echo "ERROR: no ZLIB_VERSION in the SDK's zlib.h" >&2; exit 1; }
[ "$EXPAT_SDK_VERSION" != ".." ] || { echo "ERROR: no version in the SDK's expat.h" >&2; exit 1; }

# write_pc <dir> <name> <description> <version> <library>
# No Cflags: the compiler already searches the SDK headers through -isysroot.
write_pc() {
    cat > "$1/$2.pc" <<EOF
Name: $2
Description: $3 (macOS SDK)
Version: $4
Libs: -l$5
Cflags:
EOF
}

for arch in $ARCHS; do
    pc_dir="$(get_prefix "$arch")/lib/pkgconfig"
    mkdir -p "$pc_dir"
    write_pc "$pc_dir" zlib "zlib compression library" "$ZLIB_SDK_VERSION" z
    write_pc "$pc_dir" expat "expat XML parser" "$EXPAT_SDK_VERSION" expat
    log_step "${arch}: zlib ${ZLIB_SDK_VERSION} and expat ${EXPAT_SDK_VERSION} from the macOS SDK"
done
