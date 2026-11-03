// IINA entry point. IINA runs one copy of this script for each player window.
//
// The plugin watches the video size and applies the chain from tiers.ts. It changes mpv options only when the chain
// changes, because each change of `glsl-shaders` makes mpv recompile every shader.

import { chooseChain, MANAGED_OPTIONS, tierName, type Renderer } from "./tiers";

// The parts of IINA's plugin API that this file uses.
declare const iina: {
  core: { osd(message: string): void; status: { renderAPI?: string | null } };
  mpv: {
    getNumber(name: string): number;
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

const { core, mpv, event, menu, preferences, utils, console } = iina;

/** The user's values of MANAGED_OPTIONS from before the plugin's first change, or null when nothing is changed. */
let saved: Record<string, unknown> | null = null;
/** The renderer and chain applied now, for example "vulkan:artcnn16". */
let appliedKey: string | null = null;

function enabled(): boolean {
  return preferences.get("enabled") !== false;
}

function restore() {
  if (!saved) return;
  for (const [name, value] of Object.entries(saved)) mpv.set(name, value);
  saved = null;
  appliedKey = null;
  show("Upscaler: off");
}

/** Shows the state briefly on the video and keeps it in the Plugin menu, because the on-screen message fades. */
function show(message: string) {
  core.osd(message);
  toggle.title = message;
  menu.forceUpdate();
}

function apply() {
  if (!enabled()) return restore();

  const width = mpv.getNumber("video-params/w");
  const height = mpv.getNumber("video-params/h");
  // mpv has no video parameters before the first frame is decoded, and none for audio-only files.
  if (!(width > 0 && height > 0)) return;

  // renderAPI is null until IINA has created the mpv render context. Stock IINA has no such property, and it only renders
  // with OpenGL.
  const api = core.status.renderAPI;
  if (api === null) return;
  const renderer: Renderer = api === "vulkan" ? "vulkan" : "opengl";

  const chain = chooseChain(width, height, renderer, mpv.getNumber("video-params/rotate") || 0);
  const key = `${renderer}:${chain.id}`;
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

  const message = `Upscaler: ${tierName(width, height)} → ${chain.label}`;
  console.log(`${message} (${renderer}, ${width}x${height})`);
  show(message);
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

event.on("iina.file-loaded", apply);
// The size can change inside one file, for example at a resolution switch in an adaptive stream.
event.on("mpv.video-params.changed", apply);
