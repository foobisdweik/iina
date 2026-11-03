// Downloads the shaders into shaders/ at pinned versions and checks each file's SHA-256, so that a build always bundles the
// exact files that vk-probe measured. The plugin itself never downloads anything.
//
// These pins match the files in experimental-projects/vk-probe/shaders byte for byte (checked on 2026-11-03).

import { ALL_SHADERS } from "../src/tiers";

const ARTCNN = "https://raw.githubusercontent.com/Artoriuz/ArtCNN/0837e5326e710f49e2ab0a8d995da0708047442e/GLSL";
const CFL =
  "https://raw.githubusercontent.com/Artoriuz/glsl-chroma-from-luma-prediction/066dff964b83aa34e893de25d590874bf8c8e94f";
const FSRCNNX = "https://github.com/igv/FSRCNN-TensorFlow/releases/download/1.1";

// License: ArtCNN and CfL are MIT. FSRCNNX is LGPL-3.0. Each license header stays inside its file.
const PINS: Record<string, { url: string; sha256: string }> = {
  "ArtCNN_C4F16_DS.glsl": {
    url: `${ARTCNN}/ArtCNN_C4F16_DS.glsl`,
    sha256: "57df650fddec3969e17799f5522c9b03dd2d33b1aeace237fef216bf3858125a",
  },
  "ArtCNN_C4F32_DS.glsl": {
    url: `${ARTCNN}/ArtCNN_C4F32_DS.glsl`,
    sha256: "a04c9cba6fbb8e6db9239d61848390208aedf8e348ef116e12174c803d22077e",
  },
  "CfL_Prediction.glsl": {
    url: `${CFL}/CfL_Prediction.glsl`,
    sha256: "f9d12d38d4bab4d9db266b5982c81fadca907396212e22fd8b2c1ca2f317b716",
  },
  "FSRCNNX_x2_16-0-4-1.glsl": {
    url: `${FSRCNNX}/FSRCNNX_x2_16-0-4-1.glsl`,
    sha256: "d5a24a271e5d9a3f7f7a053b150c460a44c25b3cf7f770857d57cc3a2e1c9965",
  },
};

const dir = new URL("../shaders/", import.meta.url);

function sha256(bytes: ArrayBuffer | Uint8Array): string {
  return new Bun.CryptoHasher("sha256").update(bytes).digest("hex");
}

for (const name of ALL_SHADERS) {
  const pin = PINS[name];
  if (!pin) throw new Error(`No pin for ${name}. Add it to PINS.`);
  const file = Bun.file(new URL(name, dir));
  if ((await file.exists()) && sha256(await file.arrayBuffer()) === pin.sha256) continue;

  const response = await fetch(pin.url);
  if (!response.ok) throw new Error(`${name}: HTTP ${response.status} from ${pin.url}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const actual = sha256(bytes);
  if (actual !== pin.sha256) throw new Error(`${name}: SHA-256 is ${actual}, expected ${pin.sha256}`);
  await Bun.write(file, bytes);
  console.log(`fetched ${name}`);
}
console.log(`shaders ok: ${ALL_SHADERS.length} files`);
