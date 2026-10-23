# Contributing

Use macOS 27+ on Apple silicon with Xcode 27, Python 3 and Homebrew FFmpeg.
Build and test commands are in the [README](README.md).

The Swift package in `native/` contains the ReKap executable, the ReKapCore capture,
export and persistence code, and `Tests/ReKapCoreTests`. Keep behavioral regression
tests in that target so the native GitHub Actions workflow runs them. Tests use
generated media and require both ffmpeg and ffprobe.

For changes to capture, audio, permissions or UI, also test the packaged app in a
logged-in desktop session. Headless tests cannot grant macOS privacy permissions
or prove hardware capture. Build to a separate `REKAP_APP_PATH` when the current
app is running. Ad-hoc rebuilds may require a fresh privacy grant.

Before submitting, run the full suite, build the standalone app and check
`git diff --check`. Include the checks you ran and any remaining limitations.
Do not commit generated app bundles, build caches or personal recordings.
