# Native rewrite verification

Verified locally on 23 October 2026, macOS 27.0.1, Apple silicon, Xcode 27.1.
The scoped native implementation is complete and the packaged application has
passed local automated and permission-backed desktop verification.

## Automated evidence

- `swift test --package-path native`: **18 tests passed**, no compiler warnings.
  Four XCTest export tests plus fourteen Swift Testing capture, audio, editor and
  storage tests. Package discovery includes every file in `Tests/ReKapCoreTests`.
- All six formats encode, report their expected codecs/dimensions, preserve or
  mute audio as requested, and decode successfully. Tests also cover trim duration,
  queue continuation, cancellation, shutdown cleanup and source protection.
- Capture tests cover exact decoded-frame preservation for 60 fps and variable
  frame timing, pause segment assembly, corrupt-final rebuilding with damaged
  media preserved, recovery idempotence, invalid transitions and region bounds.
- An audio regression assembles two H.264/AAC segments containing mixed 440/880 Hz
  tones. All 120 decoded frames match their sources, both tones survive on either
  side of the join, audio remains non-silent across the join, and audio/video
  durations agree within 50 ms.
- Editor tests cover finite trim bounds, sub-frame clips and selecting an export
  frame rate that preserves variable-rate capture frames. Storage tests cover
  persistence, unreadable-index backups, removed-entry reconciliation and
  settings/recording-folder history.
- The four export tests also pass with `REKAP_FFMPEG` pointing at the **bundled**
  encoder and `REKAP_FFPROBE` pointing at the development probe.
- `native/scripts/build-app.sh`: release build succeeds, emits an arm64 executable
  and bundles FFmpeg plus nineteen relocated libraries. Encoder/filter capability
  checks pass. `codesign --verify --deep --strict` passes. The helper launches with
  an empty environment and only `/usr/bin:/bin` in PATH.
- Build helper Bash/Python syntax checks pass.
- `.github/workflows/native-macos.yml` invokes the complete suite, packages the
  app, reruns exports against the bundled encoder and uploads an artifact. It now
  runs on every PR, main push, version tag and manual dispatch, with workflow lint
  and diagnostic artifacts. Both remote CI runs for the original
  rewrite passed in [PR #1](https://github.com/levibuzolic/ReKap/pull/1), including
  tests, packaging, bundled-encoder validation and artifact upload.

## Repository cleanup verification

After removing the legacy implementation, all 18 tests passed using a fresh
Swift build directory. The cleaned release app builds at
`native/build/cleanup/ReKap.app`; signature verification and all four export
tests against its bundled encoder pass. The moved icon is byte-identical to the
original, and the app bundle includes the original MIT license. Build script
syntax, retained local Markdown links and `git diff --check` also pass. The cleanup
itself has not been pushed or run in remote CI.

The subsequent GitHub Actions migration passes local actionlint validation and
the full 18-test suite with report generation. Swift Testing emits a 14-test XML
report; the four XCTest export results are retained in the test log. The revised
workflow has not yet run remotely.

## Desktop evidence

These checks used the native UI and real screen/audio capture with the user's
permission. Test media stayed on this Mac.

- Display, individual-window and numeric/drag region selection worked. An external
  display region captured at 640×360; an internal Retina display captured at
  3024×1964; a 640×360-point Retina region captured at 1280×720.
- Pause/resume creates finalized segments and excludes paused time. In the final
  packaged build, a 60 fps Retina-region session produced 667 and 409 decoded
  source frames. The assembled 19.286667-second recording contains all 1,076
  frames; every decoded frame hash matches the concatenated original segments.
  ScreenCaptureKit delivers variable timing, so the configured 60 fps is a ceiling.
- Microphone-only window capture used the built-in MacBook Pro microphone with
  system audio disabled. The approximately 19.4-second paused/resumed recording
  has non-silent 48 kHz AAC audio; audio/video durations agree within 5 ms.
- System-audio-only display capture recorded a known locally played 880 Hz tone
  with microphone disabled. Frequency analysis confirmed the expected tone.
  Window capture's option is labelled Record app audio to reflect its scope.
- The editor opens saved recordings through a direct AppKit AVPlayerView wrapper.
  Preview, inspector and export controls fit the inspected window; all six formats
  are available. The final build exported a 1–3 second selection as a 320×180,
  60 fps H.264 MP4 of exactly 2.000 seconds, confirmed by ffprobe and decoding.
- Native file import loads the expected duration and dimensions. Recording history
  survives application relaunch and completed recordings reopen.
- Completed-export Open With launched the final MP4 in QuickTime Player.
  Copy followed by Paste Item in Finder produced a byte-identical MP4 (SHA-256
  checked). Show in Finder revealed and selected the expected exported file.
- The user verified Command-Shift-2 opens recording setup while another app has
  focus. Recording controls, preferences and the menu bar were exercised.
- Permission denial shows an actionable message and settings navigation. After
  refreshing the final ad-hoc build's screen permission, actual capture succeeded.
  The user manually approved microphone access and authenticated macOS prompts.

These desktop checks describe the rewrite's verified integration build. The
subsequent repository cleanup removes the Electron sources/tooling and unused
native code, and moves the app icon into native resources. It does not change
capture, audio or export behavior. Recording was stopped, audio options were off,
and the default capture rate was restored to 30 fps after testing.

## Deliverable and limits

`native/build/ReKap.app` is the standalone local development app. Build instructions
and scope are in the root `README.md`. Plugins are excluded by scope. The obsolete
Electron implementation and tooling have been removed; Git history preserves them.

This evidence covers the tested Mac and scenarios, not every display or audio
hardware combination. Local builds use ad-hoc signing; Developer ID signing,
notarization, redistribution materials and public release hosting remain separate
release steps. They are not represented as completed by these local checks.
