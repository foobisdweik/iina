#!/bin/bash
# Candidate upscaling chains for vk-probe. Each chain is a list of mpv
# options. Shader paths are relative to this folder.
#
# Every chain except "baseline" adds CfL_Prediction, which rebuilds the
# half-size color planes (chroma) of 4:2:0 video from the full-size
# brightness plane (luma).

S=shaders
CFL="--glsl-shaders-append=$S/CfL_Prediction.glsl"
# FAST ends with the cheaper separable lanczos (two 1-D passes) in place
# of the polar EWA filter, to save time at 60 fps.
FAST="--scale=lanczos --cscale=lanczos --dscale=catmull_rom --scale-antiring=0.6 --sigmoid-upscaling --deband=no"
BASE="--scale=ewa_lanczos4sharpest --cscale=ewa_lanczos4sharpest --dscale=catmull_rom --scale-antiring=0.6 --sigmoid-upscaling --deband=no"

chain_opts() {
  case "$1" in
    baseline)     echo "$BASE" ;;
    artcnn16ds)   echo "$BASE $CFL --glsl-shaders-append=$S/ArtCNN_C4F16_DS.glsl" ;;
    artcnn32ds)   echo "$BASE $CFL --glsl-shaders-append=$S/ArtCNN_C4F32_DS.glsl" ;;
    artcnn16)     echo "$BASE $CFL --glsl-shaders-append=$S/ArtCNN_C4F16.glsl" ;;
    fsrcnnx16)    echo "$BASE $CFL --glsl-shaders-append=$S/FSRCNNX_x2_16-0-4-1.glsl" ;;
    ravuzoom)     echo "$BASE $CFL --glsl-shaders-append=$S/ravu-zoom-ar-r3.compute.hook" ;;
    # Two doublers in a row: the second runs on the output of the first.
    # gpu-next parses each shader path once and reuses it, so the second
    # doubler loads a copy under another name.
    artcnn16ds2x) echo "$BASE $CFL --glsl-shaders-append=$S/ArtCNN_C4F16_DS.glsl --glsl-shaders-append=$S/ArtCNN_C4F16_DS.second.glsl" ;;
    artcnn16ds_fast) echo "$FAST $CFL --glsl-shaders-append=$S/ArtCNN_C4F16_DS.glsl" ;;
    artcnn32ds_fast) echo "$FAST $CFL --glsl-shaders-append=$S/ArtCNN_C4F32_DS.glsl" ;;
    *) echo "unknown chain: $1" >&2; return 1 ;;
  esac
}

ALL_CHAINS="baseline artcnn16ds artcnn32ds artcnn16 fsrcnnx16 ravuzoom artcnn16ds2x artcnn16ds_fast artcnn32ds_fast"
