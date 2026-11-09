# AudioCap: improvement plan

Status: approved by the owner (sections 1–6, defaults as listed). Delivery in progress through PRs 1–6 and an integration branch; see section 5.

All findings come from reading the code and inspecting the committed `test.wav` / `test.flac`. Nothing has been run on a Mac yet. Each item is marked **observed** (seen in code or files) or **hypothesis** (still needs a run on your Mac).

---

## 1. What is broken and why

| # | Symptom | Cause | Kind |
|---|---------|-------|------|
| 1 | WAV start fails with `error 1718449215` | That number is the four-char code `'fmt?'` (unsupported data format). In `ProcessTapRecorder.start()` the only call that returns this kind of NSError is `AVAudioFile(forWriting:settings:…)`. Its settings come from the tap format. `ProcessTap.prepare` reads that format **before** the aggregate device exists, then replaces only its sample rate with the aggregate's rate. | observed (code path) |
| 1b | Why it started after the OS update | Likely candidates: the new OS reports an incomplete or different tap format at that moment (0 channels, other flags or layout), or the file settings no longer match the buffer layout. | **hypothesis** |
| 2 | FLAC is shorter than the recording | `test.wav` has 220,500 frames (5.000 s). The STREAMINFO block in `test.flac` says 217,088 (4.923 s). The last 3,412 frames are missing, which is less than one 4,096-frame FLAC block, so the final block is never flushed. | observed (fixtures) |
| 3 | External players keep playing after the shown length ends | The WAV file is only closed when the object is released (`currentFile = nil` on the main thread). The CoreAudio I/O queue writes to the same file with no lock and may still hold a reference. Conversion then starts without waiting for the file to close. A header written before the last data matches what you saw: the header promises less audio than the file contains. | observed (race) / effect is a hypothesis |
| 4 | FLAC quality | The FLAC settings set no bit depth, so the encoder picks one. The source is Float32. | observed |
| 5 | Auto-split | `SilenceDetector` reads `floatChannelData[1]`, but the tap buffers are interleaved, where only `[0]` exists. That gives a wrong RMS and can crash. After a split, the rest of the silence goes into the next file. | observed |
| 6 | Device changes | The aggregate device stays bound to the output that was the default at start (connecting AirPods, for example). Nothing happens when the source app quits (`handleInvalidation` is empty). | observed |
| 7 | Where files go | Files are hidden in `~/Library/Containers/codes.rambo.samplecode.AudioCap/Data/Library/Application Support/AudioCap`. | observed |

**The fix (PR 1):**
- One serial writer owns the file.
- Stop happens in this order: `AudioDeviceStop`, drain the queue, explicit `close()`, check the frame count against the header, then convert.
- The converter loop flushes until `endOfStream`.
- Every output file gets a duration check, and any mismatch shows up as an error in the app.
- The format is read from the aggregate's input stream **after** it starts, then validated and normalised into a canonical writer format.
- If the OS still rejects the format, the app shows the decoded error and a **Copy diagnostics** button. The report includes the OS build, output device, tap format, aggregate rate and file settings. That way the next round works from data, not guesses.

---

## 2. Is it recording "raw" quality?

Mostly, but not always.

A process tap records the app's output **after the app's own processing**, as 32-bit float, at the rate of the aggregate device. The default output device sets that clock.

- **Bit depth: OK.** Float32 holds 16- and 24-bit integer audio exactly. WAV is stored as Float32, so nothing is lost.
- **Sample rate: depends on the output device.** Say the source is 96 kHz lossless and the output device runs at 48 kHz. The audio is resampled before AudioCap sees it, either by the app or by CoreAudio, plus drift compensation. The recording is only bit-exact when the **device rate equals the source rate**. So today the device does matter, but only through its sample-rate setting.
- **Channels:** `stereoMixdownOfProcesses` folds 5.1 and Atmos down to stereo.
- **Source app settings:** an app volume below 100 %, EQ, Sound Check / normalisation and Spatial Audio all change the samples.
- **System volume:** expected not to affect the tap, because the tap sits before the device. This still needs to be checked with the null test below.

**Proposal:**
- A **Quality** panel shows the tap, device and file formats.
- A green badge reads "bit-perfect path". A yellow one names the problem, for example "resampled to 48 kHz", "downmixed to stereo" or "app volume < 100 %".
- An optional **Match output device rate** button sets the device's nominal rate and restores it when you stop.
- A `audiocap-audio-quality` skill describes a **null test**: play a known lossless file, record it, line both up, subtract one from the other. The residual should be silence when the path is bit-perfect.

### 2b. Hi-Res mode: full source quality on any speakers (owner requirement)

Requirement: always record at the full quality the source app puts out, even when the speakers you listen on (Bluetooth, the display's speakers) cannot play it. Those speakers stay as a listen-only monitor.

**Why a tap alone cannot do it:** a normal app (Music, Spotify, a browser) renders its audio at the sample rate of the device it plays to. A tap only sees what the app sends. So with Bluetooth (48 kHz at most) or a 48 kHz display as the output, the audio is already resampled inside the app before AudioCap sees it. Bluetooth codec compression (AAC/SBC) happens after the tap, so it never reaches the file; the sample rate is the only real limit. This is how CoreAudio works for typical apps. The Quality panel will confirm it on the real Mac.

**Design:**
1. **Virtual output device.** `AudioCap Hi-Res` is our own CoreAudio driver (AudioServerPlugIn), based on Apple's NullAudio sample. It is stereo, Float32, supports 44.1 / 48 / 88.2 / 96 / 176.4 / 192 kHz, and plays no sound itself.
2. **Routing while recording.** When Hi-Res mode is on, AudioCap remembers the current system output, makes `AudioCap Hi-Res` the system output and builds the tap aggregate clocked by the virtual device. The source app then renders at the virtual device's rate, and the tap records it unchanged.
3. **Monitor.** A separate engine plays the tapped audio on the remembered real device (Bluetooth, display or built-in), with a volume slider and a mute button. Only this copy is resampled.
4. **Restore.** The previous output device is restored on stop, on quit, after a crash (checked at next launch) and when the virtual device disappears.
5. **Rate policy (decision 10):**
   - **Match the source:** for Music.app, AudioCap reads the current track's sample rate through AppleScript (needs the Automation permission once) and sets the virtual device to it before the track starts. That gives a bit-perfect file at the source's own rate. Other apps, or when the rate is unknown, fall back to the fixed rate below.
   - **Fixed rate:** 96 kHz by default, configurable up to 192 kHz. Nothing above that rate is lost. Sources at 44.1/48 kHz are upsampled, which is transparent in practice but not bit-identical.
6. **Install.** `./start.sh` builds the driver, copies it to `/Library/Audio/Plug-Ins/HAL/` (asks for the admin password **once**) and restarts the audio server. `./start.sh --uninstall-driver` removes it. Nothing else on the system is changed.
7. **Diagnostics.** The Quality panel shows "source app → 96 kHz (Hi-Res) → file 96 kHz / 32-bit float → monitor: Bluetooth 48 kHz", with a green "bit-perfect" badge only when the rates match end to end.

**Alternative (decision 11):** use the free BlackHole driver (GPL-3.0, separate install) instead of our own. It is less code, but you install and update it by hand, and its rate is set in Audio MIDI Setup.

**Verification:** the driver and routing are built and unit-tested on a macOS Devin machine where possible. The real check runs on your Mac with the `audiocap-audio-quality` null test: play a 96 kHz test file through Music, record it in Hi-Res mode while monitoring on Bluetooth, and confirm the file is 96 kHz with a residual of silence. These steps are part of PR 6.

---

## 3. Features

| ID | Feature | Recommended default |
|----|---------|---------------------|
| F1 | **Auto-record on sound.** A "Wait for sound" mode arms the tap without writing anything. The first buffer above the threshold opens a file, with a 0.5 s pre-roll ring buffer so the first note is not cut. Silence of N seconds or more closes the file (trailing silence trimmed) and re-arms. Stop disarms. | Default mode is Auto, **−60 dBFS for 2 s** (a stopped player gives digital silence; −40 can cut quiet classical passages) |
| F2 | **Recordings library + player.** Each take shows source app, date, duration, format, rate/bit depth and peak level. Status is recording / converting % / done / failed with reason. The built-in player has play/pause, a scrub bar and a waveform, and shows the **decoded duration next to the header duration** so a length bug is visible at once. Also: Show in Finder, rename, move to Trash, retry conversion, and a live level meter while recording. The index is JSON in Application Support. | on |
| F3 | **Output folder.** Default `~/Music/AudioCap` (`assets.music.read-write` entitlement), changeable with a folder picker that remembers access (security-scoped bookmark). | `~/Music/AudioCap` |
| F4 | **Formats.** Capture goes to a crash-safe **CAF** file first, so a crash or forced quit never leaves a file with the wrong length. On stop it is exported to: WAV Float32 ("raw"), **FLAC 24-bit**, ALAC (lossless, Apple Music friendly), or AAC 256 kbps labelled "lossy". Every export goes through one tracked conversion path. | WAV raw; CAF intermediate |
| F5 | **Robustness.** When the default output device changes, the app rebuilds the aggregate and continues, or starts a new file if the format changed. When the source app quits or relaunches, it re-arms. It also handles sleep/wake. | on |
| F6 | **Diagnostics.** Every error shows its decoded OSStatus four-char code, plus a Copy diagnostics button and structured logs. | on |
| F7 | **Bilingual UI (es/en)** through a String Catalog, following the system language. Body text ≥ 16 pt. | on |
| F8 | **"All system audio"** entry (everything except AudioCap) next to the per-app list. | on |
| F9 | Name tracks from Now Playing (Music/Spotify through AppleScript, which needs the Automation permission) | **later round, not in this plan** |

---

## 4. Repo knowledge, docs, skills (AI-tool-neutral)

- **`AGENTS.md`** is canonical: what the app is, an architecture map, threading rules (who owns the file, what runs on the I/O queue), commands with timeouts, rules, process and gotchas (`'fmt?'`, interleaved buffers, the 4,096-frame FLAC flush).
- **Pointer files:** `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.cursor/rules/agents.mdc`, `.windsurf/rules/agents.md`.
- **Skills** in `.agents/skills/`:
  - `audiocap-feature-workflow`: plan → PR → merge order → on-device checks, plus owner preferences.
  - `audiocap-architecture`: the tap / aggregate / IOProc lifecycle, the format pipeline and gotchas.
  - `audiocap-verification`: `xcodebuild` build/test with timeouts, and what needs a real Mac with the permission granted.
  - `audiocap-audio-quality`: the bit-perfect checklist, null test, and duration check with `ffprobe`.
  - `audiocap-release`: archive, signing, ad-hoc or notarised builds, versioning.
- **README:** `README.md` + `README.es.md` with the same headings, real screenshots in `docs/images/{en,es}/`, and `docs/img/architecture.svg` (a real SVG graphic).
- **Other docs:**
  - `docs/troubleshooting{,.es}.md`: error codes and the permission reset.
  - `docs/coreaudio-taps.md`: the upstream API notes, kept with credit.
  - `docs/planning/NN_*.md`: numbered plans.
- **Launcher:** `start.sh` builds with `xcodebuild` and opens the app, and `start.sh --test` runs the tests. **macOS only, no `start.bat`**: process taps are a macOS CoreAudio API, so there is nothing to run on Windows or Linux.
- **Tests:** a new `AudioCapTests` target covers the writer, the converter, duration, a bit-exact FLAC round trip, the silence detector and the auto-arm state machine. It uses synthetic buffers, so it needs no tap and no permission.
- **CI:** none by default. Hosted macOS minutes cost 10×, and self-host-you has no macOS runner.
- **Identity:**
  - Bundle id changes from `codes.rambo.samplecode.AudioCap` to `io.github.juliatic.AudioCap`. This asks for the permission once more and starts a new container, which is fine because files move to `~/Music/AudioCap`.
  - Your Team ID goes in a git-ignored `AudioCap/Config/Local.xcconfig` and is never committed.
- **Upstream sponsor banner:** moved into a Credits section that links to insidegui/AudioCap (MIT licence kept).

---

## 5. Delivery

All PRs target `main`. English commits, titles and bodies.

- **Wave 0 (parent, small):** convert the Xcode project to folder-synchronised groups (Xcode 16+ format), add the test target, `Local.xcconfig` and an empty String Catalog. After this, new files never touch `project.pbxproj`, so parallel PRs do not conflict there.
- **Wave 1 (parallel):**
  - **PR 1, Recording engine:** section 1 fixes, CAF intermediate, FLAC 24-bit / ALAC, diagnostics, device changes, tests.
  - **PR 2, Docs and AI instructions:** section 4, minus screenshots of screens that don't exist yet.
- **Wave 2 (parallel, on top of PR 1):**
  - **PR 3:** Auto-record (F1) and the "All system audio" entry (F8).
  - **PR 4:** Library + player + level meter + output folder + Quality panel (F2, F3, section 2).
  - **PR 5:** Bilingual UI + 16 pt + accessibility pass (F7), then final README screenshots in both languages.
  - **PR 6, Hi-Res mode (section 2b):** virtual device driver, routing and restore, monitor output, rate policy, `start.sh` driver install/uninstall, null-test skill steps. It builds on PR 1. Its Quality-panel badge plugs into PR 4.
- **Integration:** an integration branch with every child merged. You merge only that one, with "Create a merge commit".

**Where the work runs:** child sessions on **macOS Devin machines**, so each PR is built and unit-tested with `xcodebuild`. Recording from a real app (permission prompt, actual playback) and the `'fmt?'` repro on your new OS can only be checked on your Mac. Each PR therefore ends with short on-device check steps, and PR 1 adds the Copy diagnostics report for that case.

## 6. Decisions (defaults ship; reply only to change one)

1. Auto mode default threshold: **−60 dBFS / 2 s**.
2. Output folder: **~/Music/AudioCap**.
3. Capture to **CAF**, export to the chosen format.
4. Formats: **WAV Float32, FLAC 24-bit, ALAC, AAC 256 (lossy)**.
5. Bundle id: **io.github.juliatic.AudioCap**, with the Team ID in a git-ignored xcconfig.
6. "Match output device rate" is a **button only**, never automatic, and the rate is restored on stop.
7. Track names from Now Playing: **later round**.
8. CI: **none**. Local `./start.sh --test` plus macOS child sessions.
9. Children on **macOS Devin machines**.
10. Hi-Res rate policy: **match the source when known (Music.app), otherwise a fixed 96 kHz** (configurable up to 192 kHz).
11. Virtual device: **our own `AudioCap Hi-Res` driver**, installed by `start.sh`, rather than BlackHole.
12. Hi-Res mode **on by default** once the driver is installed. It switches the system output only while recording, always restores it, and can be turned off in Settings.
