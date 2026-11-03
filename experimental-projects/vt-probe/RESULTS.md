# vtprobe results

Measured on 2026-11-02 on an Apple M1 Pro running macOS 27.2 (26B123), with `vtprobe` from this folder.

- **Clips:** synthetic, made by `make-clips.sh` (H.264, 30 fps, low bitrate).
- **Timing:** 300 frames per run, of which the first 10 are excluded as warm-up.
- **Gate:** a combination passes when its p95 time per frame is below half of the frame interval. That is 16.7 ms at 30 fps and 8.3 ms at 60 fps.

## Supported effects (`vtprobe caps`)

| Effect | Result |
|---|---|
| Low-latency super resolution (`llsr`) | Supported. Input from 96x96 to 1280x1280. The factors are 1.5×, 2× and 4×, each with its own input limit: 4× up to 480 px on the long side (230,400 px), 2× up to 960 px (921,600 px), 1.5× up to 1280 px (1,638,400 px). |
| Super resolution (`sr`) | Supported, at 4× only, for inputs up to 1920x1080. Needs a one-time model download from Apple. |
| Temporal noise filter (`tnf`) | **Not supported on this Mac** (`isSupported = 0`). |

## Factors per source size

| Source | llsr factors | sr factors |
|---|---|---|
| 426x240 | 1.5, 2, 4 | 4 |
| 640x360 | 1.5, 2 | 4 |
| 854x480 | 1.5, 2 | 4 |
| 1280x720 | 1.5 | 4 |
| 1920x1080 | none | 4 |
| 2560x1440 | none | none |

## Time per frame

Low Power Mode was **off** for these runs (`pmset -g`: `lowpowermode 0`), and the Mac was on battery power. Earlier runs in Low Power Mode were within about 10% for sr. For llsr they were up to about 45% slower at p95, but every one of them still passed.

| Source | Effect | Output | avg ms | p95 ms | 30 fps | 60 fps |
|---|---|---|---|---|---|---|
| 426x240 | llsr 4× | 1704x960 | 3.83 | 3.93 | PASS | PASS |
| 426x240 | llsr 2× | 852x480 | 1.51 | 2.10 | PASS | PASS |
| 640x360 | llsr 2× | 1280x720 | 1.88 | 2.39 | PASS | PASS |
| 854x480 | llsr 2× | 1708x960 | 1.94 | 2.18 | PASS | PASS |
| 854x480 | llsr 1.5× | 1281x720 | 2.07 | 2.98 | PASS | PASS |
| 1280x720 | llsr 1.5× | 1920x1080 | 3.03 | 3.22 | PASS | PASS |
| 426x240 | sr 4× | 1704x960 | 236 | 258 | FAIL | FAIL |
| 640x360 | sr 4× | 2560x1440 | 146 | 155 | FAIL | FAIL |
| 854x480 | sr 4× (Low Power Mode on) | 3416x1920 | 314 | 330 | FAIL | FAIL |
| 1280x720 | sr 4× (Low Power Mode on) | 5120x2880 | 565 | 733 | FAIL | FAIL |

Starting a session takes from 20 ms to 9 s, because it includes model loading. The filter must therefore start the session without blocking playback.

## Conclusions for the plugin

1. **Only llsr is usable for playback.** It runs at 2.1–3.9 ms (p95) per frame. sr is 10 to 40 times too slow, and tnf isn't available on this Mac.
2. **The VT stage per tier**, for the fixed 3456x2160 target:

| Tier | Source | VT stage | Size after VT | Left for gpu-next |
|---|---|---|---|---|
| T1 | 240p | llsr 4× | 1704x960 | about 2.0× |
| T2 | 360p | llsr 2×, then llsr 1.5× (chained, about 5.6 ms at p95) | 1920x1080 | about 1.8× |
| T2 | 480p | llsr 2× | 1708x960 | about 2.0× |
| T3 | 720p | llsr 1.5× | 1920x1080 | about 1.8× |
| T4, T5 | 1080p, 1440p | none (no supported factor) | — | everything |

3. **Denoise** has to come from somewhere other than VideoToolbox on this Mac. llsr itself "reduces coding artifacts", per Apple.

## Unverified

- The chained 360p case (llsr 2× then 1.5×). Its time, about 5.6 ms at p95, is the sum of two measured runs, and its image quality is untested.
- Behavior inside IINA, where decoding and gpu-next share the chip with llsr. If llsr runs on the Neural Engine, it competes less with the GPU. I haven't checked which unit it uses.
- Image quality. The clips are synthetic, so a real-footage comparison is still needed.
