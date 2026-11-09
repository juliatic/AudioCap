---
name: audiocap-release
description: Shipping an AudioCap build - archiving with xcodebuild, ad-hoc versus Developer ID signing, notarisation and stapling with notarytool, and versioning. Use when producing a build for anyone other than the developer's own Mac.
---

# AudioCap release

Nothing here has a CI job (plan decision 8); releases are cut by hand on a Mac.

## Versioning
- `MARKETING_VERSION` (user-facing, semver `X.Y.Z`) and `CURRENT_PROJECT_VERSION` (build number, always increasing) are set in `AudioCap/Config/Main.xcconfig`.
- Bump both in the release PR, tag the merge commit `vX.Y.Z`, and list changes in the GitHub release notes.

## Signing modes
| Mode | How | Good for | Caveats |
|------|-----|----------|---------|
| Ad-hoc | default `./start.sh` (`CODE_SIGN_IDENTITY=-`, no team), installed as `/Applications/AudioCap.app` | your own Mac | Gatekeeper blocks it on other Macs (quarantine); each rebuild has a new code hash, so macOS may ask for the audio-capture permission again |
| Development | `DEVELOPMENT_TEAM = <Team ID>` in git-ignored `AudioCap/Config/Local.xcconfig`; `./start.sh` picks it up | stable permission across rebuilds on your Macs | not distributable |
| Developer ID | Developer ID Application certificate + hardened runtime + notarisation | sharing with other people | needs a paid Apple Developer account |

Never commit the Team ID, certificates or notary credentials.

## Archive
```
timeout 1200 xcodebuild -project AudioCap.xcodeproj -scheme AudioCap -configuration Release \
  -archivePath build/AudioCap.xcarchive -destination 'generic/platform=macOS' archive
```
For an ad-hoc archive add `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`.

## Export for Developer ID
`build/ExportOptions.plist` (not committed):
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
```
```
timeout 600 xcodebuild -exportArchive -archivePath build/AudioCap.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export
```

## Notarise and staple
```
xcrun notarytool store-credentials AUDIOCAP_NOTARY --apple-id <apple id> --team-id <Team ID>   # once, stores in keychain
timeout 60 ditto -c -k --keepParent build/export/AudioCap.app build/AudioCap.zip
timeout 3600 xcrun notarytool submit build/AudioCap.zip --keychain-profile AUDIOCAP_NOTARY --wait
timeout 120 xcrun stapler staple build/export/AudioCap.app
timeout 60 spctl -a -vvv -t exec build/export/AudioCap.app    # expect: source=Notarized Developer ID
```
Zip the stapled app again for the GitHub release. If notarisation fails, read the log: `xcrun notarytool log <submission id> --keychain-profile AUDIOCAP_NOTARY`.

## Hi-Res driver (PR 6)
The `AudioCap Hi-Res` AudioServerPlugIn is a separate bundle installed into `/Library/Audio/Plug-Ins/HAL/`. A Developer ID release must sign and notarise it too; `./start.sh --install-driver` / `--uninstall-driver` handle local installs.
