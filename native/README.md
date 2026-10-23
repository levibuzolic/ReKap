# ReKap native

Native SwiftUI/AppKit screen recorder for **macOS 27+ on Apple silicon**. No
Electron, Node.js or plugin runtime is used by the native app. The original Kap
sources remain in the repository for reference during migration.

## Build and run

Requires Xcode 27 (including command line tools), Python 3, and Homebrew FFmpeg.

```sh
brew install ffmpeg
swift test --package-path native
native/scripts/build-app.sh
open native/build/ReKap.app
```

The build script creates a standalone ad-hoc signed app, including FFmpeg and its
non-system dynamic libraries. Running the packaged app is recommended so macOS
permissions belong to a stable app identity. Use `CONFIGURATION=debug` for a debug
bundle or `REKAP_APP_PATH=/absolute/path/ReKap.app` to change the output location.
The build process does not replace any installed application.
Quit the generated app before rebuilding it. Each ad-hoc build has a new signing
hash, so macOS may require screen recording permission to be granted again. A
stable developer signing identity is needed for a smoother ongoing release flow.

## Workflow

Use **New Recording** to choose a display, window or region. Region selection
supports dragging, dimensions in screen points and aspect presets. Press Return
or Use Region to accept; Escape cancels. Recording options include 30/60 fps,
cursor visibility, click highlighting, microphone device and system audio.
Window capture records audio from the selected window's app; display and region
capture can record system audio across apps.
Screen recording and optional microphone permissions are requested by macOS.
If denied, enable ReKap under System Settings → Privacy & Security, then retry.

Pause/resume or stop from the menu bar, main window or the global shortcut
(default Command-Shift-2; configurable in Settings). Paused time is excluded by
assembling finalized recording segments without re-encoding or dropping captured
frames. Original segments are retained for
recovery. Quitting during recording finalizes the recording first.

Choose a recording or open a video. Preview, trim, resize, set frame rate or mute
before exporting. Exports support GIF, APNG, H.264 MP4, HEVC MP4, VP9 WebM and AV1
MP4. GIF compression uses a reduced palette; it does not reproduce gifsicle's
exact byte output. Exports run sequentially, show progress, support cancellation,
and preserve existing destination/source files. Completed exports can be copied
as files, revealed in Finder, opened or opened with a chosen app.

History is stored in `~/Library/Application Support/ReKap/library.json`.
Recordings default to `~/Movies/ReKap/Session-UUID/`. On launch, session manifests
are scanned in current and previously selected recording folders for recovery;
unreadable segments are skipped and playable segments are assembled. Corrupt final
files are preserved separately when healthy segments can rebuild them. Corrupt
files cannot always be recovered. Removing history entries
does not delete videos. Imported files remain in their original locations.

## Tests and CI

`swift test --package-path native` discovers `Tests/ReKapCoreTests` through the
package test target. Tests cover history/settings, source preservation, region
bounds, capture state preconditions, segment assembly/recovery, all six real
export codecs, trim/resize/mute and cancellation/queue continuation. Media tests
require `ffmpeg` and `ffprobe`; missing tools fail rather than silently skip.

`.github/workflows/native-macos.yml` runs these tests, builds the app, validates
its signature and bundled encoder, and uploads the app on native/workflow changes.
It targets GitHub's `xcode-27` Apple silicon runner. Screen capture permission and
interactive UI behaviour require a logged-in desktop smoke test and are not
claimed as covered by headless CI.

## Distribution

Local builds use ad-hoc signing. Developer ID signing/notarization and public
release hosting are separate release steps requiring the distributor's identity.
Homebrew FFmpeg and some codecs/libraries use copyleft licenses; the bundle
includes available notices and a dependency manifest. Public redistribution also
requires the corresponding source and build materials for the exact bundled
versions. This app bundle is a local development deliverable, not a complete
public distribution package.
