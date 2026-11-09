---
name: audiocap-audio-quality
description: Proving AudioCap's recordings are bit-perfect and the right length - the bit-perfect checklist, a null test with ffmpeg or sox, and the header-versus-decoded duration check with ffprobe and afinfo. Use when changing capture, conversion or Hi-Res routing, and when the owner reports a quality or length problem.
---

# AudioCap audio quality

Tools: `ffmpeg`/`ffprobe` and optionally `sox` (`brew install ffmpeg sox`), `afinfo` (built into macOS). Bound every command with `timeout`.

## Bit-perfect checklist
A recording equals the source only when all of these hold:
- [ ] Output device (or `AudioCap Hi-Res` in Hi-Res mode) runs at the **source's sample rate** (Audio MIDI Setup or the Quality panel). Otherwise the app resamples before the tap.
- [ ] Source app volume at 100 %; EQ, Sound Check / normalisation, crossfade and Spatial Audio / Dolby Atmos off.
- [ ] Source is stereo (`stereoMixdownOfProcesses` folds surround down).
- [ ] Capture and export lossless: CAF Float32 → WAV Float32, FLAC 24-bit or ALAC. AAC is never bit-perfect.
- [ ] Source bit depth ≤ 24 (Float32 holds 16/24-bit integers exactly).
- [ ] System volume: expected not to matter (the tap is before the device); confirm with the null test.

In the app: the **Quality** panel shows the same checks (green "bit-perfect path" or yellow reasons), and the built-in player shows **Header**, **Decoded** and **Captured** lengths for each take; any difference is flagged.

## Null test
1. Make a reference with a sharp start (pink noise from sample 0), at the rate under test:
   ```
   timeout 60 ffmpeg -v error -y -f lavfi -i "anoisesrc=d=10:c=pink:r=96000:a=0.5" -ac 2 -c:a pcm_s24le ref.wav
   ```
   (sox: `timeout 60 sox -n -r 96000 -b 24 -c 2 ref.wav synth 10 pinknoise vol 0.5`)
2. Play `ref.wav` from the source app (Music: add the file, play it) and record it with AudioCap as WAV Float32 → `rec.wav`.
3. Align: strip the recording's leading digital silence.
   ```
   timeout 120 ffmpeg -v error -y -i rec.wav -af "silenceremove=start_periods=1:start_threshold=0:start_silence=0" -c:a pcm_f32le rec_aligned.wav
   ```
4. Subtract and measure the residual:
   ```
   timeout 120 ffmpeg -hide_banner -i rec_aligned.wav -i ref.wav -filter_complex "[0:a]aformat=sample_fmts=flt[a];[1:a]aformat=sample_fmts=flt,volume=-1:precision=float[inv];[a][inv]amix=inputs=2:normalize=0:duration=shortest,astats=measure_overall=Peak_level+RMS_level:measure_perchannel=none" -f null - 2>&1 | grep -E "Peak level|RMS level"
   ```
   sox alternative (trim to the reference length in samples first):
   ```
   timeout 120 sox rec_aligned.wav -b 32 -e floating-point a.wav trim 0 960000s
   timeout 120 sox -m -v 1 a.wav -v -1 ref.wav -b 32 -e floating-point diff.wav
   timeout 60 sox diff.wav -n stats 2>&1 | grep -E "Pk lev dB|RMS lev dB"
   ```
5. Read the result: **`-inf` dB = bit-perfect**. Anything around −100 dB or louder means the path changed the samples (resampling typically gives −20 to −40 dB; gain changes give a residual that follows the music). A residual that sounds like the full signal usually means misalignment: check that step 3 removed only silence.

Checked on a build machine with synthetic files: an exactly delayed copy gives `-inf` with both ffmpeg and sox; a 96 → 48 → 96 kHz round trip gives about −23 dB peak.

## Duration check (header vs decoded)
Players trust the header. A file is healthy only when the header frame count equals the number of frames that actually decode.
```
f=recording.flac
timeout 30 ffprobe -v error -show_entries stream=sample_rate,duration_ts,duration -of default=nw=1 "$f"   # header
timeout 30 afinfo "$f" | grep -E "estimated duration|audio packets|Data format"                           # Apple's view
echo decoded_frames=$(( $(timeout 120 ffmpeg -v error -i "$f" -map 0:a:0 -ac 1 -f f32le - | wc -c) / 4 ))
```
`duration_ts` (frames) must equal `decoded_frames`, and both must equal the capture's frame count. Fixtures: `test.wav` → 220,500 / 220,500; `test.flac` → 217,088 / 217,088, i.e. consistent with itself but 3,412 frames shorter than its source (the lost final block). An empty capture shows `duration=N/A` and 0 decoded frames.
