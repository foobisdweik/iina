# iina-upscaler

An IINA plugin that picks an mpv upscaling shader chain from each video's size. The tiers come from `../vk-probe/RESULTS.md`.

| Source (16:9) | Vulkan renderer | OpenGL renderer |
|---|---|---|
| about 288p or less | ArtCNN C4F32 + CfL, final `lanczos` | FSRCNNX + CfL, final `lanczos` |
| about 289p–864p | ArtCNN C4F16 + CfL, final `lanczos` | FSRCNNX + CfL, final `lanczos` |
| above about 864p | `ewa_lanczos4sharpest` only | `ewa_lanczos4sharpest` only |

The plugin decides by the scale factor `min(3456 / w, 2160 / h)`, so a wide film is judged by its width.

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
- Sources above 60 fps, and 30 fps sources, where C4F32 could probably also fit at 360p.
