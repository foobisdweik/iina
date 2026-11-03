# iina-upscaler

An IINA plugin that picks an mpv upscaling shader chain for each video. It takes the best chain whose estimated GPU time
fits the time of one frame.

How it chooses:

1. It reads the video size, the output size (`osd-width` and `osd-height`), the video frame rate (`container-fps`) and
   the display refresh rate (`display-fps`) from mpv.
2. It computes how many frames mpv renders per second. Without interpolation this is the video frame rate, capped at
   the display refresh rate. With interpolation it is the display refresh rate.
3. The budget for one frame is 85% of the frame interval. In `../vk-probe/RESULTS.md`, 13.8 ms passed at 60 fps and
   14.1 ms did not.
4. A cost model, fitted to the Phase 0 timings, estimates each chain. The plugin takes the first chain that fits, in
   this order: ArtCNN C4F32, ArtCNN C4F16, FSRCNNX (OpenGL only), `ewa_lanczos4sharpest`, then `lanczos`.

Results at 3456x2160 full screen:

| Source | 24 fps | 30 fps | 60 fps | 120 fps |
|---|---|---|---|---|
| 240p | ArtCNN C4F32 | ArtCNN C4F32 | ArtCNN C4F32 | `lanczos` |
| 360p | ArtCNN C4F32 | ArtCNN C4F32 | ArtCNN C4F16 | `lanczos` |
| 720p | ArtCNN C4F16 | ArtCNN C4F16 | ArtCNN C4F16 | `lanczos` |
| 1080p | ArtCNN C4F16 | ArtCNN C4F16 | `ewa_lanczos4sharpest` | `lanczos` |

Only the 60 fps column is measured. The other columns come from the model. A smaller window lowers the cost of the
final scaler, so it can allow a better chain. The plugin waits 400 ms after the last size change before it switches,
so that a window resize does not recompile the shaders many times.

## Requirements

- The IINA fork in this repository. The plugin uses two fork-only APIs: `core.status.renderAPI` and `@plugin/` paths.
- For ArtCNN, turn on Settings > Video > "Use Vulkan renderer". OpenGL on macOS has no compute shaders.

## Build and install

1. `bun install` is not needed: the plugin has no dependencies.
2. Run `bun run package`. It downloads the shaders at pinned commits, checks their SHA-256, and makes `upscaler.iinaplgz`.
3. Open `upscaler.iinaplgz` with IINA to install it.

The plugin adds a menu item "Upscaler" under Plugin. Turning it off restores your own values of `glsl-shaders`, `scale`, `cscale`, `dscale`, `scale-antiring` and `sigmoid-upscaling`.

## Not measured

- The OpenGL chain. FSRCNNX dropped frames from 480p up on Vulkan, so it may be too slow on OpenGL.
- Every case except 60 fps in full screen. Those choices are estimates from the cost model.
