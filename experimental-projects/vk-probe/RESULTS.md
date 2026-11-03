# vk-probe results

Measured on 2026-11-02 on an Apple M1 Pro running macOS 27.2, on AC power with Low Power Mode off. The software was Homebrew mpv 0.41.0, libplacebo 7.387.0 and MoltenVK 1.4.2, with `--vo=gpu-next --gpu-api=vulkan --hwdec=videotoolbox`, in full screen at 3456x2160.

## Source

YouTube video `F-789R8Eptc` (an LG OLED demo). It was downloaded as YouTube's own HDR10 versions (VP9 Profile 2, 10-bit, PQ, BT.2020, 59.94 fps) at 240p, 360p, 480p, 720p, 1080p, 1440p and 2160p. These are real web encodes, not copies made by our scripts. All versions decode in hardware (`hwdec=videotoolbox`).

## Method

- **HDR output:** `--target-colorspace-hint=yes`. Without it, mpv on macOS converts HDR to SDR (gamma 2.2, BT.709, 203 nits). With it, mpv outputs PQ, BT.2020, 1100 nits. IINA must set this option.
- **Speed:** a 20 s playback from 40 s, which is about 1200 frames. A chain passes when its dropped frames stay near the baseline's count. The baseline drops 5–23 frames, and those drops come from the switch to full screen.
- **Quality:** screenshots of the rendered window at 31, 46 and 116 s in the first run, and at 46 s in the HDR run. The reference is a screenshot of the 2160p version at the same time, through the same pipeline. The table gives SSIM, where 1.0 means identical, and PSNR in dB, where higher is closer.
- **Chains:** see `chains.sh`. "fast" means the final scaler is `lanczos` instead of `ewa_lanczos4sharpest`. Every chain except the baseline adds `CfL_Prediction` for chroma.

## Results with HDR output (`lg-hdr`)

| Source | Chain | avg ms | Dropped | SSIM | PSNR |
|---|---|---|---|---|---|
| 240p | baseline | 9.0 | 6 | 0.8538 | 26.82 |
| 240p | **ArtCNN_C4F32_DS fast** | 11.0 | 1 | **0.8587** | **27.04** |
| 360p | baseline | 9.0 | 23 | 0.8748 | 28.47 |
| 360p | **ArtCNN_C4F16_DS fast** | 8.6 | 12 | **0.8814** | **28.77** |
| 360p | ArtCNN_C4F32_DS fast | 14.1 | 221 (fail) | 0.8821 | 28.82 |
| 480p | baseline | 9.3 | 21 | 0.8955 | 29.70 |
| 480p | **ArtCNN_C4F16_DS fast** | 9.4 | 2 | **0.9029** | **30.10** |
| 480p | ArtCNN_C4F32_DS fast | 20.8 | 576 (fail) | 0.9034 | 30.12 |
| 720p | baseline | 9.7 | 9 | 0.9296 | 32.16 |
| 720p | **ArtCNN_C4F16_DS fast** | 13.8 | 14 | **0.9360** | **32.85** |
| 720p | ArtCNN_C4F16_DS (EWA final) | 16.8 | 261 (fail) | 0.9362 | 32.84 |
| 1080p | **baseline** | 10.2 | 6 | 0.9551 | 34.50 |
| 1080p | ravu-zoom-ar-r3 | 14.0 | 25 (borderline) | 0.9560 | 34.67 |
| 1080p | ArtCNN_C4F16_DS fast | 22.0 | 533 (fail) | 0.9586 | 35.24 |
| 1440p | **baseline** | 11.1 | 5 | 0.9737 | 36.85 |
| 1440p | ravu-zoom-ar-r3 | 15.1 | 65 (fail) | 0.9734 | 36.93 |

`results/lg.tsv` and `results/lg-means.tsv` hold the full first run: 9 chains, with SDR output and 3 screenshots each. It ranks the chains the same way.

## Tier mapping for the plugin (60 fps, HDR)

| Tier | Chain |
|---|---|
| 240p | `ArtCNN_C4F32_DS` + CfL, final `lanczos` |
| 360p–720p | `ArtCNN_C4F16_DS` + CfL, final `lanczos` |
| 1080p, 1440p | built-in scaling only (`ewa_lanczos4sharpest`) |

## Conclusions

1. **ArtCNN on Vulkan beats the built-in scaler at every size up to 720p.** The gain is +0.006 to +0.007 SSIM and +0.2 to +0.7 dB. Side-by-side crops show sharper edges and small text.
2. **The cheaper final scaler is what makes 60 fps possible.** `lanczos` instead of `ewa_lanczos4sharpest` costs at most 0.0003 SSIM. It saves 3–4 ms, and that moves 720p from 261 dropped frames to 14.
3. **The larger model (C4F32) fits only at 240p at 60 fps.** At 30 fps it would probably also fit at 360p (14.1 ms), but I did not test that.
4. **At 1080p and 1440p, no shader chain passes with a meaningful gain.** The final fit there is only 1.5–2×.
5. **ArtCNN is trained on anime.** On this live-action footage it still scores best of all the shaders. FSRCNNX equals it on PSNR but drops frames from 480p up (first run).

## Unverified

- **VideoToolbox's low-latency scaler isn't compared.** It can't run inside mpv, so comparing it needs the planned FFmpeg filter or a frame dump from `vt-probe`.
- **Only one source, and a bright, staged demo.** Grainy or dark footage may rank the chains differently.
- **Frame timing at 120 Hz in IINA isn't tested.** These runs used the display's mode at the time, and mpv chose the timing.
- **Some FSRCNNX timings in the first run are implausible:** its 240p total is lower than the baseline's. Its dropped-frame counts are the reliable signal.
