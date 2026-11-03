// Chooses an upscaling chain from the video, the output size and the frame rate. This file has no IINA calls, so
// `bun test` can run it.
//
// How the choice works:
// 1. The output size and the frame rate set a time budget for each rendered frame.
// 2. A cost model estimates the GPU time of each chain for this video and output size.
// 3. The plugin takes the best chain whose estimated time fits the budget.
//
// The cost model is fitted to experimental-projects/vk-probe/RESULTS.md, which measured an M1 Pro in full screen at
// 3456x2160 with 59.94 fps HDR10 sources on Vulkan. tiers.test.ts checks that the model reproduces every measured
// pass and fail. Other output sizes and frame rates are extrapolations from the model, not measurements.

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

/** What the plugin knows about the playback, read from mpv. */
export interface Playback {
  /** The decoded video size in pixels (`video-params/w` and `h`). */
  width: number;
  height: number;
  /** `video-params/rotate`. A 90 or 270 degree rotation swaps the axes on screen. */
  rotate?: number;
  /** The output size in pixels: the whole video area of the window (`osd-width` and `osd-height`). */
  outWidth: number;
  outHeight: number;
  /** The video frame rate (`container-fps`). 0 or less means unknown. */
  fps: number;
  /** The display refresh rate (`display-fps`), which IINA sets from the screen. 0 or less means unknown. */
  displayFps: number;
  /** `true` when mpv draws a frame on every display refresh: `video-sync=display-*` with `interpolation`. */
  interpolation?: boolean;
  renderer: Renderer;
}

// The final scaler fits the shader output to the screen. Separable `lanczos` (two 1-D passes) saved 3-4 ms per frame over
// the polar `ewa_lanczos4sharpest` and cost at most 0.0003 SSIM.
const FAST_FINAL = {
  scale: "lanczos",
  cscale: "lanczos",
  dscale: "catmull_rom",
  "scale-antiring": "0.6",
  "sigmoid-upscaling": "yes",
};
const EWA_FINAL = { ...FAST_FINAL, scale: "ewa_lanczos4sharpest", cscale: "ewa_lanczos4sharpest" };

/** Every option that any chain sets. The plugin saves these before its first change and restores them later. */
export const MANAGED_OPTIONS = ["glsl-shaders", ...Object.keys(FAST_FINAL)];

// CfL_Prediction rebuilds the half-size color planes (chroma) of 4:2:0 video from the full-size brightness plane (luma).
// It is a fragment shader, so it runs on OpenGL too.
const CFL = "CfL_Prediction.glsl";

/**
 * A chain with its cost model. Costs are in milliseconds of GPU time per rendered frame, with the sizes in megapixels:
 * `src` is the decoded video, and `out` is the area the video covers on screen.
 */
interface Candidate extends Chain {
  /** The chain runs only on these renderers. */
  renderers: Renderer[];
  /** A doubler only helps when the video grows at least this much. Below 2x the doubled frame is scaled down again. */
  minScale: number;
  cost(src: number, out: number): number;
}

// Fitted to RESULTS.md:
// - Final scaler: `lanczos` about 1.5 + 0.55 ms/MP of output, and `ewa_lanczos4sharpest` about 1.5 + 1.0 ms/MP.
//   At 3456x2160 (7.46 MP) these give 5.6 and 9.0 ms. The baseline grew from 9.0 to 11.1 ms between 240p and 1440p
//   sources, so every chain also pays about 0.55 ms per source MP for upload and the source-size passes.
// - ArtCNN C4F16 about 2 + 6.3 ms/MP of source, and C4F32 about 2 + 33 ms/MP: C4F32 is about 5 times more work.
// - FSRCNNX about 2 + 20 ms/MP. Its Vulkan timings were unreliable, so this only matches its dropped frames: it passed
//   at 360p and dropped frames from 480p up. On OpenGL it is not measured.
const fast = (out: number) => 1.5 + 0.55 * out;
const ewa = (out: number) => 1.5 + 1.0 * out;
const upload = (src: number) => 0.55 * src;

/** Candidates from best to cheapest quality. The plugin takes the first one that fits. */
const CANDIDATES: Candidate[] = [
  {
    id: "artcnn32",
    label: "ArtCNN C4F32 + CfL",
    shaders: [CFL, "ArtCNN_C4F32_DS.glsl"],
    options: FAST_FINAL,
    renderers: ["vulkan"],
    minScale: 1.5,
    cost: (src, out) => 2 + 33 * src + fast(out) + upload(src),
  },
  {
    id: "artcnn16",
    label: "ArtCNN C4F16 + CfL",
    shaders: [CFL, "ArtCNN_C4F16_DS.glsl"],
    options: FAST_FINAL,
    renderers: ["vulkan"],
    minScale: 1.5,
    cost: (src, out) => 2 + 6.3 * src + fast(out) + upload(src),
  },
  {
    id: "fsrcnnx",
    label: "FSRCNNX + CfL",
    shaders: [CFL, "FSRCNNX_x2_16-0-4-1.glsl"],
    options: FAST_FINAL,
    renderers: ["opengl"],
    minScale: 1.5,
    cost: (src, out) => 2 + 20 * src + fast(out) + upload(src),
  },
  {
    id: "builtin",
    label: "ewa_lanczos4sharpest",
    shaders: [],
    options: EWA_FINAL,
    renderers: ["vulkan", "opengl"],
    minScale: 0,
    cost: (src, out) => ewa(out) + upload(src),
  },
  // The last resort always fits, so the plugin always has a chain.
  {
    id: "fast",
    label: "lanczos",
    shaders: [],
    options: FAST_FINAL,
    renderers: ["vulkan", "opengl"],
    minScale: 0,
    cost: (src, out) => fast(out) + upload(src),
  },
];

/** Every shader file that a chain can load. scripts/fetch-shaders.ts downloads these. */
export const ALL_SHADERS = [...new Set(CANDIDATES.flatMap((c) => c.shaders))];

/**
 * The share of each frame interval that the chain may use. In RESULTS.md at 60 fps (16.7 ms), 13.8 ms kept the dropped
 * frames at the baseline's level and 14.1 ms did not, so the limit is about 85%. The rest is for presenting the frame
 * and for other GPU work on the desktop.
 */
export const BUDGET_SHARE = 0.85;

/**
 * Returns how much the video must grow to fill the output: the smaller of the two axis ratios, because the video keeps
 * its aspect ratio.
 */
export function scaleFactor(p: Pick<Playback, "width" | "height" | "rotate" | "outWidth" | "outHeight">): number {
  const [w, h] = (p.rotate ?? 0) % 180 === 90 ? [p.height, p.width] : [p.width, p.height];
  return Math.min(p.outWidth / w, p.outHeight / h);
}

/**
 * Returns how many frames mpv renders per second. Without interpolation, mpv renders each video frame once, and the
 * display repeats it, so a 60 fps video on a 120 Hz display renders 60 times per second. With interpolation, mpv renders
 * on every refresh. A video faster than the display cannot render faster than the display shows it.
 */
export function renderRate(p: Pick<Playback, "fps" | "displayFps" | "interpolation">): number {
  const display = p.displayFps > 0 ? p.displayFps : 0;
  if (p.interpolation && display) return display;
  if (p.fps > 0) return display ? Math.min(p.fps, display) : p.fps;
  // An unknown video frame rate (for example some live streams) gets the worst case: one render per refresh.
  return display || 60;
}

/** Returns the time budget for one rendered frame, in milliseconds. */
export function budgetMs(p: Playback): number {
  return (BUDGET_SHARE * 1000) / renderRate(p);
}

export interface Choice {
  chain: Chain;
  /** The model's estimate for this chain, in milliseconds. */
  costMs: number;
  budgetMs: number;
  scale: number;
}

/** Returns the model's estimate for one chain, in milliseconds, ignoring whether it fits. For tests and the log. */
export function estimateMs(id: string, p: Playback): number {
  const candidate = CANDIDATES.find((c) => c.id === id);
  if (!candidate) throw new Error(`unknown chain: ${id}`);
  const scale = scaleFactor(p);
  const src = (p.width * p.height) / 1e6;
  return candidate.cost(src, src * scale * scale);
}

/** Picks the best chain whose estimated GPU time fits the frame budget. */
export function chooseChain(p: Playback): Choice {
  const scale = scaleFactor(p);
  const src = (p.width * p.height) / 1e6;
  const out = src * scale * scale;
  const budget = budgetMs(p);
  const usable = CANDIDATES.filter((c) => c.renderers.includes(p.renderer) && scale >= c.minScale);
  const fits = usable.find((c) => c.cost(src, out) <= budget) ?? usable[usable.length - 1];
  const { id, label, shaders, options } = fits;
  return { chain: { id, label, shaders, options }, costMs: fits.cost(src, out), budgetMs: budget, scale };
}

/** Names the source size for the on-screen display, from its short side clamped to 240-1440, for example "360p". */
export function tierName(width: number, height: number): string {
  const short = Math.min(Math.max(Math.min(width, height), 240), 1440);
  const names = [240, 360, 480, 720, 1080, 1440];
  const nearest = names.reduce((a, b) => (Math.abs(b - short) < Math.abs(a - short) ? b : a));
  return `${nearest}p`;
}
