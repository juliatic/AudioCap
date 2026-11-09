---
name: audiocap-verification
description: How to verify an AudioCap change - bounded xcodebuild build and test commands, the launcher checks, how to drive the app on a macOS build machine, and which checks only a real Mac with the permission granted and real playback can do. Use before claiming anything works and when writing a PR body.
---

# AudioCap verification

Every command below has an explicit timeout. On macOS, `timeout` comes from GNU coreutils (`brew install coreutils`).

## On any macOS build machine
| Check | Command | Pass |
|-------|---------|------|
| Launcher help | `timeout 30 ./start.sh --help` | usage text, exit 0 |
| Build + install + open | `timeout 1200 ./start.sh` | exit 0; `/Applications/AudioCap.app` is new and the running process is `/Applications/AudioCap.app/Contents/MacOS/AudioCap` |
| Replace a running copy | run `timeout 1200 ./start.sh` again while the app is open | exit 0; "Quitting the AudioCap that is running"; new PID and new binary inode |
| Build + install, no launch | `timeout 1200 ./start.sh --no-open` | exit 0 |
| Build only | `timeout 1200 ./start.sh --no-install` | exit 0; `build/AudioCap.app` exists, `/Applications` unchanged |
| Failed build leaves `/Applications` alone | `AUDIOCAP_BUILD_TIMEOUT=3 timeout 60 ./start.sh` after moving `build/DerivedData` aside | non-zero exit, installed binary inode unchanged |
| Non-writable install dir | `AUDIOCAP_INSTALL_DIR=<root-owned dir> timeout 1200 ./start.sh --no-open </dev/null` | uses sudo if it needs no password, otherwise a clear error and the old copy is kept |
| Unit tests | `timeout 1200 ./start.sh --test` | exit 0; exit 3 means the checkout has no `AudioCapTests` target |
| Raw tests | `timeout 900 xcodebuild -project AudioCap.xcodeproj -scheme AudioCap -derivedDataPath build/DerivedData -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test` | `** TEST SUCCEEDED **` |
| One test | add `-only-testing:AudioCapTests/<Class>/<method>` | |
| Fixture durations | see `audiocap-audio-quality` | header frames = decoded frames |

Unit tests use synthetic buffers (writer, converter, durations, FLAC bit-exact round trip, silence detector, auto-arm state machine). They need no tap and no permission, so they run anywhere.

`start.sh` timeouts can be raised with `AUDIOCAP_BUILD_TIMEOUT` / `AUDIOCAP_TEST_TIMEOUT` (seconds).

## Driving the app on a headless build machine
- A VM without an audio output device makes the tap fail with `'!obj'` (`560947818`). A virtual output (for example BlackHole on a throwaway VM) gives the system a device; do not change audio devices on a machine other projects use.
- Play a known file with `timeout 30 afplay <file> &` and pick `afplay` in the process list.
- The process list refreshes on its own when CoreAudio's process list or a process's output state changes (`AudioProcessListMonitor`), so a freshly started `afplay` appears in the picker within a fraction of a second.
- Auto-record ("Wait for sound") check: Start with nothing playing (orange "Waiting for sound…", no take), play two 2 s tones about 5 s apart. Expect two completed takes, each about 0.5 s lead + 2 s tone + 0.5 s tail, and the waiting label back after each.
- Each ad-hoc rebuild installed into `/Applications` (and the bundle-id change) can bring the audio-capture permission prompt back on first launch.
- Show the permission prompt again: `tccutil reset AudioCapture <bundle id>` (`codes.rambo.samplecode.AudioCap` upstream, `io.github.juliatic.AudioCap` after the bundle-id change). Starting a recording may also trigger the microphone prompt.
- App logs: `timeout 30 log show --last 5m --style compact --predicate 'process == "AudioCap"'`.
- Check the result file with the duration check in `audiocap-audio-quality`; a 4,096-byte WAV with `duration=N/A` is an empty file (header only).
- Screenshots: `screencapture -x -o -l <windowID> out.png` for a single window.

## Only on the owner's Mac
- The audio-capture permission prompt and the flow after "Allow" on the owner's macOS version.
- Real capture from Music, Spotify or a browser, including Bluetooth and display outputs.
- The `'fmt?'` (`1718449215`) reproduction on the owner's newer macOS.
- The null test with a real lossless source (bit-perfect path) and Hi-Res mode with a monitor.

Put these under "Only checkable on the owner's Mac" in the PR body, and end the body with numbered **On-device check** steps.
