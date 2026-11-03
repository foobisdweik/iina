// IINA entry point. IINA runs one copy of this script for each player window.
//
// The plugin reads the video size, the output size and the frame rates from mpv, and applies the chain that tiers.ts
// picks. It changes mpv options only when the chain changes, because each change of `glsl-shaders` makes mpv recompile
// every shader.

import { chooseChain, MANAGED_OPTIONS, tierName, type Playback, type Renderer } from "./tiers";

// The parts of IINA's plugin API that this file uses.
declare const iina: {
  core: { osd(message: string): void; status: { renderAPI?: string | null } };
  mpv: {
    getFlag(name: string): boolean;
    getNumber(name: string): number;
    getString(name: string): string | null;
    getNative(name: string): unknown;
    set(name: string, value: unknown): void;
  };
  event: { on(name: string, callback: () => void): void };
  menu: {
    item(title: string, action: () => void, options?: { selected?: boolean }): { selected: boolean; title: string };
    addItem(item: unknown): void;
    forceUpdate(): void;
  };
  preferences: { get(key: string): unknown; set(key: string, value: unknown): void };
  utils: { resolvePath(path: string): string | null };
  console: { log(message: string): void; error(message: string): void };
};
// IINA's plugin runtime provides these timers.
declare function setTimeout(callback: () => void, ms: number): string;
declare function clearTimeout(id: string): void;

const { core, mpv, event, menu, preferences, utils, console } = iina;

/** The user's values of MANAGED_OPTIONS from before the plugin's first change, or null when nothing is changed. */
let saved: Record<string, unknown> | null = null;
/** The renderer and chain applied now, for example "vulkan:artcnn16". */
let appliedKey: string | null = null;

function enabled(): boolean {
  return preferences.get("enabled") !== false;
}

/** Shows the state briefly on the video and keeps it in the Plugin menu, because the on-screen message fades. */
function show(message: string) {
  core.osd(message);
  toggle.title = message;
  menu.forceUpdate();
}

function restore() {
  if (!saved) return;
  for (const [name, value] of Object.entries(saved)) mpv.set(name, value);
  saved = null;
  appliedKey = null;
  show("Upscaler: off");
}

/** Reads the playback state from mpv, or returns null when mpv cannot render the video yet. */
function readPlayback(): Playback | null {
  const width = mpv.getNumber("video-params/w");
  const height = mpv.getNumber("video-params/h");
  // osd-width and osd-height are the size that IINA renders into: the video area of the window, in pixels.
  const outWidth = mpv.getNumber("osd-width");
  const outHeight = mpv.getNumber("osd-height");
  // mpv has no video parameters before the first frame is decoded, and none for audio-only files.
  if (!(width > 0 && height > 0 && outWidth > 0 && outHeight > 0)) return null;

  // renderAPI is null until IINA has created the mpv render context. Stock IINA has no such property, and it only
  // renders with OpenGL.
  const api = core.status.renderAPI;
  if (api === null) return null;
  const renderer: Renderer = api === "vulkan" ? "vulkan" : "opengl";

  return {
    width,
    height,
    rotate: mpv.getNumber("video-params/rotate") || 0,
    outWidth,
    outHeight,
    fps: mpv.getNumber("container-fps") || 0,
    // IINA sets display-fps from the screen's refresh rate (display-fps-override), for example 120 on ProMotion.
    displayFps: mpv.getNumber("display-fps") || 0,
    interpolation: mpv.getFlag("interpolation") && (mpv.getString("video-sync") ?? "").startsWith("display-"),
    renderer,
  };
}

function apply() {
  if (!enabled()) return restore();
  const playback = readPlayback();
  if (!playback) return;

  const { chain, costMs, budgetMs, scale } = chooseChain(playback);
  const key = `${playback.renderer}:${chain.id}`;
  if (key === appliedKey) return;

  // mpv reads shader files by absolute path. "@plugin/" exists only in the IINA fork.
  const paths = chain.shaders.map((file) => utils.resolvePath(`@plugin/shaders/${file}`));
  if (paths.some((path) => !path)) {
    console.error("Cannot resolve the shader folder. This plugin needs the IINA fork with @plugin/ paths.");
    return;
  }

  if (!saved) {
    saved = {};
    for (const name of MANAGED_OPTIONS) saved[name] = mpv.getNative(name);
  }
  for (const [name, value] of Object.entries(chain.options)) mpv.set(name, value);
  mpv.set("glsl-shaders", paths);
  appliedKey = key;

  const { width, height, outWidth, outHeight, fps, displayFps } = playback;
  const message = `Upscaler: ${tierName(width, height)} → ${chain.label}`;
  console.log(
    `${message} (${playback.renderer}, ${width}x${height} to ${outWidth}x${outHeight}, ${scale.toFixed(2)}x, ` +
      `${fps.toFixed(2)} fps on ${displayFps.toFixed(0)} Hz, estimate ${costMs.toFixed(1)} of ${budgetMs.toFixed(1)} ms)`,
  );
  show(message);
}

// A window resize or the full-screen animation changes the output size many times per second. Waiting until the
// changes stop avoids a shader recompile for every step.
let pending: string | null = null;
function schedule() {
  if (pending !== null) clearTimeout(pending);
  pending = setTimeout(() => {
    pending = null;
    apply();
  }, 400);
}

const toggle = menu.item(
  "Upscaler: waiting for video",
  () => {
    const on = !enabled();
    preferences.set("enabled", on);
    toggle.selected = on;
    menu.forceUpdate();
    if (on) apply();
    else restore();
  },
  { selected: enabled() },
);
menu.addItem(toggle);

event.on("iina.file-loaded", schedule);
// IINA observes every plugin property as a number. mpv cannot convert a structure such as `osd-dimensions` to a number, so
// it would report "no value" once and never again. So the plugin observes the numeric sub-properties. A change of
// `interpolation` or `video-sync` (not numbers) takes effect at the next file or size change.
for (const property of ["video-params/w", "video-params/h", "osd-width", "osd-height", "container-fps", "display-fps"]) {
  event.on(`mpv.${property}.changed`, schedule);
}
