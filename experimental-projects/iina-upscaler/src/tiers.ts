// Chooses an upscaling chain from the video size and the renderer. This file has no IINA calls, so `bun test` can run it.
//
// The tiers come from experimental-projects/vk-probe/RESULTS.md, measured on an M1 Pro in full screen at 3456x2160 with
// 59.94 fps HDR10 sources. A chain passed when it dropped no more frames than the built-in scaler.

/** The display size that the tiers were measured at. */
export const DISPLAY = { width: 3456, height: 2160 } as const;

/** The mpv render API, from `iina.core.status.renderAPI`. Only "vulkan" can run compute shaders such as ArtCNN. */
export type Renderer = "vulkan" | "opengl";

export interface Chain {
  /** A stable key. The plugin re-applies options only when this key changes. */
  id: string;
  /** Text for the on-screen display. */
  label: string;
  /** Shader file names inside the plugin's `shaders/` folder, in the order mpv runs them. */
  shaders: string[];
  /** mpv options that the chain sets. */
  options: Record<string, string>;
}

// The final scaler fits the shader output to the screen. Separable `lanczos` (two 1-D passes) saved 3-4 ms per frame over
// the polar `ewa_lanczos4sharpest` and cost at most 0.0003 SSIM, and that saving is what let 720p run at 60 fps.
const FAST_FINAL = {
  scale: "lanczos",
  cscale: "lanczos",
  dscale: "catmull_rom",
  "scale-antiring": "0.6",
  "sigmoid-upscaling": "yes",
};

const BUILTIN_FINAL = { ...FAST_FINAL, scale: "ewa_lanczos4sharpest", cscale: "ewa_lanczos4sharpest" };

/** Every option that any chain sets. The plugin saves these before its first change and restores them later. */
export const MANAGED_OPTIONS = ["glsl-shaders", ...Object.keys(FAST_FINAL)];

// CfL_Prediction rebuilds the half-size color planes (chroma) of 4:2:0 video from the full-size brightness plane (luma).
// It is a fragment shader, so it runs on OpenGL too.
const CFL = "CfL_Prediction.glsl";

const CHAINS = {
  artcnn32: {
    id: "artcnn32",
    label: "ArtCNN C4F32 + CfL",
    shaders: [CFL, "ArtCNN_C4F32_DS.glsl"],
    options: FAST_FINAL,
  },
  artcnn16: {
    id: "artcnn16",
    label: "ArtCNN C4F16 + CfL",
    shaders: [CFL, "ArtCNN_C4F16_DS.glsl"],
    options: FAST_FINAL,
  },
  // FSRCNNX is a fragment-shader doubler, so it runs on OpenGL, which has no compute shaders. Its speed on OpenGL here
  // is not measured: on Vulkan it dropped frames from 480p up.
  fsrcnnx: {
    id: "fsrcnnx",
    label: "FSRCNNX + CfL (OpenGL)",
    shaders: [CFL, "FSRCNNX_x2_16-0-4-1.glsl"],
    options: FAST_FINAL,
  },
  builtin: {
    id: "builtin",
    label: "ewa_lanczos4sharpest",
    shaders: [],
    options: BUILTIN_FINAL,
  },
} satisfies Record<string, Chain>;

/** Every shader file that a chain can load. scripts/fetch-shaders.ts downloads these. */
export const ALL_SHADERS = [...new Set(Object.values(CHAINS).flatMap((c) => c.shaders))];

/**
 * Returns how much the video must grow to fill the display: the smaller of the two axis ratios, because the video keeps
 * its aspect ratio. `rotate` is mpv's `video-params/rotate`. A 90 or 270 degree rotation swaps the axes on screen.
 */
export function scaleFactor(width: number, height: number, rotate = 0): number {
  const [w, h] = rotate % 180 === 90 ? [height, width] : [width, height];
  return Math.min(DISPLAY.width / w, DISPLAY.height / h);
}

/** Names the source size for the on-screen display, from its short side clamped to 240-1440, for example "360p". */
export function tierName(width: number, height: number): string {
  const short = Math.min(Math.max(Math.min(width, height), 240), 1440);
  const names = [240, 360, 480, 720, 1080, 1440];
  const nearest = names.reduce((a, b) => (Math.abs(b - short) < Math.abs(a - short) ? b : a));
  return `${nearest}p`;
}

/**
 * Picks the chain for a video. The thresholds sit between the measured sizes, so that sizes such as 288p or 540p fall to
 * the nearer tier:
 * - scale factor 7.5 or more (about 288p or less for 16:9): ArtCNN C4F32. It fit 60 fps only at 240p (11.0 ms).
 * - 2.5 or more (about 864p or less): ArtCNN C4F16. It fit 60 fps from 360p to 720p (8.6-13.8 ms).
 * - less than 2.5 (1080p and up): the built-in scaler, because no shader chain gave a real gain at 1.5-2x.
 */
export function chooseChain(width: number, height: number, renderer: Renderer, rotate = 0): Chain {
  const s = scaleFactor(width, height, rotate);
  if (s < 2.5) return CHAINS.builtin;
  if (renderer !== "vulkan") return CHAINS.fsrcnnx;
  return s >= 7.5 ? CHAINS.artcnn32 : CHAINS.artcnn16;
}
