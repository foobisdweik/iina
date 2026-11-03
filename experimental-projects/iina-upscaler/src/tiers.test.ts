import { expect, test } from "bun:test";
import { chooseChain, scaleFactor, tierName } from "./tiers";

const size = (h: number) => [Math.round((h * 16) / 9), h] as const;

test("Vulkan tiers match vk-probe RESULTS.md", () => {
  expect(chooseChain(...size(240), "vulkan").id).toBe("artcnn32");
  for (const h of [360, 480, 720]) expect(chooseChain(...size(h), "vulkan").id).toBe("artcnn16");
  for (const h of [1080, 1440, 2160]) expect(chooseChain(...size(h), "vulkan").id).toBe("builtin");
});

test("OpenGL never gets a compute shader", () => {
  expect(chooseChain(...size(240), "opengl").id).toBe("fsrcnnx");
  expect(chooseChain(...size(720), "opengl").id).toBe("fsrcnnx");
  expect(chooseChain(...size(1080), "opengl").id).toBe("builtin");
});

test("a wide film is limited by its width", () => {
  // 1920x800 must grow only 1.8x to fill 3456 pixels of width, so it gets the built-in scaler.
  expect(scaleFactor(1920, 800)).toBeCloseTo(1.8);
  expect(chooseChain(1920, 800, "vulkan").id).toBe("builtin");
});

test("a rotated phone video swaps its axes", () => {
  // 1280x720 rotated 90 degrees shows as 720x1280, which needs only 2160/1280 = 1.69x.
  expect(chooseChain(1280, 720, "vulkan", 90).id).toBe("builtin");
  expect(chooseChain(1280, 720, "vulkan", 0).id).toBe("artcnn16");
});

test("tier names clamp the short side to 240-1440", () => {
  expect(tierName(160, 120)).toBe("240p");
  expect(tierName(640, 360)).toBe("360p");
  expect(tierName(1920, 1080)).toBe("1080p");
  expect(tierName(3840, 2160)).toBe("1440p");
});
