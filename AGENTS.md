# AGENTS.md

Canonical instructions for humans and for every AI coding tool working in this repository. `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.cursor/rules/agents.mdc` and `.windsurf/rules/agents.md` only point here. Task-specific playbooks live in [`.agents/skills/`](.agents/skills/).

## What AudioCap is

AudioCap is a macOS SwiftUI app that records the audio output of one chosen app (or, planned, the whole system) through **CoreAudio process taps** (macOS 14.4+), without loopback drivers. It writes a lossless capture and exports it to the format the user picks. It started as the upstream sample [insidegui/AudioCap](https://github.com/insidegui/AudioCap); this fork turns it into a reliable recorder. The approved roadmap is [`docs/planning/01_improvement_plan.md`](docs/planning/01_improvement_plan.md).

- App code: `AudioCap/` (`ProcessTap/ProcessTap.swift` holds `ProcessTap` and `ProcessTapRecorder`; views are `RootView`, `ProcessSelectionView`, `RecordingView`).
- Requirements: the process-tap API needs macOS 14.4+, but the app target currently sets `MACOSX_DEPLOYMENT_TARGET = 26.0`; keep README requirements in sync with it.
- Build settings: `AudioCap/Config/Main.xcconfig`; machine-only overrides (Team ID) in the git-ignored `AudioCap/Config/Local.xcconfig`.
- Tests: the `AudioCapTests` target (synthetic buffers; no tap, no permission needed).
- Fixtures: `test.wav` (220,500 frames) and `test.flac` (217,088 frames: the lost-final-block bug).

## Architecture map

Diagram: [`docs/img/architecture.svg`](docs/img/architecture.svg) (Spanish: [`architecture.es.svg`](docs/img/architecture.es.svg); edit both together).

1. **Source app** renders audio to its output device.
2. **Process tap** copies that app's output.
3. **Private aggregate device** exposes the tap as an input stream.
4. **IOProc** (CoreAudio IO queue) hands each buffer off.
5. **Serial writer** (only owner of the file) writes a **CAF** capture.
6. **Stop**: close the file, check frame count against the header.
7. **Export** to WAV Float32, FLAC 24-bit, ALAC or AAC 256, then a **duration check**.
8. Planned: **library + player**; **Hi-Res** virtual output device with a separate **monitor** on the real speakers.

| Stage | What it does | Status |
|-------|--------------|--------|
| Process tap | `CATapDescription` for the target process (`stereoMixdownOfProcesses`), `AudioHardwareCreateProcessTap` | shipped (upstream) |
| Aggregate device | private aggregate with the tap in `kAudioAggregateDeviceTapListKey`, clocked by the output device | shipped (upstream) |
| Format | read from the aggregate's input stream **after** it starts, validated, normalised to a canonical writer format | PR 1 |
| IOProc | `AudioDeviceCreateIOProcIDWithBlock`; copies the buffer into a preallocated ring and returns | PR 1 |
| Serial writer | one serial queue owns the `AVAudioFile`, writes CAF, closes it explicitly | PR 1 |
| Export | converter loop drains until `endOfStream`; output duration checked against the capture | PR 1 |
| Diagnostics | decoded OSStatus four-char codes, **Copy diagnostics** report | PR 1 |
| Auto-record ("Wait for sound", the default mode) | `AutoRecord/AutoRecordMachine` (pure, idle/armed/recording/closing): a take opens on the first buffer with RMS above −60 dBFS and starts with a 0.5 s pre-roll; RMS at or below the threshold for 2 s (configurable) closes it, keeping a 0.5 s tail, then re-arms. Stop disarms. Manual mode writes from the first buffer. | PR 3 |
| "All system audio" source | `AudioProcess.allSystemAudio` → `CATapDescription(stereoGlobalTapButExcludeProcesses:)` with AudioCap's own process object | PR 3 |
| Source list refresh for audio-only processes | `AudioProcessListMonitor` (CoreAudio process-list + is-running-output listeners, off the main actor, coalesced) | PR 3 |
| Library + player, level meter, output folder `~/Music/AudioCap`, Quality panel | | planned (PR 4) |
| Bilingual UI (String Catalog), ≥ 16 pt | | planned (PR 5) |
| Hi-Res mode: `AudioCap Hi-Res` virtual output device + monitor on the real speakers | | planned (PR 6) |

When a planned item lands, move it to "shipped" here in the same PR.

## Threading rules

- **The serial writer queue is the only owner of the file.** Only it creates, writes, closes and finalises the capture file. No other thread touches the `AVAudioFile` or its URL until the writer reports "closed".
- **The IO block (the CoreAudio IO queue) is real-time.** It may only copy the incoming `AudioBufferList` into storage that was allocated before `AudioDeviceStart`, and signal the writer. No allocation (no `AVAudioPCMBuffer` creation, no Swift arrays, no string formatting), no locks, no file or network I/O, no `DispatchQueue.sync`, no logging, no main-actor hops.
- **Stop order:** `AudioDeviceStop` → drain the hand-off buffer → `close()` the file on the writer queue → check frame count vs header → only then convert. Destroy the IOProc, aggregate device and tap afterwards.
- UI state is `@MainActor`; the writer posts progress and errors back to the main actor, never the IO block.
- Auto-record logic lives in `AutoRecordMachine` (pure; tests in `AutoRecordMachineTests`), not in `ProcessTapRecorder`. Its rings are allocated with the machine on the main actor before the format reaches the I/O path; `AudioRingBuffer.append` never allocates.

## Commands

Every command gets an explicit timeout. `timeout` comes from GNU coreutils (`brew install coreutils`); `start.sh` falls back to a Perl alarm when it is missing.

| Task | Command |
|------|---------|
| Build Release, install as `/Applications/AudioCap.app` (quits and replaces a running copy) and open it (the one launcher) | `./start.sh` |
| Build and install, do not open | `./start.sh --no-open` |
| Build into `./build` only, leave `/Applications` alone | `./start.sh --no-install` |
| Unit tests | `./start.sh --test` |
| Help | `./start.sh --help` |
| Raw build | `timeout 900 xcodebuild -project AudioCap.xcodeproj -scheme AudioCap -configuration Release -derivedDataPath build/DerivedData -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build` |
| Raw tests | `timeout 900 xcodebuild -project AudioCap.xcodeproj -scheme AudioCap -derivedDataPath build/DerivedData -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test` |
| One test | append `-only-testing:AudioCapTests/<TestClass>/<testMethod>` to the raw test command |
| Decode an OSStatus | `python3 -c 'import struct,sys; print(struct.pack(">i", int(sys.argv[1])))' 1718449215` |
| Header vs decoded duration | see [`audiocap-audio-quality`](.agents/skills/audiocap-audio-quality/SKILL.md) |

## Rules

- **Bilingual:** every user-facing string goes in the String Catalog with English and natural Spanish (not a word-for-word calque). `README.md` and `README.es.md` keep the same headings; the same goes for `docs/*.md` / `docs/*.es.md` pairs.
- **Readable UI:** body text is at least 16 pt.
- **One launcher:** `./start.sh` is the only entry point. Anything a user needs (build, tests, driver install) goes behind one of its options, never into a list of commands in a reply. macOS only: there is no `start.bat`.
- **Never claim untested behaviour.** Say what you ran and what you did not. Recording from a real app, the permission prompt and behaviour on the owner's macOS can only be checked on the owner's Mac.
- **Every PR body** separates "verified on a macOS build machine" from "only checkable on the owner's Mac" and ends with short numbered **On-device check** steps.
- **No personal names** in files, commits or PR bodies; describe roles ("the owner", "upstream").
- **English** commit messages, PR titles and PR bodies. PRs target `main`; branches are `devin/<timestamp>-<slug>`.
- **No CI workflows or jobs** (decision 8 of the plan).
- **Real screenshots** only (`docs/images/{en,es}/`); diagrams are real SVG, never ASCII art or Mermaid in the docs.
- **Every change updates `AGENTS.md` and the affected `.agents/skills/` in the same PR.**
- Never commit a Team ID, certificates or notarisation credentials; they go in `AudioCap/Config/Local.xcconfig` or the keychain.

## Gotchas

- **`1718449215` is `'fmt?'`** (`kAudioFormatUnsupportedDataFormatError`): the file or converter settings do not match the buffers. The upstream code read the tap format before the aggregate existed and only patched the sample rate. Read the format from the running aggregate, validate it, and include it in diagnostics.
- **`560947818` is `'!obj'`** (`kAudioHardwareBadObjectError`): the process object is gone (the app quit) or there is no usable output device.
- **Interleaved buffers expose only `floatChannelData[0]`.** Tap buffers are interleaved Float32; `floatChannelData[1]` does not exist. Index frames as `data[frame * channelCount + channel]`, or check `format.isInterleaved` first.
- **The final FLAC block gets lost** if the converter loop stops before `endOfStream`: `test.flac` is missing the last 3,412 frames (less than one 4,096-frame chunk). Always drain the converter, then compare frame counts.
- **Close the file before converting.** Converting (or letting a player read) a file that the writer has not closed yields a header that disagrees with the data, so players run past the displayed length.
- **A tap records at the rate the source app renders at, which is set by its output device.** A 96 kHz track played to a 48 kHz device (Bluetooth, most displays) is resampled before the tap sees it. Only Hi-Res mode (PR 6), which routes the system output to the `AudioCap Hi-Res` virtual device, avoids that.
- The tap sees audio **after** the app's volume, EQ, Sound Check and Spatial Audio, and `stereoMixdownOfProcesses` folds surround to stereo.
- `./start.sh` installs into `/Applications/AudioCap.app`: it quits a running AudioCap (Apple Event `quit`, 10 s, then `pkill -x AudioCap`), replaces the old copy only after a successful build, and asks once for sudo (or stops with a clear message) when `/Applications` is not writable.
- Changing the bundle id or ad-hoc re-signing can make macOS ask for the audio-capture permission again the first time the rebuilt app runs from `/Applications`. Reset it with `tccutil reset AudioCapture <bundle id>`.
- The upstream sandboxed build saves to `~/Library/Containers/codes.rambo.samplecode.AudioCap/Data/Library/Application Support/AudioCap`; the plan moves output to `~/Music/AudioCap` (PR 4).

## Skills

| Skill | Use it for |
|-------|-----------|
| [`audiocap-feature-workflow`](.agents/skills/audiocap-feature-workflow/SKILL.md) | plan → PR → merge order → on-device checks; owner preferences |
| [`audiocap-architecture`](.agents/skills/audiocap-architecture/SKILL.md) | tap / aggregate / IOProc lifecycle, format pipeline, gotchas |
| [`audiocap-verification`](.agents/skills/audiocap-verification/SKILL.md) | bounded build/test commands; what needs a real Mac |
| [`audiocap-audio-quality`](.agents/skills/audiocap-audio-quality/SKILL.md) | bit-perfect checklist, null test, duration check |
| [`audiocap-release`](.agents/skills/audiocap-release/SKILL.md) | archive, signing, notarisation, versioning |
