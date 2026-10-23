# ReKap

Native SwiftUI/AppKit screen recorder for **macOS 27+ on Apple silicon**. No
Electron, Node.js or plugin runtime is used by the native app. ReKap is a native
rewrite of [Kap](https://github.com/wulkano/kap); the original
MIT copyright notice is retained in [LICENSE.md](LICENSE.md).

## Build and run

Requires Xcode 27 (including command line tools), Python 3, and Homebrew FFmpeg.

```sh
brew install ffmpeg
swift test --package-path native
native/scripts/build-app.sh
open native/build/ReKap.app
```

The implementation, tests, resources and packaging scripts live in `native/`.

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
frames. Original segments are retained for recovery. Quitting during recording
finalizes the recording first.

Choose a recording or open a video. Preview, trim, resize, set frame rate or mute
before exporting. Exports support GIF, APNG, H.264 MP4, HEVC MP4, VP9 WebM and AV1
MP4. The smaller GIF option uses a reduced palette. Exports run sequentially,
show progress, support cancellation,
and preserve existing destination/source files. Completed exports can be copied
as files, revealed in Finder, opened or opened with a chosen app.

History is stored in `~/Library/Application Support/ReKap/library.json`.
Recordings default to `~/Movies/ReKap/Session-UUID/`. On launch, session manifests
are scanned in current and previously selected recording folders for recovery;
unreadable segments are skipped and playable segments are assembled. Corrupt final
files are preserved separately when healthy segments can rebuild them. Corrupt
files cannot always be recovered. Removing history entries does not delete videos.
Imported files remain in their original locations.

## Tests and CI

`swift test --package-path native` discovers `Tests/ReKapCoreTests` through the
package test target. Tests cover history/settings, source preservation, region
bounds, capture state preconditions, segment assembly/recovery, all six real
export codecs, trim/resize/mute and cancellation/queue continuation. Media tests
require `ffmpeg` and `ffprobe`; missing tools fail rather than silently skip.

GitHub Actions is the sole CI provider. The [CI workflow](.github/workflows/native-macos.yml)
runs on every pull request, pushes to main, version tags (`v*`) and manual dispatch.
It lints workflows, checks packaging scripts and app metadata, runs the full test
suite, builds the app, and validates its signature, resources and bundled encoder. Successful runs
upload the app ZIP; test reports and build logs are retained even on failure.
New commits cancel superseded PR runs. There are no path filters that could leave
a required check pending on a documentation-only PR.
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

See [verification evidence](native/VERIFICATION.md), [contributing](contributing.md)
and [privacy](PRIVACY.md).
