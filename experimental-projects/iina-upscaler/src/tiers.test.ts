import { describe, expect, test } from "bun:test";
import { budgetMs, chooseChain, estimateMs, renderRate, scaleFactor, tierName, type Playback } from "./tiers";

const FULL = { outWidth: 3456, outHeight: 2160 };
const size = (h: number) => ({ width: Math.round((h * 16) / 9 / 2) * 2, height: h });
const play = (h: number, extra: Partial<Playback> = {}): Playback => ({
  ...size(h),
  ...FULL,
  fps: 59.94,
  displayFps: 120,
  renderer: "vulkan",
  ...extra,
});
const pick = (h: number, extra: Partial<Playback> = {}) => chooseChain(play(h, extra)).chain.id;

describe("reproduces vk-probe RESULTS.md (60 fps, full screen)", () => {
  test("the measured tier mapping", () => {
    expect(pick(240)).toBe("artcnn32");
    for (const h of [360, 480, 720]) expect(pick(h)).toBe("artcnn16");
    for (const h of [1080, 1440]) expect(pick(h)).toBe("builtin");
  });

  // Each measured chain must land on the same side of the budget as its dropped-frame result.
  const MEASURED: [number, string, number, boolean][] = [
    // [source height, chain, measured ms, passed]
    [240, "artcnn32", 11.0, true],
    [360, "artcnn16", 8.6, true],
    [360, "artcnn32", 14.1, false],
    [480, "artcnn16", 9.4, true],
    [480, "artcnn32", 20.8, false],
    [720, "artcnn16", 13.8, true],
    [1080, "artcnn16", 22.0, false],
    [240, "builtin", 9.0, true],
    [1440, "builtin", 11.1, true],
  ];
  for (const [h, id, ms, passed] of MEASURED) {
    test(`${id} at ${h}p: measured ${ms} ms, ${passed ? "pass" : "fail"}`, () => {
      const estimate = estimateMs(id, play(h));
      expect(Math.abs(estimate - ms)).toBeLessThan(1.5);
      expect(estimate <= budgetMs(play(h))).toBe(passed);
    });
  }
});

describe("frame rate", () => {
  test("a 60 fps video on a 120 Hz display renders 60 times per second", () => {
    expect(renderRate({ fps: 59.94, displayFps: 120 })).toBe(59.94);
  });

  test("interpolation renders on every refresh", () => {
    expect(renderRate({ fps: 24, displayFps: 120, interpolation: true })).toBe(120);
  });

  test("an unknown frame rate assumes one render per refresh", () => {
    expect(renderRate({ fps: 0, displayFps: 120 })).toBe(120);
  });

  test("a 120 fps video gets a cheaper chain than a 60 fps video", () => {
    expect(pick(240, { fps: 120 })).toBe("fast");
    expect(pick(1080, { fps: 120 })).toBe("fast");
  });

  test("a 30 fps video can afford C4F32 at 360p", () => {
    expect(pick(360, { fps: 30 })).toBe("artcnn32");
  });

  test("a 24 fps film can afford C4F16 at 1080p", () => {
    expect(pick(1080, { fps: 23.976 })).toBe("artcnn16");
  });
});

describe("output size", () => {
  test("a smaller window costs less, so C4F32 fits at 360p", () => {
    expect(pick(360, { outWidth: 1728, outHeight: 1080 })).toBe("artcnn32");
  });

  test("no doubler when the video barely grows", () => {
    // 720p in a 1280x720 window does not grow at all.
    expect(pick(720, { outWidth: 1280, outHeight: 720 })).toBe("builtin");
  });

  test("a wide film is limited by its width", () => {
    expect(scaleFactor({ width: 1920, height: 800, ...FULL })).toBeCloseTo(1.8);
  });

  test("a rotated phone video swaps its axes", () => {
    expect(scaleFactor({ width: 1280, height: 720, rotate: 90, ...FULL })).toBeCloseTo(2160 / 1280);
  });
});

test("OpenGL never gets a compute shader", () => {
  for (const h of [240, 360, 480, 720, 1080]) {
    expect(["fsrcnnx", "builtin", "fast"]).toContain(pick(h, { renderer: "opengl" }));
  }
  expect(pick(360, { renderer: "opengl" })).toBe("fsrcnnx");
  expect(pick(480, { renderer: "opengl" })).toBe("builtin");
});

test("tier names clamp the short side to 240-1440", () => {
  expect(tierName(160, 120)).toBe("240p");
  expect(tierName(640, 360)).toBe("360p");
  expect(tierName(3840, 2160)).toBe("1440p");
});
