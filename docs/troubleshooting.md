# Troubleshooting

[Español](troubleshooting.es.md) · [README](../README.md)

## Decode an error number

CoreAudio and AVFoundation errors are four-character codes packed into a 32-bit number. Decode any of them with:

```
python3 -c 'import struct,sys; print(struct.pack(">i", int(sys.argv[1])))' 1718449215
```

| Number | Code | Meaning | What to do |
|--------|------|---------|------------|
| `1718449215` | `'fmt?'` | Unsupported data format: the file or converter settings do not match the audio buffers. This is the error in the original report ("Wav recording error … error 1718449215"). | Update to the build with the new recording engine (PR 1), which reads the format from the running device. If it still happens, use **Copy diagnostics** and attach the report to an issue. |
| `560947818` | `'!obj'` | Bad audio object: the process you picked has quit, or the Mac has no usable output device. Seen as "Process tap creation failed with error 560947818" and "Error reading data size for uid /glob/main: 560947818". | Start playback in the source app, pick it again from the list, and check that an output device exists in System Settings → Sound. |
| `560227702` | `'!dev'` | Bad device: the aggregate or output device disappeared. | Stop, reconnect the output (Bluetooth, display), start again. |
| `2003332927` | `'who?'` | Unknown property: the device does not support what was asked. | Report it with diagnostics; include your macOS version. |
| `1852797029` | `'nope'` | Illegal operation for this device or state. | Stop and start the recording again. |
| `561211770` | `'!siz'` | Wrong property size. | Report it with diagnostics. |
| `1937010544` | `'stop'` | The device is not running. | Start playback in the source app and start again. |
| `2003329396` | `'what'` | Unspecified CoreAudio error. | Report it with diagnostics. |

## Permission

AudioCap needs **System Audio Recording** permission. On first use macOS shows "“AudioCap” would like access to record your system audio." Click **Allow**. macOS may also ask for microphone access when you start a recording.

If you clicked **Don't Allow**, or the prompt never appears:

1. Open System Settings → Privacy & Security → Screen & System Audio Recording, and enable AudioCap under "System Audio Recording Only".
2. Or reset the decision in Terminal and launch the app again, so the prompt comes back:
   ```
   tccutil reset AudioCapture codes.rambo.samplecode.AudioCap
   ```
   After the bundle-id change in the plan, the id is `io.github.juliatic.AudioCap`.

Ad-hoc builds (the default `./start.sh` build without a Team ID) get a new signature on every rebuild, so macOS can ask again after you rebuild. Putting your Team ID in `AudioCap/Config/Local.xcconfig` (`DEVELOPMENT_TEAM = XXXXXXXXXX`) keeps the permission across rebuilds.

## Where recordings are saved

- **Current build:** inside the app's sandbox container, which Finder hides:
  `~/Library/Containers/codes.rambo.samplecode.AudioCap/Data/Library/Application Support/AudioCap`
  Open it from Terminal with `open ~/Library/Containers/codes.rambo.samplecode.AudioCap/Data/Library/Application\ Support/AudioCap`.
- **Planned (PR 4):** `~/Music/AudioCap` by default, changeable with a folder picker, plus **Show in Finder** in the library.

## The recording is empty or has the wrong length

- A WAV of exactly 4,096 bytes with no duration contains only a header: no audio reached the file. This is what the original engine produces when it cannot build its buffers (the log says "Failed to create PCM buffer"). The new engine reports that as an error instead.
- If players keep playing after the shown length, or a FLAC ends early, compare the header and decoded durations as described in [`.agents/skills/audiocap-audio-quality/SKILL.md`](../.agents/skills/audiocap-audio-quality/SKILL.md#duration-check-header-vs-decoded).

## The recording is not at the source's quality

A process tap records at the rate the source app plays at, which is set by your output device. Bluetooth headphones and most displays run at 48 kHz, so a 96 kHz track arrives already resampled. See "Recording quality" in the [README](../README.md#recording-quality).

## Collecting logs

```
log show --last 10m --style compact --predicate 'process == "AudioCap"'
```
