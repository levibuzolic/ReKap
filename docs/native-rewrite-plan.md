# Native ReKap implementation plan

## Scope and completion criteria

Build a standalone Apple silicon macOS 27+ application using SwiftUI, AppKit,
ScreenCaptureKit and AVFoundation. No Electron, Node runtime or plugins. Preserve
region/window/display selection, 30/60 fps, cursor/click options, microphone input,
pause/resume, global shortcut, preview/trim/resize/FPS/mute, GIF/APNG/H.264/HEVC/
WebM/AV1 export, cancellable progress, clipboard/open-with, recording history and
interrupted-recording recovery. System audio is an additional built-in option.

Completion requires a reproducible .app build, automated behavioural and media
integration tests, launch/UI verification, and an actual capture-to-export smoke
test. Any OS permission or signing limitation must be reported explicitly rather
than counted as a passing verification. A local ad-hoc signed build is distinct
from Developer ID notarized public distribution.

## Architecture

- `native/Package.swift`: Swift package with testable ReKapCore library and ReKap
  executable. Deployment target macOS 27; packaged binary arm64 only.
- ReKapCore models: shared recording, capture and export values.
- Capture engine: ScreenCaptureKit content enumeration, display/region/window
  capture, native microphone/system audio, recording state machine. Pause uses
  finalized segments and resume starts a fresh segment; final assembly removes
  paused time. Persist a session manifest before writing media for recovery.
- Selection UI: native AppKit drag overlay, explicit screen/window choices,
  numeric region dimensions and aspect presets.
- Export engine: bundled FFmpeg, explicit argument arrays, capability checking,
  progress parsing, cancellation and atomic output delivery. Retain codec tools
  rather than reimplement codecs; package their runtime libraries and licenses.
- Editor: AVPlayer preview, bounded trim controls, linked dimensions, FPS, mute,
  format/loop/compression options and export queue with native destination actions.
- App shell: shared observable state, native menu bar, main library, preferences,
  persistent settings, global shortcut, file import and recovery UI.
- Build: script emits an ad-hoc signed .app with usage descriptions and all tools.
  CI builds/tests on a supported macOS/Xcode runner, including media export probes.

## Parallel work and ownership

1. Capture task owns `ReKapCore/Capture*`, `ReKapCore/Region*` and capture tests.
   Deliver content selection, capture lifecycle, segment assembly and recovery.
2. Export task owns `ReKapCore/Export*`, export tests and encoder bundling helper.
   Deliver six real formats, validation, queue progress and cancellation.
3. Editor task owns `ReKap/Editor*`. Deliver native preview/edit/export UI against
   the shared core models and export engine.
4. Integration task owns package, app shell, history/settings, menu bar/shortcut,
   application packaging, docs and CI. Integrate continuously and perform end-to-
   end verification. Shared API changes are coordinated before editing.

## Implementation sequence

1. Establish common models, package and build contracts.
2. Implement capture/export/editor independently while building shell and storage.
3. Compile together; fix isolation, lifecycle and API integration failures.
4. Run lasting tests through CI: settings/history/recovery, export argument and
   validation contracts, real synthetic-media exports, cancellation and capture
   state/geometry where possible without prompting for permissions.
5. Package and launch; inspect native UI, import a generated clip, exercise editor,
   run actual display/region/window capture and pause/resume if permissions allow.
6. Resolve failures, document build/run instructions and exact verification status.

## Risks to validate

Retina point-to-pixel mapping, multi-display origins, selection overlays excluded
from recording, screen permission denial/revocation, microphone denial, recording
finalization races, stop during pause, audio continuity, cancelled exports leaving
partial files, interrupted sessions, external codec dependencies and malformed
or unsupported imported media. Avoid automatic deletion of user source media.

## Completion

Implemented the scoped native app and completed local verification on 23 October
2026. The standalone arm64 app is at `native/build/ReKap.app`. All 18 automated
tests pass; bundled-encoder export tests pass for all six formats. Actual display,
window and Retina region capture, pause/resume, microphone/system audio, editing,
export and destination actions were exercised. The user confirmed the global
shortcut from another app. See `native/VERIFICATION.md` for exact evidence and
release limitations. CI is configured; no remote run or public release is claimed.
