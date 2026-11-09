---
name: audiocap-architecture
description: AudioCap's CoreAudio process-tap pipeline - tap, private aggregate device and IOProc lifecycle, the serial writer and CAF capture, the format pipeline from tap to export, Hi-Res routing, and the known gotchas. Use when touching ProcessTap.swift or anything that records or converts audio.
---

# AudioCap architecture

Diagram: [`docs/img/architecture.svg`](../../../docs/img/architecture.svg). Upstream API notes: [`docs/coreaudio-taps.md`](../../../docs/coreaudio-taps.md).

## Lifecycle (start)
1. PID → `AudioObjectID` with `kAudioHardwarePropertyTranslatePIDToProcessObject`. "All system audio" (PR 3) uses a global tap instead.
2. `CATapDescription(stereoMixdownOfProcesses: [objectID])`, keep its `uuid`; `AudioHardwareCreateProcessTap` → tap ID.
3. Aggregate description: private (`kAudioAggregateDeviceIsPrivateKey`), tap list `[[kAudioSubTapUIDKey: uuid]]`, main sub-device = the clock device (default output today; `AudioCap Hi-Res` in Hi-Res mode). `AudioHardwareCreateAggregateDevice`.
4. Preallocate the hand-off storage, then `AudioDeviceCreateIOProcIDWithBlock` and `AudioDeviceStart`.
5. Read the **aggregate's input stream format** once it runs (`kAudioStreamPropertyVirtualFormat` on the input stream; cross-check `kAudioTapPropertyFormat`). Validate: Float32, packed, channel count > 0, sample rate > 0, interleaving known. Build the writer format from it; never patch a copy of an earlier format.
6. The serial writer opens a CAF file with exactly that format.

## Lifecycle (stop)
`AudioDeviceStop` → drain the hand-off → writer `close()` → check written frames against the file header → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap` → convert → duration check on the output.

Invalidation (source app quits, device disappears, default output changes) runs the same stop path and reports why.

## Threads
| Context | Allowed |
|---------|---------|
| IO block | copy `AudioBufferList` into preallocated storage, update an atomic counter, signal. Nothing else: no allocation, locks, I/O, logging, main-actor hops. |
| Writer queue (serial) | owns the `AVAudioFile`: create, write, close. Computes levels for the meter/auto-record from what it wrote. |
| Converter (background) | reads the closed CAF, writes the export, drains to `endOfStream`. |
| Main actor | UI state, start/stop requests, error display. |

## Format pipeline
tap (Float32, interleaved, aggregate rate) → CAF capture (same format, lossless) → export:
- WAV: Float32 (lossless copy of the capture)
- FLAC: 24-bit integer (Float32 holds 24-bit sources exactly; values beyond ±1.0 would clip)
- ALAC: 24-bit
- AAC: 256 kbps (lossy)

## Rate and quality
- The tap records at the rate the source app renders at, which is the rate of the device it plays to. Bluetooth and most displays run at 48 kHz, so a 96 kHz track is resampled before the tap.
- Hi-Res mode (PR 6): make `AudioCap Hi-Res` (AudioServerPlugIn, 44.1–192 kHz, silent) the system output while recording, clock the aggregate from it, and play a separate monitor copy on the remembered real device. Restore the previous output on stop, quit, crash (checked at next launch) and device loss. Rate policy: match the Music.app track rate when known, otherwise fixed 96 kHz.

## Gotchas
- `1718449215` = `'fmt?'` (unsupported data format): settings and buffers disagree.
- `560947818` = `'!obj'`: process object gone or no usable output device.
- Interleaved buffers expose only `floatChannelData[0]`; channel `c` of frame `f` is at `[f * channels + c]`. The upstream `SilenceDetector` indexed `floatChannelData[ch]`.
- The upstream converter dropped the final partial block (`test.flac`: 3,412 frames short of `test.wav`). Drain until `endOfStream`.
- The file must be closed before conversion or playback, otherwise the header disagrees with the data.
- `stereoMixdownOfProcesses` folds surround to stereo; app volume, EQ, Sound Check and Spatial Audio happen before the tap.

## Library, player and quality (PR 4)
| File | Role |
|------|------|
| `Library/RecordingLibrary.swift` | `@MainActor` index of `LibraryEntry`; `observe(recorder)` consumes `takeEvents()`; status changes go through `LibraryEntry.Status.canTransition` (a late progress event never undoes "done"); saves `library.json` on state changes, not on every progress tick. Busy takes at launch become "failed" with a retry hint. |
| `Library/AudioFileInspector.swift` | reads a file back: header frames, decoded frames, WAV/CAF payload frames from the bytes on disk, peak, waveform bins. |
| `Library/OutputFolder.swift` | default `~/Music/AudioCap`, picked folder via security-scoped bookmark. A new folder applies to the next recorder (`ProcessSelectionView` recreates an idle one). |
| `Quality/QualityAssessment.swift` | pure logic: `QualityPath` in, issues (yellow) and notes out; bit-perfect only with no issues. |
| `Quality/QualityPanel.swift` | `QualityPathBuilder` reads `ProcessTap` diagnostics every 2 s; view and localized texts. |
| `Quality/DeviceRateMatcher.swift` | explicit "Match output device rate"; restores the previous rate. |

Extension point for Hi-Res (PR 6): implement `QualityPathContributor`, register it with `QualityPathContributors.register(_:)`, and set `path.clock?.isVirtualHiRes`, `path.monitor` or append `path.notes`. Don't special-case Hi-Res inside `QualityAssessment`.

