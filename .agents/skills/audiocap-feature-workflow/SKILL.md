---
name: audiocap-feature-workflow
description: How a change to AudioCap goes from plan to merged PR - numbered plans, PR order and integration, PR body format with on-device check steps, and the owner's standing preferences. Use before starting any feature or fix.
---

# AudioCap feature workflow

## 1. Plan
- Plans live in `docs/planning/NN_<slug>.md`, numbered in order, each with a `Status:` line (`proposed`, `approved`, `in progress`, `done`).
- Every open decision gets a recommended default; the default ships unless the owner changes it. Do not re-ask decided items.
- Mark findings **observed** (seen in code, files or a run) or **hypothesis** (needs a run on the owner's Mac).

## 2. Branch and PR
- Branch from `main`: `devin/<unix timestamp>-<slug>`. PRs target `main`.
- English commit messages, PR title and body. No personal names anywhere; say "the owner", "upstream".
- Keep a PR to one plan item. Update `AGENTS.md` and the affected `.agents/skills/*` in the same PR.
- No CI workflows or jobs. Verification is local (`./start.sh --test`) and on macOS build machines.

## 3. Merge order (plan section 5)
1. Wave 0: Xcode project as folder-synchronised groups, `AudioCapTests` target, `Local.xcconfig`, empty String Catalog. After it, new files do not touch `project.pbxproj`.
2. Wave 1 in parallel: PR 1 recording engine; PR 2 docs and AI instructions.
3. Wave 2 on top of PR 1: PR 3 auto-record + "All system audio"; PR 4 library, player, meter, output folder, Quality panel; PR 5 bilingual UI, 16 pt, accessibility, final screenshots; PR 6 Hi-Res mode.
4. Integration: one branch with every child merged; the owner merges only that one, with "Create a merge commit".

## 4. PR body template
```
## Summary
<what changed and why, with code names>

## Verified on a macOS build machine
- <command> → <result you saw>

## Only checkable on the owner's Mac
- permission prompt, real capture from Music/Spotify, behaviour on the owner's macOS version

## On-device check
1. ...
2. ...
```
Never list something under "verified" that you did not run. If a run failed, say so and paste the decoded error.

## 5. Owner preferences
- Spanish and English for UI and docs; Spanish must read naturally, not as a calque. Same headings in both READMEs.
- Body text ≥ 16 pt in the UI (`AppStyle`), contrast ≥ 4.5:1, every control reachable by keyboard and labelled for VoiceOver, controls locked while a recording, conversion or request runs. New UI strings go in `Localizable.xcstrings` (English + Spanish) in the same PR; add only your own keys to keep merges small.
- One launcher (`./start.sh`), zero manual steps.
- Real screenshots and real SVG diagrams; no placeholders, no ASCII art, no Mermaid.
- Maximum quality by default; be honest about where the signal is resampled or changed.
- Every command bounded by a timeout.
