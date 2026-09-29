# Camera admission deadline review (2026-09-28)

Source measurement: `mjpeg/reports/ov5640/ddr3_parallel_raw_t64_20260927_2343`.
No board access by this reviewer. TIM1, descriptor timestamps, capture RTL and engine RTL were correlated.

## Evidence

- 161 valid complete frames, zero aborted frames, zero camera FIFO overflows, zero encoder input-wait ticks.
- Descriptor SOF timestamp spacing is 3,333,113/114 core clocks (33.33113/14 ms at 100 MHz), or exactly twice that when one camera frame is skipped.
- All 19 observed skipped-next-frame events have previous-frame `total_ticks >= 3,249,514`.
- All 141 consecutive accepted-next-frame events have previous-frame `total_ticks <= 3,249,460`.
- Those sets do not overlap. Pair-by-pair evidence is in `camera_admission_deadline_pairs.csv`.
- `feed_ticks` is always 3,224,101/102; the largest total is 3,250,868. Merely comparing this total with the SOF period therefore misses the real deadline.

## Cause and timing meaning

`mjpeg_board_test_engine` starts TIM1 on `input_frame = source_valid && s_ready && source_sof`, after the raw Bayer demosaic. It ends total timing on the transported descriptor's final word. Its admission output additionally requires PSEND, table/camera readiness, `!busy`, no STOP, and no pending quality change.

The old `ov5640_dvp_capture` samples the synchronized admission request exactly once on camera VSYNC falling. It never reconsiders the admission when the previous frame completes later in the front porch. VSYNC falling precedes the measured first decoded pixel, so the effective deadline is earlier than the next pixel SOF.

The observed boundary is between 32.49460 and 32.49514 ms after the previous processed pixel SOF: approximately 0.83624 ms earlier than the next processed SOF. The configured sensor line is HTS=2240 with measured PCLK about75 MHz; 28 lines are 0.8362667 ms, agreeing within the inferred boundary. Demosaic itself delays output by one row plus a column. This is strong phase evidence, but the report does not directly timestamp VSYNC/HREF; the precise 27-row front porch is inferred rather than directly sampled.

`busy` correctly includes a still-active final DDR transaction. TIM1 ends at the descriptor and does not explicitly measure final DDR commit / busy release. It must not be redefined as proof of the next VSYNC admission. Nevertheless the clean cutoff around transported total timing accounts for all 19 skips here; the report alone cannot separately measure a smaller DDR tail.

## Implemented behavior

- New capture parameter `ADMIT_AT_HREF=0` preserves old tops' behavior.
- Only `davinci_mjpeg_ddr3_top` enables `ADMIT_AT_HREF(1)`.
- VSYNC falling clears coordinates and arms an admission pending flag. The first active HREF byte takes exactly one synchronized admission decision. If still unavailable, the entire frame is rejected and cannot be joined on a later row.
- Accepted RAW byte zero enters the FIFO on that very decision edge; accepted YUV first byte is latched on that edge and the next byte completes pixel zero. Pixel/marker tests verify no shift or missing byte.
- Once admitted, subsequent enable deassertion cannot interrupt the frame. STOP before the first HREF rejects that frame. Existing fault flush/ACK protection remains in place; an armed frame without HREF expires at the next VSYNC rise.
- Newly added state and decision logic stay local to PCLK; existing two-stage admission/ACK and capture-active synchronization remain unchanged.

This moves the admission decision about27 lines /0.8064 ms later for the current raw profile, while preserving the one-row demosaic latency. It does not bypass `busy`, DDR commit, STOP or quality guards, and does not require a full-frame buffer.

## Verification

Legacy six capture modes and asynchronous FIFO reset/flush regression: PASS. New HREF six capture modes: PASS (both YUV orders, both sample edges, RAW8 on both edges). These include late availability in porch, rejection when unavailable at byte zero, no mid-frame joining, porch STOP, byte-zero/marker preservation, random consumer stalls, overflow flush, malformed-line abort and next-frame recovery. Existing complete real-camera pipeline: PASS (three golden JPEG byte matches and independent decodes, intentional abort, STOP framing). HREF-enabled complete real-camera integration from a temporary TB copy also PASS: three golden JPEG byte matches and independent decodes, intentional short-line abort/recovery and STOP framing. Production RTL remains frozen. HREF report files are under `work/ddr3_20260928/href_admission_sim/`; legacy reports remain under `mjpeg/reports/mjpeg_board_test/simulation_camera_capture/` and `simulation_real_camera/`.


## Repository runner verification

The formal HREF integration is now reproducible from the repository root:

```powershell
.\mjpeg\scripts\run_real_camera_sim.ps1 -AdmitAtHref 1
```

The runner defaults to `-AdmitAtHref 0`, keeps its previous report directory unchanged, and selects TB `ADMIT_AT_HREF` through `xelab --generic_top`. The formal run on 2026-09-28 passed. This directory holds its capture, logs, PASS marker, `simulation_configuration.json`, and independently generated `real_camera_evidence.json`: three golden JPEG byte matches and decodes, intentional short-line abort/recovery, active-frame STOP and random downstream stalls. The archived cutoff CSV/review above describe the pre-fix physical measurement and are retained as diagnosis evidence; the small simulation is not a physical FPS benchmark.
