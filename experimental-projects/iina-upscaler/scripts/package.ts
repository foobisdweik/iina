// Makes upscaler.iinaplgz: a zip with the manifest, the bundled script and the shaders. Open it in IINA to install.

import { $ } from "bun";

const root = new URL("..", import.meta.url).pathname;
await $`rm -f upscaler.iinaplgz && zip -qr upscaler.iinaplgz Info.json dist shaders`.cwd(root);
console.log(`${root}upscaler.iinaplgz`);
